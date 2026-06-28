#!/usr/bin/env bash
# 读取视频编码参数（面向 iPhone 拍摄的 MOV/MP4），便于统一后续编码设置
set -euo pipefail

die() {
  echo "错误: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法: probe_video.sh [选项] <视频文件> [更多文件...]

读取 iPhone 等设备的视频编码参数，输出人类可读报告；也可导出 JSON / shell 变量，
供 cut.sh 等脚本统一编码设置。

选项:
  -j, --json       输出 JSON（单文件时为一个对象，多文件时为数组）
  -v, --vars       输出 shell 变量（可 source），以首个文件为准
  -c, --compare    多文件时输出参数对比表
  -h, --help       显示此帮助

示例:
  probe_video.sh ~/Movies/IMG_1234.MOV
  probe_video.sh --json video.mov > encoding_reference.json
  probe_video.sh --vars video.mov
  probe_video.sh --compare clip1.mov clip2.mov
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

MODE="human"
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--json)  MODE="json"; shift ;;
    -v|--vars)  MODE="vars"; shift ;;
    -c|--compare) MODE="compare"; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "未知选项: $1（使用 --help 查看用法）" ;;
    *)          FILES+=("$1"); shift ;;
  esac
done

[[ "${#FILES[@]}" -gt 0 ]] || { usage; exit 1; }

FFMPEG="$(find_ffmpeg)" || die "未找到 ffmpeg，请安装: brew install ffmpeg-full"
FFPROBE="$(dirname "${FFMPEG}")/ffprobe"
[[ -x "${FFPROBE}" ]] || FFPROBE="$(command -v ffprobe)" || die "未找到 ffprobe"

for f in "${FILES[@]}"; do
  [[ -f "${f}" ]] || die "文件不存在: ${f}"
done

export FFPROBE MODE
python3 - "${FILES[@]}" <<'PY'
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

ffprobe = os.environ["FFPROBE"]
mode = os.environ["MODE"]
paths = [str(Path(p).resolve()) for p in sys.argv[1:]]


def run_ffprobe(path: str) -> dict:
    out = subprocess.check_output(
        [
            ffprobe,
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            path,
        ],
        text=True,
    )
    return json.loads(out)


def pick_stream(streams, codec_type):
    typed = [s for s in streams if s.get("codec_type") == codec_type]
    if not typed:
        return None
    return typed[0]


def tag_get(tags, *keys, default=""):
    if not tags:
        return default
    for key in keys:
        if key in tags and tags[key]:
            return str(tags[key])
    return default


def parse_rotation(stream):
    if not stream:
        return 0
    tags = stream.get("tags") or {}
    rotate = tag_get(tags, "rotate")
    if rotate.lstrip("-").isdigit():
        return int(rotate) % 360
    for side in stream.get("side_data_list") or []:
        if side.get("side_data_type") == "Display Matrix":
            rot = side.get("rotation")
            if rot is not None:
                return int(float(rot)) % 360
    return 0


def fps_from_rate(rate: str) -> str:
    rate = (rate or "").strip()
    if not rate or rate == "0/0":
        return ""
    if "/" in rate:
        num, den = rate.split("/", 1)
        try:
            n, d = float(num), float(den)
            if d:
                val = n / d
                if abs(val - round(val)) < 0.001:
                    return str(int(round(val)))
                return f"{val:.6g}"
        except ValueError:
            pass
    return rate


def timescale_from_stream(stream):
    if not stream:
        return ""
    tb = (stream.get("time_base") or "").strip()
    if "/" in tb:
        return tb.split("/", 1)[1]
    return tb or ""


def bitrate_kbps(value) -> str:
    if value in (None, "", "N/A"):
        return ""
    try:
        bps = int(value)
    except (TypeError, ValueError):
        return str(value)
    if bps <= 0:
        return ""
    return f"{bps // 1000} kbps"


