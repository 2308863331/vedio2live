# video → iPhone 实况照片（Live Photo）转换工具 · 建造报告

交付目录：`apple-livephoto/`
日期：2026-11-25
状态：**全部验收通过**（自检 19 项通过 / 0 项不通过，`verify.sh` 退出码 0）

---

## 0. 一句话结论

能在本机把视频转成 iPhone 实况照片（`.jpg` + `.mov` 一对，共用同一个 UUID，MOV 内有
`still-image-time` 元数据轨）。**默认整段不裁剪**，197 秒的真实素材转出来 197.253 秒（源 197.254 秒），
耗时 7～15 秒且画质零损失（直通复制）。`--duration` 可选裁剪，10 秒 / 30 秒 / 60 秒都不截断。
不需要 ffmpeg、exiftool、Homebrew，没有 sudo，没有联网。

---

## 1. 交付清单与凭据（md5 / mtime）

| 文件 | 大小 | md5 | mtime |
|---|---|---|---|
| `video2livephoto.swift` | 42210 | `f897475ca6c33648addb84872f741b45` | 2026-11-25 16:23:58 |
| `mktestvideo.swift` | 12504 | `3e50941e7b71e9f235841690d03c1b96` | 2026-11-25 16:21:12 |
| `build.sh` | 951 | `14673d887faf776a8af6b26175b56d1b` | 2026-11-25 16:06:46 |
| `livephoto.sh` | 2120 | `8b3441904a1ecf0ac1f2f51fcd143a75` | 2026-11-25 16:26:18 |
| `verify.sh` | 9080 | `77d877a580bb2c51e4fbf611b1c2c515` | 2026-11-25 16:26:18 |
| `README.md` | 5284 | `116e1783809fa06a998911333e05780d` | 2026-11-25 16:25:38 |
| `bin/video2livephoto`（编译产物） | 212128 | `e78b704e61f828440c220b806bc61b4c` | 2026-11-25 16:26:46 |
| `bin/mktestvideo`（编译产物） | 99264 | `5267636542dc8d76a7d11745a4727d41` | 2026-11-25 16:26:55 |
| `test/test-source.mp4`（合成测试片，20 秒/1280x720） | 265761 | `52e9bfe232fbaec59c4613e76e5a269d` | 2026-11-25 16:22:37 |

取这些数的命令：`md5 -q <file>` / `stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' <file>`；
`verify.sh` 每次跑完也会把这张表打印一遍。

---

## 2. 环境与约束（按题目给的事实执行，未重复验证）

- macOS 12.7.6 (Monterey) / Intel x86_64 / Swift 5.7.2（`/Library/Developer/CommandLineTools`）
- 没有 ffmpeg、没有 exiftool，**没有安装任何东西**，没用 sudo
- 文件沙箱 workspace-write：所有临时文件都落在 `apple-livephoto/` 内（`.build-cache/`、`.build-tmp/`、`test/`）
- 参考实现整份读完（654 行）后照抄了它对的两处做法：asset identifier 写法、still-image-time 元数据轨写法；
  `durationVideo(at:outputPath:targetDuration:)` 的「源片短了用首尾帧定格撑长」逻辑保留

---

## 3. 编译

`build.sh` 用 swiftc 直接编译（`-O` + 链接 Foundation / AVFoundation / CoreMedia / CoreVideo / CoreGraphics / ImageIO）。

编译输出（最终一次，原始）：

```
== 编译 video2livephoto ==
  -> bin/video2livephoto
== 编译 mktestvideo ==
  -> bin/mktestvideo

编译完成。
total 616
-rwxr-xr-x  1 <user>  staff   99264 11 25 16:26 mktestvideo
-rwxr-xr-x  1 <user>  staff  212128 11 25 16:26 video2livephoto
```

`error:` 行数 = 0（warning 允许，`verify.sh` 里专门断言了这一条）。

### 踩坑 1：clang 模块缓存写不进去

第一次编译直接失败：

