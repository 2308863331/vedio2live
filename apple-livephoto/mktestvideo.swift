// mktestvideo.swift
// 本机没有 ffmpeg，用 AVFoundation 自己合成一段测试视频。
// 画面：默认 1280x720 / 20 秒 / 30fps，前半段深蓝背景、后半段深红背景，
//       一个方块从左向右移动，底部有一条进度条 —— 方便肉眼分辨首/中/尾帧。
// 声音：440Hz 正弦音（用来验证音频能不能被带到实况图的 MOV 里）。
//
// 用法: mktestvideo <输出文件.mp4> [时长秒] [宽] [高] [帧率]
//
// 坑（实测踩过，写在这里免得下次再踩）：
//   AVAssetWriter 要交错（interleave）音视频。若「先把视频全部写完再写音频」或者
//   「在某个输入没 ready 时阻塞等待」，writer 攒够缓冲后那个输入就再也不 ready，
//   互相卡死（20 秒测试片必卡，1 秒的反而不卡，很容易误判成分辨率问题）。
//   正确做法：每个输入一条自己的队列 + requestMediaDataWhenReady，谁 ready 谁写。

import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import CoreMedia

func log(_ s: String) { print(s); fflush(stdout) }

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(("错误: " + m + "\n").data(using: .utf8)!)
    exit(1)
}

/// 清掉 AVAssetWriter 留下的 .sb-xxxx 中间文件
func cleanSidecars(_ url: URL) {
    let dir = url.deletingLastPathComponent()
    let prefix = url.lastPathComponent + ".sb-"
    if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
        for f in items where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("用法: mktestvideo <输出文件.mp4> [时长秒=20] [宽=1280] [高=720] [帧率=30]")
    exit(1)
}
let outPath = (args[0] as NSString).expandingTildeInPath
let duration = args.count > 1 ? (Double(args[1]) ?? 20.0) : 20.0
let width = args.count > 2 ? (Int(args[2]) ?? 1280) : 1280
let height = args.count > 3 ? (Int(args[3]) ?? 720) : 720
let fps = args.count > 4 ? (Double(args[4]) ?? 30.0) : 30.0

let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: outURL)
try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let writer: AVAssetWriter
do {
    writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
} catch {
    fail("无法创建输出文件 \(outPath): \(error.localizedDescription)")
}
writer.shouldOptimizeForNetworkUse = true

let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 4_000_000,
    ],
]
let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
videoInput.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: videoInput,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])

let audioSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: 44100.0,
    AVNumberOfChannelsKey: 1,
    AVEncoderBitRateKey: 64000,
]
let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
audioInput.expectsMediaDataInRealTime = false

writer.add(videoInput)
writer.add(audioInput)

guard writer.startWriting() else { fail("writer 启动失败: \(writer.error?.localizedDescription ?? "未知")") }
writer.startSession(atSourceTime: .zero)

// ---------- 画面 ----------
let totalFrames = Int((duration * fps).rounded())
let colorSpace = CGColorSpaceCreateDeviceRGB()
var frameIndex = 0

func makeFrame(_ index: Int, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let ctx = CGContext(data: base,
                              width: width,
                              height: height,
                              bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

    // 让 y 轴向下，方便按「从上往下」的思路画
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)

    let t = Double(index) / fps
    let progress = min(1.0, t / duration)
    let isSecondHalf = t >= duration / 2

    // 背景：前半段深蓝，后半段深红 —— 一眼分辨前后半段
    ctx.setFillColor(isSecondHalf
        ? CGColor(red: 0.55, green: 0.05, blue: 0.05, alpha: 1)
        : CGColor(red: 0.05, green: 0.12, blue: 0.50, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // 正中的竖直分界线（标出两半的交界）
    ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 0.6))
    ctx.fill(CGRect(x: CGFloat(width) / 2 - 2, y: 0, width: 4, height: CGFloat(height)))

    // 移动方块：左 -> 右
    let squareSize = CGFloat(min(width, height)) / 6
    let travel = CGFloat(width) - squareSize - 80
    let x = 40 + travel * CGFloat(progress)
    let y = CGFloat(height) / 2 - squareSize / 2
    ctx.setFillColor(isSecondHalf
        ? CGColor(red: 0.20, green: 1.0, blue: 0.40, alpha: 1)
        : CGColor(red: 1.0, green: 0.95, blue: 0.20, alpha: 1))
    ctx.fill(CGRect(x: x, y: y, width: squareSize, height: squareSize))

    // 底部进度条
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.fill(CGRect(x: 40, y: CGFloat(height) - 70, width: CGFloat(width) - 80, height: 26))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fill(CGRect(x: 40, y: CGFloat(height) - 70, width: (CGFloat(width) - 80) * CGFloat(progress), height: 26))
}

