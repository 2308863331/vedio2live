# 视频 → 安卓实况照片（Motion Photo）· 建造报告

日期：2026-11-25　机器：macOS 12.7.6 / Intel x86_64 / Swift 5.7.2 / python3 3.15.2（Pillow 13.0.0）
目录：`android-motionphoto/`（独立目录，没动 `tools/livephoto/` 里任何原有文件）

---

## 1. 做了什么

一套「视频 → 安卓 Motion Photo 单文件」的工具，6 个文件：

| 文件 | 作用 |
|---|---|
| `motionphoto.py` | 组装器：JPEG + MP4 → 一个 `.jpg` |
| `verify-motionphoto.py` | 校验器：真解析产物，19 项逐条打印，有问题退出码 1 |
| `remux-faststart.swift` | 直通重封装（不重编码）：MP4/MOV → moov 在前的 MP4；另有 `--info` 看时长/轨/box |
| `build.sh` | 编译 Swift 工具到 `bin/remux-faststart` |
| `make-motionphoto.sh` | 给人用的一行封装：生成 + 自动校验 |
| `test-mutations.py` | 反向验证：故意改坏产物，确认校验器真会报错 |
| `README.md` | 中文使用说明（含「没验证过的事」清单） |

产物样例（就在工具目录下）：
- `sample-motionphoto.jpg` — 197.254 秒整段，13,619,493 字节
- `short-motionphoto.jpg` — 短视频源（5 秒）做的，958,062 字节

---

## 2. 格式规则（照需求里的字段表写的，没自己发明字段）

产物三块，顺序固定：
```
[ FF D8 ... JPEG 段 ... FF D9 ][ MP4 全部字节 ]
                              ↑ 视频直接接在 EOI 后面
```

XMP 写在 JPEG 的 **APP1 段**里，段 payload = 标识串 `http://ns.adobe.com/xap/1.0/` + `\x00` + XMP 包。
包里**新一代（GCamera/Container）和老一代（MicroVideo）两套字段同写**：

```
GCamera:MotionPhoto="1"                                  GCamera:MotionPhotoVersion="1"
GCamera:MotionPhotoPresentationTimestampUs="<微秒>"       GCamera:MicroVideo="1"
GCamera:MicroVideoVersion="1"                            GCamera:MicroVideoOffset="<距文件末尾的字节数>"
GCamera:MicroVideoPresentationTimestampUs="<微秒>"
Container:Directory → rdf:Seq:
  rdf:li → Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary"     Item:Length="0"       Item:Padding="0"
  rdf:li → Container:Item Item:Mime="video/mp4"  Item:Semantic="MotionPhoto" Item:Length="<视频字节数>" Item:Padding="0"
```

### MicroVideoOffset 的算法规格与自验算

规则是**从文件末尾倒着数**：`offset = 文件总长 − 视频起始偏移`。

因为视频是紧接在 EOI 后面的，等号右边正好就是视频字节数，所以在本次产物里
**`MicroVideoOffset == Item:Length == 视频字节数`**。代码里仍然按「写完再回代」的
不动点循环算（`assemble()`，最多 6 轮），不直接写 `offset = len(video)`，
这样以后若在视频后面加 padding 也不会静默算错。

自验算（`--video sample.mp4`，原始输出）：
```
文件总长        : 13619493 字节
其中 JPEG 部分  : 170220 字节（到 EOI 为止，EOI 在 0x298EA）
其中视频部分    : 13449273 字节（整段，未裁剪）
视频起始偏移    : 170220（正着数，从文件开头）
写入 XMP 的 offset: 13449273（倒着数，距文件末尾）
自验算          : 文件总长 13619493 − 视频起始 170220 = 13449273  一致
```
两个 170220 / 13449273 在 `verify` 里由**两条互相独立的路径**再算一遍（见 §4.3）。

### APP 段位置与旧 XMP

- XMP APP1 插在**开头连续 APP0 之后**（JFIF 规定 APP0 必须紧跟 SOI，两边都照顾到），段位置 `0x14`。
- 插入前先把原有 XMP APP1 段删掉，避免两份打架。
- 图片扫描数据一个字节都没动（`rebuild_jpeg()` 只重建 SOI→SOS 之间的段，之后原样拼接）。