```
<unknown>:0: error: unable to open output file
'/var/folders/.../C/clang/ModuleCache/....pcm': 'Operation not permitted'
<unknown>:0: error: could not build Objective-C module 'AVFoundation'
```

沙箱只让写工作目录，clang 默认拿 `$TMPDIR` 下的模块缓存去写就被拒。
**修法**：`build.sh` 里把缓存和临时目录都指到工具目录内：

```bash
mkdir -p bin .build-cache .build-tmp
export TMPDIR="$(pwd)/.build-tmp"
swiftc -O -module-cache-path "$(pwd)/.build-cache" ...
```

---

## 4. 实现要点（对应 CLI 规格）

### 4.1 两种模式

| 模式 | 触发条件 | 行为 |
|---|---|---|
| 整段（默认） | 不传 `--duration` | 整段视频做成一张实况图，`rangeStart=0`、`rangeDuration=源时长`，封面默认第 0 帧（`--at` 可覆盖） |
| 裁剪 | 显式传 `--duration` | 以 `--at` 为中心向前后各取 `duration/2`，贴边时整体平移不缩短；`--at` 不传则取视频中点 |

`--at` 支持逗号分隔多个时间点，一次出多组（这是核心价值：批量）。
`--duration` 无上限，源码里没有任何时长常量；用 `--duration 10`、`30`、`60` 实测过。

### 4.2 三条产出路径（按需要选，能直通就不重编码）

1. **直通复制（默认）**：`AVMutableComposition` 里用 `insertTimeRange(at: .zero)` 把片段重排到 0 起，
   `AVAssetReaderTrackOutput(outputSettings: nil)` → `AVAssetWriterInput(outputSettings: nil)`，
   压缩样本原样搬。画质零损失，速度接近拷文件。
2. **`--width` 缩放**：`AVAssetReaderVideoCompositionOutput` + `AVVideoComposition`（renderSize + 旋转纠正）
   → H.264 编码。**单遍完成，不落临时文件**。只有显式要缩放才走这条路。
3. **首尾帧定格补长**（源片比 `--duration` 短）：照参考实现的做法，合成轨里插入首帧/末帧各 1 帧再
   `scaleTimeRange` 撑到目标时长。这一步**必须重编码**，所以走
   `AVAssetExportSession`（HighestQuality）先导出一个临时 MOV，再直通包一层元数据；临时文件在 `defer` 里删掉。
   整段模式和普通裁剪**都不走两遍写盘**。

### 4.3 元数据（照抄参考实现，这是「能被 iOS 认成实况照片」的关键）

- `writer.metadata = [assetID]`，key = `com.apple.quicktime.content.identifier`，值 = 每组新生成的 UUID
- still-image-time 轨：`CMMetadataFormatDescriptionCreateWithMetadataSpecifications`
  （`kCMMetadataFormatType_Boxed` + `mdta/com.apple.quicktime.still-image-time` + `int8`）
  → `AVAssetWriterInputMetadataAdaptor`，样本的 `timeRange.start` = 封面帧在**输出**里的时间
  （整段模式 = `--at`；裁剪模式 = `--at - 片段起点`）
- JPG：`CGImageDestinationAddImage` 带 `kCGImagePropertyMakerAppleDictionary: ["17": UUID]`
- `writer.shouldOptimizeForNetworkUse = true`（moov 前置，等价 faststart）

### 4.4 竖屏

直通路径把源轨的 `preferredTransform` 原样写到 writer input 上；重编码路径用
`AVVideoComposition` 的 `renderSize` + layer transform 把方向烘焙进画面。
实测 720x1280 竖屏素材进出都是 720x1280（见验收 §6.7），没被转成横屏。

### 4.5 失败不静默

任何一步失败都 `throw ToolError` → 主流程 `fail()` → 打印中文错误 + `exit(1)`。
写入等待都有上限（元数据/编码器 ready 等 10 秒即报错），不会静默挂死。

### 4.6 边角处理

