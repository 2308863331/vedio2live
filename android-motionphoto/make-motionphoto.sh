#!/bin/bash
# 一行把视频做成安卓实况照片（Motion Photo）。
# 用法: ./make-motionphoto.sh <视频> <输出.jpg> [--at 秒]
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -lt 2 ]; then
  echo "用法: ./make-motionphoto.sh <视频> <输出.jpg> [--at <封面秒数>]" >&2
  echo "例:   ./make-motionphoto.sh ~/Downloads/sample.mp4 sample.jpg" >&2
  echo "例:   ./make-motionphoto.sh ~/Downloads/sample.mp4 sample.jpg --at 12.5" >&2
  exit 2
fi

VIDEO="$1"
OUT="$2"
shift 2

if [ ! -f "${VIDEO}" ]; then
  echo "错误: 视频不存在: ${VIDEO}" >&2
  exit 1
fi

# 第一次用会没有 bin/remux-faststart，自动编一次
if [ ! -x ./bin/remux-faststart ]; then
  echo "第一次用，先编译 remux-faststart..."
  bash ./build.sh
fi

echo "################ 1. 生成 ################"
python3 ./motionphoto.py --video "${VIDEO}" --out "${OUT}" "$@"

echo
echo "################ 2. 校验 ################"
python3 ./verify-motionphoto.py "${OUT}" --source "${VIDEO}"