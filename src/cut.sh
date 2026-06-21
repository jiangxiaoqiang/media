#!/usr/bin/env bash
# 视频剪辑：MOV → MP4，distName 命名，标题淡入淡出（PNG + fade）
# step 4：26s 起嵌入 Google 地图动画 movie.mov
# 仅重编码片头+标题+缓冲（约 27s，一次编码），片尾流复制；地图段局部重编码
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METADATA="${SCRIPT_DIR}/processMatadata.json"

# 标题时间轴（秒）：6s 后开始，6s 淡入 + 6s 显示 + 6s 淡出
TITLE_START=6
FADE_IN=6
DISPLAY=6
FADE_OUT=6
TITLE_DURATION=$((FADE_IN + DISPLAY + FADE_OUT))
TITLE_END=$((TITLE_START + TITLE_DURATION))

# step 4：Google 地图动画从第 26 秒起嵌入
MAP_START=26

FONT_FILE="${SCRIPT_DIR}/fonts/Noto_Sans_SC/static/NotoSansSC-Medium.ttf"
[[ -f "${FONT_FILE}" ]] || FONT_FILE="${SCRIPT_DIR}/fonts/Noto_Sans_SC/static/NotoSansSC-Regular.ttf"

# 英文字体
FONT_FILE_EN="${SCRIPT_DIR}/fonts/Noto_Sans/static/NotoSans-Medium.ttf"
[[ -f "${FONT_FILE_EN}" ]] || FONT_FILE_EN="${SCRIPT_DIR}/fonts/Noto_Sans/static/NotoSans-Regular.ttf"
[[ -f "${FONT_FILE_EN}" ]] || FONT_FILE_EN="${SCRIPT_DIR}/fonts/Noto_Sans_SC/static/NotoSansSC-Medium.ttf"

die() {
  echo "错误: $*" >&2
  exit 1
}

[[ -f "${FONT_FILE}" ]] || die "找不到开源字体 Noto Sans SC，请检查 src/fonts 目录"
command -v swift >/dev/null 2>&1 || die "未找到 swift（macOS 自带）"

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

FFMPEG="$(find_ffmpeg)" || die "未找到 ffmpeg，请安装: brew install ffmpeg-full"
FFPROBE="$(dirname "${FFMPEG}")/ffprobe"
[[ -x "${FFPROBE}" ]] || FFPROBE="$(command -v ffprobe)" || die "未找到 ffprobe"

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

# 读取英文元数据（可选）
METADATA_EN="${SCRIPT_DIR}/processMetadata_en.json"
TITLE_EN=""
if [[ -f "${METADATA_EN}" ]]; then
  TITLE_EN="$(python3 - "${METADATA_EN}" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
print(data.get("title", "").strip())
PY
)" || true
fi

INPUT_MOV="${VIDEO_PATH}/${SRC_NAME}"
[[ -f "${INPUT_MOV}" ]] || die "输入文件不存在: ${INPUT_MOV}"
[[ "${INPUT_MOV##*.}" =~ ^[Mm][Oo][Vv]$ ]] || die "输入文件必须是 MOV 格式: ${INPUT_MOV}"

MAP_MOV=""
for _map_candidate in "${VIDEO_PATH}/movie.mov" "${SCRIPT_DIR}/movie.mov"; do
  [[ -f "${_map_candidate}" ]] || continue
  MAP_MOV="${_map_candidate}"
  break
done

OUTPUT_MP4="${VIDEO_PATH}/${DIST_NAME}.mp4"
[[ ! -f "${OUTPUT_MP4}" ]] || die "输出文件已存在，请先删除或重命名: ${OUTPUT_MP4}"

DURATION="$("${FFPROBE}" -v error -show_entries format=duration -of csv=p=0 "${INPUT_MOV}")"
[[ -n "${DURATION}" ]] || die "无法读取视频时长"

VIDEO_CODEC="$("${FFPROBE}" -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "${INPUT_MOV}" | tr -d '[:space:]')"
case "${VIDEO_CODEC}" in
  hevc|h265) ENCODER="hevc_videotoolbox"; VIDEO_TAG="hvc1"; BSF="hevc_mp4toannexb" ;;
  h264|avc1) ENCODER="h264_videotoolbox"; VIDEO_TAG="avc1"; BSF="h264_mp4toannexb" ;;
  *)         die "不支持的视频编码: ${VIDEO_CODEC}" ;;
esac
VIDEO_TIMESCALE=19200

VIDEO_WIDTH="$("${FFPROBE}" -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "${INPUT_MOV}" | head -1 | cut -d, -f1 | tr -cd '0-9')"
VIDEO_HEIGHT="$("${FFPROBE}" -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "${INPUT_MOV}" | head -1 | cut -d, -f1 | tr -cd '0-9')"
[[ -n "${VIDEO_WIDTH}" && -n "${VIDEO_HEIGHT}" ]] || die "无法读取视频分辨率"
FONT_SIZE="$(awk -v h="${VIDEO_HEIGHT}" 'BEGIN { printf "%d", h / 18 }')"

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/media-cut.XXXXXX")"
cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT

