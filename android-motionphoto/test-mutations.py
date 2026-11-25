#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test-mutations.py —— 反向验证：故意把产物改坏，确认 verify-motionphoto.py 真会报错。

改坏前那份必须退出码 0；4 种改坏方式必须全部退出码 1，且指明是哪一项不通过。
用法: python3 test-mutations.py [产物.jpg] [源视频]
"""

import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.join(HERE, ".tmp", "mutations")
GOOD = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "sample-motionphoto.jpg")
SOURCE = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/Downloads/sample.mp4")


def xmp_offset(data):
    m = re.search(rb'GCamera:MicroVideoOffset="(\d+)"', data)
    return int(m.group(1)) if m else None


def mutate_offset(data):
    m = re.search(rb'GCamera:MicroVideoOffset="(\d+)"', data)
    old = m.group(1)
    new = str(int(old) + 1).encode()
    assert len(new) == len(old), "位数变了就不是同长替换，测试没意义"
    return data[:m.start(1)] + new + data[m.end(1):], \
        "把 XMP 里 MicroVideoOffset 从 %s 改成 %s" % (old.decode(), new.decode())


def mutate_item_length(data):
    m = re.search(rb'(Item:Semantic="MotionPhoto" Item:Length=")(\d+)(")', data)
    old = m.group(2)
    new = str(int(old) - 2).encode()
    assert len(new) == len(old)
    return data[:m.start(2)] + new + data[m.end(2):], \
        "把 XMP 里 Item:Length 从 %s 改成 %s" % (old.decode(), new.decode())


def mutate_truncate(data):
    return data[:-100], "截掉文件末尾 100 字节（视频尾巴被切）"


def mutate_insert(data):
    off = xmp_offset(data)
    file_len = len(data)
    start = file_len - off
    pos = start + 1000
    return data[:pos] + b"\x00" + data[pos:], "在视频中间（起点后 1000 字节处）插 1 个字节"


MUTATIONS = [
    ("改 MicroVideoOffset", mutate_offset, ["offset"]),
    ("改 Item:Length", mutate_item_length, ["Item:Length", "MicroVideoOffset"]),
    ("截掉视频尾部", mutate_truncate, ["Item:Length", "MicroVideoOffset", "时长"]),
    ("视频中间插一字节", mutate_insert, ["Item:Length", "MicroVideoOffset"]),
]


def run_verify(path):
    r = subprocess.run([sys.executable, os.path.join(HERE, "verify-motionphoto.py"),
                        path, "--source", SOURCE],
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main():
    os.makedirs(TMP, exist_ok=True)
    ok = True

    print("== 0. 改坏前的那一份必须先过（退出码 0） ==")
    rc, out = run_verify(GOOD)
    fails = [l for l in out.splitlines() if l.startswith("[FAIL]")]
    print("verify 退出码 = %d" % rc)
    for l in out.splitlines():
        if l.startswith("=== 结果"):
            print(l)
    if rc != 0:
        print("!! 改坏前就没过，反向验证无意义")
        for l in fails:
            print("   " + l)
        sys.exit(1)
    print("改坏前退出码 0 ✓\n")

    good = open(GOOD, "rb").read()
    for i, (name, fn, expect_keywords) in enumerate(MUTATIONS, 1):
        bad, desc = fn(good)
        p = os.path.join(TMP, "bad%d.jpg" % i)
        with open(p, "wb") as f:
            f.write(bad)
        print("== %d. %s ==" % (i, name))
        print("   做法: %s" % desc)
        print("   文件: %s（%d 字节，原 %d 字节）" % (p, len(bad), len(good)))
        rc, out = run_verify(p)
        fail_lines = [l for l in out.splitlines() if l.startswith("[FAIL]")]
        summary = [l for l in out.splitlines() if l.startswith("=== 结果")]
        print("   verify 退出码 = %d" % rc)
        for l in summary:
            print("   " + l)
        for l in fail_lines:
            print("   " + l)
        if rc != 1:
            print("   !! 期望退出码 1，实际 %d —— 校验是假货" % rc)
            ok = False
        elif not fail_lines:
            print("   !! 退出码对但没指出哪一项不过")
            ok = False
        else:
            joined = "\n".join(fail_lines)
            hit = [k for k in expect_keywords if k in joined]
            print("   指出失败项: %s" % ("命中预期关键词 " + str(hit) if hit else "（没命中预期关键词，见上）"))
        print()

    print("=== 反向验证总结: %s ===" % ("4 种改坏方式全部退出码 1，改坏前退出码 0" if ok else "有不符合预期的情况"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()