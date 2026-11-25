// video2livephoto.swift
// 把普通视频转成 iPhone 实况照片（Live Photo）：<前缀>.jpg + <前缀>.mov
// 纯 AVFoundation / ImageIO 实现，不依赖 ffmpeg / exiftool。
//
// 两种模式：
//   1) 整段模式（默认）：不传 --duration，整段视频做成一张实况图，时长不裁剪
//   2) 裁剪模式：显式传 --duration，以 --at 为中心取一段（可逗号分隔多个 --at，批量出多组）
//
// 关键实现（照抄 TouSC/Video2LivePhoto 的验证过的做法）：
//   - MOV 写入 com.apple.quicktime.content.identifier = 同一个 UUID
//   - JPG 写入 Apple maker note key "17" = 同一个 UUID
//   - MOV 内写入 mediaType = metadata 的定时元数据轨，格式 com.apple.quicktime.still-image-time（boxed/mebx）
//   - still-image-time 的时间点 == 封面帧在输出片段里的位置
//   - shouldOptimizeForNetworkUse = true（moov 前置，等价 faststart）

import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreVideo
import ImageIO

// MARK: - 常量

let kKeyContentIdentifier = "com.apple.quicktime.content.identifier"
let kKeyStillImageTime = "com.apple.quicktime.still-image-time"
let kKeySpaceQuickTimeMetadata = "mdta"
let kStillImageTimeIdentifier = "mdta/com.apple.quicktime.still-image-time"

// MARK: - 基础工具

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("错误: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func evenUp(_ v: Double) -> Int {
    let i = max(2, Int(v.rounded()))
    return i % 2 == 0 ? i : i + 1
}

func fmt(_ v: Double, _ digits: Int = 3) -> String {
    String(format: "%.\(digits)f", v)
}

/// 有上限的等待：等不到就带 writer 状态和 error 报错，绝不无限挂住
func waitReadySync(_ input: AVAssetWriterInput, _ writer: AVAssetWriter, _ what: String) throws {
    var ticks = 0
    while !input.isReadyForMoreMediaData {
        if writer.status == .failed || writer.status == .cancelled {
            throw ToolError("\(what) 写入中断: \(writer.error?.localizedDescription ?? "未知原因")")
        }
        usleep(2000)
        ticks += 1
        if ticks > 5000 {
            throw ToolError("\(what) 等 isReadyForMoreMediaData 超过 10 秒: status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "无")")
        }
    }
}

/// 每个输入一条自己的串行队列，各自 requestMediaDataWhenReady。
/// 关键：绝不能在一个输入「没准备好」时阻塞等待 —— 那样另一个输入（音频）就永远灌不进去，
/// writer 的交错缓冲会一直攒着不写，最后死锁（实测 197 秒的视频卡在第 32 秒左右）。
/// 这个写法照搬参考实现（Converter4Video.swift）的多队列 + DispatchGroup 做法。
func pumpAll(_ jobs: [(String, AVAssetWriterInput, AVAssetReaderOutput)], writer: AVAssetWriter, timeout: TimeInterval) throws {
    let group = DispatchGroup()
    let lock = NSLock()
    var firstError: String? = nil

    for (label, input, output) in jobs {
        let queue = DispatchQueue(label: "livephoto.pump.\(label)")
        group.enter()
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                guard let sb = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    group.leave()
                    return
                }
                if !input.append(sb) {
                    lock.lock()
                    if firstError == nil {
                        firstError = "\(label) append 失败: \(writer.error?.localizedDescription ?? "未知原因")"
                    }
                    lock.unlock()
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
            // 这个输入暂时不 ready：直接返回，等它 ready 时系统会再调回来
        }
    }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        throw ToolError("写盘超时（超过 \(Int(timeout)) 秒还没写完）。writer.status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "无")")
    }
    if let e = firstError { throw ToolError(e) }
}

func displaySizeOf(_ track: AVAssetTrack) -> CGSize {
    let t = track.naturalSize.applying(track.preferredTransform)
    return CGSize(width: abs(t.width), height: abs(t.height))
}

/// 清掉 AVAssetWriter 在输出目录留下的 .sb-xxxx 中间文件
func cleanSidecars(_ url: URL) {
    let dir = url.deletingLastPathComponent()
    let prefix = url.lastPathComponent + ".sb-"
    if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
        for f in items where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}

// MARK: - 元数据

func metadataForAssetID(_ assetIdentifier: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.key = kKeyContentIdentifier as (NSCopying & NSObjectProtocol)?
    item.keySpace = AVMetadataKeySpace(rawValue: kKeySpaceQuickTimeMetadata)
    item.value = assetIdentifier as (NSCopying & NSObjectProtocol)?
    item.dataType = "com.apple.metadata.datatype.UTF-8"
    return item.copy() as! AVMetadataItem
}

func metadataForStillImageTime() -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.key = kKeyStillImageTime as (NSCopying & NSObjectProtocol)?
    item.keySpace = AVMetadataKeySpace(rawValue: kKeySpaceQuickTimeMetadata)
    item.value = 0 as (NSCopying & NSObjectProtocol)?
    item.dataType = kCMMetadataBaseDataType_SInt8 as String
    return item.copy() as! AVMetadataItem
}

