# vedio2live：把长视频变成手机上的实况照片

拍了一段视频，想让它像「实况照片」一样——照片是封面，长按或滑动会动。这个仓库给两套工具：一套做苹果的 Live Photo，一套做安卓的 Motion Photo。

- **苹果（Live Photo）**：做出**两个文件**，一张封面照 `.jpg` + 一段视频 `.mov`，靠同一个编号配对。
- **安卓（Motion Photo）**：做出**一个文件**，就是把视频直接接到一张 `.jpg` 后面。
- **两套互不兼容。** 苹果手机、苹果相册认不了安卓那套，反过来也一样。别混用。

---

## 先想清楚你给谁用

| 你的手机 | 用哪套 | 目录 | 产物 |
|---|---|---|---|
| iPhone | 苹果 Live Photo | `apple-livephoto/` | `.jpg` + `.mov` 两个文件 |
| 安卓 | 安卓 Motion Photo | `android-motionphoto/` | 一个 `.jpg` 文件 |

---

## 环境要求

- macOS（用系统自带的 AVFoundation / ImageIO）
- Xcode Command Line Tools（提供 `swiftc`，没装的话 `build.sh` 会提示）
- **不需要** ffmpeg、exiftool、Homebrew、sudo，也不联网

---

## 快速开始（苹果）

```bash
cd apple-livephoto
bash build.sh
./livephoto.sh 我的视频.mp4 12.5      # 第 12.5 秒做封面，默认取 3 秒
```

结果在 `apple-livephoto/实况图/`：`我的视频.jpg` + `我的视频.mov` 是一对，**拷进 iPhone 要两个一起拷**（AirDrop 或同步进「照片」），长按会动。

不加 `12.5` 就是整段视频做成一张实况照片，不裁剪。更多用法见 `apple-livephoto/README.md`。

---

## 快速开始（安卓）

安卓那套要借用苹果那套的抽帧工具，**先编译它**（只做一次）：

```bash
cd apple-livephoto && bash build.sh && cd ..
```

然后：

```bash
cd android-motionphoto
./make-motionphoto.sh ~/Downloads/我的视频.mp4 我的视频.jpg --at 12.5
```

`--at 12.5` = 封面取第 12.5 秒那一帧，不写就是第 0 秒。视频默认整段嵌进去不裁剪。

第一次跑会自动编译一个小的 Swift 工具（约 1 分钟）。跑完最后会自动校验一遍，**最后一行是「退出码 0」才算好**。跳过上面编译那步会报「找不到抽帧工具」，也可以用 `--image` 直接给一张封面图绕过去。更多用法见 `android-motionphoto/README.md`。

---

## 已知限制 / 没验证的事

这几条请当真，别当成「已经能用了」。

- **两套互不兼容**：安卓 Motion Photo 的文件，苹果手机和苹果相册认不了；苹果 Live Photo 的两个文件，安卓手机也认不了。
- **安卓那套没在真机上试过一次。** 本机没有安卓手机，微信、小红书、OPPO / vivo / 荣耀 / 小米相册认不认这个文件，**完全没测**。本机只验证了字节结构符合公开规范，这不等于手机上一定认。
- **苹果那套同样没在真机 iPhone 上验过识别。** 文件格式是对的，但「照片」App 认不认、长按动不动，没在真机上确认过。
- **各平台没公布实况照片的时长上限。** 文件本身没有时长限制（10 秒、60 秒都能做出来），但微信朋友圈、小红书等平台收不收长视频，只能你自己实测。
- **3 秒只是 iPhone 相机的拍摄默认值，不是格式上限。** 文件层面没有时长限制。

---

## 目录结构

```
vedio2live/
├── README.md               本文件
├── .gitignore
├── apple-livephoto/        苹果 Live Photo（iPhone 用）
└── android-motionphoto/    安卓 Motion Photo（安卓手机用）
```

两边各自的目录里都有独立的 `README.md`，写的是详细用法和参数。

---

## License

仓库现在没放 LICENSE 文件，你可以按自己的需要自行添加一个。
