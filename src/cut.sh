#!/usr/bin/env bash
# 视频剪辑：MOV → MP4，distName 命名，标题淡入淡出（PNG + fade）
# 剪辑前 probe 原始 MOV 编码参数，后续重编码（标题 / Google 地图）均以该基准为准
# step 4（可选 --map）：26s 起嵌入 Google 地图动画 movie.mov（3/4 居中叠加）
# 局部重编码 + 关键帧对齐流复制拼接（-noaccurate_seek），避免拼接处卡顿
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

# step 4：Google 地图动画从第 26 秒起嵌入（默认关闭，传 --map 开启）
MAP_START=26
ENABLE_MAP=0

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
  cat <<'EOF'
用法: cut.sh [选项]

选项:
  --map       开启 Google 地图动画嵌入（第 26s 起叠加 movie.mov）
  -h, --help  显示此帮助

默认不嵌入 Google 地图动画。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --map) ENABLE_MAP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知选项: $1（使用 --help 查看用法）" ;;
  esac
done

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

VIDEO_PATH="$(resolve_video_path "${VIDEO_PATH}")"

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
MAP_WORKING=""
MAP_PREPROCESSED=0
if [[ "${ENABLE_MAP}" -eq 1 ]]; then
  for _map_candidate in \
    "${VIDEO_PATH}/movie.mov" \
    "${VIDEO_PATH}/workspace/movie.mov" \
    "${SCRIPT_DIR}/workspace/movie.mov" \
    "${SCRIPT_DIR}/movie.mov"; do
    [[ -f "${_map_candidate}" ]] || continue
    MAP_MOV="${_map_candidate}"
    break
  done
  if [[ -n "${MAP_MOV}" ]]; then
    echo "Google 地图动画: 开启（${MAP_MOV}，自 ${MAP_START}s 起）"
  else
    echo "警告: 已指定 --map 但未找到 movie.mov（videoPath 或 workspace 目录），跳过地图嵌入"
  fi
else
  echo "Google 地图动画: 关闭（使用 --map 开启）"
fi

OUTPUT_MP4="${VIDEO_PATH}/${DIST_NAME}.mp4"
[[ ! -f "${OUTPUT_MP4}" ]] || die "输出文件已存在，请先删除或重命名: ${OUTPUT_MP4}"

PROBE_SCRIPT="${SCRIPT_DIR}/probe_video.sh"
[[ -x "${PROBE_SCRIPT}" ]] || die "找不到 probe_video.sh: ${PROBE_SCRIPT}"

echo "读取原始视频编码参数: ${INPUT_MOV}"
eval "$("${PROBE_SCRIPT}" --vars "${INPUT_MOV}")"

[[ -n "${VIDEO_CODEC:-}" ]] || die "无法读取视频编码"
[[ -n "${ENCODER:-}" ]] || die "不支持的视频编码: ${VIDEO_CODEC}"
[[ -n "${OUTPUT_FPS:-}" && -n "${VIDEO_TIMESCALE:-}" ]] || die "无法读取帧率或 timescale"
[[ -n "${VIDEO_WIDTH:-}" && -n "${VIDEO_HEIGHT:-}" ]] || die "无法读取视频分辨率"
[[ -n "${PIX_FMT:-}" ]] || die "无法读取像素格式"

DURATION="${SOURCE_DURATION:-}"
[[ -n "${DURATION}" ]] || die "无法读取视频时长"

TAIL_START="0"
INTRO_DURATION="0"
PRE_MAP_INTRO_DUR="0"

VIDEO_BITRATE="${SUGGESTED_VIDEO_BITRATE:-12M}"
AUDIO_BITRATE="${SUGGESTED_AUDIO_BITRATE:-192k}"
FONT_SIZE="$(awk -v h="${VIDEO_HEIGHT}" 'BEGIN { printf "%d", h / 18 }')"

echo "原始基准: ${VIDEO_CODEC} ${VIDEO_WIDTH}x${VIDEO_HEIGHT} ${OUTPUT_FPS}fps timescale=${VIDEO_TIMESCALE} pix_fmt=${PIX_FMT}"
echo "重编码码率: 视频 ${VIDEO_BITRATE}（源 ${SOURCE_VIDEO_BITRATE_KBPS:-—} kbps）, 音频 ${AUDIO_BITRATE}（源 ${SOURCE_AUDIO_BITRATE_KBPS:-—} kbps）"
if [[ -n "${DEVICE_MODEL:-}" ]]; then
  echo "拍摄设备: ${DEVICE_MODEL}"
