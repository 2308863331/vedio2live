#!/bin/bash
# 自检脚本：真的去跑、真的去比数，不打印空话「OK」。
#
# 验的八件事：
#   1 编译 0 error
#   2 测试视频生成成功（本机没有 ffmpeg，用 AVFoundation 自己合成）
#   3 整段模式：不带 --duration，输出 MOV 时长 == 源视频时长
#   4 长时长参数有效：--duration 10 出 10 秒（没有写死 3/5 上限）
#   5 批量：--at 30,120 --duration 5 出 2 组 4 个文件
#   6 JPG 与 MOV 的 asset identifier 相同 / MOV 有 still-image-time 元数据轨 / 能读出实际时长
#   7 竖屏视频不会被转成横屏或变形
#   8 源片比 --duration 短时首尾帧定格撑长，且定格出来不是黑帧
#
# 跑法: bash verify.sh
set -uo pipefail
cd "$(dirname "$0")"

BIN=bin/video2livephoto
MKTEST=bin/mktestvideo
TESTDIR=test
SRC="$TESTDIR/test-source.mp4"          # 自己合成的 20 秒测试片
REAL="$HOME/Downloads/sample.mp4"      # 真素材（197 秒竖屏），有就用它验整段模式
OUT="$TESTDIR/verify-out"

PASS=0
FAIL=0
check() { # check <描述> <1|0>
  if [ "$2" = "1" ]; then
    echo "  [通过] $1"
    PASS=$((PASS + 1))
  else
    echo "  [不通过] $1"
    FAIL=$((FAIL + 1))
  fi
}

echo "=========================================================="
echo " livephoto 自检    $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================================="

# ---------- 1 编译 ----------
echo
echo "【1】编译"
mkdir -p "$TESTDIR"
if bash build.sh > "$TESTDIR-build.log" 2>&1; then
  check "bash build.sh 编译成功（日志 $TESTDIR-build.log）" 1
else
  check "bash build.sh 编译成功" 0
  tail -20 "$TESTDIR-build.log"
  exit 1
fi
check "编译日志里 error 行数 = 0" \
      "$(grep -c 'error:' "$TESTDIR-build.log" | awk '{print ($1==0)?1:0}')"

# ---------- 2 测试视频 ----------
echo
echo "【2】测试视频（AVFoundation 自己合成，本机没有 ffmpeg）"
if [ ! -f "$SRC" ]; then
  "$MKTEST" "$SRC" 20 1280 720 30 || { check "生成测试视频" 0; exit 1; }
fi
check "测试视频存在且非空（$(stat -f %z "$SRC" 2>/dev/null) 字节）" \
      "$([ -s "$SRC" ] && echo 1 || echo 0)"
PROBE=$("$BIN" --probe "$SRC")
echo "$PROBE" | sed 's/^/  | /'
check "测试视频时长 ≈ 20 秒" \
      "$(echo "$PROBE" | sed -n 's/^时长: \([0-9.]*\) 秒.*/\1/p' | awk '{print ($1>19.5 && $1<20.5)?1:0}')"

# 选整段模式的输入：优先真素材，没有就用测试片
if [ -f "$REAL" ]; then
  WHOLE_SRC="$REAL"
  WHOLE_NAME="sample.mp4（真素材，只读不改）"
else
  WHOLE_SRC="$SRC"
  WHOLE_NAME="test-source.mp4（测试片，真素材不在本机）"
fi
SRC_DUR=$("$BIN" --probe "$WHOLE_SRC" | sed -n 's/^时长: \([0-9.]*\) 秒.*/\1/p')

# ---------- 3 整段模式 ----------
echo
echo "【3】整段模式（不带 --duration，不裁剪）：$WHOLE_NAME"
rm -rf "$OUT/whole"
T0=$(date +%s)
WHOLE_LOG=$("$BIN" --video "$WHOLE_SRC" --out "$OUT/whole" --name whole 2>&1)
WHOLE_RC=$?
T1=$(date +%s)
echo "$WHOLE_LOG" | sed 's/^/  | /'
check "整段模式跑通（退出码 0）" "$([ "$WHOLE_RC" = "0" ] && echo 1 || echo 0)"

WHOLE_DUR=$("$BIN" --inspect "$OUT/whole/whole.jpg" "$OUT/whole/whole.mov" 2>/dev/null \
            | sed -n 's/.*MOV 实际时长 = \([0-9.]*\) 秒.*/\1/p' | head -1)