DURATION_GT() { awk -v a="$1" -v b="$2" 'BEGIN { exit (a > b) ? 0 : 1 }'; }

next_keyframe_after() {
  python3 - "${FFPROBE}" "$1" "$2" <<'PY'
import re, subprocess, sys

def next_keyframe(ffprobe: str, path: str, after: float) -> float:
    out = subprocess.check_output(
        [
            ffprobe, "-v", "error", "-select_streams", "v:0",
            "-show_packets", "-read_intervals", f"{after}%+12",
            "-i", path,
        ],
        text=True,
    )
    for block in out.split("[PACKET]"):
        if "codec_type=video" not in block or not re.search(r"flags=K", block):
            continue
        match = re.search(r"pts_time=([-0-9.]+)", block)
        if match and float(match.group(1)) > after + 0.001:
            return float(match.group(1))
    return after + 1.0

ffprobe, path, anchor = sys.argv[1], sys.argv[2], float(sys.argv[3])
kf = anchor + 0.01
for _ in range(4):
    kf = next_keyframe(ffprobe, path, kf)
print(kf)
PY
}

# step 4：将 movie.mov 嵌入成片（从 MAP_START 秒起，仅重编码地图段）
embed_map_animation() {
  local pre_map="$1"
  local output="$2"

  if [[ -z "${MAP_MOV}" ]]; then
    cp "${pre_map}" "${output}"
    return 0
  fi

  local final_duration map_duration map_body map_end map_tail_start map_filter
  final_duration="$("${FFPROBE}" -v error -show_entries format=duration -of csv=p=0 "${pre_map}")"
  [[ -n "${final_duration}" ]] || die "无法读取中间视频时长"

  if ! DURATION_GT "${final_duration}" "${MAP_START}"; then
    echo "视频不足 ${MAP_START}s，跳过地图嵌入..."
    cp "${pre_map}" "${output}"
    return 0
  fi

  map_duration="$("${FFPROBE}" -v error -show_entries format=duration -of csv=p=0 "${MAP_MOV}")"
  [[ -n "${map_duration}" ]] || die "无法读取地图视频时长: ${MAP_MOV}"

  map_body="$(awk -v md="${map_duration}" -v fd="${final_duration}" -v ms="${MAP_START}" \
    'BEGIN { avail=fd-ms; print (md<avail)?md:avail }')"

  if ! awk -v b="${map_body}" 'BEGIN { exit (b > 0.05) ? 0 : 1 }'; then
    echo "地图片段时长过短，跳过嵌入..."
    cp "${pre_map}" "${output}"
    return 0
  fi

  map_end="$(awk -v ms="${MAP_START}" -v mb="${map_body}" 'BEGIN { print ms+mb }')"
  echo "嵌入 Google 地图动画 ${MAP_START}s ~ ${map_end}s（${MAP_MOV}）..."

  map_tail_start="$(next_keyframe_after "${pre_map}" "${map_end}")"
  [[ -n "${map_tail_start}" ]] || die "无法计算地图段关键帧切点"

  local map_w map_h
  map_w="$(awk -v w="${VIDEO_WIDTH}" 'BEGIN { printf "%d", w * 3 / 4 }')"
  map_h="$(awk -v h="${VIDEO_HEIGHT}" 'BEGIN { printf "%d", h * 3 / 4 }')"

  map_filter="[0:v]trim=duration=${map_body},setpts=PTS-STARTPTS[bg];"
  map_filter+="[1:v]trim=duration=${map_body},setpts=PTS-STARTPTS,"
  map_filter+="scale=${map_w}:${map_h}:force_original_aspect_ratio=decrease,"
  map_filter+="format=rgba[fg];"
  map_filter+="[bg][fg]overlay=(W-w)/2:(H-h)/2:format=auto:shortest=1[vout]"

  local -a concat_parts=()

  if awk -v ms="${MAP_START}" 'BEGIN { exit (ms > 0.05) ? 0 : 1 }'; then
    echo "提取地图前段 0 ~ ${MAP_START}s（流复制）..."
    "${FFMPEG}" -hide_banner -y -i "${pre_map}" -t "${MAP_START}" \
      -map 0:v:0 -map "0:a:0?" -c copy -movflags +faststart \
      "${TMPDIR}/part_map_pre.mp4"
    concat_parts+=("part_map_pre")
  fi

  echo "重编码地图段 ${MAP_START}s ~ ${map_tail_start}s（overlay ${map_body}s）..."
  "${FFMPEG}" -hide_banner -y \
    -ss "${MAP_START}" -i "${pre_map}" \
    -i "${MAP_MOV}" \
    -filter_complex "${map_filter}" \
    -map "[vout]" -map "0:a:0?" -t "${map_body}" \
    -c:v "${ENCODER}" -b:v 12M -tag:v "${VIDEO_TAG}" \
    -fps_mode cfr -r 60000/1001 -video_track_timescale "${VIDEO_TIMESCALE}" \
    -c:a copy \
    -avoid_negative_ts make_zero -reset_timestamps 1 \
    "${TMPDIR}/part_map_body.mp4"
  concat_parts+=("part_map_body")

  if awk -v fd="${final_duration}" -v ts="${map_tail_start}" 'BEGIN { exit (fd > ts) ? 0 : 1 }'; then
    echo "提取地图后段 ${map_tail_start}s ~ 结束（流复制）..."
    "${FFMPEG}" -hide_banner -y -ss "${map_tail_start}" -i "${pre_map}" \
      -map 0:v:0 -map "0:a:0?" \
      -c copy -video_track_timescale "${VIDEO_TIMESCALE}" \
      -avoid_negative_ts make_zero -reset_timestamps 1 \
      "${TMPDIR}/part_map_post.mp4"
    concat_parts+=("part_map_post")
  fi

  if [[ "${#concat_parts[@]}" -eq 1 ]]; then
    cp "${TMPDIR}/part_map_body.mp4" "${output}"
    return 0
  fi

  local part map_concat_list="${TMPDIR}/map_concat.txt"
  for part in "${concat_parts[@]}"; do
    echo "转 TS: ${part}..."
    "${FFMPEG}" -hide_banner -y -i "${TMPDIR}/${part}.mp4" \
      -c copy -bsf:v "${BSF}" -f mpegts "${TMPDIR}/${part}.ts"
  done

  : > "${map_concat_list}"
  for part in "${concat_parts[@]}"; do
    printf "file '%s'\n" "${TMPDIR}/${part}.ts" >> "${map_concat_list}"
  done

  echo "合并地图前/中/后段（TS concat demuxer）..."
  "${FFMPEG}" -hide_banner -y -f concat -safe 0 -i "${map_concat_list}" \
    -c copy -bsf:a aac_adtstoasc -movflags +faststart \
    "${output}"
}