fi
if [[ -n "${COLOR_TRANSFER:-}" ]]; then
  echo "色彩: range=${COLOR_RANGE:-—} space=${COLOR_SPACE:-—} primaries=${COLOR_PRIMARIES:-—} transfer=${COLOR_TRANSFER}"
fi

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/media-cut.XXXXXX")"
cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT

DURATION_GT() { awk -v a="$1" -v b="$2" 'BEGIN { exit (a > b) ? 0 : 1 }'; }

# 重编码参数一律以原始视频 probe 结果为基准（写入 VIDEO_ENCODE_ARGS，兼容 macOS bash 3.2）
video_encode_args() {
  VIDEO_ENCODE_ARGS=(
    -c:v "${ENCODER}"
    -b:v "${VIDEO_BITRATE}"
    -tag:v "${VIDEO_TAG}"
    -fps_mode cfr
    -r "${OUTPUT_FPS}"
    -video_track_timescale "${VIDEO_TIMESCALE}"
    -pix_fmt "${PIX_FMT}"
  )
  [[ -n "${COLOR_RANGE:-}" && "${COLOR_RANGE}" != "unknown" ]] && VIDEO_ENCODE_ARGS+=( -color_range "${COLOR_RANGE}" )
  [[ -n "${COLOR_SPACE:-}" && "${COLOR_SPACE}" != "unknown" ]] && VIDEO_ENCODE_ARGS+=( -colorspace "${COLOR_SPACE}" )
  [[ -n "${COLOR_PRIMARIES:-}" && "${COLOR_PRIMARIES}" != "unknown" ]] && VIDEO_ENCODE_ARGS+=( -color_primaries "${COLOR_PRIMARIES}" )
  [[ -n "${COLOR_TRANSFER:-}" && "${COLOR_TRANSFER}" != "unknown" ]] && VIDEO_ENCODE_ARGS+=( -color_trc "${COLOR_TRANSFER}" )
}

# 地图源是否为 MJPEG/VFR/像素格式不兼容，需预处理为 CFR
map_needs_preprocess() {
  python3 - "${FFPROBE}" "$1" "${OUTPUT_FPS}" "${PIX_FMT}" <<'PY'
import json, subprocess, sys

ffprobe, path, target_fps, target_pix = sys.argv[1:5]

def parse_fps(rate: str) -> float:
    rate = (rate or "").strip()
    if not rate or rate == "0/0":
        return 0.0
    if "/" in rate:
        num, den = rate.split("/", 1)
        try:
            d = float(den)
            return float(num) / d if d else 0.0
        except ValueError:
            return 0.0
    try:
        return float(rate)
    except ValueError:
        return 0.0

raw = subprocess.check_output(
    [
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=codec_name,avg_frame_rate,pix_fmt",
        "-of", "json", path,
    ],
    text=True,
)
stream = json.loads(raw)["streams"][0]
codec = (stream.get("codec_name") or "").lower()
pix = stream.get("pix_fmt") or ""
fps = parse_fps(stream.get("avg_frame_rate") or "")
target = parse_fps(target_fps)
if target <= 0:
    target = 60.0

need = (
    codec in ("mjpeg", "png", "bmp", "gif")
    or (fps > 0 and abs(fps - target) > 1.0)
    or (pix and target_pix and pix != target_pix)
)
print("yes" if need else "no")
PY
}

# MJPEG/VFR 地图 → CFR + 目标像素格式 + 3/4 缩放，避免 overlay 时帧率/色彩不一致
preprocess_map_video() {
  local source="$1"
  local dest="${TMPDIR}/map_preprocessed.mp4"
  local map_w map_h vf

  map_w="$(awk -v w="${VIDEO_WIDTH}" 'BEGIN { printf "%d", w * 3 / 4 }')"
  map_h="$(awk -v h="${VIDEO_HEIGHT}" 'BEGIN { printf "%d", h * 3 / 4 }')"

  echo "预处理地图: $(basename "${source}") → CFR ${OUTPUT_FPS}fps ${PIX_FMT} (${map_w}x${map_h})..." >&2
  vf="fps=${OUTPUT_FPS},scale=${map_w}:${map_h}:force_original_aspect_ratio=decrease,format=${PIX_FMT}"

  video_encode_args
  "${FFMPEG}" -hide_banner -y -i "${source}" \
    -vf "${vf}" \
    -an \
    "${VIDEO_ENCODE_ARGS[@]}" \
    -force_key_frames "expr:gte(t,n_forced*2)" \
    -movflags +faststart \
    "${dest}" >&2

  [[ -f "${dest}" ]] || die "地图预处理失败: ${dest}"
  echo "${dest}"
}

