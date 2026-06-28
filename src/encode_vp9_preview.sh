#!/usr/bin/env bash
# 将剪辑成片的前 N 秒重编码为 VP9/WebM，用于本地检查拼接处是否卡顿（类似 YouTube 二次转码）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_METADATA="${SCRIPT_DIR}/processMatadata.json"
DEFAULT_DURATION=60

DURATION="${DEFAULT_DURATION}"
INPUT=""
OUTPUT=""
METADATA=""

die() {
  echo "错误: $*" >&2
  exit 1
}

# videoPath：相对 workspace 根目录（如 src），`.` 表示脚本目录，或绝对路径
resolve_video_path() {
  local p="$1"
  if [[ -z "${p}" || "${p}" == "." ]]; then
    echo "${SCRIPT_DIR}"
  elif [[ "${p}" != /* ]]; then
    local workspace_root
    workspace_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    echo "$(cd "${workspace_root}/${p}" && pwd)"
  else
    echo "${p}"
  fi
}

usage() {
  cat <<EOF
用法: encode_vp9_preview.sh [选项] [输入视频]

将视频前 N 秒重编码为 VP9（WebM），便于检查标题 (~18s)、地图 (~26s) 等拼接点是否卡顿。

选项:
  -d, --duration SEC   截取时长（秒），默认 ${DEFAULT_DURATION}
  -o, --output PATH    输出 WebM 路径（默认同目录 \${basename}_vp9_\${N}s.webm）
  -m, --metadata JSON  从 processMatadata.json 读取剪辑输出（output/distName.mp4）
  -h, --help           显示此帮助

示例:
  encode_vp9_preview.sh -m processMatadata.json
  encode_vp9_preview.sh ./成片.mp4
  encode_vp9_preview.sh -d 90 -o /tmp/test.webm ./成片.mp4
EOF
}

find_ffmpeg() {
  local candidate
  for candidate in \
    "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg" \
    "/usr/local/opt/ffmpeg-full/bin/ffmpeg"; do
    [[ -x "${candidate}" ]] || continue
    echo "${candidate}"
    return 0
  done
  candidate="$(command -v ffmpeg 2>/dev/null || true)"
  [[ -n "${candidate}" && -x "${candidate}" ]] && echo "${candidate}"
}

resolve_input_from_metadata() {
  local meta="$1"
  [[ -f "${meta}" ]] || die "找不到元数据: ${meta}"
  eval "$(python3 - "${meta}" <<'PY'
import json, shlex, sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

video_path = data.get("videoPath", "").strip()
dist_name = data.get("distName", "").strip()
if not video_path or not dist_name:
    sys.exit("videoPath 或 distName 为空")

print(f"VIDEO_PATH={shlex.quote(video_path)}")
print(f"DIST_NAME={shlex.quote(dist_name)}")
PY
)"
  VIDEO_PATH="$(resolve_video_path "${VIDEO_PATH}")"
  INPUT="${SCRIPT_DIR}/output/${DIST_NAME}.mp4"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--duration)
      [[ $# -ge 2 ]] || die "--duration 需要秒数"
      DURATION="$2"
      shift 2
      ;;
    -o|--output)
      [[ $# -ge 2 ]] || die "--output 需要路径"
      OUTPUT="$2"
      shift 2
      ;;
    -m|--metadata)
      [[ $# -ge 2 ]] || die "--metadata 需要 JSON 路径"
      METADATA="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*) die "未知选项: $1（使用 --help 查看用法）" ;;
    *)
      [[ -z "${INPUT}" ]] || die "只能指定一个输入文件"
      INPUT="$1"
      shift
      ;;
  esac
done

if [[ -n "${METADATA}" ]]; then
  [[ -z "${INPUT}" ]] || die "不能同时指定输入文件与 --metadata"
  resolve_input_from_metadata "${METADATA}"
elif [[ -z "${INPUT}" && -f "${DEFAULT_METADATA}" ]]; then
  resolve_input_from_metadata "${DEFAULT_METADATA}"
fi

[[ -n "${INPUT}" ]] || { usage; exit 1; }
[[ -f "${INPUT}" ]] || die "输入文件不存在: ${INPUT}"

if ! awk -v d="${DURATION}" 'BEGIN { exit (d > 0) ? 0 : 1 }'; then
  die "时长必须大于 0: ${DURATION}"
fi

FFMPEG="$(find_ffmpeg)" || die "未找到 ffmpeg，请安装: brew install ffmpeg-full"
FFPROBE="$(dirname "${FFMPEG}")/ffprobe"
[[ -x "${FFPROBE}" ]] || FFPROBE="$(command -v ffprobe)" || die "未找到 ffprobe"

INPUT_DIR="$(cd "$(dirname "${INPUT}")" && pwd)"
INPUT_BASE="$(basename "${INPUT}")"
INPUT_STEM="${INPUT_BASE%.*}"

if [[ -z "${OUTPUT}" ]]; then
  OUTPUT="${INPUT_DIR}/${INPUT_STEM}_vp9_${DURATION}s.webm"
fi

SOURCE_DURATION="$("${FFPROBE}" -v error -show_entries format=duration -of csv=p=0 "${INPUT}")"
[[ -n "${SOURCE_DURATION}" ]] || die "无法读取视频时长"

ENCODE_DURATION="${DURATION}"
if awk -v src="${SOURCE_DURATION}" -v want="${DURATION}" 'BEGIN { exit (src < want) ? 0 : 1 }'; then
  ENCODE_DURATION="${SOURCE_DURATION}"
  echo "源视频仅 ${SOURCE_DURATION}s，将编码全部时长"
fi

eval "$(python3 - "${FFPROBE}" "${INPUT}" <<'PY'
import json, shlex, subprocess, sys

ffprobe, path = sys.argv[1], sys.argv[2]
raw = subprocess.check_output(
    [
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate,pix_fmt",
        "-of", "json", path,
    ],
    text=True,
)
stream = json.loads(raw)["streams"][0]
width = stream.get("width", "")
height = stream.get("height", "")
r_fps = stream.get("r_frame_rate", "60/1")
pix_fmt = stream.get("pix_fmt", "")

def fps_value(rate: str) -> str:
    rate = (rate or "").strip()
    if not rate or rate == "0/0":
        return "60"
    if "/" in rate:
        num, den = rate.split("/", 1)
        try:
            n, d = float(num), float(den)
            if d:
                val = n / d
                if abs(val - round(val)) < 0.001:
                    return str(int(round(val)))
                if abs(val - 60000 / 1001) < 0.02:
                    return "60000/1001"
                return f"{val:.6g}"
        except ValueError:
            pass
    return rate

fps = fps_value(r_fps)
print(f"VIDEO_WIDTH={shlex.quote(str(width))}")
print(f"VIDEO_HEIGHT={shlex.quote(str(height))}")
print(f"OUTPUT_FPS={shlex.quote(fps)}")
print(f"PIX_FMT={shlex.quote(pix_fmt)}")
PY
)"

HAS_AUDIO=0
if "${FFPROBE}" -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "${INPUT}" >/dev/null 2>&1; then
  HAS_AUDIO=1
fi

# 60fps 下 GOP=120 ≈ 2 秒，便于观察拼接点附近解码是否异常
GOP="$(awk -v fps="${OUTPUT_FPS}" 'BEGIN {
  if (fps ~ /^\//) { print 120; exit }
  split(fps, a, "/")
  if (length(a) == 2 && a[2] > 0) { v = a[1] / a[2] } else { v = fps + 0 }
  if (v <= 0) v = 60
  g = int(v * 2 + 0.5)
  if (g < 30) g = 30
  print g
}')"

echo "输入:   ${INPUT}"
echo "输出:   ${OUTPUT}"
echo "范围:   0 ~ ${ENCODE_DURATION}s"
echo "视频:   ${VIDEO_WIDTH}x${VIDEO_HEIGHT} ${OUTPUT_FPS}fps (${PIX_FMT}) → VP9 (libvpx-vp9, CRF 32, GOP ${GOP})"
echo "提示:   重点拖到 ~18s（标题拼接）、~26s（地图嵌入）检查是否卡顿"
echo "编码中（4K VP9 较慢，请耐心等待）..."

AUDIO_ARGS=( -an )
if [[ "${HAS_AUDIO}" -eq 1 ]]; then
  AUDIO_ARGS=( -c:a libopus -b:a 128k )
fi

"${FFMPEG}" -hide_banner -y \
  -i "${INPUT}" \
  -t "${ENCODE_DURATION}" \
  -map 0:v:0 \
  -map "0:a:0?" \
  -c:v libvpx-vp9 \
  -crf 32 \
  -b:v 0 \
  -row-mt 1 \
  -tile-columns 2 \
  -tile-rows 1 \
  -g "${GOP}" \
  -keyint_min "${GOP}" \
  -deadline good \
  -cpu-used 4 \
  -fps_mode cfr \
  -r "${OUTPUT_FPS}" \
  -pix_fmt yuv420p \
  "${AUDIO_ARGS[@]}" \
  -avoid_negative_ts make_zero \
  "${OUTPUT}"

echo "完成: ${OUTPUT}"
echo "播放: open \"${OUTPUT}\""