func createStillImageTimeAdaptor() throws -> AVAssetWriterInputMetadataAdaptor {
    let spec: NSDictionary = [
        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString: kStillImageTimeIdentifier,
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString: "com.apple.metadata.datatype.int8",
    ]
    var desc: CMFormatDescription?
    let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [spec] as CFArray,
        formatDescriptionOut: &desc)
    guard status == noErr, let formatDesc = desc else {
        throw ToolError("创建 still-image-time 元数据格式描述失败 (OSStatus=\(status))")
    }
    let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDesc)
    return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
}

// MARK: - 写 MOV（直通或重编码，由调用方决定）

func writeLivePhotoMOV(reader: AVAssetReader,
                       videoOutput: AVAssetReaderOutput,
                       videoInputSettings: [String: Any]?,
                       videoTransform: CGAffineTransform,
                       audioPairs: [(AVAssetWriterInput, AVAssetReaderTrackOutput)],
                       assetIdentifier: String,
                       stillTime: CMTime,
                       frameDur: CMTime,
                       movURL: URL) throws {
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(outputURL: movURL, fileType: .mov)
    } catch {
        throw ToolError("无法创建 MOV 输出 \(movURL.path): \(error.localizedDescription)")
    }
    // moov 前置（faststart 等价物），手机上不用下完整个文件就能播
    writer.shouldOptimizeForNetworkUse = true

    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoInputSettings)
    videoIn.expectsMediaDataInRealTime = false
    videoIn.transform = videoTransform
    writer.add(videoIn)

    for (audioIn, _) in audioPairs { writer.add(audioIn) }

    let adaptor = try createStillImageTimeAdaptor()
    writer.add(adaptor.assetWriterInput)
    writer.metadata = [metadataForAssetID(assetIdentifier)]

    guard writer.startWriting() else {
        throw ToolError("AVAssetWriter 启动失败: \(writer.error?.localizedDescription ?? "未知原因")")
    }
    guard reader.startReading() else {
        throw ToolError("AVAssetReader 启动失败: \(reader.error?.localizedDescription ?? "未知原因")")
    }
    writer.startSession(atSourceTime: .zero)

    // still-image-time：定时元数据，位置 = 封面帧在输出里的时间
    let stillGroup = AVTimedMetadataGroup(items: [metadataForStillImageTime()],
                                          timeRange: CMTimeRange(start: stillTime, duration: frameDur))
    try waitReadySync(adaptor.assetWriterInput, writer, "still-image-time")
    guard adaptor.append(stillGroup) else {
        throw ToolError("still-image-time 元数据写入失败: \(writer.error?.localizedDescription ?? "未知原因")")
    }
    adaptor.assetWriterInput.markAsFinished()

    var jobs: [(String, AVAssetWriterInput, AVAssetReaderOutput)] = [("视频", videoIn, videoOutput)]
    var i = 0
    for (audioIn, audioOut) in audioPairs {
        i += 1
        jobs.append(("音频\(i)", audioIn, audioOut))
    }
    try pumpAll(jobs, writer: writer, timeout: 3600)

    guard reader.status != .failed else {
        throw ToolError("读取失败: \(reader.error?.localizedDescription ?? "未知原因")")
    }

    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else {
        throw ToolError("MOV 写盘失败: \(writer.error?.localizedDescription ?? "未知原因") (status=\(writer.status.rawValue))")
    }
}

// MARK: - 封面图（JPG / HEIC）

/// 封面格式 → UTType。两种都走同一个 CGImageDestination 路径，maker note key 17 的写法完全一样。
func photoUTI(_ format: String) -> String {
    return format == "heic" ? "public.heic" : "public.jpeg"
}

func writePhoto(_ image: CGImage, to url: URL, format: String, assetIdentifier: String) throws {
    let uti = photoUTI(format)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
        throw ToolError("无法创建 \(format.uppercased()) 输出（UTType \(uti)）: \(url.path)")
    }
    // Apple maker note key 17 = asset identifier：JPG 与 HEIC 都写这一份，逻辑不分叉
    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.95,
        kCGImagePropertyMakerAppleDictionary: ["17": assetIdentifier] as CFDictionary,
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw ToolError("\(format.uppercased()) 写入失败: \(url.path)")
    }
}

func scaleImage(_ image: CGImage, to size: CGSize) -> CGImage? {
    let w = Int(size.width), h = Int(size.height)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

func extractFrame(asset: AVAsset, at seconds: Double) throws -> CGImage {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let t = CMTime(seconds: seconds, preferredTimescale: 600)
    var actual = CMTime.zero
    do {
        return try gen.copyCGImage(at: t, actualTime: &actual)
    } catch {
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        return try gen.copyCGImage(at: t, actualTime: &actual)
    }
}

// MARK: - 合成轨

/// 取 [start, start+dur) 一段，重排到 0 起（不重编码，只是引用）
func buildRangeComposition(srcURL: URL, start: Double, dur: Double) throws -> (AVMutableComposition, AVAssetTrack) {
    let asset = AVURLAsset(url: srcURL)
    guard let vTrack = asset.tracks(withMediaType: .video).first else {
        throw ToolError("输入视频里没有视频轨: \(srcURL.path)")
    }
    let ts: CMTimeScale = vTrack.naturalTimeScale > 0 ? vTrack.naturalTimeScale : 600
    let comp = AVMutableComposition()
    guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw ToolError("无法创建视频合成轨")
    }
    let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: ts),
                            duration: CMTime(seconds: dur, preferredTimescale: ts))
    try cv.insertTimeRange(range, of: vTrack, at: .zero)
    if let aTrack = asset.tracks(withMediaType: .audio).first,
       let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        try? ca.insertTimeRange(range, of: aTrack, at: .zero)
    }
    return (comp, vTrack)
}