- 输出目录不存在自动创建；重名文件先删再写
- `--at` 超出视频时长 → 明确报错退出（不猜、不静默裁剪）
- 每组封面时刻、片段区间、输出时长、耗时、still-image-time 位置全部打印出来
- 清掉 `AVAssetWriter` 在输出目录留下的 `.sb-xxxx` 中间文件

---

## 5. 验收（原始输出）

### 5.1 验收 1：`bash build.sh` 编译成功，0 error

见 §3。`grep -c 'error:'` = 0。

### 5.2 验收 2：生成测试视频成功（本机无 ffmpeg，AVFoundation 自己合成）

```
$ ./bin/mktestvideo test/test-source.mp4 20 1280 720 30
完成: apple-livephoto/test/test-source.mp4
  20 秒 / 1280x720 / 30fps / 600 帧 / 440Hz 正弦音 / 265761 字节

$ ./bin/video2livephoto --probe test/test-source.mp4
== 探测 ==
文件: .../test/test-source.mp4
大小: 265761 字节
时长: 20.000 秒
轨: mediaType=vide 编码 1280x720 显示 1280x720 帧率 30.00
轨: mediaType=soun 编码 0x0 显示 0x0 帧率 43.07
```

画面：前半段深蓝底 + 黄方块从左向右、后半段深红底 + 绿方块、底部进度条、中间竖直分界线；
带 440Hz 正弦音（用来验证音频能不能被带到实况图里）。首/末帧已用 `--grab` 目视确认（见 §6.9）。

### 5.3 验收 3：测试片跑 `--at 5,12 --duration 3`，出 2 组 4 个文件

```
$ ./bin/video2livephoto --video test/test-source.mp4 --out test/out-pair --name pair --at 5,12 --duration 3
[1/2] 封面 5s → pair_1.jpg / pair_1.mov
  片段 [3.500s, 6.500s)，长度 3.000s
  方式: 直通复制（不重编码）
  输出时长 3.000 秒（源片片段 3.000 秒）｜still-image-time 在 1.500 秒｜耗时 0.54 秒
[2/2] 封面 12s → pair_2.jpg / pair_2.mov
  片段 [10.500s, 13.500s)，长度 3.000s
  方式: 直通复制（不重编码）
  输出时长 3.000 秒（源片片段 3.000 秒）｜still-image-time 在 1.500 秒｜耗时 0.21 秒

完成：共 2 组，4 个文件，总耗时 0.75 秒。

$ ls -la
-rw-r--r--  1 <user>  staff   31636  pair_1.jpg
-rw-r--r--  1 <user>  staff   42298  pair_1.mov
-rw-r--r--  1 <user>  staff   32396  pair_2.jpg
-rw-r--r--  1 <user>  staff   48564  pair_2.mov
```

### 5.4 验收 4：长时长不被截断 —— `--duration 10` → 10.000 秒

```
$ ./bin/video2livephoto --video test/test-source.mp4 --out test/out-long --name long10 --at 5 --duration 10
输出时长 10.000 秒（源片片段 10.000 秒）｜still-image-time 在 5.000 秒

$ ./bin/video2livephoto --inspect test/out-long/long10.jpg test/out-long/long10.mov
[c] MOV 实际时长 = 10.000 秒
```

另外单测过 `--duration 30`（源片只有 20 秒 → 走定格补长，输出 30.000 秒）和 `--duration 60`：

```
$ ./bin/video2livephoto --video ~/Downloads/sample.mp4 \
      --out test/verify-out/sixty --name sixty --at 30 --duration 60
  输出时长 60.000 秒（源片片段 60.000 秒）｜still-image-time 在 30.000 秒｜耗时 4.76 秒
$ ./bin/video2livephoto --inspect test/verify-out/sixty/sixty.jpg test/verify-out/sixty/sixty.mov
  => 通过：JPG 与 MOV 的 asset identifier 相同
  => 通过：存在 boxed metadata 轨，格式为 mdta/com.apple.quicktime.still-image-time
  still-image-time 标记在片段第 30.000 秒
[c] MOV 实际时长 = 60.000 秒
  音频轨数量 = 1
```

3 秒 / 5 秒 / 10 秒 / 60 秒都没有被砍成更短的固定值，源码里也没有任何时长常量。