### 关于 Apple MakerNote 的选择

**实测本机用 `video2livephoto --grab` 抽出来的封面 JPEG 里根本没有 Apple MakerNote**：
Exif 段只有 64 字节，IFD0 里只有一个 ExifIFD 指针（34665），ExifIFD 里只有
PixelXDimension / PixelYDimension（40962 / 40963）两个 tag，**没有 orientation、没有 key 17**。

所以这次「留还是剥」没产生任何差别。**选择是：不主动剥 Exif。**
理由：剥 MakerNote 要重建整条 Exif IFD 链（改 offset 表），风险是连带弄坏 orientation
—— orientation 决定照片在手机上正不正，是用户看得见的。而 MakerNote 对安卓解析毫无影响。
**拿正确性换干净，不划算。**

---

## 3. 验收标准逐条结果

### 3.1 用 `sample.mp4` 生成，嵌入视频时长 == 197.254 秒（整段没裁）

`./make-motionphoto.sh ~/Downloads/sample.mp4 sample-motionphoto.jpg` → 退出码 0

```
=== 4/4 结果 ===
产物: sample-motionphoto.jpg
文件总长        : 13619493 字节
其中 JPEG 部分  : 170220 字节（到 EOI 为止，EOI 在 0x298EA）
其中视频部分    : 13449273 字节（整段，未裁剪）
视频起始偏移    : 170220（正着数，从文件开头）
写入 XMP 的 offset: 13449273（倒着数，距文件末尾）
自验算          : 文件总长 13619493 − 视频起始 170220 = 13449273  一致
封面时刻        : 0.0 秒 → 0 微秒
嵌入视频时长    : 197.254000 秒
重封装          : 没做（源已是 MP4+faststart，字节原样复用）
总耗时          : 0.61 秒
```
校验器读出来的：
```
  切出的 MP4 时长: mvhd=197.254000 秒  AVFoundation=197.254000  mdls=拿不到
  源视频时长      : mvhd=197.254000 秒  AVFoundation=197.254000
[ OK ] 嵌入视频时长 == 源视频时长（没被裁剪）  — 源 197.254000 秒 vs 嵌入 197.254000 秒（差 +0.000000 秒）
```
✅ 197.254 秒，差 0.000000。

### 3.2 校验器全项通过，退出码 0

`python3 verify-motionphoto.py sample-motionphoto.jpg --source ~/Downloads/sample.mp4`