/// 源片比目标时长短：首尾帧定格撑长（照抄参考实现的做法）
func buildPaddedComposition(srcURL: URL, targetDuration: Double) throws -> (AVMutableComposition, AVAssetTrack, Double) {
    let asset = AVURLAsset(url: srcURL)
    let srcDur = CMTimeGetSeconds(asset.duration)
    guard let vTrack = asset.tracks(withMediaType: .video).first else {
        throw ToolError("输入视频里没有视频轨: \(srcURL.path)")
    }
    let ts: CMTimeScale = vTrack.naturalTimeScale > 0 ? vTrack.naturalTimeScale : 600
    let comp = AVMutableComposition()
    guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw ToolError("无法创建视频合成轨")
    }
    let prefix = (targetDuration - srcDur) / 2
    let suffix = targetDuration - srcDur - prefix
    var frameDur = vTrack.minFrameDuration
    if !frameDur.isValid || CMTimeGetSeconds(frameDur) <= 0 { frameDur = CMTime(value: 1, timescale: 30) }

    try cv.insertTimeRange(CMTimeRange(start: .zero, duration: frameDur), of: vTrack, at: .zero)
    cv.scaleTimeRange(CMTimeRange(start: .zero, duration: frameDur),
                      toDuration: CMTime(seconds: prefix, preferredTimescale: ts))

    let mainStart = CMTime(seconds: prefix, preferredTimescale: ts)
    try cv.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: vTrack, at: mainStart)

    if suffix > 0.01 {
        let lastStart = CMTimeSubtract(asset.duration, frameDur)
        let suffixStart = CMTimeAdd(mainStart, asset.duration)
        try cv.insertTimeRange(CMTimeRange(start: lastStart, duration: frameDur), of: vTrack, at: suffixStart)
        cv.scaleTimeRange(CMTimeRange(start: suffixStart, duration: frameDur),
                          toDuration: CMTime(seconds: suffix, preferredTimescale: ts))
    }
    if let aTrack = asset.tracks(withMediaType: .audio).first,
       let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        try? ca.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: aTrack, at: mainStart)
    }
    return (comp, vTrack, prefix)
}

/// --width 缩放 / 旋转纠正
func makeVideoComposition(compVideo: AVAssetTrack, sourceTrack: AVAssetTrack, targetWidth: Int?) -> (AVMutableVideoComposition, CGSize) {
    let displaySize = displaySizeOf(sourceTrack)
    let preferredTransform = sourceTrack.preferredTransform
    let transformed = CGRect(origin: .zero, size: sourceTrack.naturalSize).applying(preferredTransform)

    var outWidth: Double
    if let w = targetWidth {
        outWidth = Double(w)
    } else {
        outWidth = displaySize.width > 1920 ? 1920 : displaySize.width
    }
    let scaleFactor = outWidth / displaySize.width
    let outSize = CGSize(width: Double(evenUp(outWidth)), height: Double(evenUp(displaySize.height * scaleFactor)))

    let normalize = preferredTransform.concatenating(
        CGAffineTransform(translationX: -transformed.origin.x, y: -transformed.origin.y))
    let finalTransform = normalize.concatenating(CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))

    var fps = 30.0
    let nominal = Double(sourceTrack.nominalFrameRate)
    if nominal.isFinite && nominal >= 1 { fps = nominal.rounded() }
    if fps > 120 { fps = 120 }

    let vcomp = AVMutableVideoComposition()
    vcomp.renderSize = outSize
    vcomp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 36000, preferredTimescale: 600))
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
    layer.setTransform(finalTransform, at: .zero)
    instruction.layerInstructions = [layer]
    vcomp.instructions = [instruction]
    return (vcomp, outSize)
}

// MARK: - 一组转换

struct GroupResult {
    var photo: URL
    var mov: URL
    var photoFormat: String
    var stillOffset: Double
    var outDuration: Double
    var mode: String
    var elapsed: Double
    var reencoded: Bool
}