# 视频过短：无需标题
if ! DURATION_GT "${DURATION}" "${TITLE_START}"; then
  echo "视频不足 ${TITLE_START}s，跳过标题，直接 remux..."
  "${FFMPEG}" -hide_banner -y -i "${INPUT_MOV}" \
    -map 0:v:0 -map "0:a:0?" \
    -c copy -movflags +faststart \
    "${TMPDIR}/pre_map.mp4"
  embed_map_animation "${TMPDIR}/pre_map.mp4" "${OUTPUT_MP4}"
  echo "完成: ${OUTPUT_MP4}"
  exit 0
fi

TITLE_PNG="${TMPDIR}/title.png"
echo "生成标题 PNG..."
if [[ -n "${TITLE_EN}" && -n "${FONT_FILE_EN}" ]]; then
  echo "使用双语标题: 中文 + 英文"
  # 英文标题字体大小为主标题的 0.6 倍
  FONT_SIZE_EN="$(awk -v s="${FONT_SIZE}" 'BEGIN { printf "%d", s * 0.6 }')"
  swift "${SCRIPT_DIR}/render_title.swift" "${FONT_FILE}" "${TITLE}" "${TITLE_PNG}" "${FONT_SIZE}" "${FONT_FILE_EN}" "${TITLE_EN}" "${FONT_SIZE_EN}"
else
  swift "${SCRIPT_DIR}/render_title.swift" "${FONT_FILE}" "${TITLE}" "${TITLE_PNG}" "${FONT_SIZE}"
fi

# 流复制起点 = 标题结束后第 4 关键帧；intro 一次性重编码到此处（无中间文件拼接）
TAIL_START="$(next_keyframe_after "${INPUT_MOV}" "${TITLE_END}")"
[[ -n "${TAIL_START}" ]] || die "无法计算关键帧切点"

HEAD_DURATION="${TITLE_START}"
BODY_DURATION="${TITLE_DURATION}"
if ! awk -v d="${DURATION}" -v e="${TITLE_END}" 'BEGIN { exit (d >= e) ? 0 : 1 }'; then
  BODY_DURATION="$(awk -v d="${DURATION}" -v s="${TITLE_START}" 'BEGIN { print d - s }')"
fi

INTRO_DURATION="${TAIL_START}"
if ! awk -v d="${DURATION}" -v s="${TAIL_START}" 'BEGIN { exit (d > s) ? 0 : 1 }'; then
  INTRO_DURATION="${DURATION}"
fi

