#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify-motionphoto.py —— 真解析一个 Motion Photo，逐项打印并判定。

用法:
    python3 verify-motionphoto.py <产物.jpg> [--source <源视频>] [--quiet]

退出码: 0 = 全项通过；1 = 有任一检查不通过（会指明是哪一项）。

它做 6 件事：
  1. 读 JPEG 结构：FF D8 开头、找到 EOI、EOI 之后才是视频、Pillow 还能解码出尺寸
  2. 找到 XMP(APP1/标识串 http://ns.adobe.com/xap/1.0/) 并把每个字段打印出来
  3. 由 MicroVideoOffset 反算视频起点，验证起点合法、该处是 ftyp、长度自洽、offset 逐字节相等
  4. 把嵌入的 MP4 切出来单独存一份，读它的时长，和源视频比（证明没被裁剪）
  5. 用 Pillow 读图片的 XMP，确认读得到、字段齐全
  6. 打印「正着算 / 倒着算」对照表
"""

import argparse
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TMPDIR = os.path.join(HERE, ".tmp")
BIN_REMUX = os.path.join(HERE, "bin", "remux-faststart")
XMP_ID = b"http://ns.adobe.com/xap/1.0/\x00"

RESULTS = []


def record(name, ok, detail=""):
    RESULTS.append((name, ok, detail))
    print(("[ OK ] " if ok else "[FAIL] ") + name + (("  — " + detail) if detail else ""),
          flush=True)
    return ok


def die(msg):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(2)


# ------------------------------------------------------------------ JPEG

def jpeg_layout(data):
    """返回 (segments, sos_offset, eoi_offset)。segments = [(marker, raw), ...]，只到 SOS 之前。"""
    if data[:2] != b"\xff\xd8":
        die("不是 JPEG：开头不是 FF D8")
    segs, off, n = [], 2, len(data)
    while off + 4 <= n:
        if data[off] != 0xFF:
            die("JPEG 段结构坏了：0x%X 处不是段标记" % off)
        m = data[off + 1]
        if m == 0xD9:
            die("还没到 SOS 就遇到 EOI")
        if m == 0xDA:
            eoi = data.find(b"\xff\xd9", off)
            if eoi < 0:
                die("找不到 EOI(FF D9)")
            return segs, off, eoi
        if m == 0xD8 or 0xD0 <= m <= 0xD7 or m == 0x01:
            off += 2
            continue
        ln = struct.unpack(">H", data[off + 2:off + 4])[0]
        if ln < 2 or off + 2 + ln > n:
            die("JPEG 段长度不合法：FF%02X 在 0x%X" % (m, off))
        segs.append((m, data[off:off + 2 + ln]))
        off += 2 + ln
    die("扫描不到 SOS")


# ------------------------------------------------------------------ MP4

def top_boxes(path):
    total = os.path.getsize(path)
    out, off = [], 0
    with open(path, "rb") as f:
        while off + 8 <= total:
            f.seek(off)
            h = f.read(8)
            if len(h) < 8:
                break
            n = struct.unpack(">I", h[:4])[0]
            typ = h[4:8].decode("latin1")
            if n == 1:
                n = struct.unpack(">Q", f.read(8))[0]
            elif n == 0:
                n = total - off
            if n < 8:
                break
            out.append((typ, off, n))
            off += n
    return out


def mvhd_duration(path):
    with open(path, "rb") as f:
        data = f.read(4 * 1024 * 1024)
    i = data.find(b"mvhd")
    if i < 0:
        return None
    try:
        if data[i + 4] == 0:
            ts, dur = struct.unpack(">II", data[i + 16:i + 24])
        else:
            ts, dur = struct.unpack(">IQ", data[i + 20:i + 32])
    except struct.error:
        return None
    return (dur / ts) if ts else None


def avf_duration(path):
    """用 AVFoundation 读时长（调编译好的 Swift 工具）。拿不到返回 None。"""
    if not os.path.exists(BIN_REMUX):
        return None
    r = subprocess.run([BIN_REMUX, "--info", path], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    m = re.search(r"时长: ([0-9.]+) 秒 \(AVFoundation\)", r.stdout)
    return float(m.group(1)) if m else None


def mdls_duration(path):
    try:
        r = subprocess.run(["mdls", "-name", "kMDItemDurationSeconds", path],
                           capture_output=True, text=True)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    m = re.search(r"=\s*([0-9.]+)\s*$", r.stdout.strip())
    return float(m.group(1)) if m else None


# ------------------------------------------------------------------ XMP

def parse_xmp(xml_text):
    fields = {}
    for k in ("MotionPhoto", "MotionPhotoVersion", "MotionPhotoPresentationTimestampUs",
              "MicroVideo", "MicroVideoVersion", "MicroVideoOffset",
              "MicroVideoPresentationTimestampUs"):
        m = re.search(r'GCamera:%s="([^"]*)"' % k, xml_text)
        fields["GCamera:" + k] = m.group(1) if m else None
    items = []
    for m in re.finditer(r"<Container:Item\b([^>]*)/>", xml_text):
        attrs = dict(re.findall(r'(\w+:\w+)="([^"]*)"', m.group(1)))
        items.append(attrs)
    fields["Container:Item"] = items
    fields["_ns"] = {
        pfx: bool(re.search(r'xmlns:%s="([^"]*)"' % pfx, xml_text))
        for pfx in ("GCamera", "Container", "Item")
    }
    return fields


def main():
    ap = argparse.ArgumentParser(description="校验一个安卓 Motion Photo 的字节结构")
    ap.add_argument("file", help="产物 .jpg")
    ap.add_argument("--source", default=None, help="源视频，用来比对时长（证明没裁剪）")
    ap.add_argument("--quiet", action="store_true", help="少打印过程（不推荐）")
    args = ap.parse_args()
    path = args.file
    if not os.path.exists(path):
        die("文件不存在: " + path)

    data = open(path, "rb").read()
    file_len = len(data)
    print("=== 校验 %s ===" % path)
    print("文件总长: %d 字节 (%.3f MiB)" % (file_len, file_len / 1048576.0))
    print()

    # ---- 1. JPEG 结构
    print("--- 1. JPEG 结构 ---")
    record("JPEG 以 FF D8 开头", data[:2] == b"\xff\xd8", "实际 %s" % data[:2].hex().upper())
    segs, sos, eoi = jpeg_layout(data)
    jpeg_len = eoi + 2
    record("找到 EOI(FF D9)", data[eoi:eoi + 2] == b"\xff\xd9",
           "EOI 在 0x%X，图片到 %d 字节结束（含 EOI）" % (eoi, jpeg_len))
    record("EOI 之后还有数据（视频）", file_len > jpeg_len,
           "EOI 之后 %d 字节" % (file_len - jpeg_len))

    ok_pil = False
    try:
        from PIL import Image
        with Image.open(path) as im:            # 打开整个文件（含尾部视频）
            im.load()
            ok_pil = True
            d = "尺寸 %dx%d，格式 %s" % (im.size[0], im.size[1], im.format)
        record("Pillow 能打开并解码（整个文件）", ok_pil, d)
    except Exception as e:
        record("Pillow 能打开并解码（整个文件）", False, repr(e))

    # ---- 2. XMP
    print()
    print("--- 2. XMP（APP1 段） ---")
    xmps = [(m, raw) for m, raw in segs if m == 0xE1 and raw[4:4 + len(XMP_ID)] == XMP_ID]
    record("找到 XMP APP1 段（标识串 http://ns.adobe.com/xap/1.0/）", len(xmps) == 1,
           "共 %d 段" % len(xmps))
    if not xmps:
        summary()
    xmp_raw = xmps[0][1]
    xmp_packet = xmp_raw[4 + len(XMP_ID):]
    seg_off = 2 + sum(len(r) for _, r in segs[:segs.index(xmps[0])])
    print("  APP1 段位置 0x%X，段长 %d，XMP 包 %d 字节" % (seg_off, len(xmp_raw), len(xmp_packet)))
    xml_text = xmp_packet.decode("utf-8", "replace")
    f = parse_xmp(xml_text)
    print("  --- XMP 里的每个字段 ---")
    for k in ("MotionPhoto", "MotionPhotoVersion", "MotionPhotoPresentationTimestampUs",
              "MicroVideo", "MicroVideoVersion", "MicroVideoOffset",
              "MicroVideoPresentationTimestampUs"):
        print("  %-46s = %s" % ("GCamera:" + k, f["GCamera:" + k]))
    for i, it in enumerate(f["Container:Item"]):
        print("  Container:Item[%d] %s" % (i, it))
    print("  xmlns 声明: %s" % f["_ns"])

    needed = ["GCamera:MotionPhoto", "GCamera:MotionPhotoVersion",
              "GCamera:MotionPhotoPresentationTimestampUs", "GCamera:MicroVideo",
              "GCamera:MicroVideoVersion", "GCamera:MicroVideoOffset",
              "GCamera:MicroVideoPresentationTimestampUs"]
    missing = [k for k in needed if f[k] is None]
    record("新一代 + 老一代字段齐全", not missing,
           "缺: %s" % missing if missing else "7 个 GCamera 字段都在")

    items = f["Container:Item"]
    ok_items = (len(items) == 2
                and items[0].get("Item:Semantic") == "Primary"
                and items[0].get("Item:Mime") == "image/jpeg"
                and items[1].get("Item:Semantic") == "MotionPhoto"
                and items[1].get("Item:Mime") == "video/mp4")
    record("Container:Directory 两项（Primary / MotionPhoto）", ok_items,
           "" if ok_items else "实际 %s" % items)

    # ---- 3. 由 offset 反算视频起点
    print()
    print("--- 3. 由 MicroVideoOffset 反算视频起点 ---")
    off_str = f["GCamera:MicroVideoOffset"]
    len_str = items[1].get("Item:Length") if len(items) > 1 else None
    try:
        off_val = int(off_str)
    except (TypeError, ValueError):
        record("MicroVideoOffset 是整数", False, "实际 %r" % off_str)
        summary()
    try:
        len_val = int(len_str)
    except (TypeError, ValueError):
        record("Item:Length 是整数", False, "实际 %r" % len_str)
        summary()

    video_start = file_len - off_val          # 由 XMP 里的 offset 反算（倒着算）
    obs_start = jpeg_len                      # 由 JPEG 结构实测（正着算），两条路互相独立
    record("反算出的视频起点落在文件内", 0 < video_start < file_len,
           "起点 = %d（文件总长 %d − offset %d）" % (video_start, file_len, off_val))
    if not (0 < video_start < file_len):
        summary()
    record("由 offset 反算的起点 == JPEG 实测的起点", video_start == obs_start,
           "反算 %d vs 实测（EOI 之后）%d" % (video_start, obs_start))
    record("实测视频起点处是合法 MP4（有 ftyp box）",
           data[obs_start + 4:obs_start + 8] == b"ftyp",
           "该处 box 类型 = %r" % data[obs_start + 4:obs_start + 8])
    # 下面这几条一律用「实测起点」算，不能用 offset 自己算出来的起点，
    # 否则是恒真等式（那样校验就是假的，改坏了也照样过）。
    tail = file_len - obs_start
    record("实测视频长度（文件末尾 − 实测起点）== XMP 的 Item:Length", tail == len_val,
           "%d vs XMP 写 %d" % (tail, len_val))
    record("Item:Length == MicroVideoOffset", len_val == off_val,
           "%d vs %d" % (len_val, off_val))
    recomputed = str(tail)
    record("重新算的 offset（文件总长 − 实测起点）和 XMP 里写的逐字节相等",
           recomputed.encode() == off_str.encode(),
           "%r vs %r" % (recomputed, off_str))

    # ---- 4. 切出 MP4 比时长
    print()
    print("--- 4. 切出嵌入的 MP4，比时长（证明整段没裁） ---")
    os.makedirs(TMPDIR, exist_ok=True)
    base = os.path.splitext(os.path.basename(path))[0]
    emb = os.path.join(TMPDIR, "verify-%s-video.mp4" % base)
    with open(emb, "wb") as fp:
        fp.write(data[obs_start:])          # 从实测起点切，不用 offset 自己算的起点
    emb_len = os.path.getsize(emb)
    record("切出的 MP4 大小 == Item:Length", emb_len == len_val,
           "%d 字节，XMP 写 %d" % (emb_len, len_val))
    boxes = top_boxes(emb)
    order = " ".join(b[0] for b in boxes)
    print("  切出的 MP4 顶层 box: %s" % order)
    moov_i = next((i for i, b in enumerate(boxes) if b[0] == "moov"), None)
    mdat_i = next((i for i, b in enumerate(boxes) if b[0] == "mdat"), None)
    record("切出的 MP4 是 faststart（moov 在 mdat 前）",
           moov_i is not None and mdat_i is not None and moov_i < mdat_i, order)

    emb_mvhd = mvhd_duration(emb)
    emb_avf = avf_duration(emb)
    emb_mdls = mdls_duration(emb)
    print("  切出的 MP4 时长: mvhd=%.6f 秒  AVFoundation=%s  mdls=%s"
          % (emb_mvhd or -1, "%.6f" % emb_avf if emb_avf else "拿不到",
             "%.6f" % emb_mdls if emb_mdls else "拿不到"))
    src = args.source
    if src:
        if not os.path.exists(src):
            record("源视频存在", False, src)
        else:
            src_mvhd = mvhd_duration(src)
            src_avf = avf_duration(src)
            print("  源视频时长      : mvhd=%.6f 秒  AVFoundation=%s"
                  % (src_mvhd or -1, "%.6f" % src_avf if src_avf else "拿不到"))
            ref = src_avf or src_mvhd
            got = emb_avf or emb_mvhd
            ok = ref is not None and got is not None and abs(got - ref) <= 0.02
            record("嵌入视频时长 == 源视频时长（没被裁剪）", ok,
                   "源 %.6f 秒 vs 嵌入 %.6f 秒（差 %+.6f 秒）"
                   % (ref or -1, got or -1, (got or 0) - (ref or 0)))
    else:
        print("  （没给 --source，跳过和源视频的时长比对）")

    # ---- 5. Pillow 读 XMP
    print()
    print("--- 5. 用 Pillow 读图片的 XMP ---")
    try:
        from PIL import Image
        with Image.open(path) as im:
            raw = im.info.get("xmp")
        record("Pillow 读得到 XMP", raw is not None,
               "%d 字节" % len(raw) if raw else "info 里没有 xmp")
        if raw is not None:
            record("Pillow 读到的 XMP 和我们解析的是同一份",
                   raw.rstrip(b"\x00 ") == xmp_packet.rstrip(b"\x00 "))
            pf = parse_xmp(raw.decode("utf-8", "replace"))
            miss2 = [k for k in needed if pf[k] is None]
            record("Pillow 读到的 XMP 字段齐全", not miss2,
                   "缺: %s" % miss2 if miss2 else "7 个字段都在")
        import importlib.util
        if importlib.util.find_spec("defusedxml") is None:
            print("  [跳过] Pillow getxmp() 结构化解析：本机没装 defusedxml（Pillow 官方依赖），"
                  "它会报警告并返回空。改用 info['xmp'] 原始字节自己解析，结论不受影响。")
        else:
            try:
                with Image.open(path) as im:
                    d = im.getxmp()
                record("Pillow getxmp() 结构化解析", bool(d), "解析出 %d 个顶层键" % len(d))
            except Exception as e:
                record("Pillow getxmp() 结构化解析", False, repr(e))
    except Exception as e:
        record("Pillow 读得到 XMP", False, repr(e))

    # ---- 6. 正算 / 倒算对照
    print()
    print("--- 6. 正着算 / 倒着算 对照 ---")
    print("  正着算（用 JPEG 结构实测，从文件开头往后）:")
    print("    文件总长                     %d" % file_len)
    print("    JPEG 段结束（EOI 之后）      %d" % obs_start)
    print("    视频长度 = 文件总长 − 实测起点 %d" % tail)
    print("  倒着算（用 XMP 里的 offset，从文件末尾往前）:")
    print("    XMP 里的 MicroVideoOffset    %s" % off_str)
    print("    反算的视频起始 = %d − %s = %d" % (file_len, off_str, video_start))
    print("    XMP 里的 Item:Length         %s" % len_str)
    print("  对照:")
    print("    正着算起点 %d  ==  倒着算起点 %d   %s"
          % (obs_start, video_start, "一致" if obs_start == video_start else "不一致!!"))
    print("    正着算视频长度 %d  ==  MicroVideoOffset %s   %s"
          % (tail, off_str, "一致" if str(tail) == off_str else "不一致!!"))
    print("    Item:Length %s  ==  MicroVideoOffset %s   %s"
          % (len_str, off_str, "一致" if off_str == len_str else "不一致!!"))

    summary()


def summary():
    print()
    fails = [r for r in RESULTS if not r[1]]
    print("=== 结果: %d 项检查，%d 项通过，%d 项不通过 ==="
          % (len(RESULTS), len(RESULTS) - len(fails), len(fails)))
    if fails:
        for name, _, detail in fails:
            print("  不通过: %s  — %s" % (name, detail))
        print("退出码 1")
        sys.exit(1)
    print("退出码 0")
    sys.exit(0)


if __name__ == "__main__":
    main()