func convertGroup(srcURL: URL,
                  srcDur: Double,
                  rangeStart: Double,
                  rangeDuration: Double,
                  coverTime: Double,
                  width: Int?,
                  photoFormat: String,
                  outDir: URL,
                  prefix: String) throws -> GroupResult {
    let t0 = Date()
    let padding = rangeDuration > srcDur + 0.001
    let photoURL = outDir.appendingPathComponent("\(prefix).\(photoFormat)")
    let movURL = outDir.appendingPathComponent("\(prefix).mov")
    // 两种格式都清一遍：换格式重跑时不留上一次的旧封面
    for ext in ["jpg", "heic"] {
        try? FileManager.default.removeItem(at: outDir.appendingPathComponent("\(prefix).\(ext)"))
    }
    try? FileManager.default.removeItem(at: movURL)
    let assetIdentifier = UUID().uuidString

    let srcAsset = AVURLAsset(url: srcURL)
    guard let srcVideo = srcAsset.tracks(withMediaType: .video).first else {
        throw ToolError("输入视频里没有视频轨: \(srcURL.path)")
    }

    // ---- 封面帧（取 --at 那一帧）
    let rawStill = try extractFrame(asset: srcAsset, at: coverTime)
    var stillImage = rawStill
    if let w = width {
        let ds = displaySizeOf(srcVideo)
        let s = Double(w) / ds.width
        let target = CGSize(width: Double(evenUp(Double(w))), height: Double(evenUp(ds.height * s)))
        if let scaled = scaleImage(rawStill, to: target) { stillImage = scaled }
    }

    var frameDur = srcVideo.minFrameDuration
    if !frameDur.isValid || CMTimeGetSeconds(frameDur) <= 0 { frameDur = CMTime(value: 1, timescale: 30) }

    var tempFile: URL? = nil
    defer { if let f = tempFile { try? FileManager.default.removeItem(at: f) } }

    var mode: String
    var reencoded = false
    var stillOffset: Double
    var readerAsset: AVAsset
    var videoOutput: AVAssetReaderOutput
    var videoSettings: [String: Any]?
    var videoTransform = srcVideo.preferredTransform
    var audioPairs: [(AVAssetWriterInput, AVAssetReaderTrackOutput)] = []
    let reader: AVAssetReader

    if padding {
        // 只在这一种情况下走「先导出临时片段」：定格补长必须重编码
        let (comp, _, prefixDur) = try buildPaddedComposition(srcURL: srcURL, targetDuration: rangeDuration)
        guard let compVideo = comp.tracks(withMediaType: .video).first else { throw ToolError("合成轨里没有视频轨") }
        let (vcomp, _) = makeVideoComposition(compVideo: compVideo, sourceTrack: srcVideo, targetWidth: width)
        let tmp = outDir.appendingPathComponent(".tmp-\(prefix)-\(UUID().uuidString).mov")
        tempFile = tmp
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ToolError("无法创建导出会话")
        }
        export.outputURL = tmp
        export.outputFileType = .mov
        export.videoComposition = vcomp
        export.shouldOptimizeForNetworkUse = false
        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        sem.wait()
        guard export.status == .completed else {
            throw ToolError("定格补长片段导出失败: \(export.error?.localizedDescription ?? "未知原因")")
        }
        let padded = AVURLAsset(url: tmp)
        readerAsset = padded
        reencoded = true
        mode = "首尾帧定格补长 + 重编码"
        stillOffset = min(prefixDur + coverTime, rangeDuration - 0.001)
        videoSettings = nil
        videoTransform = .identity
        reader = try AVAssetReader(asset: padded)
        guard let vTrack = padded.tracks(withMediaType: .video).first else { throw ToolError("补长片段没有视频轨") }
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        videoOutput = vOut
        for aTrack in padded.tracks(withMediaType: .audio) {
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            reader.add(aOut)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            aIn.expectsMediaDataInRealTime = false
            audioPairs.append((aIn, aOut))
        }
    } else {
        let (comp, _) = try buildRangeComposition(srcURL: srcURL, start: rangeStart, dur: rangeDuration)
        guard let compVideo = comp.tracks(withMediaType: .video).first else { throw ToolError("合成轨里没有视频轨") }
        readerAsset = comp
        stillOffset = coverTime - rangeStart
        reader = try AVAssetReader(asset: comp)

        if let w = width {
            // 要缩放：解一帧编一帧，单遍完成，不落临时文件
            let (vcomp, outSize) = makeVideoComposition(compVideo: compVideo, sourceTrack: srcVideo, targetWidth: w)
            let vOut = AVAssetReaderVideoCompositionOutput(
                videoTracks: [compVideo],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
            vOut.videoComposition = vcomp
            vOut.alwaysCopiesSampleData = false
            reader.add(vOut)
            videoOutput = vOut
            let bitrate = max(2_000_000, Int(outSize.width * outSize.height * 6.0))
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outSize.width),
                AVVideoHeightKey: Int(outSize.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
            ]
            videoTransform = .identity
            reencoded = true
            mode = "按 --width \(w) 缩放 + 重编码"
        } else {
            // 不缩放：直通复制压缩样本，画质零损失、速度基本等于拷文件
            let vOut = AVAssetReaderTrackOutput(track: compVideo, outputSettings: nil)
            vOut.alwaysCopiesSampleData = false
            reader.add(vOut)
            videoOutput = vOut
            videoSettings = nil
            mode = "直通复制（不重编码）"
        }

        for aTrack in comp.tracks(withMediaType: .audio) {
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            aOut.alwaysCopiesSampleData = false
            reader.add(aOut)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            aIn.expectsMediaDataInRealTime = false
            audioPairs.append((aIn, aOut))
        }
    }

    _ = readerAsset
    let maxStill = padding ? rangeDuration - 0.001 : rangeDuration - 0.001
    let stillTime = CMTime(seconds: min(max(stillOffset, 0), max(0, maxStill)), preferredTimescale: 600)

    try writePhoto(stillImage, to: photoURL, format: photoFormat, assetIdentifier: assetIdentifier)
    try writeLivePhotoMOV(reader: reader,
                          videoOutput: videoOutput,
                          videoInputSettings: videoSettings,
                          videoTransform: videoTransform,
                          audioPairs: audioPairs,
                          assetIdentifier: assetIdentifier,
                          stillTime: stillTime,
                          frameDur: frameDur,
                          movURL: movURL)

    let outDur = CMTimeGetSeconds(AVURLAsset(url: movURL).duration)
    cleanSidecars(movURL)
    return GroupResult(photo: photoURL, mov: movURL, photoFormat: photoFormat,
                       stillOffset: CMTimeGetSeconds(stillTime),
                       outDuration: outDur,
                       mode: mode,
                       elapsed: Date().timeIntervalSince(t0),
                       reencoded: reencoded)
}

