#!/usr/bin/env bash
# 视频剪辑：MOV → MP4，distName 命名，标题淡入淡出渲染（仅重编码 18 秒片段）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
METADATA="${SCRIPT_DIR}/processMatadata.json"

# 标题时间轴（秒）：6s 后开始，6s 淡入 + 6s 显示 + 6s 淡出
TITLE_START=6
FADE_IN=6
DISPLAY=6
FADE_OUT=6
TITLE_DURATION=$((FADE_IN + DISPLAY + FADE_OUT))
TITLE_END=$((TITLE_START + TITLE_DURATION))

FONT_FILE="${SCRIPT_DIR}/fonts/Noto_Sans_SC/static/NotoSansSC-Medium.ttf"
[[ -f "${FONT_FILE}" ]] || FONT_FILE="${SCRIPT_DIR}/fonts/Noto_Sans_SC/static/NotoSansSC-Regular.ttf"

die() {
  echo "错误: $*" >&2
  exit 1
}

[[ -f "${FONT_FILE}" ]] || die "找不到开源字体 Noto Sans SC，请检查 src/fonts 目录"

command -v ffmpeg >/dev/null 2>&1 || die "未找到 ffmpeg，请先安装: brew install ffmpeg"
command -v ffprobe >/dev/null 2>&1 || die "未找到 ffprobe，请先安装: brew install ffmpeg"
command -v swift >/dev/null 2>&1 || die "未找到 swift（macOS 自带）"

[[ -f "${METADATA}" ]] || die "找不到元数据文件: ${METADATA}"

eval "$(python3 - "${METADATA}" <<'PY'
import json, shlex, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)

for key, var_name in (
    ("srcName", "SRC_NAME"),
    ("distName", "DIST_NAME"),
    ("title", "TITLE"),
    ("videoPath", "VIDEO_PATH"),
):
    value = data.get(key, "").strip()
    if not value:
        sys.exit(f"{key} 为空")
    print(f"{var_name}={shlex.quote(value)}")
PY
)"

INPUT_MOV="${VIDEO_PATH}/${SRC_NAME}"
[[ -f "${INPUT_MOV}" ]] || die "输入文件不存在: ${INPUT_MOV}"
[[ "${INPUT_MOV##*.}" =~ ^[Mm][Oo][Vv]$ ]] || die "输入文件必须是 MOV 格式: ${INPUT_MOV}"

OUTPUT_MP4="${VIDEO_PATH}/${DIST_NAME}.mp4"
[[ ! -f "${OUTPUT_MP4}" ]] || die "输出文件已存在，请先删除或重命名: ${OUTPUT_MP4}"

DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${INPUT_MOV}")"
[[ -n "${DURATION}" ]] || die "无法读取视频时长"

VIDEO_CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "${INPUT_MOV}")"
case "${VIDEO_CODEC}" in
  hevc|h265) ENCODER="hevc_videotoolbox" ;;
  *)         ENCODER="h264_videotoolbox" ;;
esac

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/media-cut.XXXXXX")"
cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT

PARTS=()
DURATION_GT() { awk -v a="$1" -v b="$2" 'BEGIN { exit (a > b) ? 0 : 1 }'; }

# 片头：0 ~ TITLE_START，流复制
if DURATION_GT "${DURATION}" 0 && [[ "${TITLE_START}" -gt 0 ]]; then
  HEAD_DURATION="${TITLE_START}"
  if ! DURATION_GT "${DURATION}" "${TITLE_START}"; then
    HEAD_DURATION="${DURATION}"
  fi
  echo "提取片头 0 ~ ${HEAD_DURATION}s（流复制）..."
  ffmpeg -hide_banner -y -i "${INPUT_MOV}" -t "${HEAD_DURATION}" \
    -map 0:v:0 -map 0:a:0? \
    -c copy -avoid_negative_ts make_zero -reset_timestamps 1 \
    "${TMPDIR}/part_head.mp4"
  PARTS+=("${TMPDIR}/part_head.mp4")
