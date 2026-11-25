// remux-faststart.swift
// 把视频直通重封装成「moov 在 mdat 前面」的 MP4（faststart），不重编码。
//
// 用法:
//   remux-faststart <输入视频> <输出.mp4>   直通重封装（整段，不裁剪）
//   remux-faststart --info <视频>           打印时长 / 轨 / 顶层 box 顺序
//
// 只做容器层的事：改 moov 位置。视频、音频样本原样搬运。

import Foundation
import AVFoundation
import CoreMedia

func err(_ s: String) -> Never {
    FileHandle.standardError.write(("错误: " + s + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - 顶层 box 扫描（不依赖 AVFoundation，直接读字节）

struct Box { let type: String; let offset: Int; let size: Int }

func topLevelBoxes(_ path: String) -> [Box] {
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    let totalBytes = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
    guard totalBytes > 0 else { return [] }
    var out: [Box] = []
    var off = 0
    while off + 8 <= totalBytes {
        fh.seek(toFileOffset: UInt64(off))
        let h = fh.readData(ofLength: 8)
        guard h.count == 8 else { break }
        let n = h.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let t = String(bytes: h[4..<8], encoding: .isoLatin1) ?? "????"
        var size = Int(n)
        if size == 1 {
            let h2 = fh.readData(ofLength: 8)
            guard h2.count == 8 else { break }
            size = Int(h2.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
        } else if size == 0 {
            size = totalBytes - off
        }
        guard size >= 8 else { break }
        out.append(Box(type: t, offset: off, size: size))
        off += size
    }
    return out
}

func moovBeforeMdat(_ path: String) -> Bool? {
    let boxes = topLevelBoxes(path)
    guard let m = boxes.firstIndex(where: { $0.type == "moov" }),
          let d = boxes.firstIndex(where: { $0.type == "mdat" }) else { return nil }
    return m < d
}

// MARK: - 信息模式

func printInfo(_ path: String) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else { err("文件不存在: \(path)") }
    let sz = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
    print("文件: \(path)")
    print("大小: \(sz) 字节")
    let asset = AVAsset(url: url)
    let dur = CMTimeGetSeconds(asset.duration)
    print(String(format: "时长: %.6f 秒 (AVFoundation)", dur))
    for t in asset.tracks {
        let sub = t.formatDescriptions.first.map {
            let f = $0 as! CMFormatDescription
            return fourCC(CMFormatDescriptionGetMediaSubType(f))
        } ?? "?"
        let s = t.naturalSize
        print(String(format: "轨: %@  %@  %.1fx%.1f  %.2ffps  时长 %.6f 秒",
                     t.mediaType.rawValue, sub, s.width, s.height, t.nominalFrameRate, CMTimeGetSeconds(t.timeRange.duration)))
    }
    print("顶层 box 顺序:")
    for b in topLevelBoxes(path) {
        print("  \(b.type)  offset=\(b.offset)  size=\(b.size)")
    }
    if let ok = moovBeforeMdat(path) {
        print("faststart(moov 在 mdat 前): \(ok ? "是" : "否")")
    } else {
        print("faststart(moov 在 mdat 前): 无法判断（缺 moov 或 mdat）")
    }
}

func fourCC(_ c: FourCharCode) -> String {
    let b = [UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
    return String(bytes: b, encoding: .isoLatin1) ?? "????"
}

// MARK: - 重封装

func cleanSidecars(_ outPath: String) {
    let dir = (outPath as NSString).deletingLastPathComponent
    let base = (outPath as NSString).lastPathComponent
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: dir.isEmpty ? "." : dir) else { return }
    for it in items where it.hasPrefix(base + ".sb-") {
        try? fm.removeItem(atPath: (dir.isEmpty ? "." : dir) + "/" + it)
    }
}

func remux(_ inPath: String, _ outPath: String, faststart: Bool = true) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: inPath) else { err("输入文件不存在: \(inPath)") }
    if fm.fileExists(atPath: outPath) { try? fm.removeItem(atPath: outPath) }

    let asset = AVAsset(url: URL(fileURLWithPath: inPath))
    guard asset.tracks(withMediaType: .video).count > 0 else { err("输入没有视频轨，不做重封装") }

    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        err("拿不到 AVAssetExportSession（passthrough）")
    }
    session.outputURL = URL(fileURLWithPath: outPath)
    session.outputFileType = .mp4
    session.shouldOptimizeForNetworkUse = faststart
    // 整段，不裁剪
    session.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

    let inSize = ((try? fm.attributesOfItem(atPath: inPath)[.size]) as? Int) ?? 0
    let inDur = CMTimeGetSeconds(asset.duration)
    let t0 = Date()

    let sem = DispatchSemaphore(value: 0)
    session.exportAsynchronously { sem.signal() }
    // 本机没有 timeout 命令，上限写在程序里，不静默挂死
    if sem.wait(timeout: .now() + 900) == .timedOut {
        session.cancelExport()
        err("重封装超时（900 秒），已取消")
    }
    cleanSidecars(outPath)

    if session.status != .completed {
        err("重封装失败: status=\(session.status.rawValue) error=\(String(describing: session.error))")
    }

    let elapsed = Date().timeIntervalSince(t0)
    let outSize = ((try? fm.attributesOfItem(atPath: outPath)[.size]) as? Int) ?? 0
    let outAsset = AVAsset(url: URL(fileURLWithPath: outPath))
    let outDur = CMTimeGetSeconds(outAsset.duration)

    print("输入: \(inPath)")
    print("输出: \(outPath)")
    print(String(format: "耗时: %.3f 秒", elapsed))
    print("输入大小: \(inSize) 字节")
    print("输出大小: \(outSize) 字节  (差 \(outSize - inSize))")
    print(String(format: "输入时长: %.6f 秒", inDur))
    print(String(format: "输出时长: %.6f 秒  (差 %.6f)", outDur, outDur - inDur))
    if let before = moovBeforeMdat(inPath) {
        print("输入 faststart: \(before ? "是" : "否")")
    }
    if let after = moovBeforeMdat(outPath) {
        print("输出 faststart: \(after ? "是" : "否")")
        if after != faststart && faststart == false {
            print("（--no-faststart：本来就要 moov 在后）")
        }
    }
    print("输出顶层 box 顺序: " + topLevelBoxes(outPath).map { "\($0.type)(\($0.size))" }.joined(separator: " "))
    if outDur <= 0 { err("输出时长读不出来，视为失败") }
    if abs(outDur - inDur) > 0.01 { err("输出时长和输入不一致，视为失败") }
}

// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
if args.count == 2 && args[0] == "--info" {
    printInfo(args[1])
} else if args.count == 3 && args[0] == "--no-faststart" {
    // 只给测试用：故意产一个 moov 在后的 MP4，验证下游会认出来并转回 faststart
    remux(args[1], args[2], faststart: false)
} else if args.count == 2 && !args[0].hasPrefix("--") {
    remux(args[0], args[1])
} else {
    print("""
    用法:
      remux-faststart <输入视频> <输出.mp4>   直通重封装成 faststart MP4（整段，不重编码）
      remux-faststart --info <视频>           打印时长 / 轨 / 顶层 box 顺序
      remux-faststart --no-faststart <输入> <输出.mp4>   只给测试用：故意写成 moov 在后
    """)
    exit(2)
}