// MARK: - --inspect

func hexFourCC(_ code: FourCharCode) -> String {
    let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

/// 在 JPEG 的 APP1/Exif 段里找 asset identifier 的字节（ImageIO 之外的第二条证据）
func uuidInJPEGExif(url: URL, uuid: String) -> (Bool, String) {
    guard let data = try? Data(contentsOf: url) else { return (false, "读文件失败") }
    let bytes = [UInt8](data)
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return (false, "不是 JPEG") }
    let needle = [UInt8](uuid.utf8)
    var i = 2
    while i + 4 <= bytes.count {
        if bytes[i] != 0xFF { i += 1; continue }
        let marker = bytes[i + 1]
        if marker == 0xDA { break }
        if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) { i += 2; continue }
        let segLen = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        let segStart = i + 4
        let segEnd = min(bytes.count, i + 2 + segLen)
        if marker == 0xE1 && segLen >= 6 {
            let exifTag = Array(bytes[segStart..<min(segStart + 6, bytes.count)])
            if exifTag == Array("Exif\u{0}\u{0}".utf8) {
                var p = segStart
                while p + needle.count <= segEnd {
                    if Array(bytes[p..<(p + needle.count)]) == needle {
                        return (true, "在 APP1/Exif 段（文件偏移 \(p)）找到该 UUID")
                    }
                    p += 1
                }
                return (false, "APP1/Exif 段里没有这个 UUID")
            }
        }
        if segLen < 2 { break }
        i += 2 + segLen
    }
    return (false, "JPEG 里没有找到 Exif 段")
}

/// 字节子串查找（[UInt8] 上没有 range(of:)，自己写一个）
func containsBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for i in 0...(haystack.count - needle.count) {
        if Array(haystack[i..<(i + needle.count)]) == needle { return true }
    }
    return false
}

/// HEIC 里找 asset identifier 的字节。
/// HEIC 的 Exif（含 Apple maker note）是一个独立的 HEIF item，条带/位置都在 box 结构里，
/// 手写 HEIF box 解析器不划算，所以这里做的是「整文件字节搜索 + 结构检查」：
///   1) 确认文件头是 HEIF：offset 4 起是 'ftyp'，brand 是 heic/heix/mif1 之一
///   2) 找到 UUID 字节出现的所有偏移
///   3) 报告 UUID 前面最近的一段字节，看是不是 Apple maker note 头（"Apple" 开头）
/// 结论强度：能证伪（找不到就是没写进去），不能单独证明「它一定在 MakerNote tag 17 里」——
/// 所以 ImageIO 走一遍 `kCGImagePropertyMakerAppleDictionary` 才是主证据，这个只是第二条证据。
func uuidInHEICBytes(url: URL, uuid: String) -> (Bool, String) {
    guard let data = try? Data(contentsOf: url) else { return (false, "读文件失败") }
    let bytes = [UInt8](data)
    guard bytes.count > 12 else { return (false, "文件太小") }
    let ftyp = Array(bytes[4..<8])
    guard ftyp == Array("ftyp".utf8) else {
        return (false, "不是 HEIF：偏移 4 起的 4 字节不是 'ftyp'（实际 \(String(bytes: ftyp, encoding: .ascii) ?? "?")）")
    }
    let brand = String(bytes: bytes[8..<min(12, bytes.count)], encoding: .ascii) ?? "?"
    let needle = [UInt8](uuid.utf8)
    var hits: [Int] = []
    var p = 0
    while p + needle.count <= bytes.count {
        if Array(bytes[p..<(p + needle.count)]) == needle { hits.append(p) }
        p += 1
    }
    guard let first = hits.first else {
        return (false, "HEIF（brand=\(brand)）里整文件搜不到这个 UUID 的字节 —— maker note 没写进去")
    }
    // 往前找 96 字节，看能不能看到 Apple maker note 头
    let backStart = max(0, first - 96)
    let window = Array(bytes[backStart..<first])
    let hasApple = containsBytes(window, Array("Apple".utf8))
    let isMakerTag = containsBytes(window, Array("MM".utf8)) || containsBytes(window, Array("II".utf8))
    return (true, "HEIF（brand=\(brand)）里找到 \(hits.count) 处 UUID，第一处在偏移 \(first)"
        + "；前 96 字节里\(hasApple ? "有" : "没有") Apple maker note 头，"
        + "\(isMakerTag ? "有" : "没有") MakerNote 的 TIFF 字节序标记（MM/II）")
}