echo
echo "  源视频时长 = ${SRC_DUR}s    输出 MOV 时长 = ${WHOLE_DUR}s"
check "输出时长 == 源时长（差 ≤ 0.1 秒）" \
      "$(awk -v a="$SRC_DUR" -v b="${WHOLE_DUR:-0}" 'BEGIN{d=a-b; if(d<0)d=-d; print (d<=0.1)?1:0}')"
check "整段转换耗时 $((T1-T0)) 秒 < 视频时长 ${SRC_DUR}s（说明是直通复制，不是逐帧重编码）" \
      "$(awk -v e="$((T1-T0))" -v d="$SRC_DUR" 'BEGIN{print (e<d)?1:0}')"

# ---------- 4 长时长参数 ----------
echo
echo "【4】长时长：--duration 10（证明没写死上限）"
rm -rf "$OUT/ten"
"$BIN" --video "$WHOLE_SRC" --out "$OUT/ten" --name ten --duration 10 > /dev/null 2>&1
TEN=$("$BIN" --inspect "$OUT/ten/ten.jpg" "$OUT/ten/ten.mov" 2>/dev/null \
      | sed -n 's/.*MOV 实际时长 = \([0-9.]*\) 秒.*/\1/p' | head -1)
check "MOV 时长 ${TEN}s ≈ 10 秒（9.5~10.5）" \
      "$(awk -v d="${TEN:-0}" 'BEGIN{print (d>=9.5 && d<=10.5)?1:0}')"

# ---------- 5 批量 ----------
echo
echo "【5】批量：--at 30,120 --duration 5（应该 2 组 4 个文件）"
rm -rf "$OUT/batch"
"$BIN" --video "$WHOLE_SRC" --out "$OUT/batch" --name b --at 30,120 --duration 5 > /dev/null 2>&1
NB=$(ls -1 "$OUT/batch" 2>/dev/null | grep -c -E '\.(jpg|mov)$')
check "产出文件数 = 4（实际 ${NB}）" "$([ "$NB" = "4" ] && echo 1 || echo 0)"
B1=$("$BIN" --inspect "$OUT/batch/b_1.jpg" "$OUT/batch/b_1.mov" 2>/dev/null \
     | sed -n 's/.*MOV 实际时长 = \([0-9.]*\) 秒.*/\1/p' | head -1)
check "第 1 组时长 ${B1}s ≈ 5 秒" \
      "$(awk -v d="${B1:-0}" 'BEGIN{print (d>=4.5 && d<=5.5)?1:0}')"

# ---------- 6 配对三件事 ----------
echo
echo "【6】配对自检（--inspect 的三项）"
rm -rf "$OUT/pair"
"$BIN" --video "$SRC" --out "$OUT/pair" --name pair --at 5,12 --duration 3 > /dev/null 2>&1
NP=$(ls -1 "$OUT/pair" 2>/dev/null | grep -c -E '\.(jpg|mov)$')
check "测试片 --at 5,12 --duration 3 产出 4 个文件（实际 ${NP}）" "$([ "$NP" = "4" ] && echo 1 || echo 0)"
rm -rf "$OUT/long"
"$BIN" --video "$SRC" --out "$OUT/long" --name long10 --at 5 --duration 10 > /dev/null 2>&1
LONG=$("$BIN" --inspect "$OUT/long/long10.jpg" "$OUT/long/long10.mov" 2>/dev/null)
LONG_RC=$?
echo "$LONG" | sed 's/^/  | /'
check "a+b+c 三项全通过（--inspect 退出码 0）" "$([ "$LONG_RC" = "0" ] && echo 1 || echo 0)"
check "a 两端 asset identifier 相同" \
      "$(echo "$LONG" | grep -c '通过：JPG 与 MOV 的 asset identifier 相同' | awk '{print ($1>=1)?1:0}')"
check "b metadata 轨格式为 still-image-time" \
      "$(echo "$LONG" | grep -c '通过：存在 boxed metadata 轨' | awk '{print ($1>=1)?1:0}')"
check "c 读出了 MOV 实际时长（>=9.5 秒）" \
      "$(echo "$LONG" | sed -n 's/.*MOV 实际时长 = \([0-9.]*\) 秒.*/\1/p' | awk 'NF{print ($1>=9.5)?1:0}' | head -1)"