POST_DURATION=0
if awk -v d="${INTRO_DURATION}" -v e="${TITLE_END}" 'BEGIN { exit (d > e) ? 0 : 1 }'; then
  POST_DURATION="$(awk -v d="${INTRO_DURATION}" -v e="${TITLE_END}" 'BEGIN { print d - e }')"
fi

FADE_OUT_START=$((FADE_IN + DISPLAY))
if awk -v b="${BODY_DURATION}" -v t="${TITLE_DURATION}" 'BEGIN { exit (b < t) ? 0 : 1 }'; then
  FADE_OUT_START="$(awk -v b="${BODY_DURATION}" -v f="${FADE_OUT}" 'BEGIN { print b - f }')"
  [[ "${FADE_OUT_START}" -ge "${FADE_IN}" ]] || FADE_OUT_START="${FADE_IN}"
fi

# 片头 + 标题(18s) + 关键帧缓冲：一次重编码视频；音频流复制（与片尾同源，避免拼接处 AAC 空洞）
FILTER="[0:v]trim=duration=${HEAD_DURATION},setpts=PTS-STARTPTS[h];"
FILTER+="[0:v]trim=start=${TITLE_START}:duration=${BODY_DURATION},setpts=PTS-STARTPTS[bs];"
FILTER+="[1:v]format=rgba,fade=t=in:st=0:d=${FADE_IN}:alpha=1,"
FILTER+="fade=t=out:st=${FADE_OUT_START}:d=${FADE_OUT}:alpha=1[ov];"
FILTER+="[bs][ov]overlay=(W-w)/2:(H-h)/2:format=auto[bt];"

if awk -v p="${POST_DURATION}" 'BEGIN { exit (p > 0) ? 0 : 1 }'; then
  FILTER+="[0:v]trim=start=${TITLE_END}:duration=${POST_DURATION},setpts=PTS-STARTPTS[te];"
  FILTER+="[h][bt][te]concat=n=3:v=1:a=0,format=yuv420p10le[vout]"
else
  FILTER+="[h][bt]concat=n=2:v=1:a=0,format=yuv420p10le[vout]"
fi

echo "重编码 0 ~ ${INTRO_DURATION}s（标题 ${BODY_DURATION}s，流复制从 ${TAIL_START}s 起）..."
"${FFMPEG}" -hide_banner -y \
  -i "${INPUT_MOV}" \
  -loop 1 -framerate 60000/1001 -t "${BODY_DURATION}" -i "${TITLE_PNG}" \
  -filter_complex "${FILTER}" \
  -map "[vout]" -map "0:a:0?" -t "${INTRO_DURATION}" \
  -c:v "${ENCODER}" -b:v 12M -tag:v "${VIDEO_TAG}" \
  -fps_mode cfr -r 60000/1001 -video_track_timescale "${VIDEO_TIMESCALE}" \
  -c:a copy \
  -avoid_negative_ts make_zero -reset_timestamps 1 \
  "${TMPDIR}/part_intro.mp4"

if ! awk -v d="${DURATION}" -v s="${TAIL_START}" 'BEGIN { exit (d > s) ? 0 : 1 }'; then
  embed_map_animation "${TMPDIR}/part_intro.mp4" "${OUTPUT_MP4}"
  echo "完成: ${OUTPUT_MP4}"
  exit 0
fi

# 片尾：从 TAIL_START 流复制
echo "提取片尾 ${TAIL_START}s ~ 结束（流复制）..."
"${FFMPEG}" -hide_banner -y -ss "${TAIL_START}" -i "${INPUT_MOV}" \
  -map 0:v:0 -map "0:a:0?" \
  -c copy -video_track_timescale "${VIDEO_TIMESCALE}" \
  -avoid_negative_ts make_zero -reset_timestamps 1 \
  "${TMPDIR}/part_tail.mp4"

# 唯一拼接：intro（一次重编码）+ tail（流复制），经 TS concat
for part in part_intro part_tail; do
  echo "转 TS: ${part}..."
  "${FFMPEG}" -hide_banner -y -i "${TMPDIR}/${part}.mp4" \
    -c copy -bsf:v "${BSF}" -f mpegts "${TMPDIR}/${part}.ts"
done

CONCAT_LIST="${TMPDIR}/concat.txt"
{
  printf "file '%s'\n" "${TMPDIR}/part_intro.ts"
  printf "file '%s'\n" "${TMPDIR}/part_tail.ts"
} > "${CONCAT_LIST}"

echo "合并 intro + tail（TS concat demuxer）..."
"${FFMPEG}" -hide_banner -y -f concat -safe 0 -i "${CONCAT_LIST}" \
  -c copy -bsf:a aac_adtstoasc -movflags +faststart \
  "${TMPDIR}/pre_map.mp4"

embed_map_animation "${TMPDIR}/pre_map.mp4" "${OUTPUT_MP4}"
echo "完成: ${OUTPUT_MP4}"