### 5.5 验收 5：`verify.sh` 真的验证三件事（不是只打印 OK）

`--inspect` 的实际输出（拿 `--duration 10` 那组当样本）：

```
== 自检 ==
JPG: .../long10.jpg
MOV: .../long10.mov

[a] asset identifier 比对
  MOV  com.apple.quicktime.content.identifier = 9DDD7B25-7766-485A-A622-C875E6BE3113
  JPG  Apple maker note key 17      = 9DDD7B25-7766-485A-A622-C875E6BE3113
  源码复核（直接在 JPEG 的 Exif 段里找这个 UUID 的字节）: 命中 — 在 APP1/Exif 段（文件偏移 130）找到该 UUID
  => 通过：JPG 与 MOV 的 asset identifier 相同

[b] metadata 轨与 still-image-time 格式
  mediaType = metadata 的轨数量: 1
  轨#0 mediaSubType = mebx（'mebx' = boxed metadata）
  轨#0 标识符 = mdta/com.apple.quicktime.still-image-time
  => 通过：存在 boxed metadata 轨，格式为 mdta/com.apple.quicktime.still-image-time
  still-image-time 标记在片段第 5.000 秒

[c] MOV 实际时长 = 10.000 秒
  视频轨 编码尺寸 1280x720，显示尺寸 1280x720，帧率 30.00
  音频轨数量 = 1

== 结论: 全部通过 ==
```

补充说明（**双证据**，不只信 ImageIO 的回读）：JPEG 那一侧除了用
`CGImageSourceCopyPropertiesAtIndex` 读 `kCGImagePropertyMakerAppleDictionary["17"]`，
还会自己走一遍 JPEG 段结构，在 `APP1/Exif` 段里按字节找那个 UUID 字符串；
两条都对上才算通过（两条都实测命中）。

### 5.6 验收 6：`ls -la` 证明产物真实存在

```
$ ls -la test/verify-out/whole test/verify-out/pad test/verify-out/batch
test/verify-out/whole:
-rw-r--r--  1 <user>  staff    169127  whole.jpg
-rw-r--r--  1 <user>  staff  13409885  whole.mov          <- 197 秒整段，13.4 MB

test/verify-out/batch:
-rw-r--r--  1 <user>  staff    233369  b_1.jpg
-rw-r--r--  1 <user>  staff    712057  b_1.mov
-rw-r--r--  1 <user>  staff    133095  b_2.jpg
-rw-r--r--  1 <user>  staff    836550  b_2.mov

test/verify-out/pad:
-rw-r--r--  1 <user>  staff    277692  pad30.mov
-rw-r--r--  1 <user>  staff      30172  frame-1s.jpg     <- 抽帧目视用
-rw-r--r--  1 <user>  staff      33666  frame-29s.jpg
-rw-r--r--  1 <user>  staff    31392  frame-15s.jpg
-rw-r--r--  1 <user>  staff     31636  pad30.jpg
```

### 5.7 失败路径：一律非 0 退出 + 明确中文报错（不静默通过）

```
$ ./bin/video2livephoto --video test/test-source.mp4 --out test/errtest --at 999 --duration 3
错误: --at 999.0 超出视频时长 20.000 秒                                   exit=1
$ ./bin/video2livephoto --video /Users/<user>/not-exist.mp4 --out test/errtest
错误: 输入视频不存在: /Users/<user>/not-exist.mp4                            exit=1
$ ./bin/video2livephoto --video test/test-source.mp4 --out test/errtest --duration abc
错误: --duration 必须是大于 0 的数字，收到：abc                            exit=1
$ ./bin/video2livephoto --video test/test-source.mp4
错误: 缺少 --out（并打印完整用法）                                         exit=1
```

另外程序内部所有等待都有上限：元数据/编码器 `isReadyForMoreMediaData` 等 10 秒、
整体写盘等 1 小时，超时就带 `writer.status` 和 `writer.error` 报错退出，不会静默挂死。

---