```
=== 结果: 19 项检查，19 项通过，0 项不通过 ===
退出码 0
```
19 项清单（每项都打印了实测值）：
```
--- 1. JPEG 结构 ---
[ OK ] JPEG 以 FF D8 开头  — 实际 FFD8
[ OK ] 找到 EOI(FF D9)  — EOI 在 0x298EA，图片到 170220 字节结束（含 EOI）
[ OK ] EOI 之后还有数据（视频）  — EOI 之后 13449273 字节
[ OK ] Pillow 能打开并解码（整个文件）  — 尺寸 720x1280，格式 JPEG
--- 2. XMP（APP1 段） ---
[ OK ] 找到 XMP APP1 段（标识串 http://ns.adobe.com/xap/1.0/）  — 共 1 段
  APP1 段位置 0x14，段长 1175，XMP 包 1142 字节
  GCamera:MotionPhoto                            = 1
  GCamera:MotionPhotoVersion                     = 1
  GCamera:MotionPhotoPresentationTimestampUs     = 0
  GCamera:MicroVideo                             = 1
  GCamera:MicroVideoVersion                      = 1
  GCamera:MicroVideoOffset                       = 13449273
  GCamera:MicroVideoPresentationTimestampUs      = 0
  Container:Item[0] {'Item:Mime': 'image/jpeg', 'Item:Semantic': 'Primary', 'Item:Length': '0', 'Item:Padding': '0'}
  Container:Item[1] {'Item:Mime': 'video/mp4', 'Item:Semantic': 'MotionPhoto', 'Item:Length': '13449273', 'Item:Padding': '0'}
  xmlns 声明: {'GCamera': True, 'Container': True, 'Item': True}
[ OK ] 新一代 + 老一代字段齐全  — 7 个 GCamera 字段都在
[ OK ] Container:Directory 两项（Primary / MotionPhoto）
--- 3. 由 MicroVideoOffset 反算视频起点 ---
[ OK ] 反算出的视频起点落在文件内  — 起点 = 170220（文件总长 13619493 − offset 13449273）
[ OK ] 由 offset 反算的起点 == JPEG 实测的起点  — 反算 170220 vs 实测（EOI 之后）170220
[ OK ] 实测视频起点处是合法 MP4（有 ftyp box）  — 该处 box 类型 = b'ftyp'
[ OK ] 实测视频长度（文件末尾 − 实测起点）== XMP 的 Item:Length  — 13449273 vs XMP 写 13449273
[ OK ] Item:Length == MicroVideoOffset  — 13449273 vs 13449273
[ OK ] 重新算的 offset（文件总长 − 实测起点）和 XMP 里写的逐字节相等  — '13449273' vs '13449273'
--- 4. 切出嵌入的 MP4，比时长 ---
[ OK ] 切出的 MP4 大小 == Item:Length  — 13449273 字节，XMP 写 13449273
  切出的 MP4 顶层 box: ftyp moov free mdat
[ OK ] 切出的 MP4 是 faststart（moov 在 mdat 前）  — ftyp moov free mdat
[ OK ] 嵌入视频时长 == 源视频时长（没被裁剪）
--- 5. 用 Pillow 读图片的 XMP ---
[ OK ] Pillow 读得到 XMP  — 1142 字节
[ OK ] Pillow 读到的 XMP 和我们解析的是同一份
[ OK ] Pillow 读到的 XMP 字段齐全  — 7 个字段都在
  [跳过] Pillow getxmp() 结构化解析：本机没装 defusedxml（Pillow 官方依赖），它会报警告并返回空。
--- 6. 正着算 / 倒着算 对照 ---
  正着算（用 JPEG 结构实测，从文件开头往后）:
    文件总长                     13619493
    JPEG 段结束（EOI 之后）      170220
    视频长度 = 文件总长 − 实测起点 13449273
  倒着算（用 XMP 里的 offset，从文件末尾往前）:
    XMP 里的 MicroVideoOffset    13449273
    反算的视频起始 = 13619493 − 13449273 = 170220
    XMP 里的 Item:Length         13449273
  对照:
    正着算起点 170220  ==  倒着算起点 170220   一致
    正着算视频长度 13449273  ==  MicroVideoOffset 13449273   一致
    Item:Length 13449273  ==  MicroVideoOffset 13449273   一致
```

### 3.3 换一个比源视频短的也做一遍

第二份源视频：用已有的 `video2livephoto` 从 `sample.mp4` 第 60 秒起裁 5 秒，得到
`short.mov`（QuickTime，5.000 秒，766,612 字节）；再：

`./make-motionphoto.sh .tmp/short/short.mov short-motionphoto.jpg --at 1.5` → 退出码 0

```
源视频 ftyp 主品牌: qt  （不是 MP4 系）
需要重封装：不是 MP4 容器；
耗时: 0.112 秒   输入 766612 字节 → 输出 765584 字节   时长 5.000000 → 5.000000
=== 4/4 结果 ===
产物: short-motionphoto.jpg
文件总长        : 958062 字节
其中 JPEG 部分  : 192478 字节（到 EOI 为止，EOI 在 0x2EFDC）
其中视频部分    : 765584 字节（整段，未裁剪）
自验算          : 文件总长 958062 − 视频起始 192478 = 765584  一致
封面时刻        : 1.5 秒 → 1500000 微秒
嵌入视频时长    : 5.000000 秒
=== 结果: 19 项检查，19 项通过，0 项不通过 ===
退出码 0
```
XMP 里读出来的（`--at 1.5` 生效，封面时间戳是可变的，不是写死的）：
```
GCamera:MotionPhotoPresentationTimestampUs     = 1500000
GCamera:MicroVideoOffset                       = 765584
Container:Item[1] {'Item:Mime': 'video/mp4', 'Item:Semantic': 'MotionPhoto', 'Item:Length': '765584', 'Item:Padding': '0'}
```