# --map：probe 完成后预处理地图（MJPEG ~39fps → CFR 60fps 等）
if [[ "${ENABLE_MAP}" -eq 1 && -n "${MAP_MOV}" ]]; then
  if [[ "$(map_needs_preprocess "${MAP_MOV}")" == "yes" ]]; then
    MAP_WORKING="$(preprocess_map_video "${MAP_MOV}")"
    MAP_PREPROCESSED=1
  else
    MAP_WORKING="${MAP_MOV}"
    echo "地图视频参数已兼容，跳过预处理"
  fi
fi

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
print(next_keyframe(ffprobe, path, anchor))
PY
}

# pre_map 时间轴 → 原片 INPUT_MOV 时间（intro 重编码 + tail 流复制结构）
pre_map_to_original_time() {
  local pre_t="$1"
  local intro_dur="${PRE_MAP_INTRO_DUR:-0}"
  local tail_start="${TAIL_START:-0}"
  awk -v t="${pre_t}" -v intro="${intro_dur}" -v tail="${tail_start}" \
    'BEGIN {
      if (intro > 0.05) { print tail + (t - intro) } else { print t }
    }'
}

# step 4：将 movie.mov 嵌入成片（从 MAP_START 秒起，仅重编码地图段）
embed_map_animation() {
  local pre_map="$1"
  local output="$2"
  local map_input="${MAP_WORKING:-${MAP_MOV}}"

  if [[ -z "${map_input}" ]]; then
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

  map_duration="$("${FFPROBE}" -v error -show_entries format=duration -of csv=p=0 "${map_input}")"
  [[ -n "${map_duration}" ]] || die "无法读取地图视频时长: ${map_input}"

  map_body="$(awk -v md="${map_duration}" -v fd="${final_duration}" -v ms="${MAP_START}" \
    'BEGIN { avail=fd-ms; print (md<avail)?md:avail }')"

  if ! awk -v b="${map_body}" 'BEGIN { exit (b > 0.05) ? 0 : 1 }'; then
    echo "地图片段时长过短，跳过嵌入..."
    cp "${pre_map}" "${output}"
    return 0
  fi

  map_end="$(awk -v ms="${MAP_START}" -v mb="${map_body}" 'BEGIN { print ms+mb }')"
  echo "嵌入 Google 地图动画 ${MAP_START}s ~ ${map_end}s（$(basename "${map_input}")）..."

  local map_body_kf map_encode_dur map_rel_start map_overlay_end
  map_body_kf="$(next_keyframe_after "${pre_map}" "$(awk -v ms="${MAP_START}" 'BEGIN { print ms - 0.05 }')")"
  [[ -n "${map_body_kf}" ]] || die "无法计算地图段起始关键帧"

  map_rel_start="$(awk -v ms="${MAP_START}" -v kf="${map_body_kf}" 'BEGIN { d=ms-kf; print (d>0)?d:0 }')"
  map_overlay_end="$(awk -v rs="${map_rel_start}" -v mb="${map_body}" 'BEGIN { print rs + mb }')"

  # map_overlay_end 是相对 map_body_kf 重编码段的时间；查关键帧须换算成 pre_map 绝对时间
  local map_abs_overlay_end
  map_abs_overlay_end="$(awk -v kf="${map_body_kf}" -v oe="${map_overlay_end}" 'BEGIN { print kf + oe }')"
  map_tail_start="$(next_keyframe_after "${pre_map}" "$(awk -v ae="${map_abs_overlay_end}" 'BEGIN { print ae - 0.05 }')")"
  [[ -n "${map_tail_start}" ]] || die "无法计算地图段结束关键帧切点"

  map_encode_dur="$(awk -v end="${map_tail_start}" -v start="${map_body_kf}" 'BEGIN { print end - start }')"
  if ! awk -v d="${map_encode_dur}" 'BEGIN { exit (d > 0.05) ? 0 : 1 }'; then
    echo "地图重编码段过短，跳过嵌入..."
    cp "${pre_map}" "${output}"
    return 0
  fi

  local map_w map_h
  map_w="$(awk -v w="${VIDEO_WIDTH}" 'BEGIN { printf "%d", w * 3 / 4 }')"
  map_h="$(awk -v h="${VIDEO_HEIGHT}" 'BEGIN { printf "%d", h * 3 / 4 }')"

  local map_fade_out_d map_fade_out_st fg_suffix
  map_fade_out_d="0.5"
  map_fade_out_st="$(awk -v end="${map_overlay_end}" -v d="${map_fade_out_d}" \
    'BEGIN { st=end-d; print (st>0)?st:0 }')"
  fg_suffix="format=rgba"
  if awk -v end="${map_overlay_end}" -v st="${map_fade_out_st}" 'BEGIN { exit (end > st + 0.05) ? 0 : 1 }'; then
    fg_suffix="format=rgba,fade=t=out:st=${map_fade_out_st}:d=${map_fade_out_d}:alpha=1"
  fi

  map_filter="[0:v]trim=duration=${map_encode_dur},setpts=PTS-STARTPTS[bg];"
  map_filter+="[1:v]trim=duration=${map_body},setpts=PTS-STARTPTS,"
  if [[ "${MAP_PREPROCESSED}" -eq 1 ]]; then
    map_filter+="${fg_suffix}[fg];"
  else
    map_filter+="fps=${OUTPUT_FPS},"
    map_filter+="scale=${map_w}:${map_h}:force_original_aspect_ratio=decrease,"
    map_filter+="${fg_suffix}[fg];"
  fi
  if awk -v rs="${map_rel_start}" 'BEGIN { exit (rs > 0.05) ? 0 : 1 }'; then
    map_filter+="[bg][fg]overlay=(W-w)/2:(H-h)/2:format=auto:"
    map_filter+="enable='between(t,${map_rel_start},${map_overlay_end})'[vtmp]"
  else
    map_filter+="[bg][fg]overlay=(W-w)/2:(H-h)/2:format=auto:shortest=1[vtmp]"
  fi
  map_filter+=";[vtmp]format=${PIX_FMT}[vout]"

  local -a concat_parts=()

  if awk -v kf="${map_body_kf}" 'BEGIN { exit (kf > 0.05) ? 0 : 1 }'; then
    echo "提取地图前段 0 ~ ${map_body_kf}s（关键帧对齐，流复制）..."
    "${FFMPEG}" -hide_banner -y -i "${pre_map}" -to "${map_body_kf}" \
      -map 0:v:0 -map "0:a:0?" -c copy -movflags +faststart \
      "${TMPDIR}/part_map_pre.mp4"
    concat_parts+=("part_map_pre")
  fi

  echo "重编码地图段 ${map_body_kf}s ~ ${map_tail_start}s（overlay ${map_body}s，自 ${MAP_START}s 起，基准 ${OUTPUT_FPS}fps ${PIX_FMT}）..."
  video_encode_args
  if [[ "${MAP_PREPROCESSED}" -eq 1 ]]; then
    "${FFMPEG}" -hide_banner -y \
      -ss "${map_body_kf}" -noaccurate_seek -i "${pre_map}" \
      -i "${map_input}" \
      -filter_complex "${map_filter}" \
      -map "[vout]" -map "0:a:0?" -t "${map_encode_dur}" \
      "${VIDEO_ENCODE_ARGS[@]}" \
      -force_key_frames "expr:eq(n,0)+gte(t,${map_encode_dur}-0.1)" \
      -c:a copy \
      -avoid_negative_ts make_zero -reset_timestamps 1 \
      "${TMPDIR}/part_map_body.mp4"
  else
    "${FFMPEG}" -hide_banner -y \
      -ss "${map_body_kf}" -noaccurate_seek -i "${pre_map}" \
      -r "${OUTPUT_FPS}" -i "${map_input}" \
      -filter_complex "${map_filter}" \
      -map "[vout]" -map "0:a:0?" -t "${map_encode_dur}" \
      "${VIDEO_ENCODE_ARGS[@]}" \
      -force_key_frames "expr:eq(n,0)+gte(t,${map_encode_dur}-0.1)" \
      -c:a copy \
      -avoid_negative_ts make_zero -reset_timestamps 1 \
      "${TMPDIR}/part_map_body.mp4"
  fi
  concat_parts+=("part_map_body")

  if awk -v fd="${final_duration}" -v ts="${map_tail_start}" 'BEGIN { exit (fd > ts) ? 0 : 1 }'; then
    local orig_post_ss
    orig_post_ss="$(pre_map_to_original_time "${map_tail_start}")"
    echo "提取地图后段 ${map_tail_start}s ~ 结束（原片 ${orig_post_ss}s 起，关键帧对齐，流复制）..."
    "${FFMPEG}" -hide_banner -y -ss "${orig_post_ss}" -noaccurate_seek -i "${INPUT_MOV}" \
      -map 0:v:0 -map "0:a:0?" \
      -c copy \
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

# 流复制起点 = 标题结束后首个关键帧；intro 仅重编码 0~此处（约 18s 标题窗 + 缓冲，无中间拼接）
TAIL_START="$(next_keyframe_after "${INPUT_MOV}" "${TITLE_END}")"
[[ -n "${TAIL_START}" ]] || die "无法计算关键帧切点"

BODY_DURATION="${TITLE_DURATION}"
if ! awk -v d="${DURATION}" -v e="${TITLE_END}" 'BEGIN { exit (d >= e) ? 0 : 1 }'; then
  BODY_DURATION="$(awk -v d="${DURATION}" -v s="${TITLE_START}" 'BEGIN { print d - s }')"
fi

INTRO_DURATION="${TAIL_START}"
if ! awk -v d="${DURATION}" -v s="${TAIL_START}" 'BEGIN { exit (d > s) ? 0 : 1 }'; then
  INTRO_DURATION="${DURATION}"
fi

OVERLAY_END="$(awk -v s="${TITLE_START}" -v b="${BODY_DURATION}" 'BEGIN { print s + b }')"

FADE_OUT_START=$((FADE_IN + DISPLAY))
if awk -v b="${BODY_DURATION}" -v t="${TITLE_DURATION}" 'BEGIN { exit (b < t) ? 0 : 1 }'; then
  FADE_OUT_START="$(awk -v b="${BODY_DURATION}" -v f="${FADE_OUT}" 'BEGIN { print b - f }')"
  [[ "${FADE_OUT_START}" -ge "${FADE_IN}" ]] || FADE_OUT_START="${FADE_IN}"
fi

# 单次 trim + 定时 overlay（避免 head/body/post 三段 concat 在标题消失处丢帧卡顿）
FILTER="[0:v]trim=duration=${INTRO_DURATION},setpts=PTS-STARTPTS[base];"
FILTER+="[1:v]format=rgba,fade=t=in:st=0:d=${FADE_IN}:alpha=1,"
FILTER+="fade=t=out:st=${FADE_OUT_START}:d=${FADE_OUT}:alpha=1,"
FILTER+="setpts=PTS+${TITLE_START}/TB[ov];"
FILTER+="[base][ov]overlay=(W-w)/2:(H-h)/2:format=auto:"
FILTER+="enable='between(t,${TITLE_START},${OVERLAY_END})'[vtmp];"
FILTER+="[vtmp]format=${PIX_FMT}[vout]"

INTRO_MAP=( -map "[vout]" )
INTRO_AUDIO=( -an )
if [[ "${HAS_AUDIO}" -eq 1 ]]; then
  INTRO_MAP+=( -map "0:a:0?" )
  INTRO_AUDIO=( -c:a copy )
fi

video_encode_args

echo "重编码 0 ~ ${INTRO_DURATION}s（标题 ${BODY_DURATION}s，关键帧切点 ${TAIL_START}s，流复制从此处起）..."
"${FFMPEG}" -hide_banner -y \
  -i "${INPUT_MOV}" \
  -loop 1 -framerate "${OUTPUT_FPS}" -t "${BODY_DURATION}" -i "${TITLE_PNG}" \
  -filter_complex "${FILTER}" \
  "${INTRO_MAP[@]}" -t "${INTRO_DURATION}" \
  "${VIDEO_ENCODE_ARGS[@]}" \
  -force_key_frames "expr:gte(t,${INTRO_DURATION}-0.1)" \
  "${INTRO_AUDIO[@]}" \
  -avoid_negative_ts make_zero -reset_timestamps 1 \
  "${TMPDIR}/part_intro.mp4"

PRE_MAP_INTRO_DUR="$("${FFPROBE}" -v error -show_entries format=duration -of csv=p=0 "${TMPDIR}/part_intro.mp4")"
[[ -n "${PRE_MAP_INTRO_DUR}" ]] || PRE_MAP_INTRO_DUR="${INTRO_DURATION}"

if ! awk -v d="${DURATION}" -v s="${TAIL_START}" 'BEGIN { exit (d > s) ? 0 : 1 }'; then
  embed_map_animation "${TMPDIR}/part_intro.mp4" "${OUTPUT_MP4}"
  echo "完成: ${OUTPUT_MP4}"
  exit 0
fi

# 片尾：从 TAIL_START 关键帧流复制（-noaccurate_seek 对齐关键帧，避免卡顿）
echo "提取片尾 ${TAIL_START}s ~ 结束（关键帧对齐，流复制）..."
"${FFMPEG}" -hide_banner -y -ss "${TAIL_START}" -noaccurate_seek -i "${INPUT_MOV}" \
  -map 0:v:0 -map "0:a:0?" \
  -c copy \
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
