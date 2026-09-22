import AppKit
import AVFoundation
import AudioToolbox
import CoreVideo

struct MediaInfo {
    let duration: Double
    let frameRate: Double
    let width: Int
    let height: Int
    let hasAudio: Bool
}

/// All decoding runs on a detached task. No frames or PCM buffers are retained across the video.
enum MediaAnalyzer {
    static func inspect(_ url: URL) async throws -> MediaInfo {
        try await background {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw AnalysisError.invalidDuration }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw AnalysisError.noVideo }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = CGRect(origin: .zero, size: size).applying(transform)
            guard transformed.width.isFinite, transformed.height.isFinite,
                  abs(transformed.width) > 0, abs(transformed.height) > 0 else {
                throw AnalysisError.invalidDuration
            }
            let frameRate = Double(try await track.load(.nominalFrameRate))
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            try Task.checkCancellation()
            return MediaInfo(duration: duration, frameRate: frameRate > 0 ? frameRate : 30,
                             width: Int(abs(transformed.width).rounded()),
                             height: Int(abs(transformed.height).rounded()), hasAudio: !audioTracks.isEmpty)
        }
    }

    static func thumbnail(_ url: URL, at seconds: Double, width: CGFloat = 320, exact: Bool = false) async -> NSImage? {
        try? await background {
            try Task.checkCancellation()
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            let safeWidth = width.isFinite ? min(4096, max(32, width)) : 320
            generator.maximumSize = CGSize(width: safeWidth, height: safeWidth)
            let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.06, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let safeTime = seconds.isFinite ? max(0, seconds) : 0
            let frame = try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: safeTime, preferredTimescale: 600))
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
            try Task.checkCancellation()
            return NSImage(cgImage: frame.image, size: .zero)
        }
    }

    /// Per-bin, linear PCM root-mean-square amplitude in 0...1. Silence is zero.
    /// Uses timestamps, so an audio track starting late remains aligned with the picture.
    static func waveform(_ url: URL, bins: Int = 320) async throws -> [Double] {
        try await background {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw AnalysisError.invalidDuration }
            let count = min(20_000, max(1, bins))
            var squares = [Double](repeating: 0, count: count)
            var sampleCounts = [Int](repeating: 0, count: count)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw AnalysisError.audioDecode }
            reader.add(output)
            try Task.checkCancellation()
            guard reader.startReading() else { throw AnalysisError.reader("音频", reader.error) }
            defer { reader.cancelReading() }

            while true {
                try Task.checkCancellation()
                let hasSample = try autoreleasepool { () throws -> Bool in
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    guard let description = CMSampleBufferGetFormatDescription(sample),
                          let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                          let block = CMSampleBufferGetDataBuffer(sample) else { return true }
                    let sampleRate = format.pointee.mSampleRate
                    let channels = Int(format.pointee.mChannelsPerFrame)
                    guard sampleRate > 0, channels > 0,
                          format.pointee.mBitsPerChannel == 32,
                          format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                        throw AnalysisError.audioDecode
                    }
                    let byteCount = CMBlockBufferGetDataLength(block)
                    let floatCount = byteCount / MemoryLayout<Float>.size
                    guard floatCount > 0 else { return true }
                    var pcm = [Float](repeating: 0, count: floatCount)
                    let status = pcm.withUnsafeMutableBytes {
                        CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                                   dataLength: floatCount * MemoryLayout<Float>.size,
                                                   destination: $0.baseAddress!)
                    }
                    guard status == kCMBlockBufferNoErr else { throw AnalysisError.audioDecode }
                    let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard start.isFinite else { return true }
                    for frame in 0..<(floatCount / channels) {
                        if frame % 4096 == 0 { try Task.checkCancellation() }
                        let position = (start + Double(frame) / sampleRate) / duration
                        guard position >= 0, position < 1 else { continue }
                        let bin = min(count - 1, Int(position * Double(count)))
                        for channel in 0..<channels {
                            let value = Double(pcm[frame * channels + channel])
                            if value.isFinite {
                                squares[bin] += value * value
                                sampleCounts[bin] += 1
                            }
                        }
                    }
                    return true
                }
                if !hasSample { break }
            }
            try Task.checkCancellation()
            if reader.status == .failed { throw AnalysisError.reader("音频", reader.error) }
            return zip(squares, sampleCounts).map { sum, count in
                count == 0 ? 0 : min(1, sqrt(sum / Double(count)))
            }
        }
    }

    /// Local visual cut proposals. Higher sensitivity values mean a stricter difference threshold.
    /// At most about 3,600 downscaled frames are sampled, normally eight per second.
    static func detectCuts(_ url: URL, sensitivity: Double = 0.32,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Double] {
        try await background {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw AnalysisError.noVideo
            }
            let assetDuration = try await asset.load(.duration)
            let duration = assetDuration.seconds
            let naturalSize = try await track.load(.naturalSize)
            guard duration.isFinite, duration > 0,
                  naturalSize.width > 0, naturalSize.height > 0 else { throw AnalysisError.invalidDuration }
            let threshold = sensitivity.isFinite ? min(0.95, max(0.06, sensitivity)) : 0.32
            let interval = max(0.125, duration / 3_600)
            let renderWidth: CGFloat = 96
            let renderHeight = max(2, (renderWidth * naturalSize.height / naturalSize.width / 2).rounded() * 2)
            // Video composition performs downscaling and frame-rate conversion before samples reach us.
            // Orientation does not affect frame-to-frame differences; preserving source axes avoids cropping.
            let composition = AVMutableVideoComposition()
            composition.renderSize = CGSize(width: renderWidth, height: min(384, renderHeight))
            composition.frameDuration = CMTime(seconds: interval, preferredTimescale: 60_000)
            let instruction = AVMutableVideoCompositionInstruction()
            // Preserve the exact asset timebase. Rounding down to 1/600 second leaves
            // an uncovered tail, which AVFoundation rejects with invalidVideoComposition (-11841).
            instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(CGAffineTransform(scaleX: composition.renderSize.width / naturalSize.width,
                                                y: composition.renderSize.height / naturalSize.height), at: .zero)
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
                                                            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                                                                kCVPixelFormatType_32BGRA])
            output.videoComposition = composition
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw AnalysisError.videoDecode }
            reader.add(output)
            try Task.checkCancellation()
            guard reader.startReading() else { throw AnalysisError.reader("视频", reader.error) }
            defer { reader.cancelReading() }
            progress(0)

            var previous: Signature?
            var pending: (time: Double, strength: Double, before: Signature)?
            var candidates: [(time: Double, strength: Double)] = []
            var baseline = 0.03
            var lastProgress = -1.0
            var sampledFrames = 0

            func appendCandidate(_ time: Double, _ strength: Double) {
                guard time >= 0.15, time <= duration - 0.15 else { return }
                if let last = candidates.last, time - last.time < 0.3 {
                    if strength > last.strength { candidates[candidates.count - 1] = (time, strength) }
                } else {
                    candidates.append((time, strength))
                }
            }

            while sampledFrames < 3_610 {
                try Task.checkCancellation()
                let decoded = try autoreleasepool { () throws -> (Double, Signature)? in
                    try Task.checkCancellation()
                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { throw AnalysisError.videoDecode }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    return (time, try Signature(pixelBuffer))
                }
                guard let (time, signature) = decoded else { break }
                sampledFrames += 1
                guard time.isFinite else { continue }
                var flashReturned = false
                if let waiting = pending {
                    // Discard a one-sample flash when the picture immediately returns to its old appearance.
                    flashReturned = signature.distance(to: waiting.before) < 0.08
                    if !flashReturned { appendCandidate(waiting.time, waiting.strength) }
                    pending = nil
                }
                if let previous {
                    let strength = signature.distance(to: previous)
                    if !flashReturned, strength >= threshold,
                       strength > baseline * 1.65 || strength > 0.72 {
                        pending = (time, strength, previous)
                    }
                    baseline = 0.88 * baseline + 0.12 * min(strength, 0.5)
                }
                previous = signature
                let fraction = min(0.99, max(0, time / duration))
                if fraction - lastProgress >= 0.01 {
                    progress(fraction)
                    lastProgress = fraction
                }
            }
            try Task.checkCancellation()
            if reader.status == .failed { throw AnalysisError.reader("视频", reader.error) }
            if let waiting = pending { appendCandidate(waiting.time, waiting.strength) }
            progress(1)
            return candidates.map(\.time)
        }
    }

    private struct Signature {
        let pixels: [UInt8]
        let histogram: [Double]

        init(_ buffer: CVPixelBuffer) throws {
            let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
            guard status == kCVReturnSuccess else { throw AnalysisError.videoDecode }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AnalysisError.videoDecode }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            guard width > 0, height > 0 else { throw AnalysisError.videoDecode }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let columns = 32, rows = 18
            var pixels = [UInt8]()
            pixels.reserveCapacity(columns * rows * 3)
            var histogram = [Double](repeating: 0, count: 48)
            for y in 0..<rows {
                let sourceY = min(height - 1, (y * height + height / 2) / rows)
                for x in 0..<columns {
                    let sourceX = min(width - 1, (x * width + width / 2) / columns)
                    let offset = sourceY * rowBytes + sourceX * 4
                    for channel in 0..<3 {
                        let value = bytes[offset + channel]
                        pixels.append(value)
                        histogram[channel * 16 + Int(value) / 16] += 1 / Double(columns * rows)
                    }
                }
            }
            self.pixels = pixels
            self.histogram = histogram
        }

        func distance(to other: Signature) -> Double {
            var pixelDifference = 0.0
            for index in pixels.indices {
                pixelDifference += Double(abs(Int(pixels[index]) - Int(other.pixels[index])))
            }
            pixelDifference /= Double(pixels.count) * 255
            var histogramDifference = 0.0
            for index in histogram.indices {
                histogramDifference += abs(histogram[index] - other.histogram[index])
            }
            histogramDifference /= 6
            return min(1, 1.7 * (pixelDifference * 0.7 + histogramDifference * 0.3))
        }
    }

    private static func background<Value>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AnalysisError {
            throw error
        } catch {
            throw AnalysisError.reader("媒体", error)
        }
    }

    private enum AnalysisError: LocalizedError {
        case noVideo, invalidDuration, audioDecode, videoDecode
        case reader(String, Error?)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "这个文件没有可读取的视频画面。"
            case .invalidDuration: return "无法读取视频时长或画面尺寸，请尝试其他视频文件。"
            case .audioDecode: return "无法解码这段视频的音频。"
            case .videoDecode: return "无法解码这段视频的画面。"
            case let .reader(kind, underlying):
                return "\(kind)分析失败。\(underlying.map { " \($0.localizedDescription)" } ?? "请检查文件是否完整。")"
            }
        }
    }
}