func inspect(photoPath: String, movPath: String) -> Int32 {
    let photoURL = URL(fileURLWithPath: photoPath)
    let movURL = URL(fileURLWithPath: movPath)
    var ok = true

    let ext = photoURL.pathExtension.lowercased()
    let kind = (ext == "heic" || ext == "heif") ? "HEIC" : "JPG"

    log("== 自检 ==")
    log("封面(\(kind)): \(photoURL.path)")
    log("MOV: \(movURL.path)")

    guard FileManager.default.fileExists(atPath: photoURL.path) else { fail("封面不存在: \(photoURL.path)") }
    guard FileManager.default.fileExists(atPath: movURL.path) else { fail("MOV 不存在: \(movURL.path)") }

    // ---- (a) asset identifier
    let asset = AVURLAsset(url: movURL)
    var movIdentifier: String? = nil
    for item in asset.metadata(forFormat: .quickTimeMetadata) {
        if (item.key as? String) == kKeyContentIdentifier,
           item.keySpace?.rawValue == kKeySpaceQuickTimeMetadata {
            movIdentifier = item.value as? String
        }
    }

    var photoIdentifier: String? = nil
    if let src = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let apple = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] {
        photoIdentifier = apple["17"] as? String
    }
    let (byteHit, byteNote): (Bool, String) = (kind == "HEIC")
        ? uuidInHEICBytes(url: photoURL, uuid: movIdentifier ?? "___none___")
        : uuidInJPEGExif(url: photoURL, uuid: movIdentifier ?? "___none___")

    log("")
    log("[a] asset identifier 比对")
    log("  MOV  \(kKeyContentIdentifier) = \(movIdentifier ?? "<读不到>")")
    log("  \(kind)  Apple maker note key 17      = \(photoIdentifier ?? "<ImageIO 读不到>")")
    log("  源码复核（\(kind == "HEIC" ? "整文件字节搜索 + HEIF 结构检查" : "直接在 JPEG 的 Exif 段里找这个 UUID 的字节")）: \(byteHit ? "命中" : "未命中") — \(byteNote)")
    let identifierOK = movIdentifier != nil && photoIdentifier != nil && movIdentifier == photoIdentifier
    if identifierOK {
        log("  => 通过：\(kind) 与 MOV 的 asset identifier 相同")
    } else {
        ok = false
        log("  => 不通过：两端 identifier 不一致或读不到")
    }
    // 字节层第二条证据：ImageIO 读到了、字节也搜到了，才算双证
    if !byteHit {
        ok = false
        log("  => 不通过：字节层复核没命中（见上面那行说明）")
    }

    // ---- (b) metadata 轨 + still-image-time
    log("")
    log("[b] metadata 轨与 still-image-time 格式")
    let metaTracks = asset.tracks(withMediaType: .metadata)
    log("  mediaType = metadata 的轨数量: \(metaTracks.count)")
    var stillIdentifiers: [String] = []
    var subTypes: [String] = []
    if metaTracks.isEmpty {
        ok = false
        log("  => 不通过：没有 metadata 轨")
    }
    for (idx, track) in metaTracks.enumerated() {
        for fd in track.formatDescriptions {
            let desc = fd as! CMFormatDescription
            let sub = hexFourCC(CMFormatDescriptionGetMediaSubType(desc))
            subTypes.append(sub)
            log("  轨#\(idx) mediaSubType = \(sub)（'mebx' = boxed metadata）")
            if let ids = CMMetadataFormatDescriptionGetIdentifiers(desc) as? [String] {
                for id in ids {
                    stillIdentifiers.append(id)
                    log("  轨#\(idx) 标识符 = \(id)")
                }
            }
        }
    }
    let hasStillIdentifier = stillIdentifiers.contains(kStillImageTimeIdentifier)
    let hasBoxed = subTypes.contains("mebx")
    if hasStillIdentifier && hasBoxed {
        log("  => 通过：存在 boxed metadata 轨，格式为 \(kStillImageTimeIdentifier)")
    } else {
        ok = false
        log("  => 不通过：没找到 \(kStillImageTimeIdentifier) 的 boxed metadata 轨")
    }

    var stillSeconds: Double? = nil
    if let track = metaTracks.first {
        do {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(out)
            reader.startReading()
            while let sb = out.copyNextSampleBuffer() {
                if let group = AVTimedMetadataGroup(sampleBuffer: sb) {
                    for item in group.items where (item.key as? String) == kKeyStillImageTime {
                        stillSeconds = CMTimeGetSeconds(group.timeRange.start)
                    }
                }
            }
        } catch {
            log("  读 still-image-time 样本失败: \(error.localizedDescription)")
        }
    }
    if let s = stillSeconds {
        log("  still-image-time 标记在片段第 \(fmt(s)) 秒")
    } else {
        log("  （没读出 still-image-time 样本的时间点）")
    }

    // ---- (c) 实际时长
    let dur = CMTimeGetSeconds(asset.duration)
    log("")
    log("[c] MOV 实际时长 = \(fmt(dur)) 秒")
    if let v = asset.tracks(withMediaType: .video).first {
        let ds = displaySizeOf(v)
        log("  视频轨 编码尺寸 \(Int(v.naturalSize.width))x\(Int(v.naturalSize.height))，显示尺寸 \(Int(ds.width))x\(Int(ds.height))，帧率 \(fmt(Double(v.nominalFrameRate), 2))")
    }
    log("  音频轨数量 = \(asset.tracks(withMediaType: .audio).count)")

    log("")
    log("== 结论: \(ok ? "全部通过" : "有检查项不通过") ==")
    return ok ? 0 : 1
}

// MARK: - --probe

func probe(path: String) -> Int32 {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("文件不存在: \(path)") }
    let asset = AVURLAsset(url: url)
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    log("== 探测 ==")
    log("文件: \(url.path)")
    log("大小: \((attrs?[.size] as? Int) ?? 0) 字节")
    log("时长: \(fmt(CMTimeGetSeconds(asset.duration))) 秒")
    for t in asset.tracks {
        let kind = t.mediaType.rawValue
        let ds = displaySizeOf(t)
        log("轨: mediaType=\(kind) 编码 \(Int(t.naturalSize.width))x\(Int(t.naturalSize.height)) 显示 \(Int(ds.width))x\(Int(ds.height)) 帧率 \(fmt(Double(t.nominalFrameRate), 2))")
    }
    for item in asset.metadata(forFormat: .quickTimeMetadata) {
        if let k = item.key as? String, k == kKeyContentIdentifier {
            log("已有的 \(k) = \(item.value as? String ?? "<空>")")
        }
    }
    return 0
}