## 6. 需求变更后的新增验收（「视频多长、实况图就多长」）

素材：`~/Downloads/sample.mp4`（**只读，未修改未移动**）
规格：197.254 秒 / 720x1280 竖屏 / H.264 + AAC / 13.4 MB

### 6.1 整段模式：输出时长 == 源时长

```
$ ./bin/video2livephoto --video ~/Downloads/sample.mp4 --out test/verify-out/whole --name whole
输入视频 : ~/Downloads/sample.mp4
源片时长 : 197.254 秒
模式     : 整段（不裁剪）
封面时刻 : 0 秒
输出宽度 : 保持原分辨率，直通复制不重编码

[1/1] 封面 0s → whole.jpg / whole.mov
  片段 [0.000s, 197.254s)，长度 197.254s
  方式: 直通复制（不重编码）
  输出时长 197.253 秒（源片片段 197.254 秒）｜still-image-time 在 0.000 秒｜耗时 10.06 秒
```

**源 197.254s vs 输出 197.253s，差 0.001 秒**（判定阈值 ±0.1 秒，通过）。
产物 13,409,885 字节 vs 源 13,449,273 字节 —— 大小几乎一样，这就是「直通复制没重编码」的旁证。

### 6.2 耗时 << 视频时长（证明直通不是重编码）

`verify.sh` 实测：**7 秒（缓存热）/ 10～15 秒（首次）** 跑完 197 秒视频，判定条件
「耗时 < 视频时长」通过。若逐帧重编码同规格素材，本机（Intel，无硬件编码加速保证）需要约百秒量级。

### 6.3 `--duration 10` 仍然有效

```
$ ./bin/video2livephoto --video ~/Downloads/sample.mp4 --out test/out-10s --name ten --duration 10
输出时长 10.000 秒（源片片段 10.000 秒）｜still-image-time 在 5.000 秒｜耗时 0.94 秒
```

（不传 `--at` 时自动取视频中点 98.6 秒做封面，日志里会写明「未指定 --at，取视频中点」。）

### 6.4 默认裁剪 + 多时间点批量

```
$ ... --out test/out-3s   --name three --at 60 --duration 3
输出时长 3.000 秒｜still-image-time 在 1.500 秒｜耗时 0.50 秒

$ ... --out test/out-batch --name b --at 30,120 --duration 5
[1/2] 封面 30s  → 输出时长 5.000 秒｜still-image-time 在 2.500 秒
[2/2] 封面 120s → 输出时长 5.000 秒｜still-image-time 在 2.500 秒
完成：共 2 组，4 个文件，总耗时 1.62 秒
```

### 6.5 三段性/边界

- 封面在片段中点 → still-image-time 位置 = duration/2（3 秒 → 1.500、5 秒 → 2.500、10 秒 → 5.000），完全一致
- 整段模式封面第 0 帧 → still-image-time = 0.000 秒
- 定格补长（20 秒源片 + `--duration 30`）→ still-image-time 在 10.000 秒 = 前 5 秒定格 + 源片第 5 秒，正确

### 6.6 音频

源片有音轨就带上：197 秒整段、10 秒、5 秒、3 秒各组的 `--inspect` 都报 `音频轨数量 = 1`；
测试片的 440Hz 正弦音也原样带进了实况图 MOV。

### 6.7 竖屏不变形

```
$ ./bin/video2livephoto --probe ~/Downloads/sample.mp4
轨: mediaType=vide 编码 720x1280 显示 720x1280 帧率 24.00

$ ./bin/video2livephoto --inspect test/verify-out/portrait-real/pr.jpg test/verify-out/portrait-real/pr.mov
视频轨 编码尺寸 720x1280，显示尺寸 720x1280
```

源 720x1280 == 输出 720x1280，通过。

### 6.8 首尾帧定格补长（源片比 duration 短）

```
$ ./bin/video2livephoto --video test/test-source.mp4 --out test/verify-out/pad --name pad30 --at 5 --duration 30
方式: 首尾帧定格补长 + 重编码
输出时长 30.000 秒（源片片段 30.000 秒）｜still-image-time 在 10.000 秒｜耗时 11.31 秒
```