def bitrate_ffmpeg(value) -> str:
    """ffprobe bit_rate (bps) → ffmpeg -b:v / -b:a 取值（如 59912k、185k）。"""
    if value in (None, "", "N/A"):
        return ""
    try:
        bps = int(value)
    except (TypeError, ValueError):
        return str(value)
    if bps <= 0:
        return ""
    kbps = bps // 1000
    if kbps >= 1000 and kbps % 1000 == 0:
        return f"{kbps // 1000}M"
    return f"{kbps}k"


def suggest_encoder(codec_name: str) -> dict:
    codec = (codec_name or "").lower()
    if codec in ("hevc", "h265"):
        return {
            "encoder": "hevc_videotoolbox",
            "video_tag": "hvc1",
            "bsf": "hevc_mp4toannexb",
        }
    if codec in ("h264", "avc1"):
        return {
            "encoder": "h264_videotoolbox",
            "video_tag": "avc1",
            "bsf": "h264_mp4toannexb",
        }
    return {"encoder": "", "video_tag": "", "bsf": ""}


def analyze(path: str) -> dict:
    raw = run_ffprobe(path)
    streams = raw.get("streams") or []
    fmt = raw.get("format") or {}
    fmt_tags = fmt.get("tags") or {}

    video = pick_stream(streams, "video")
    audio = pick_stream(streams, "audio")

    rotation = parse_rotation(video)
    width = int(video.get("width") or 0) if video else 0
    height = int(video.get("height") or 0) if video else 0
    if rotation in (90, 270) and width and height:
        display_width, display_height = height, width
    else:
        display_width, display_height = width, height

    r_fps = fps_from_rate((video or {}).get("r_frame_rate", ""))
    avg_fps = fps_from_rate((video or {}).get("avg_frame_rate", ""))
    timescale = timescale_from_stream(video)
    suggest = suggest_encoder((video or {}).get("codec_name", ""))

    v_bitrate = (video or {}).get("bit_rate") or fmt.get("bit_rate")
    a_bitrate = (audio or {}).get("bit_rate") if audio else ""

    result = {
        "path": path,
        "filename": Path(path).name,
        "format": {
            "format_name": fmt.get("format_name", ""),
            "format_long_name": fmt.get("format_long_name", ""),
            "duration_sec": fmt.get("duration", ""),
            "size_bytes": fmt.get("size", ""),
            "bit_rate": fmt.get("bit_rate", ""),
            "bit_rate_kbps": bitrate_kbps(fmt.get("bit_rate")),
        },
        "device": {
            "make": tag_get(fmt_tags, "com.apple.quicktime.make", "make"),
            "model": tag_get(fmt_tags, "com.apple.quicktime.model", "model"),
            "software": tag_get(fmt_tags, "com.apple.quicktime.software", "encoder"),
            "creation_time": tag_get(fmt_tags, "creation_time", "com.apple.quicktime.creationdate"),
            "location": tag_get(fmt_tags, "com.apple.quicktime.location.ISO6709", "location"),
        },
        "video": None,
        "audio": None,
        "cut_sh": {},
    }

    if video:
        vtags = video.get("tags") or {}
        result["video"] = {
            "index": video.get("index"),
            "codec_name": video.get("codec_name", ""),
            "codec_long_name": video.get("codec_long_name", ""),
            "profile": video.get("profile", ""),
            "level": video.get("level"),
            "codec_tag_string": video.get("codec_tag_string", ""),
            "width": width,
            "height": height,
            "display_width": display_width,
            "display_height": display_height,
            "rotation_deg": rotation,
            "pix_fmt": video.get("pix_fmt", ""),
            "color_range": video.get("color_range", ""),
            "color_space": video.get("color_space", ""),
            "color_transfer": video.get("color_transfer", ""),
            "color_primaries": video.get("color_primaries", ""),
            "field_order": video.get("field_order", ""),
            "r_frame_rate": video.get("r_frame_rate", ""),
            "avg_frame_rate": video.get("avg_frame_rate", ""),
            "fps": r_fps,
            "avg_fps": avg_fps,
            "time_base": video.get("time_base", ""),
            "video_track_timescale": timescale,
            "bit_rate": v_bitrate,
            "bit_rate_kbps": bitrate_kbps(v_bitrate),
            "nb_frames": video.get("nb_frames", ""),
            "has_b_frames": video.get("has_b_frames"),
            "start_time": video.get("start_time", ""),
            "tags": {
                "creation_time": tag_get(vtags, "creation_time"),
                "handler_name": tag_get(vtags, "handler_name"),
            },
        }

    if audio:
        atags = audio.get("tags") or {}
        result["audio"] = {
            "index": audio.get("index"),
            "codec_name": audio.get("codec_name", ""),
            "codec_long_name": audio.get("codec_long_name", ""),
            "profile": audio.get("profile", ""),
            "sample_rate": audio.get("sample_rate", ""),
            "channels": audio.get("channels"),
            "channel_layout": audio.get("channel_layout", ""),
            "bit_rate": a_bitrate,
            "bit_rate_kbps": bitrate_kbps(a_bitrate),
            "start_time": audio.get("start_time", ""),
            "tags": {
                "creation_time": tag_get(atags, "creation_time"),
                "handler_name": tag_get(atags, "handler_name"),
            },
        }

    has_audio = audio is not None
    suggested_video_bitrate = bitrate_ffmpeg(v_bitrate) or "12M"
    suggested_audio_bitrate = bitrate_ffmpeg(a_bitrate) or ("192k" if has_audio else "")
    result["cut_sh"] = {
        "VIDEO_CODEC": (video or {}).get("codec_name", ""),
        "ENCODER": suggest["encoder"],
        "VIDEO_TAG": suggest["video_tag"],
        "BSF": suggest["bsf"],
        "OUTPUT_FPS": r_fps,
        "VIDEO_TIMESCALE": timescale or "19200",
        "VIDEO_WIDTH": str(display_width or width or ""),
        "VIDEO_HEIGHT": str(display_height or height or ""),
        "HAS_AUDIO": "1" if has_audio else "0",
        "PIX_FMT": (video or {}).get("pix_fmt", ""),
        "SOURCE_VIDEO_BITRATE_KBPS": bitrate_kbps(v_bitrate).replace(" kbps", "") if v_bitrate else "",
        "SOURCE_AUDIO_BITRATE_KBPS": bitrate_kbps(a_bitrate).replace(" kbps", "") if a_bitrate else "",
        "SUGGESTED_VIDEO_BITRATE": suggested_video_bitrate,
        "SUGGESTED_AUDIO_BITRATE": suggested_audio_bitrate,
        "SUGGESTED_AUDIO_CODEC": "aac" if has_audio else "",
    }

    return result