# ---------- 7 竖屏不变形 ----------
echo
echo "【7】竖屏不变形"
if [ -f "$REAL" ]; then
  rm -rf "$OUT/portrait-real"
  "$BIN" --video "$REAL" --out "$OUT/portrait-real" --name pr --at 10 --duration 2 > /dev/null 2>&1
  PR=$("$BIN" --inspect "$OUT/portrait-real/pr.jpg" "$OUT/portrait-real/pr.mov" 2>/dev/null \
       | sed -n 's/.*显示尺寸 \([0-9]*x[0-9]*\).*/\1/p' | head -1)
  SRC_SIZE=$("$BIN" --probe "$REAL" | sed -n 's/.*显示 \([0-9]*x[0-9]*\).*/\1/p' | head -1)
  echo "  源显示尺寸 ${SRC_SIZE}   输出显示尺寸 ${PR}"
  check "竖屏尺寸保持一致（源 ${SRC_SIZE} == 输出 ${PR}）" "$([ "$SRC_SIZE" = "$PR" ] && echo 1 || echo 0)"
else
  PT=$("$BIN" --probe "$SRC" | sed -n 's/.*显示 \([0-9]*x[0-9]*\).*/\1/p' | head -1)
  echo "  （真素材不在本机，跳过竖屏检查；测试片是横屏 ${PT}）"
fi

# ---------- 8 首尾帧定格补长 ----------
echo
echo "【8】源片比 --duration 短：首尾帧定格撑长"
rm -rf "$OUT/pad"
PAD=$("$BIN" --video "$SRC" --out "$OUT/pad" --name pad30 --at 5 --duration 30 2>&1)
echo "$PAD" | grep -E '方式|输出时长' | sed 's/^/  | /'
PADDUR=$("$BIN" --inspect "$OUT/pad/pad30.jpg" "$OUT/pad/pad30.mov" 2>/dev/null \
         | sed -n 's/.*MOV 实际时长 = \([0-9.]*\) 秒.*/\1/p' | head -1)
check "20 秒源片 + --duration 30 → MOV 时长 ${PADDUR}s ≈ 30 秒" \
      "$(awk -v d="${PADDUR:-0}" 'BEGIN{print (d>=29.5 && d<=30.5)?1:0}')"
L1=$("$BIN" --grab "$OUT/pad/pad30.mov" 1 "$OUT/pad/frame-1s.jpg" | sed -n 's/.*平均亮度 \([0-9.]*\) .*/\1/p')
L2=$("$BIN" --grab "$OUT/pad/pad30.mov" 29 "$OUT/pad/frame-29s.jpg" | sed -n 's/.*平均亮度 \([0-9.]*\) .*/\1/p')
echo "  定格段第 1 秒亮度 ${L1}，第 29 秒亮度 ${L2}（0 = 黑帧，说明定格没成）"
check "定格出来的画面不是黑帧（两处亮度都 > 5）" \
      "$(awk -v a="${L1:-0}" -v b="${L2:-0}" 'BEGIN{print (a>5 && b>5)?1:0}')"
check "首段与末段内容不同（亮度不相等，说明一段定的是首帧、一段定的是末帧）" \
      "$(awk -v a="${L1:-0}" -v b="${L2:-0}" 'BEGIN{d=a-b; if(d<0)d=-d; print (d>1)?1:0}')"

# ---------- 9 清单 ----------
echo
echo "【9】产物清单"
ls -la bin
echo
ls -la "$OUT"
echo
echo "--- 交付文件 md5 / mtime（证明真写盘了）---"
for f in video2livephoto.swift mktestvideo.swift build.sh livephoto.sh verify.sh; do
  printf "%s  md5=%s  mtime=%s\n" "$f" "$(md5 -q "$f")" "$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$f")"
done
for f in bin/video2livephoto bin/mktestvideo; do
  printf "%s  md5=%s  mtime=%s\n" "$f" "$(md5 -q "$f")" "$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$f")"
done

echo
echo "=========================================================="
echo " 通过 $PASS 项，不通过 $FAIL 项"
echo "=========================================================="
if [ "$FAIL" -eq 0 ]; then
  echo "自检全部通过。"
  exit 0
else
  echo "自检有失败项，看上面标了 [不通过] 的行。"
  exit 1
fi