fi

# 标题段：TITLE_START ~ TITLE_END，仅重编码此 18 秒
if DURATION_GT "${DURATION}" "${TITLE_START}"; then
  REMAIN="$(awk -v d="${DURATION}" -v s="${TITLE_START}" 'BEGIN { print d - s }')"
  MID_DURATION="${TITLE_DURATION}"
  if ! awk -v r="${REMAIN}" -v t="${TITLE_DURATION}" 'BEGIN { exit (r >= t) ? 0 : 1 }'; then
    MID_DURATION="${REMAIN}"
  fi

  VIDEO_HEIGHT="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "${INPUT_MOV}")"
  FONT_SIZE="$(awk -v h="${VIDEO_HEIGHT}" 'BEGIN { printf "%d", h / 18 }')"
  TITLE_PNG="${TMPDIR}/title.png"

  echo "生成标题图片..."
  swift "${SCRIPT_DIR}/render_title.swift" "${FONT_FILE}" "${TITLE}" "${TITLE_PNG}" "${FONT_SIZE}"

  FILTER="[1:v]format=rgba,fade=t=in:st=0:d=${FADE_IN}:alpha=1,fade=t=out:st=$((FADE_IN + DISPLAY)):d=${FADE_OUT}:alpha=1[ov];[0:v][ov]overlay=(W-w)/2:(H-h)/2:format=auto,format=yuv420p"

  echo "渲染标题段 ${TITLE_START} ~ $((TITLE_START + MID_DURATION))s（${ENCODER}，仅 ${MID_DURATION}s）..."
  ffmpeg -hide_banner -y \
    -hwaccel videotoolbox \
    -ss "${TITLE_START}" -to "$((TITLE_START + MID_DURATION))" -i "${INPUT_MOV}" \
    -loop 1 -framerate 60 -t "${MID_DURATION}" -i "${TITLE_PNG}" \
    -filter_complex "${FILTER}" \
    -map 0:v:0 -map 0:a:0? \
    -t "${MID_DURATION}" \
    -c:v "${ENCODER}" -b:v 12M \
    -c:a copy \
    -avoid_negative_ts make_zero -reset_timestamps 1 \
    "${TMPDIR}/part_title.mp4"
  PARTS+=("${TMPDIR}/part_title.mp4")
fi

# 片尾：TITLE_END ~ 结束，流复制
if DURATION_GT "${DURATION}" "${TITLE_END}"; then
  echo "提取片尾 ${TITLE_END}s ~ 结束（流复制，约 $(awk -v d="${DURATION}" -v e="${TITLE_END}" 'BEGIN { printf "%.0f", d - e }')s）..."
  ffmpeg -hide_banner -y -ss "${TITLE_END}" -i "${INPUT_MOV}" \
    -map 0:v:0 -map 0:a:0? \
    -c copy -avoid_negative_ts make_zero -reset_timestamps 1 \
    "${TMPDIR}/part_tail.mp4"
  PARTS+=("${TMPDIR}/part_tail.mp4")
fi

[[ ${#PARTS[@]} -gt 0 ]] || die "未生成任何片段，请检查视频时长"

if [[ ${#PARTS[@]} -eq 1 ]]; then
  cp "${PARTS[0]}" "${OUTPUT_MP4}"
else
  CONCAT_LIST="${TMPDIR}/concat.txt"
  : > "${CONCAT_LIST}"
  for part in "${PARTS[@]}"; do
    printf "file '%s'\n" "${part}" >> "${CONCAT_LIST}"
  done
  echo "合并 ${#PARTS[@]} 个片段..."
  ffmpeg -hide_banner -y -f concat -safe 0 -i "${CONCAT_LIST}" \
    -c copy -movflags +faststart \
    "${OUTPUT_MP4}"
fi

echo "完成: ${OUTPUT_MP4}"