第三份源视频：**故意非 faststart 的 MP4**（`remux-faststart --no-faststart` 造出来的，
`ftyp mdat moov`，13,408,844 字节，197.253 秒），验证「不是 faststart 就转一遍」这条路：
```
源视频顶层 box: ftyp mdat moov
需要重封装：moov 不在 mdat 前
耗时: 0.480 秒   输出顶层 box: ftyp(28) moov(73302) mdat(13335514)
=== 结果: 19 项检查，19 项通过，0 项不通过 ===
退出码 0
```
✅ 三种源（MP4+faststart / QuickTime MOV / MP4 非 faststart）都跑通。

### 3.4 反向验证 4 种改坏方式

`python3 test-mutations.py sample-motionphoto.jpg ~/Downloads/sample.mp4` → 退出码 0（脚本自身）：
```
== 0. 改坏前的那一份必须先过（退出码 0） ==
verify 退出码 = 0
=== 结果: 19 项检查，19 项通过，0 项不通过 ===
改坏前退出码 0 ✓

== 1. 改 MicroVideoOffset ==
   做法: 把 XMP 里 MicroVideoOffset 从 13449273 改成 13449274
   verify 退出码 = 1
   === 结果: 19 项检查，16 项通过，3 项不通过 ===
   [FAIL] 由 offset 反算的起点 == JPEG 实测的起点  — 反算 170219 vs 实测（EOI 之后）170220
   [FAIL] Item:Length == MicroVideoOffset  — 13449273 vs 13449274
   [FAIL] 重新算的 offset（文件总长 − 实测起点）和 XMP 里写的逐字节相等  — '13449273' vs '13449274'

== 2. 改 Item:Length ==
   做法: 把 XMP 里 Item:Length 从 13449273 改成 13449271
   verify 退出码 = 1
   === 结果: 19 项检查，16 项通过，3 项不通过 ===
   [FAIL] 实测视频长度（文件末尾 − 实测起点）== XMP 的 Item:Length  — 13449273 vs XMP 写 13449271
   [FAIL] Item:Length == MicroVideoOffset  — 13449271 vs 13449273
   [FAIL] 切出的 MP4 大小 == Item:Length  — 13449273 字节，XMP 写 13449271

== 3. 截掉视频尾部 ==
   做法: 截掉文件末尾 100 字节（视频尾巴被切）
   verify 退出码 = 1
   === 结果: 19 项检查，15 项通过，4 项不通过 ===
   [FAIL] 由 offset 反算的起点 == JPEG 实测的起点  — 反算 170120 vs 实测（EOI 之后）170220
   [FAIL] 实测视频长度（文件末尾 − 实测起点）== XMP 的 Item:Length  — 13449173 vs XMP 写 13449273
   [FAIL] 重新算的 offset（文件总长 − 实测起点）和 XMP 里写的逐字节相等  — '13449173' vs '13449273'
   [FAIL] 切出的 MP4 大小 == Item:Length  — 13449173 字节，XMP 写 13449273

== 4. 视频中间插一字节 ==
   做法: 在视频中间（起点后 1000 字节处）插 1 个字节
   verify 退出码 = 1
   === 结果: 19 项检查，14 项通过，5 项不通过 ===
   [FAIL] 由 offset 反算的起点 == JPEG 实测的起点  — 反算 170221 vs 实测（EOI 之后）170220
   [FAIL] 实测视频长度（文件末尾 − 实测起点）== XMP 的 Item:Length  — 13449274 vs XMP 写 13449273
   [FAIL] 重新算的 offset（文件总长 − 实测起点）和 XMP 里写的逐字节相等  — '13449274' vs '13449273'
   [FAIL] 切出的 MP4 大小 == Item:Length  — 13449274 字节，XMP 写 13449273
   [FAIL] 切出的 MP4 是 faststart（moov 在 mdat 前）  — ftyp moov fre

=== 反向验证总结: 4 种改坏方式全部退出码 1，改坏前退出码 0 ===
```
✅ 4 种全部退出码 1，每种都打印出**具体哪一项**不通过。

### 3.5 重封装耗时（证明直通不重编码）