def fmt_line(label: str, value, width: int = 22) -> str:
    if value in (None, "", "N/A"):
        value = "—"
    return f"  {label:<{width}} {value}"


def print_human(report: dict) -> None:
    print(f"文件: {report['path']}")
    print()
    print("[容器]")
    f = report["format"]
    print(fmt_line("格式", f.get("format_name")))
    print(fmt_line("时长", f"{f.get('duration_sec')} s" if f.get("duration_sec") else "—"))
    print(fmt_line("文件大小", f.get("size_bytes")))
    print(fmt_line("总码率", f.get("bit_rate_kbps") or f.get("bit_rate")))
    print()
    print("[设备 / 元数据]")
    d = report["device"]
    print(fmt_line("设备品牌", d.get("make")))
    print(fmt_line("设备型号", d.get("model")))
    print(fmt_line("系统版本", d.get("software")))
    print(fmt_line("拍摄时间", d.get("creation_time")))
    if d.get("location"):
        print(fmt_line("GPS", d.get("location")))
    print()
    v = report.get("video")
    if v:
        print("[视频流]")
        print(fmt_line("编码", f"{v.get('codec_name')} ({v.get('codec_tag_string')})"))
        print(fmt_line("Profile / Level", f"{v.get('profile')} / {v.get('level')}"))
        print(fmt_line("分辨率", f"{v.get('width')}x{v.get('height')}"))
        if v.get("rotation_deg"):
            print(fmt_line("旋转", f"{v.get('rotation_deg')}°"))
            print(fmt_line("显示分辨率", f"{v.get('display_width')}x{v.get('display_height')}"))
        print(fmt_line("像素格式", v.get("pix_fmt")))
        print(fmt_line("色彩", f"range={v.get('color_range') or '—'}, "
                             f"space={v.get('color_space') or '—'}, "
                             f"transfer={v.get('color_transfer') or '—'}, "
                             f"primaries={v.get('color_primaries') or '—'}"))
        print(fmt_line("帧率", f"r={v.get('r_frame_rate')}, avg={v.get('avg_frame_rate')} → {v.get('fps')} fps"))
        print(fmt_line("time_base", v.get("time_base")))
        print(fmt_line("timescale", v.get("video_track_timescale")))
        print(fmt_line("视频码率", v.get("bit_rate_kbps") or v.get("bit_rate")))
        print(fmt_line("B 帧", v.get("has_b_frames")))
        print()
    a = report.get("audio")
    if a:
        print("[音频流]")
        print(fmt_line("编码", a.get("codec_name")))
        print(fmt_line("采样率", a.get("sample_rate")))
        print(fmt_line("声道", f"{a.get('channels')} ({a.get('channel_layout')})"))
        print(fmt_line("音频码率", a.get("bit_rate_kbps") or a.get("bit_rate")))
        print()
    else:
        print("[音频流] 无")
        print()
    c = report["cut_sh"]
    print("[cut.sh 建议参数]")
    print(fmt_line("ENCODER", c.get("ENCODER")))
    print(fmt_line("VIDEO_TAG", c.get("VIDEO_TAG")))
    print(fmt_line("BSF", c.get("BSF")))
    print(fmt_line("OUTPUT_FPS", c.get("OUTPUT_FPS")))
    print(fmt_line("VIDEO_TIMESCALE", c.get("VIDEO_TIMESCALE")))
    print(fmt_line("VIDEO_WIDTH", c.get("VIDEO_WIDTH")))
    print(fmt_line("VIDEO_HEIGHT", c.get("VIDEO_HEIGHT")))
    print(fmt_line("HAS_AUDIO", c.get("HAS_AUDIO")))
    print(fmt_line("源视频码率", f"{c.get('SOURCE_VIDEO_BITRATE_KBPS')} kbps" if c.get("SOURCE_VIDEO_BITRATE_KBPS") else "—"))
    print(fmt_line("重编码建议", f"-c:v {c.get('ENCODER')} -b:v {c.get('SUGGESTED_VIDEO_BITRATE')} "
                                f"-tag:v {c.get('VIDEO_TAG')} -fps_mode cfr -r {c.get('OUTPUT_FPS')} "
                                f"-video_track_timescale {c.get('VIDEO_TIMESCALE')}"))
    if c.get("HAS_AUDIO") == "1":
        print(fmt_line("音频建议", f"-c:a {c.get('SUGGESTED_AUDIO_CODEC')} -b:a {c.get('SUGGESTED_AUDIO_BITRATE')}"))