// MARK: - --grab

/// 抽一帧存成 JPG，并打印平均亮度（用来验证「不是黑帧」）
func grab(path: String, seconds: Double, out: String) -> Int32 {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("文件不存在: \(path)") }
    let asset = AVURLAsset(url: url)
    let dur = CMTimeGetSeconds(asset.duration)
    guard seconds <= dur else { fail("时间点 \(seconds)s 超出时长 \(fmt(dur))s") }
    let img: CGImage
    do {
        img = try extractFrame(asset: asset, at: seconds)
    } catch {
        fail("抽帧失败: \(error.localizedDescription)")
    }
    let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
        fail("无法创建输出: \(out)")
    }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("写 JPG 失败: \(out)") }
    log("已抽出帧: \(outURL.path)")
    log("  时间点 \(fmt(seconds))s / \(img.width)x\(img.height)，平均亮度 \(fmt(meanLuminance(img), 2)) / 255")
    return 0
}

func meanLuminance(_ image: CGImage) -> Double {
    let w = 32, h = 32
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum = 0.0
    for i in stride(from: 0, to: buf.count, by: 4) {
        sum += 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
    }
    return sum / Double(w * h)
}

// MARK: - 参数解析

func usage() -> String {
    """
    用法:
      video2livephoto --video <输入视频> --out <输出目录> [--at <秒>[,<秒>...]] [--duration <秒>] [--name <前缀>] [--width <像素>] [--photo-format jpg|heic]
      video2livephoto --inspect <封面图> <mov>
      video2livephoto --probe <视频文件>
      video2livephoto --grab <视频文件> <秒> <输出jpg>

    模式:
      整段模式（默认，不带 --duration）: 整段视频做成一张实况图，时长不裁剪
      裁剪模式（带 --duration）        : 以 --at 为中心取 --duration 秒

    参数:
      --video     输入视频路径（mp4 / mov / m4v ...）
      --at        封面时刻（秒），支持逗号分隔多个，例：--at 5,12.5,30
                  整段模式下默认 0（第一帧）；裁剪模式下不传则取视频中点
      --duration  要裁剪的片段时长（秒）。不传 = 整段不裁剪。没有上限，10 / 30 / 60 / 600 都支持
      --out       输出目录（不存在会自动建）
      --name      输出文件名前缀，默认取输入视频的文件名
      --width     输出宽度（像素）。不传则保持原分辨率（最长边不超过 1920）且直通复制不重编码
      --photo-format 封面照格式：jpg（默认）或 heic。heic 给 .livp 打包用（导入流程按 HEIC 找封面）
      --inspect   自检：比对 <封面图> <mov> 的 asset identifier / metadata 轨 / 时长（jpg / heic 都认）
      --probe     看一个视频文件的时长、轨、分辨率
      --grab      从视频里抽一帧存成 jpg（并打印该帧平均亮度，用来判断是不是黑帧）

    输出:
      <前缀>.jpg 或 <前缀>.heic（封面照）+ <前缀>.mov（视频部分），两者共用同一个 UUID 作为 asset identifier
      多个 --at 时依次为 <前缀>_1.jpg / <前缀>_1.mov / <前缀>_2.jpg ...
    """
}

var argv = Array(CommandLine.arguments.dropFirst())

if argv.contains("--help") || argv.contains("-h") {
    print(usage())
    exit(0)
}
if argv.isEmpty {
    print(usage())
    exit(1)
}

if let i = argv.firstIndex(of: "--inspect") {
    let rest = Array(argv[(i + 1)...])
    guard rest.count >= 2 else { fail("--inspect 需要两个参数：<封面图jpg/heic> <mov>") }
    exit(inspect(photoPath: rest[0], movPath: rest[1]))
}
if let i = argv.firstIndex(of: "--probe") {
    let rest = Array(argv[(i + 1)...])
    guard let p = rest.first else { fail("--probe 需要一个文件参数") }
    exit(probe(path: (p as NSString).expandingTildeInPath))
}
if let i = argv.firstIndex(of: "--grab") {
    let rest = Array(argv[(i + 1)...])
    guard rest.count >= 3, let sec = Double(rest[1]) else {
        fail("--grab 需要三个参数：<视频> <秒> <输出jpg>")
    }
    exit(grab(path: (rest[0] as NSString).expandingTildeInPath, seconds: sec, out: rest[2]))
}

var videoPath: String? = nil
var atRaw: String? = nil
var durationArg: Double? = nil
var outPath: String? = nil
var namePrefix: String? = nil
var width: Int? = nil
var photoFormat = "jpg"          // 默认 jpg：不传 --photo-format 时行为和以前完全一样

var idx = 0
while idx < argv.count {
    let a = argv[idx]
    func value(_ flag: String) -> String {
        guard idx + 1 < argv.count else { fail("\(flag) 后面缺参数值") }
        return argv[idx + 1]
    }
    switch a {
    case "--video": videoPath = value(a); idx += 2
    case "--at": atRaw = value(a); idx += 2
    case "--duration":
        let v = value(a)
        guard let d = Double(v), d > 0 else { fail("--duration 必须是大于 0 的数字，收到：\(v)") }
        durationArg = d
        idx += 2
    case "--out": outPath = value(a); idx += 2
    case "--name": namePrefix = value(a); idx += 2
    case "--width":
        let v = value(a)
        guard let w = Int(v), w > 0 else { fail("--width 必须是正整数，收到：\(v)") }
        width = w
        idx += 2
    case "--photo-format":
        let v = value(a).lowercased()
        guard v == "jpg" || v == "heic" else { fail("--photo-format 只能是 jpg 或 heic，收到：\(v)") }
        photoFormat = v
        idx += 2
    default: fail("未知参数：\(a)\n\n" + usage())
    }
}

