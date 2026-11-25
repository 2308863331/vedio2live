#!/bin/bash
# 编译 remux-faststart 到 bin/
# 关键：clang 模块缓存必须指到工具目录内，否则沙箱拒写 /var/folders/... 直接编译失败
set -euo pipefail
cd "$(dirname "$0")"

export TMPDIR="$PWD/.tmp"
mkdir -p .tmp .build-cache bin

echo "== 编译 remux-faststart =="
swiftc -O \
  -module-cache-path "$PWD/.build-cache" \
  -o bin/remux-faststart \
  remux-faststart.swift

echo "OK: bin/remux-faststart"
ls -la bin/remux-faststart