def print_vars(report: dict) -> None:
    c = report["cut_sh"]
    v = report.get("video") or {}
    a = report.get("audio") or {}
    pairs = {
        "PROBE_SOURCE": report["path"],
        "VIDEO_CODEC": c.get("VIDEO_CODEC", ""),
        "ENCODER": c.get("ENCODER", ""),
        "VIDEO_TAG": c.get("VIDEO_TAG", ""),
        "BSF": c.get("BSF", ""),
        "OUTPUT_FPS": c.get("OUTPUT_FPS", ""),
        "VIDEO_TIMESCALE": c.get("VIDEO_TIMESCALE", ""),
        "VIDEO_WIDTH": c.get("VIDEO_WIDTH", ""),
        "VIDEO_HEIGHT": c.get("VIDEO_HEIGHT", ""),
        "PIX_FMT": c.get("PIX_FMT", ""),
        "HAS_AUDIO": c.get("HAS_AUDIO", "0"),
        "AUDIO_CODEC": a.get("codec_name", ""),
        "AUDIO_SAMPLE_RATE": a.get("sample_rate", ""),
        "AUDIO_CHANNELS": str(a.get("channels") or ""),
        "SOURCE_VIDEO_BITRATE_KBPS": c.get("SOURCE_VIDEO_BITRATE_KBPS", ""),
        "SOURCE_AUDIO_BITRATE_KBPS": c.get("SOURCE_AUDIO_BITRATE_KBPS", ""),
        "SUGGESTED_VIDEO_BITRATE": c.get("SUGGESTED_VIDEO_BITRATE", ""),
        "SUGGESTED_AUDIO_BITRATE": c.get("SUGGESTED_AUDIO_BITRATE", ""),
        "VIDEO_PROFILE": v.get("profile", ""),
        "VIDEO_LEVEL": str(v.get("level") or ""),
        "COLOR_RANGE": v.get("color_range", ""),
        "COLOR_SPACE": v.get("color_space", ""),
        "COLOR_PRIMARIES": v.get("color_primaries", ""),
        "COLOR_TRANSFER": v.get("color_transfer", ""),
        "SOURCE_DURATION": report["format"].get("duration_sec", ""),
        "DEVICE_MODEL": report["device"].get("model", ""),
    }
    for key, value in pairs.items():
        print(f"{key}={shlex.quote(str(value))}")


