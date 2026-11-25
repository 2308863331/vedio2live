#!/bin/bash
# 编译 video2livephoto 和 mktestvideo（纯 swiftc，不需要 Xcode 工程）
#
# 注意：本机文件沙箱只允许写工作目录，clang 默认的模块缓存（/var/folders/...）写不进去，
# 所以这里把模块缓存和临时目录都指到本目录下。
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p bin .build-cache .build-tmp
export TMPDIR="$(pwd)/.build-tmp"
CACHE="$(pwd)/.build-cache"

FRAMEWORKS=(
  -framework Foundation
  -framework AVFoundation
  -framework CoreMedia
  -framework CoreVideo
  -framework CoreGraphics
  -framework ImageIO
)

echo "== 编译 video2livephoto =="
swiftc -O -module-cache-path "$CACHE" "${FRAMEWORKS[@]}" -o bin/video2livephoto video2livephoto.swift
echo "  -> bin/video2livephoto"

echo "== 编译 mktestvideo =="
swiftc -O -module-cache-path "$CACHE" "${FRAMEWORKS[@]}" -o bin/mktestvideo mktestvideo.swift
echo "  -> bin/mktestvideo"

echo
echo "编译完成。"
ls -la bin/
