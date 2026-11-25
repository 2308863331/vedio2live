#!/bin/bash
# 给非程序员用的一行封装：把视频变成 iPhone 的实况照片。
#
# 用法:
#   ./livephoto.sh 我的视频.mp4                 整段视频做成一张实况照片（默认，不裁剪）
#   ./livephoto.sh 我的视频.mp4 12.5            第 12.5 秒做封面，取 3 秒
#   ./livephoto.sh 我的视频.mp4 12.5 8          第 12.5 秒做封面，取 8 秒
#   ./livephoto.sh 我的视频.mp4 5,12.5,30 10    一次做 3 张，每张都是 10 秒
#
# 结果放在 ./实况图/ ：每组的 .jpg + .mov 是一对，拷进 iPhone 要一起拷。
set -euo pipefail
cd "$(dirname "$0")"

BIN=bin/video2livephoto

if [ ! -x "$BIN" ]; then
  echo "还没编译，先跑一次 build.sh ……"
  bash build.sh
fi

if [ $# -lt 1 ]; then
  cat <<'EOF'
用法: ./livephoto.sh <视频文件> [封面时刻(秒)] [片段时长(秒)] [输出宽度]

例:
  ./livephoto.sh 我的视频.mp4                整段做一张实况照片（不裁剪，默认）
  ./livephoto.sh 我的视频.mp4 12.5           第 12.5 秒做封面，取 3 秒（默认）
  ./livephoto.sh 我的视频.mp4 12.5 8         第 12.5 秒做封面，取 8 秒
  ./livephoto.sh 我的视频.mp4 5,12.5,30 10   一次做 3 张，每张 10 秒
  ./livephoto.sh 我的视频.mp4 30 60          来一张 60 秒的（时长没有上限）

产出: ./实况图/<视频名>.jpg + ./实况图/<视频名>.mov
EOF
  exit 1
fi

VIDEO="$1"
AT="${2:-}"
DUR="${3:-3}"
WIDTH="${4:-}"

if [ ! -f "$VIDEO" ]; then
  echo "找不到视频文件: ${VIDEO}"
  exit 1
fi

OUT="实况图"
ARGS=(--video "$VIDEO" --out "$OUT")
if [ -n "$AT" ]; then
  ARGS+=(--at "$AT" --duration "$DUR")
  echo "正在转换：${VIDEO}  ——  封面第 ${AT} 秒，片段 ${DUR} 秒"
else
  echo "正在转换：${VIDEO}  ——  整段不裁剪"
fi
if [ -n "$WIDTH" ]; then
  ARGS+=(--width "$WIDTH")
fi

"$BIN" "${ARGS[@]}"

echo
echo "做完了，文件在 $(pwd)/${OUT} ："
ls -la "$OUT"
echo
echo "拷进 iPhone 的方法：把成对的 .jpg 和 .mov 一起 AirDrop 或同步进「照片」，"
echo "系统会认成一张实况照片（长按会动）。"