```
### 1) 197.254 秒 MP4（已 faststart）→ 直通重封装成 faststart MP4
耗时: 1.283 秒   13449273 → 13408844 字节（差 -40429，即 -0.30%）   197.254000 → 197.253000 秒
real 0m1.416s
### 2) 197.253 秒非 faststart MP4 → faststart MP4
耗时: 1.833 秒   13408844 → 13408844 字节（差 0）                    197.253000 → 197.253000 秒
real 0m1.922s
### 3) 5 秒 QuickTime MOV → MP4
耗时: 0.105 秒   766612 → 765584 字节（差 -1028）                    5.000000 → 5.000000 秒
real 0m0.218s
```

判断依据，两条一起看：
- **速度**：197 秒的视频重封装 1.3～1.9 秒（≈100 倍速以上）。真重编码至少是「视频时长的 0.3～1 倍」，197 秒的视频要一分钟以上。
- **体积/时长**：输出和输入差 0～0.3%，时长只差 0.001 秒（第 1 条那 0.001 秒差是因为源文件 moov 里带了个 1ms 的 `free`/编辑表差异，重编码不可能只差 1ms）。

✅ 确认是直通，没重编码。

### 3.6 产物的 JPEG 部分能被 Pillow 正常打开

校验器第 1 节：`[ OK ] Pillow 能打开并解码（整个文件）— 尺寸 720x1280，格式 JPEG`
（`im.load()` 强制解码过，不只是打开；打开的是**带尾部视频的整个文件**，证明追加没把图片搞坏。）
另外校验器第 5 节还会 `Image.open()` 再读一次 XMP。

### 3.7 产物存在、文件大小

```
$ ls -la
-rw-r--r--   1 <user>  staff      958062 11 25 17:28 short-motionphoto.jpg
-rw-r--r--   1 <user>  staff    13619493 11 25 17:28 sample-motionphoto.jpg
drwxr-xr-x   3 <user>  staff          96 11 25 17:27 bin
$ ls -la bin/
-rwxr-xr-x  1 <user>  staff  90032 11 25 17:27 remux-faststart
```

---

## 4. 踩到的坑（按「花的时间」排）

### 坑 1（差点让整个工具白做）：XMP APP1 忘了拼标识串

第一版 `build_xmp()` 返回 `<?xpacket ...` 就直接当 APP1 payload 写进去了，
**前面漏了 `http://ns.adobe.com/xap/1.0/\x00` 这 29 个字节**。
文件看起来"有 XMP 段"（FFE1 也在、XMP 内容也在），但任何解析器都认不出这是 XMP
——因为 APP1 靠标识串区分 Exif / XMP / 扩展 XMP。

**是靠 Pillow 才发现的**：`Image.open(产物).info` 里没有 `xmp` 这个键（Exif 有）。
修法：`rebuild_jpeg()` 里写成 `payload = XMP_ID + new_xmp`。

### 坑 2（**这次最值得记的一条**）：校验脚本里写了两条「恒真检查」，等于假货

第一版 `verify-motionphoto.py` 里这两条：
```
video_start = 文件总长 − MicroVideoOffset        # 用 offset 反算出起点
record("起点到文件末尾长度 == Item:Length",  文件总长 − video_start == Item:Length)
record("重算的 offset == XMP 里的 offset",   str(文件总长 − video_start) == MicroVideoOffset)
```
代数上 `文件总长 − (文件总长 − offset) == offset` **永远成立**。
所以改坏了也照样绿 —— 除非外部正好还有别的检查命中，否则就是一张假绿灯。

**是反向验证抠出来的**：把 `MicroVideoOffset` 改成错值后，这两条居然还是 OK。
修法：所有长度/偏移的检查，一律用**另一条独立路径**算出来的起点做基准
——即「JPEG 结构实测的起点 = EOI 结束位置」（正着算），去和 XMP 里的值（倒着算）比。
改完再跑反向验证，第 1 种改坏方式立刻多出 2 条 FAIL，才算真会报错。

**教训**：写校验时，凡是「用一个量算出 A，再用 A 反算回那个量」的写法，先自己代数验一遍是不是恒等式。

### 坑 3：QuickTime MOV 被误判成「可以直接复用」

第二份源视频是从 `video2livephoto` 出来的 `.mov`，box 顺序是 `ftyp moov wide mdat`
—— 是 faststart。第一版 `ensure_faststart()` 只看 faststart，于是决定"原字节直接复用"。
但它的 ftyp 主品牌是 `qt  `（QuickTime），产物会在 XMP 里声明 `video/mp4` 却塞着 MOV 字节，
安卓按 MP4 解很可能解不动。

