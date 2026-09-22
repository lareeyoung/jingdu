import Foundation
import AVFoundation

/// A disposable copy of the selected timeline. The caller owns cleanup after a
/// successful preparation; failed and cancelled preparations clean themselves up.
struct PreparedScriptMedia {
    let videoURL: URL
    let byteCount: Int
    let duration: Double
    let hasAudio: Bool

    fileprivate init(videoURL: URL, byteCount: Int, duration: Double, hasAudio: Bool) {
        self.videoURL = videoURL
        self.byteCount = byteCount
        self.duration = duration
        self.hasAudio = hasAudio
    }

    /// Idempotent, and removes only the unique directory made for this preparation.
    func cleanup() {
        try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent())
    }
}

enum ScriptMediaPreparer {
    static let maximumDuration: Double = 300
    // Keep the uploaded video small enough for the relay request-body deadline.
    static let maximumByteCount = ScriptCompression.maximumByteCount

    static func prepare(_ project: FilmProject, rangeStart: Double, rangeEnd: Double,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedScriptMedia {
        let worker = Task.detached(priority: .userInitiated) {
            try await prepareInBackground(project, rangeStart: rangeStart, rangeEnd: rangeEnd, progress: progress)
        }
        return try await withTaskCancellationHandler {
            let media = try await worker.value
            do {
                try Task.checkCancellation()
                return media
            } catch {
                media.cleanup()
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }

    private static func prepareInBackground(_ project: FilmProject, rangeStart: Double, rangeEnd: Double,
                                            progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedScriptMedia {
        try Task.checkCancellation()
        guard rangeStart.isFinite, rangeEnd.isFinite, rangeStart >= 0, rangeEnd > rangeStart,
              rangeEnd < Double(Int64.max) / 600_000 else {
            throw PreparationError.message("分析范围无效。请在时间轴上选择一段有时长的视频。")
        }
        guard rangeEnd - rangeStart <= maximumDuration + 0.000_01 else {
            throw PreparationError.message("一次最多反解 5 分钟视频，请缩短选中的范围后重试。")
        }
        progress(0)
        let built = try await CompositionBuilder.build(project)
        try Task.checkCancellation()
        let exactDuration = try await built.asset.load(.duration)
        guard exactDuration.isNumeric, exactDuration.seconds.isFinite, exactDuration.seconds > 0,
              rangeStart < exactDuration.seconds, rangeEnd <= exactDuration.seconds + 0.000_01 else {
            throw PreparationError.message("分析范围超出了作品的实际时长，请重新选择范围。")
        }
        let start = rangeStart == 0 ? CMTime.zero : CMTime(seconds: rangeStart, preferredTimescale: 600_000)
        // Preserve the original endpoint, including a fractional audio tail. Rebuilding
        // this CMTime at a coarse scale can leave an uncovered end and cause -11841.
        let end = abs(rangeEnd - exactDuration.seconds) <= 0.000_01
            ? exactDuration : CMTime(seconds: rangeEnd, preferredTimescale: 600_000)
        let selection = CMTimeRange(start: start, end: end)
        guard CMTimeCompare(selection.duration, .zero) > 0 else {
            throw PreparationError.message("选中的范围太短，请至少保留一帧画面。")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jingdu-script-\(UUID().uuidString)", isDirectory: true)
        var keepResult = false
        defer { if !keepResult { try? FileManager.default.removeItem(at: directory) } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("selected-video.mp4")
            progress(0.04)
            try Task.checkCancellation()
            let compressed = try await ScriptCompression.export(asset: built.asset,
                videoComposition: built.videoComposition, audioMix: built.audioMix,
                timeRange: selection, outputURL: url) { value in progress(0.04 + value * 0.94) }
            try Task.checkCancellation()
            let result = PreparedScriptMedia(videoURL: url, byteCount: compressed.byteCount,
                duration: compressed.duration, hasAudio: compressed.hasAudio)
            progress(1)
            try Task.checkCancellation()
            keepResult = true
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PreparationError {
            throw error
        } catch {
            throw PreparationError.message("准备分析视频失败。请检查素材是否可读、临时磁盘空间是否足够，或缩短所选范围。\n\(error.localizedDescription)")
        }
    }

    private enum PreparationError: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case let .message(text): return text } }
    }
}