guard let videoArg = videoPath else { fail("缺少 --video\n\n" + usage()) }
guard let outArg = outPath else { fail("缺少 --out\n\n" + usage()) }

let srcURL = URL(fileURLWithPath: (videoArg as NSString).expandingTildeInPath)
guard FileManager.default.fileExists(atPath: srcURL.path) else { fail("输入视频不存在: \(srcURL.path)") }

let outURL = URL(fileURLWithPath: (outArg as NSString).expandingTildeInPath)
do {
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true, attributes: nil)
} catch {
    fail("无法创建输出目录 \(outURL.path): \(error.localizedDescription)")
}

let srcAsset = AVURLAsset(url: srcURL)
let srcDur = CMTimeGetSeconds(srcAsset.duration)
guard srcDur.isFinite, srcDur > 0 else { fail("读不出输入视频时长: \(srcURL.path)") }

let explicitCrop = durationArg != nil
let cropDuration = durationArg ?? 0

// 解析时间点
var times: [Double] = []
if let raw = atRaw {
    for piece in raw.split(separator: ",") {
        let s = piece.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let d = Double(s), d >= 0 else { fail("--at 里有非法时间点：'\(s)'") }
        times.append(d)
    }
    guard !times.isEmpty else { fail("--at 至少要有一个时间点") }
} else if explicitCrop {
    times = [srcDur / 2]
} else {
    times = [0]
}
for t in times where t > srcDur {
    fail("--at \(t) 超出视频时长 \(fmt(srcDur)) 秒")
}

let baseName = namePrefix ?? srcURL.deletingPathExtension().lastPathComponent

log("输入视频 : \(srcURL.path)")
log("源片时长 : \(fmt(srcDur)) 秒")
log("模式     : \(explicitCrop ? "裁剪（--duration \(fmt(cropDuration, 2)) 秒）" : "整段（不裁剪）")")
log("封面时刻 : \(times.map { String(format: "%g", $0) }.joined(separator: ", ")) 秒" + (atRaw == nil && explicitCrop ? "（未指定 --at，取视频中点）" : ""))
log("输出目录 : \(outURL.path)")
if let w = width { log("输出宽度 : \(w) px（需要重编码）") } else { log("输出宽度 : 保持原分辨率，直通复制不重编码") }
log("封面格式 : \(photoFormat.uppercased())" + (photoFormat == "heic" ? "（.livp 打包用）" : "（默认）"))
log("")

let totalStart = Date()
var results: [GroupResult] = []
for (i, t) in times.enumerated() {
    var rangeStart = 0.0
    var rangeDuration = srcDur
    if explicitCrop {
        if srcDur >= cropDuration {
            rangeStart = t - cropDuration / 2
            var end = t + cropDuration / 2
            if rangeStart < 0 { rangeStart = 0; end = cropDuration }
            if end > srcDur { end = srcDur; rangeStart = max(0, end - cropDuration) }
            rangeDuration = end - rangeStart
        } else {
            rangeStart = 0
            rangeDuration = cropDuration
        }
    }
    let prefix = times.count == 1 ? baseName : "\(baseName)_\(i + 1)"
    log("[\(i + 1)/\(times.count)] 封面 \(String(format: "%g", t))s → \(prefix).\(photoFormat) / \(prefix).mov")
    log("  片段 [\(fmt(rangeStart))s, \(fmt(rangeStart + rangeDuration))s)，长度 \(fmt(rangeDuration))s")
    do {
        let r = try convertGroup(srcURL: srcURL,
                                 srcDur: srcDur,
                                 rangeStart: rangeStart,
                                 rangeDuration: rangeDuration,
                                 coverTime: t,
                                 width: width,
                                 photoFormat: photoFormat,
                                 outDir: outURL,
                                 prefix: prefix)
        results.append(r)
        log("  方式: \(r.mode)")
        log("  封面(\(r.photoFormat.uppercased())): \(r.photo.path)")
        log("  MOV: \(r.mov.path)")
        log("  输出时长 \(fmt(r.outDuration)) 秒（源片片段 \(fmt(rangeDuration)) 秒）｜still-image-time 在 \(fmt(r.stillOffset)) 秒｜耗时 \(fmt(r.elapsed, 2)) 秒")
    } catch {
        fail("第 \(i + 1) 组（封面 \(t)s）失败：\(error)")
    }
    log("")
}

let totalElapsed = Date().timeIntervalSince(totalStart)
log("完成：共 \(results.count) 组，\(results.count * 2) 个文件，总耗时 \(fmt(totalElapsed, 2)) 秒。")
if let first = results.first, !first.reencoded {
    log("直通复制模式：耗时 \(fmt(totalElapsed, 2)) 秒 vs 视频时长 \(fmt(first.outDuration, 1)) 秒 —— 远小于视频时长即证明没有逐帧重编码。")
}
log("用 --inspect <封面图> <mov> 可以自检配对是否正确。")
exit(0)