修法：判断条件从「是不是 faststart」改成「**是 MP4（ftyp 主品牌在 MP4 系白名单里）+ 是 faststart**」，
两条缺一就重封装。白名单里没有 `qt  `。

### 坑 4：Pillow 的 `getxmp()` 要 defusedxml，本机没有，而且它不抛异常

`PIL 13.0.0` 调 `im.getxmp()` 时本机只打一条 `UserWarning: XMP data cannot be read without defusedxml dependency`，
然后返回空 `{}`。**不抛异常**，很容易误判成"XMP 没写进去"或者"解析出 0 个键 = XMP 坏了"。
本机不能装包（不联网、无 Homebrew），所以：
- 正式解析走 `im.info['xmp']`（Pillow 会把 APP1 XMP 原始字节放进这里），自己解析；
- `getxmp()` 那条检查改成**显式跳过并说明**，不算失败（`importlib.util.find_spec("defusedxml")` 判断）。

### 坑 5：`mktestvideo --help` 会把 `--help` 当输出文件名

参考工具的 `mktestvideo` 只吃位置参数，`./bin/mktestvideo --help` 不是打用法，
而是**在 `tools/livephoto/` 里生成了一个叫 `--help` 的 265,761 字节视频文件**。
已 `rm` 掉这个误生成的文件；`tools/livephoto/` 的**原有文件一个都没改**（见 §6 的核对）。
教训：调别人没写 `--help` 的 CLI，先别拿 `--help` 试。

### 坑 6（引用已有报告的结论，这次同样命中）：clang 模块缓存必须在工具目录内

`tools/livephoto/BUILD-REPORT.md` §8 坑 1 说的那条，这次原样复现：
`swiftc` 默认拿 `$TMPDIR` 下的模块缓存去写，被沙箱拒 → 编译直接 fail。
`build.sh` 里 `TMPDIR` 和 `-module-cache-path` 都指到工具目录内（`.tmp/` 和 `.build-cache/`）。
另外：**第一次编译要一分多钟**（Swift 要现编标准库，日志里有 `did not find a prebuilt standard library`），
所以我在后台跑、超时给到 10 分钟，别用默认 60 秒等它。

### 顺带：这次**没**踩到「AVAssetWriter 音视频交错死锁」

那份报告 §8 坑 2 的死锁，发生在自己开 `AVAssetReader/Writer` 手写交错循环时。
这次重封装走的是 `AVAssetExportSession(presetName: AVAssetExportPresetPassthrough)`
+ `shouldOptimizeForNetworkUse = true`，一行搞定，没有自己写读写循环，所以没遇到。
留给以后：**如果哪天要在重封装里塞自己的 metadata（比如苹果那套 still-image-time 轨），
就得回到 AVAssetReader/Writer，那时必须照 §8 坑 2 的修法（每个输入一条队列 + `requestMediaDataWhenReady`）。**

---

## 5. 已知限制 / 没做的事（实话，README 里也写了）

1. **本机没有安卓手机，一次都没在真机上试过。**
   微信 / 小红书 / OPPO / vivo / 荣耀 / 小米相册**认不认这个文件，完全没测**。
2. **本机验的只是「字节结构符合公开格式规范」**：JPEG 完整、视频在 EOI 后面、
   XMP 标识串和字段齐全、长度和偏移正反算一致、视频时长没被裁。
   **这不等于手机上一定认。不要写成「已验证可用」。**
3. 具体没验的项：
   - 197 秒这种长实况照片在安卓上的播放表现（要不要等、会不会卡）
   - 微信 / 小红书收不收桌面电脑生成的文件（可能只认手机拍的）
   - 封面时间戳（`--at`）在手机上跳转的位置对不对
   - 竖屏 / 横屏、带旋转标记的视频在手机上的显示方向
   - 无音轨、多视频轨的源
   - 超过 2 GB 的文件（XMP 的 `Item:Length` 目前按十进制整数写，能表示但没测过大文件）
   - HEVC/H.265 源（只测了 H.264；直通路径理论上不限编码，但没测）