（这一段是唯一走「导出临时片段 + 再直通包元数据」两遍写盘的路径，因为定格必须重编码；临时文件用完即删。）

### 6.9 目视验证（`--grab` 抽帧，不是只信数字）

```
$ ./bin/video2livephoto --grab test/verify-out/pad/pad30.mov 1  frame-1s.jpg
  时间点 1.000s / 1280x720，平均亮度 56.76 / 255
$ ./bin/video2livephoto --grab test/verify-out/pad/pad30.mov 29 frame-29s.jpg
  时间点 29.000s / 1280x720，平均亮度 76.38 / 255
$ ./bin/video2livephoto --grab test/verify-out/whole/whole.mov 100 frame-100s.jpg
  时间点 100.000s / 720x1280，平均亮度 85.77 / 255
```

三张图我都看了：

- `frame-1s.jpg`：深蓝底 + 黄方块在**最左**、进度条空 → 确实是**首帧**被定格
- `frame-29s.jpg`：深红底 + 绿方块在**最右**、进度条满 → 确实是**末帧**被定格（不是黑帧、不是乱帧）
- `frame-100s.jpg`：真素材第 100 秒，720x1280 竖屏、字幕位置正常、画面清晰 → 直通复制的画面对

---

## 7. `verify.sh` 最终一次运行的判定汇总

```
==========================================================
 livephoto 自检    2026-11-25 16:26
==========================================================

【1】编译
  [通过] bash build.sh 编译成功（日志 test-build.log）
  [通过] 编译日志里 error 行数 = 0
【2】测试视频
  [通过] 测试视频存在且非空（265761 字节）
  [通过] 测试视频时长 ≈ 20 秒
【3】整段模式（sample.mp4）
  [通过] 整段模式跑通（退出码 0）
  源视频时长 = 197.254s    输出 MOV 时长 = 197.253s
  [通过] 输出时长 == 源时长（差 ≤ 0.1 秒）
  [通过] 整段转换耗时 7 秒 < 视频时长 197.254s（说明是直通复制，不是逐帧重编码）
【4】长时长
  [通过] MOV 时长 10.000s ≈ 10 秒（9.5~10.5）
【5】批量
  [通过] 产出文件数 = 4（实际 4）
  [通过] 第 1 组时长 5.000s ≈ 5 秒
【6】配对自检
  [通过] 测试片 --at 5,12 --duration 3 产出 4 个文件（实际 4）
  [通过] a+b+c 三项全通过（--inspect 退出码 0）
  [通过] a 两端 asset identifier 相同
  [通过] b metadata 轨格式为 still-image-time
  [通过] c 读出了 MOV 实际时长（>=9.5 秒）
【7】竖屏不变形
  源显示尺寸 720x1280   输出显示尺寸 720x1280
  [通过] 竖屏尺寸保持一致（源 720x1280 == 输出 720x1280）
【8】首尾帧定格补长
  [通过] 20 秒源片 + --duration 30 → MOV 时长 30.000s ≈ 30 秒
  定格段第 1 秒亮度 56.76，第 29 秒亮度 76.38（0 = 黑帧，说明定格没成）
  [通过] 定格出来的画面不是黑帧（两处亮度都 > 5）
  [通过] 首段与末段内容不同（亮度不相等，说明一段定的是首帧、一段定的是末帧）
==========================================================
 通过 19 项，不通过 0 项
==========================================================
自检全部通过。（退出码 0）
```

完整原始输出：`test/verify-raw.log`。

---

## 8. 踩到的坑与修法（复现时先看这节）

### 坑 1：clang 模块缓存被沙箱挡住 → 编译直接 fail

`'Operation not permitted'` 写不了 `/var/folders/...clang/ModuleCache/*.pcm`。
修法：`TMPDIR` + `-module-cache-path` 都指到工具目录内（见 §3）。

### 坑 2（**花了最多时间的一个**）：AVAssetWriter 交错写入死锁，长视频必卡

