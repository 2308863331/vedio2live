#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
motionphoto.py —— 把「一张 JPEG」+「一段 MP4」组装成一个安卓 Motion Photo 单文件。

产物结构（就三块，顺序固定）：
    [ FFD8 ... JPEG 数据 ... FFD9 ]  +  [ MP4 全部字节 ]
                                      ↑ 视频直接接在 EOI 后面
    XMP 写在 JPEG 的 APP1 段里，声明「视频从末尾往前数多少字节开始、有多少字节」。

用法:
    python3 motionphoto.py --video <视频> --out <输出.jpg> [--at <秒>] [--name <前缀>]
                           [--image <已有的封面jpg>] [--no-remux]

注意：这是安卓的 Motion Photo（单文件），不是苹果的 Live Photo（jpg+mov 两个文件）。两者不兼容。
"""

import argparse
import os
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TMPDIR = os.path.join(HERE, ".tmp")
BIN_REMUX = os.path.join(HERE, "bin", "remux-faststart")
# 复用已有的苹果实况图工具抽封面帧（只读调用，不修改它）
GRAB_TOOL = os.environ.get(
    "MOTIONPHOTO_GRAB_TOOL",
    "apple-livephoto/bin/video2livephoto",
)

XMP_NS = 'http://ns.adobe.com/xap/1.0/'
XMP_ID = b'http://ns.adobe.com/xap/1.0/\x00'


def log(msg):
    print(msg, flush=True)


def die(msg):
    print("错误: " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


# ---------------------------------------------------------------- MP4 box 扫描

def top_boxes(path):
    """返回顶层 box 列表 [(type, offset, size), ...]。"""
    size_total = os.path.getsize(path)
    out = []
    with open(path, "rb") as f:
        off = 0
        while off + 8 <= size_total:
            f.seek(off)
            h = f.read(8)
            if len(h) < 8:
                break
            n = struct.unpack(">I", h[:4])[0]
            typ = h[4:8].decode("latin1")
            if n == 1:
                n = struct.unpack(">Q", f.read(8))[0]
            elif n == 0:
                n = size_total - off
            if n < 8:
                break
            out.append((typ, off, n))
            off += n
    return out


def is_faststart(path):
    """moov 是否在 mdat 前面。判断不了返回 None。"""
    boxes = top_boxes(path)
    mi = next((i for i, b in enumerate(boxes) if b[0] == "moov"), None)
    di = next((i for i, b in enumerate(boxes) if b[0] == "mdat"), None)
    if mi is None or di is None:
        return None
    return mi < di


def mp4_duration(path):
    """直接读 moov/mvhd 拿时长（秒），不依赖 AVFoundation。拿不到返回 None。"""
    with open(path, "rb") as f:
        data = f.read(4 * 1024 * 1024)
    i = data.find(b"mvhd")
    if i < 0:
        return None
    ver = data[i + 4]
    try:
        if ver == 0:
            ts, dur = struct.unpack(">II", data[i + 16:i + 24])
        else:
            ts, dur = struct.unpack(">IQ", data[i + 20:i + 32])
    except struct.error:
        return None
    if ts == 0:
        return None
    return dur / ts


def has_ftyp(path, offset=0):
    with open(path, "rb") as f:
        f.seek(offset)
        head = f.read(8)
    return len(head) == 8 and head[4:8] == b"ftyp"


# 能被安卓当成 video/mp4 吃的 ftyp 主品牌。QuickTime 的 'qt  ' 不在里面。
MP4_BRANDS = {b"isom", b"iso2", b"iso4", b"iso5", b"iso6", b"mp41", b"mp42",
              b"avc1", b"dash", b"MSNV", b"M4V ", b"M4VH", b"M4VP", b"f4v ",
              b"cmfc", b"3gp4", b"3gp5"}


def ftyp_brand(path):
    """读 ftyp 的主品牌。拿不到返回 None。"""
    with open(path, "rb") as f:
        head = f.read(16)
    if len(head) < 12 or head[4:8] != b"ftyp":
        return None
    return head[8:12]


def ensure_faststart(video, name):
    """
    产物里嵌的视频必须同时满足两条，否则拿不到就重封装一份：
      1. 是 MP4（ftyp 主品牌是 mp4 系，不是 QuickTime 的 'qt  '）—— 否则安卓按 video/mp4 解会失败
      2. faststart（moov 在 mdat 前）—— 否则从中间位置起播会卡
    """
    brand = ftyp_brand(video)
    ok_brand = brand in MP4_BRANDS
    ok_fast = is_faststart(video)
    log("源视频顶层 box: " + " ".join(b[0] for b in top_boxes(video)))
    log("源视频 ftyp 主品牌: %s（%s）" % (brand.decode("latin1") if brand else "无",
                                        "MP4 系" if ok_brand else "不是 MP4 系"))
    need = not ok_brand or ok_fast is not True
    if not need:
        log("源视频已是 MP4 + faststart，直接复用原字节，不重封装")
        return video, False
    log("需要重封装：%s%s" % ("" if ok_brand else "不是 MP4 容器；",
                            "" if ok_fast is True else "moov 不在 mdat 前"))
    if not os.path.exists(BIN_REMUX):
        die("找不到 %s，先跑 bash build.sh 编译" % BIN_REMUX)
    os.makedirs(TMPDIR, exist_ok=True)
    outv = os.path.join(TMPDIR, "%s-faststart.mp4" % name)
    r = subprocess.run([BIN_REMUX, video, outv], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        die("直通重封装失败（退出码 %d）" % r.returncode)
    if ftyp_brand(outv) not in MP4_BRANDS:
        die("重封装后仍不是 MP4 品牌，产物不可用")
    if is_faststart(outv) is not True:
        die("重封装后 moov 仍不在 mdat 前，产物不可用")
    return outv, True


def grab_cover(video, at, name):
    """用已有工具抽封面帧。"""
    os.makedirs(TMPDIR, exist_ok=True)
    out = os.path.join(TMPDIR, "%s-cover.jpg" % name)
    if not os.path.exists(GRAB_TOOL):
        die("找不到抽帧工具 %s；可以用 --image 直接指定一张封面图" % GRAB_TOOL)
    r = subprocess.run([GRAB_TOOL, "--grab", video, str(at), out],
                       capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    if r.returncode != 0 or not os.path.exists(out):
        die("抽帧失败（退出码 %d）" % r.returncode)
    return out


# ---------------------------------------------------------------- JPEG 段操作

def jpeg_layout(data):
    """
    解析 JPEG 的段结构。
    返回 (segments, sos_offset, eoi_offset)
      segments  : [(marker, 完整段字节), ...]  从 SOI 之后到 SOS 之前
      sos_offset: SOS 段起点
      eoi_offset: EOI(FFD9) 起点；图片到这里结束
    """
    if data[:2] != b"\xff\xd8":
        die("这不是 JPEG：开头不是 FF D8")
    segs = []
    off = 2
    n = len(data)
    while off + 4 <= n:
        if data[off] != 0xFF:
            die("JPEG 段结构坏了：0x%X 处不是段标记" % off)
        m = data[off + 1]
        if m == 0xD9:
            die("还没到 SOS 就遇到 EOI，这张 JPEG 不正常")
        if m == 0xDA:
            # SOS：后面是熵编码数据，找第一个 FF D9（熵数据里 FF 必被转义，FFD9 不会误命中）
            eoi = data.find(b"\xff\xd9", off)
            if eoi < 0:
                die("JPEG 找不到 EOI(FF D9)")
            return segs, off, eoi
        if m == 0xD8 or 0xD0 <= m <= 0xD7 or m == 0x01:
            off += 2
            continue
        ln = struct.unpack(">H", data[off + 2:off + 4])[0]
        if ln < 2 or off + 2 + ln > n:
            die("JPEG 段长度不合法：marker FF%02X 在 0x%X" % (m, off))
        segs.append((m, data[off:off + 2 + ln]))
        off += 2 + ln
    die("JPEG 段结构扫描失败（没找到 SOS）")


def is_xmp_app1(marker, raw):
    return marker == 0xE1 and raw[4:4 + len(XMP_ID)] == XMP_ID


def rebuild_jpeg(data, new_xmp=None):
    """
    重建 JPEG：去掉原有的 XMP APP1（避免两份打架），把 new_xmp 插在开头连续 APP0 之后。
    图片扫描数据一个字节都不动。
    """
    segs, sos, eoi = jpeg_layout(data)
    out = bytearray(b"\xff\xd8")
    i = 0
    while i < len(segs) and segs[i][0] == 0xE0:      # JFIF 规定 APP0 必须紧跟 SOI
        out += segs[i][1]
        i += 1
    if new_xmp is not None:
        payload = XMP_ID + new_xmp                       # APP1 必须是「标识串 + XMP 包」
        if len(payload) + 2 > 0xFFFF:
            die("XMP 超过 APP1 段上限（%d 字节）" % len(payload))
        out += b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload
    for m, raw in segs[i:]:
        if is_xmp_app1(m, raw):
            continue                                  # 丢掉旧 XMP
        out += raw
    head_len = len(out)
    out += data[sos:]                                 # SOS + 图像数据 + EOI，原样
    new_eoi = head_len + (eoi - sos)                  # EOI 在新文件里的位置
    if bytes(out[new_eoi:new_eoi + 2]) != b"\xff\xd9":
        die("重建后 EOI 位置算错了（内部错误）")
    return bytes(out), new_eoi


def build_xmp(video_start_from_end, video_len, pts_us):
    """生成 XMP 包。新一代（GCamera/Container）和老一代（MicroVideo）两套字段同写。"""
    xml = (
        '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="motionphoto.py">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '  <rdf:Description rdf:about=""\n'
        '    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"\n'
        '    xmlns:Container="http://ns.google.com/photos/1.0/container/"\n'
        '    xmlns:Item="http://ns.google.com/photos/1.0/container/item/"\n'
        '    GCamera:MotionPhoto="1"\n'
        '    GCamera:MotionPhotoVersion="1"\n'
        '    GCamera:MotionPhotoPresentationTimestampUs="%d"\n'
        '    GCamera:MicroVideo="1"\n'
        '    GCamera:MicroVideoVersion="1"\n'
        '    GCamera:MicroVideoOffset="%d"\n'
        '    GCamera:MicroVideoPresentationTimestampUs="%d">\n'
        '   <Container:Directory>\n'
        '    <rdf:Seq>\n'
        '     <rdf:li rdf:parseType="Resource">\n'
        '      <Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/>\n'
        '     </rdf:li>\n'
        '     <rdf:li rdf:parseType="Resource">\n'
        '      <Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="%d" Item:Padding="0"/>\n'
        '     </rdf:li>\n'
        '    </rdf:Seq>\n'
        '   </Container:Directory>\n'
        '  </rdf:Description>\n'
        ' </rdf:RDF>\n'
        '</x:xmpmeta>\n'
        '<?xpacket end="w"?>'
    ) % (pts_us, video_start_from_end, pts_us, video_len)
    return xml.encode("utf-8")


# ---------------------------------------------------------------- 组装

def assemble(image_path, video_path, out_path, at):
    img = open(image_path, "rb").read()
    vid = open(video_path, "rb").read()
    video_len = len(vid)
    pts_us = int(round(at * 1_000_000))

    # MicroVideoOffset = 文件总长 − 视频起始偏移；这里视频紧跟在 EOI 后面，
    # 所以它等于视频字节数。但仍然按「算完再回代」的不动点方式做，避免以后加 padding 就写错。
    offset = video_len
    jpeg_full = None
    for it in range(6):
        xmp = build_xmp(offset, video_len, pts_us)
        jpeg_no_video, eoi = rebuild_jpeg(img, new_xmp=xmp)
        file_len = len(jpeg_no_video) + video_len
        video_start = len(jpeg_no_video)
        new_offset = file_len - video_start          # 从文件末尾往前数
        if new_offset == offset:
            jpeg_full = jpeg_no_video
            break
        offset = new_offset
    if jpeg_full is None:
        die("算 MicroVideoOffset 时没收敛")

    # 逐字节自验算：视频起始位置必须正好是 EOI 之后
    _, _, eoi = jpeg_layout(jpeg_full)
    if eoi + 2 != len(jpeg_full):
        die("JPEG 里 EOI 后面还有多余字节，追加位置不对")

    out_dir = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(jpeg_full)
        f.write(vid)

    return {
        "file_len": os.path.getsize(out_path),
        "jpeg_len": len(jpeg_full),
        "video_start": len(jpeg_full),
        "video_len": video_len,
        "offset": offset,
        "pts_us": pts_us,
        "eoi_at": eoi,
    }


def main():
    ap = argparse.ArgumentParser(
        description="把 JPEG + MP4 组成一个安卓 Motion Photo 单文件（不是苹果 Live Photo）")
    ap.add_argument("--video", required=True, help="要嵌进去的视频（整段，不裁剪）")
    ap.add_argument("--out", required=True, help="输出的 .jpg")
    ap.add_argument("--at", type=float, default=0.0, help="封面帧取第几秒，默认 0")
    ap.add_argument("--name", default=None, help="临时文件前缀，默认取视频文件名")
    ap.add_argument("--image", default=None, help="直接指定封面 JPEG，不抽帧")
    ap.add_argument("--no-remux", action="store_true", help="不做 faststart 检查/重封装（调试用）")
    args = ap.parse_args()

    t0 = time.time()
    if not os.path.exists(args.video):
        die("视频不存在: " + args.video)
    name = args.name or os.path.splitext(os.path.basename(args.video))[0]
    os.makedirs(TMPDIR, exist_ok=True)

    log("=== 1/4 规整视频（要 moov 在 mdat 前，否则从中间起播会卡） ===")
    if args.no_remux:
        video, remuxed = args.video, False
        log("--no-remux：跳过 faststart 处理")
    else:
        video, remuxed = ensure_faststart(args.video, name)

    log("=== 2/4 取封面帧 ===")
    if args.image:
        image = args.image
        log("用指定的封面图: " + image)
    else:
        image = grab_cover(args.video, args.at, name)
    log("封面图: %s（%d 字节）" % (image, os.path.getsize(image)))

    log("=== 3/4 组装 ===")
    info = assemble(image, video, args.out, args.at)

    log("=== 4/4 结果 ===")
    log("产物: %s" % args.out)
    log("文件总长        : %d 字节" % info["file_len"])
    log("其中 JPEG 部分  : %d 字节（到 EOI 为止，EOI 在 0x%X）" % (info["jpeg_len"], info["eoi_at"]))
    log("其中视频部分    : %d 字节（整段，未裁剪）" % info["video_len"])
    log("视频起始偏移    : %d（正着数，从文件开头）" % info["video_start"])
    log("写入 XMP 的 offset: %d（倒着数，距文件末尾）" % info["offset"])
    log("自验算          : 文件总长 %d − 视频起始 %d = %d  %s"
        % (info["file_len"], info["video_start"],
           info["file_len"] - info["video_start"],
           "一致" if info["file_len"] - info["video_start"] == info["offset"] else "不一致!"))
    log("封面时刻        : %s 秒 → %d 微秒" % (args.at, info["pts_us"]))
    dur = mp4_duration(video)
    if dur is not None:
        log("嵌入视频时长    : %.6f 秒" % dur)
    log("重封装          : %s" % ("做了（源不是 MP4 或不是 faststart）" if remuxed else "没做（源已是 MP4+faststart，字节原样复用）"))
    log("总耗时          : %.2f 秒" % (time.time() - t0))


if __name__ == "__main__":
    main()