4. **苹果手机、苹果相册不认这个文件** —— 格式就不是一套东西（单文件 vs 两个文件），
   互不兼容。反过来也一样。
5. `mdls` 在本机读不出时长（Downloads 和 `.tmp` 都没被 Spotlight 索引，返回 null），
   所以时长用了两条独立的路：直接解析 `moov/mvhd`（python）+ AVFoundation（Swift 工具）。
   `mdls` 那条留着，拿不到就打印「拿不到」，不静默跳过。
6. 没做：GUI、批量模式、苹果 Live Photo ↔ 安卓 Motion Photo 互转
   （互转需要重新配对/编码，是另一件事）。
7. `verify-motionphoto.py` 只校验**结构**，不校验**语义**
   （比如封面那一帧画面对不对、视频能不能在安卓上解码出来），那要有安卓设备才能做。

---

## 6. 复现命令（一把梭）

```bash
cd android-motionphoto

bash build.sh                                    # 编译（第一次约 1 分钟）

# 主产物
./make-motionphoto.sh ~/Downloads/sample.mp4 sample-motionphoto.jpg
python3 verify-motionphoto.py sample-motionphoto.jpg --source ~/Downloads/sample.mp4

# 短视频源（对照）
apple-livephoto/bin/video2livephoto \
    --video ~/Downloads/sample.mp4 --out .tmp/short --at 60 --duration 5 --name short
./make-motionphoto.sh .tmp/short/short.mov short-motionphoto.jpg --at 1.5

# 反向验证
python3 test-mutations.py sample-motionphoto.jpg ~/Downloads/sample.mp4

# 重封装计时（/tmp 不可写，输出放工具目录内的 .tmp/）
time ./bin/remux-faststart ~/Downloads/sample.mp4 .tmp/t1.mp4
time ./bin/remux-faststart .tmp/sample-nofaststart.mp4 .tmp/t2.mp4
time ./bin/remux-faststart .tmp/short/short.mov .tmp/t3.mp4
```

`tools/livephoto/` 的核对（证明没动它）：只做了两件事 ——
① 只读调用 `bin/video2livephoto`（`--grab` / 裁 5 秒）；
② 删掉 `mktestvideo --help` 误生成的 `tools/livephoto/--help`（我自己刚生成的，非原有文件）。
**没有修改、移动、删除该目录下任何原有文件。**

---

## 7. 新建文件的 md5 + mtime

```
motionphoto.py               08ccb236f8e4239c34149fcc8250e5a8  Nov 25 17:26:26 2026
verify-motionphoto.py        30d341e04732061d36f2f7341eb828f7  Nov 25 17:27:10 2026
remux-faststart.swift        bb49f035518ff54782dbcc573e9c8734  Nov 25 17:27:25 2026
build.sh                     3fbb55117f62d526c2e4e4373b755afd  Nov 25 17:21:23 2026
make-motionphoto.sh          12d5c5ffa306dce5b667a10308bff06c  Nov 25 17:27:36 2026
README.md                    dd6d34f6dec34376dddbf4f78d3ce551  Nov 25 17:30:03 2026
test-mutations.py            849799003bc65f512ef3273b6ecb5648  Nov 25 17:26:41 2026
bin/remux-faststart          e5d62a95bca173f8e35b553cba0dbb86  Nov 25 17:27:28 2026
sample-motionphoto.jpg        c5a85e07604d5931fd2d552c05a74463  Nov 25 17:28:01 2026
short-motionphoto.jpg        2f1fdcf0de78b8c4266958a1787b660e  Nov 25 17:28:02 2026
```
（`md5 -q` / `stat -f "%Sm"`，均在 2026-11-25 17:28 采集。）

产物样例（第二、三份产物放在 `.tmp/` 下，属过程文件）：
`.tmp/samples/nofaststart-motionphoto.jpg`（非 faststart 源做的，13,579,064 字节，校验 19/19 通过）；
校验时切出来的嵌入 MP4 样例：`.tmp/verify-sample-motionphoto-video.mp4`。

`BUILD-REPORT.md` 这份报告本身（就是你正在读的这个文件）没有列 md5 —— 文件装不下自己的哈希
（写进去哈希就变了）。要核对它请直接 `md5 -q BUILD-REPORT.md`。