COMPARE_FIELDS = [
    ("filename", "文件名"),
    ("device.model", "设备"),
    ("video.codec_name", "视频编码"),
    ("video.profile", "Profile"),
    ("video.width x video.height", "分辨率"),
    ("video.fps", "帧率"),
    ("video.pix_fmt", "像素格式"),
    ("video.color_transfer", "HDR/传输"),
    ("video.bit_rate_kbps", "视频码率"),
    ("audio.codec_name", "音频编码"),
    ("audio.sample_rate", "采样率"),
    ("audio.channels", "声道"),
    ("format.duration_sec", "时长(s)"),
]


def get_nested(report: dict, dotted: str):
    if dotted == "video.width x video.height":
        v = report.get("video") or {}
        w, h = v.get("width"), v.get("height")
        return f"{w}x{h}" if w and h else ""
    obj = report
    for part in dotted.split("."):
        if not isinstance(obj, dict):
            return ""
        obj = obj.get(part)
    return obj if obj not in (None, "") else "—"


def print_compare(reports: list[dict]) -> None:
    labels = [Path(r["path"]).name for r in reports]
    col_w = max(16, max(len(x) for x in labels) + 2)
    print("参数对比")
    print()
    for field, title in COMPARE_FIELDS:
        print(f"{title}:")
        for label, report in zip(labels, reports):
            value = get_nested(report, field)
            print(f"  {label:<{col_w}} {value}")
        print()


reports = [analyze(p) for p in paths]

if mode == "json":
    payload = reports[0] if len(reports) == 1 else reports
    print(json.dumps(payload, ensure_ascii=False, indent=2))
elif mode == "vars":
    if len(reports) != 1:
        print("错误: --vars 仅支持单个文件", file=sys.stderr)
        sys.exit(1)
    print_vars(reports[0])
elif mode == "compare":
    if len(reports) < 2:
        print("错误: --compare 至少需要两个文件", file=sys.stderr)
        sys.exit(1)
    print_compare(reports)
else:
    for i, report in enumerate(reports):
        if i:
            print("=" * 72)
            print()
        print_human(report)
PY