// ---------- 声音 ----------
let sampleRate = 44100.0
let totalSamples = Int(duration * sampleRate)
let chunk = 4096
var written = 0

guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
    fail("无法创建音频格式")
}

// ---------- 两个输入各一条队列，谁 ready 谁写 ----------
let group = DispatchGroup()
let lock = NSLock()
var pumpError: String? = nil

// 视频
group.enter()
var videoDone = false
videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "mktest.video")) {
    while videoInput.isReadyForMoreMediaData && frameIndex < totalFrames {
        guard let pool = adaptor.pixelBufferPool else {
            lock.lock(); pumpError = "拿不到 pixelBufferPool"; lock.unlock()
            videoInput.markAsFinished(); videoDone = true; group.leave(); return
        }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess, let buffer = pb else {
            lock.lock(); pumpError = "创建 pixelBuffer 失败"; lock.unlock()
            videoInput.markAsFinished(); videoDone = true; group.leave(); return
        }
        makeFrame(frameIndex, into: buffer)
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        if !adaptor.append(buffer, withPresentationTime: pts) {
            lock.lock(); pumpError = "append 第 \(frameIndex) 帧失败: \(writer.error?.localizedDescription ?? "未知")"; lock.unlock()
            videoInput.markAsFinished(); videoDone = true; group.leave(); return
        }
        frameIndex += 1
    }
    if frameIndex >= totalFrames && !videoDone {
        videoDone = true
        videoInput.markAsFinished()
        group.leave()
    }
}

// 音频
group.enter()
var audioDone = false
audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "mktest.audio")) {
    while audioInput.isReadyForMoreMediaData && written < totalSamples {
        let n = min(chunk, totalSamples - written)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(n)),
              let dst = pcm.floatChannelData?[0] else {
            lock.lock(); pumpError = "音频 buffer 创建失败"; lock.unlock()
            audioInput.markAsFinished(); audioDone = true; group.leave(); return
        }
        pcm.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let s = Double(written + i) / sampleRate
            dst[i] = Float(sin(2.0 * Double.pi * 440.0 * s) * 0.15)
        }

        var asbd = audioFormat.streamDescription.pointee
        var blockBuffer: CMBlockBuffer?
        let byteCount = n * 4
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                 flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let bb = blockBuffer else {
            lock.lock(); pumpError = "创建音频 block buffer 失败"; lock.unlock()
            audioInput.markAsFinished(); audioDone = true; group.leave(); return
        }
        _ = CMBlockBufferReplaceDataBytes(with: dst, blockBuffer: bb, offsetIntoDestination: 0, dataLength: byteCount)

        var formatDesc: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &formatDesc) == noErr, let fd = formatDesc else {
            lock.lock(); pumpError = "创建音频格式描述失败"; lock.unlock()
            audioInput.markAsFinished(); audioDone = true; group.leave(); return
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)),
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd,
                                        sampleCount: CMItemCount(n), sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                        sampleSizeArray: nil, sampleBufferOut: &sampleBuffer) == noErr,
              let sb = sampleBuffer else {
            lock.lock(); pumpError = "创建音频 sample buffer 失败"; lock.unlock()
            audioInput.markAsFinished(); audioDone = true; group.leave(); return
        }
        if !audioInput.append(sb) {
            lock.lock(); pumpError = "追加音频失败: \(writer.error?.localizedDescription ?? "未知")"; lock.unlock()
            audioInput.markAsFinished(); audioDone = true; group.leave(); return
        }
        written += n
    }
    if written >= totalSamples && !audioDone {
        audioDone = true
        audioInput.markAsFinished()
        group.leave()
    }
}

if group.wait(timeout: .now() + 600) == .timedOut {
    fail("写盘超时：视频写了 \(frameIndex)/\(totalFrames) 帧，音频写了 \(written)/\(totalSamples) 采样，status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "无")")
}
if let e = pumpError { fail(e) }

let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
guard writer.status == .completed else {
    fail("写盘失败: \(writer.error?.localizedDescription ?? "未知")")
}
cleanSidecars(outURL)

let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
let size = (attrs?[.size] as? Int) ?? 0
log("完成: \(outURL.path)")
log("  \(Int(duration)) 秒 / \(width)x\(height) / \(Int(fps))fps / \(totalFrames) 帧 / 440Hz 正弦音 / \(size) 字节")