**现象**：短片（1～3 秒）全部成功；197 秒的视频卡在第 32 秒左右、文件 0 字节，进程不退、不报错。
`writer.status` 一直是 1（`.writing`），`writer.error` 是 nil。`mktestvideo` 生成 20 秒片时同样卡死，
1 秒的却没事 —— 极容易误判成「分辨率/编码器不支持」。

**根因**：AVAssetWriter 要把音视频**交错**写盘。我的第一版是「视频没 ready 就阻塞等待」的单线程循环：
视频输入攒够缓冲后不再 ready（因为音频一个样本还没灌进去、writer 要等它对齐），
而我的循环正卡在等视频 ready 上，**永远走不到灌音频那一步** → 死锁。
`mktestvideo` 里我「先把视频全部写完再写音频」，同一个死锁换了张脸。

**修法**（照参考实现）：每个输入挂一条自己的串行队列 + `requestMediaDataWhenReady(on:)`，
谁 ready 谁写；主线程只在 `DispatchGroup.wait(timeout:)` 上等，超时报错不静默挂死。
`mktestvideo` 的视频生成和音频生成同样各走一条队列。**这条是必读，换机器/换素材都可能再遇到。**

### 坑 3：macOS bash 里中文紧跟变量名

`verify.sh` 里 `"（实际 $NB）"` 被 BSD bash 解释成变量 `NB）`，
直接 `unbound variable` 把脚本打断在**正在检查的那条路上**（看起来像「没输出」而不是「报错」）。

```
verify.sh: line 114: NB）: unbound variable
```

修法：变量后面跟中文标点/汉字一律写 `${NB}`。已全文件复核（`livephoto.sh` 无此写法）。

### 坑 4：`AVAssetWriter` 会在输出目录留 `.sb-xxxx` 中间文件

每次成功写盘后目录里都会多一个 `<名字>.mov.sb-<随机串>`。已加 `cleanSidecars()` 在写完后清掉，
`mktestvideo` 里同样处理。

### 顺带记下：本机没有 `timeout` 命令

`timeout 60 ./bin/xxx` 直接 `command not found`。要限时得用后台任务 + 轮询，
或者（我采用的）在程序内部给所有等待加上限。

---

## 9. 已知限制 / 没做的事（实话）

1. **真机没测**。所有结论都是本机 AVFoundation 读出来的（时长、轨、格式、identifier）。
   「iOS 相册/微信/小红书是否认这张实况照片」**必须真机实测**，工具不保证。
2. **极长视频（10 分钟级）**文件能生成（197 秒已验证；时长无上限代码路径一致），
   但在相册/社交平台里的识别与播放表现同样待实测。
3. 输出是 `.mov` + `.jpg` 两个文件，不是苹果打包好的 `.pvt` 包。
4. 只处理有视频轨的文件；纯音频直接报错退出。
5. 锁屏动态壁纸实际只播开头约 2 秒（这是 iOS 的用法限制，不是文件限制）；
   发朋友圈/小红书的上限**待实测**，README 里按这个口径写的。
6. `--width` 缩放路径实测可用（H.264 编码在本机可用），但没有做画质对比测试。

---

## 10. 复现命令（一把梭）

```bash
cd apple-livephoto
bash build.sh                      # 编译，0 error
bash verify.sh                     # 19 项自检，打印每一个数字，失败退出码非 0
./livephoto.sh 我的视频.mp4         # 整段做一张
./livephoto.sh 我的视频.mp4 12.5 3  # 第 12.5 秒做封面，取 3 秒
```

## 11. 给后续接手的人

- 想改「输出怎么编」→ 只看 `convertGroup()`：三条路径的分叉都在那里，且每组的日志会打印走了哪条
- 想改「元数据」→ `writeLivePhotoMOV()`：assetID + still-image-time 轨都在这一处
- 想加格式（如 HEIC 封面）→ `writeJPEG()` 一个函数
- `--probe / --grab / --inspect` 是排查三件套：先 probe 看输入、再 grab 看画面、最后 inspect 看配对
