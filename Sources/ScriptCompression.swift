import Foundation
import AVFoundation

/// Upload-only encoding. Playback, source files, composition instructions and
/// audio-mix values are left untouched. Base64 expands 11 MB to about 14.67 MB.
enum ScriptCompression {
    static let maximumByteCount = 11_000_000
    static let targetByteCount = 10_500_000
    static let maximumFrameRate = 15.0

    /// Long analyses reserve more of the fixed upload budget for each frame.
    /// Source playback retains its original cadence in the main workstation.
    static func frameRateLimit(for duration: Double) -> Double { duration > 90 ? 6 : maximumFrameRate }

    struct Result {
        let byteCount: Int
        let duration: Double
        let hasAudio: Bool
        let frameRate: Double
        let width: Int
        let height: Int
    }

    /// The destination must be a new local MP4. An unsuccessful attempt removes
    /// its partial output; only a fully validated result is left for the caller.
    static func export(asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?,
                       timeRange: CMTimeRange, outputURL: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        try Task.checkCancellation()
        guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == "mp4",
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CompressionError.message("分析副本必须保存到新的临时 MP4，不能覆盖已有文件。")
        }
        guard timeRange.isValid, timeRange.start.isNumeric, timeRange.duration.isNumeric,
              timeRange.start.seconds.isFinite, timeRange.start.seconds >= 0,
              timeRange.duration.seconds.isFinite, timeRange.duration.seconds > 0 else {
            throw CompressionError.message("分析视频的时间范围无效。")
        }
        let assetDuration = try await asset.load(.duration)
        guard assetDuration.isNumeric, assetDuration.seconds.isFinite,
              timeRange.end.seconds <= assetDuration.seconds + 0.000_01 else {
            throw CompressionError.message("分析范围超出视频实际时长。")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw CompressionError.message("分析视频没有可读取的画面。") }
        let original: AVVideoComposition
        if let videoComposition { original = videoComposition }
        else { original = try await AVVideoComposition.videoComposition(withPropertiesOf: asset) }
        guard let uploadComposition = original.mutableCopy() as? AVMutableVideoComposition else {
            throw CompressionError.message("无法创建分析视频的画面副本。")
        }
        // ExpectedSourceFrameRate is only an encoder hint. frameDuration and an
        // invalid source timing track actually cap rendered frames without speedup.
        let frameRateLimit = frameRateLimit(for: timeRange.duration.seconds)
        let minimumFrameDuration = CMTime(seconds: 1 / frameRateLimit, preferredTimescale: 600_000)
        let sourceFrameDuration = uploadComposition.frameDuration
        uploadComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        uploadComposition.frameDuration = sourceFrameDuration.isNumeric && CMTimeCompare(sourceFrameDuration, .zero) > 0
            ? CMTimeMaximum(sourceFrameDuration, minimumFrameDuration) : minimumFrameDuration
        let sourceSize = uploadComposition.renderSize
        guard sourceSize.width.isFinite, sourceSize.height.isFinite, sourceSize.width > 0, sourceSize.height > 0 else {
            throw CompressionError.message("分析视频的画面尺寸无效。")
        }

        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: outputURL) } }
        let presets = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPreset640x480]
        let boundaries = [0.0, 0.72, 0.87, 0.98]
        var lastFailure: Error?
        var rejectedSizeOrDuration = false
        progress(0)
        for (index, preset) in presets.enumerated() {
            try Task.checkCancellation()
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4),
                  let session = AVAssetExportSession(asset: asset, presetName: preset),
                  session.supportedFileTypes.contains(.mp4) else { continue }
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: outputURL)
            session.outputURL = outputURL; session.outputFileType = .mp4
            session.videoComposition = uploadComposition; session.audioMix = audioMix
            session.timeRange = timeRange; session.shouldOptimizeForNetworkUse = true
            // Apple documents this as approximate. Inspect actual bytes and full
            // duration below; an oversized or shortened file is never returned.
            session.fileLengthLimit = Int64(targetByteCount)
            let lower = boundaries[index], upper = boundaries[index + 1]
            progress(lower)
            do {
                try await run(session, lower: lower, upper: upper, progress: progress)
                try Task.checkCancellation()
                let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= maximumByteCount else {
                    rejectedSizeOrDuration = true
                    continue
                }
                let output = AVURLAsset(url: outputURL)
                let duration = try await output.load(.duration)
                guard let track = try await output.loadTracks(withMediaType: .video).first else {
                    throw CompressionError.message("压缩后的分析视频缺少画面。")
                }
                let frameRate = Double(try await track.load(.nominalFrameRate))
                guard frameRate.isFinite, frameRate > 0, frameRate <= frameRateLimit + 0.01 else {
                    throw CompressionError.message("系统未能正确生成分析视频的帧率。")
                }
                let tolerance = max(0.05, 1 / max(1, frameRate))
                guard duration.isNumeric, duration.seconds.isFinite,
                      abs(duration.seconds - timeRange.duration.seconds) <= tolerance else {
                    rejectedSizeOrDuration = true
                    continue
                }
                let dimensions = try await track.load(.naturalSize)
                guard max(dimensions.width, dimensions.height) <= 1280,
                      min(dimensions.width, dimensions.height) <= 720,
                      dimensions.width <= sourceSize.width + 2, dimensions.height <= sourceSize.height + 2 else {
                    throw CompressionError.message("系统未能按原比例缩小分析视频。")
                }
                let formats = try await track.load(.formatDescriptions)
                guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
                    throw CompressionError.message("系统未能生成兼容的 H.264 分析视频。")
                }
                let hasAudio = !(try await output.loadTracks(withMediaType: .audio)).isEmpty
                let result = Result(byteCount: size, duration: duration.seconds, hasAudio: hasAudio,
                                    frameRate: frameRate, width: Int(dimensions.width), height: Int(dimensions.height))
                try Task.checkCancellation()
                progress(1)
                try Task.checkCancellation()
                retained = true
                return result
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); lastFailure = error }
        }
        if rejectedSizeOrDuration {
            throw CompressionError.message("分析副本无法在 11 MB 内保留完整视频，请缩短选段后重试。")
        }
        if let lastFailure { throw lastFailure }
        throw CompressionError.message("这组素材暂时无法压缩成分析视频。")
    }

    private static func run(_ session: AVAssetExportSession, lower: Double, upper: Double,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let control = ExportControl(session)
        let reporter = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(lower + min(1, max(0, control.progress)) * (upper - lower))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        do {
            try await withTaskCancellationHandler { try await control.run() } onCancel: { control.cancel() }
        } catch {
            reporter.cancel(); await reporter.value
            throw error
        }
        reporter.cancel(); await reporter.value
        try Task.checkCancellation()
        if session.status == .cancelled { throw CancellationError() }
        guard session.status == .completed else {
            throw CompressionError.message("分析视频压缩失败。\(session.error.map { "\n\($0.localizedDescription)" } ?? "")")
        }
    }

    private final class ExportControl: @unchecked Sendable {
        private let session: AVAssetExportSession
        private let lock = NSLock()
        private var started = false
        private var cancelled = false
        init(_ session: AVAssetExportSession) { self.session = session }
        var progress: Double { Double(session.progress) }
        func run() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelled else {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                started = true
                session.exportAsynchronously { continuation.resume(returning: ()) }
                lock.unlock()
            }
        }
        func cancel() {
            lock.lock(); cancelled = true
            let shouldCancel = started
            lock.unlock()
            if shouldCancel { session.cancelExport() }
        }
    }

    private enum CompressionError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
