import Foundation
import AVFoundation
import CoreGraphics

struct CompositionResult {
    let asset: AVAsset
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
}

/// Builds playback and export from the same timeline, without changing any source file.
enum CompositionBuilder {
    static func build(_ project: FilmProject) async throws -> CompositionResult {
        try await background { try await assemble(project) }
    }

    static func inspectAudio(_ url: URL) async throws -> Double {
        try await background {
            try checkFile(url, title: url.lastPathComponent)
            let asset = AVURLAsset(url: url)
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw CompositionError.message("《\(url.lastPathComponent)》没有可读取的音轨。")
            }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                throw CompositionError.message("无法读取《\(url.lastPathComponent)》的音频时长。")
            }
            try Task.checkCancellation()
            return duration.seconds
        }
    }

    static func export(_ project: FilmProject, to destination: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try await background {
            guard destination.isFileURL, destination.pathExtension.lowercased() == "mp4" else {
                throw CompositionError.message("请选择本地 .mp4 文件作为导出位置。")
            }
            let sourceURLs = project.videoClips.map { URL(fileURLWithPath: $0.sourcePath) }
                + project.music.map { URL(fileURLWithPath: $0.sourcePath) }
            guard !sourceURLs.contains(where: { sameFile($0, destination) }) else {
                throw CompositionError.message("导出位置与源素材相同。请换一个文件名，避免覆盖原始视频或音乐。")
            }
            progress(0)
            let result = try await assemble(project)
            try Task.checkCancellation()
            let preferred = [AVAssetExportPreset1920x1080, AVAssetExportPresetHighestQuality]
            var selectedPreset: String?
            for preset in preferred {
                if await AVAssetExportSession.compatibility(ofExportPreset: preset, with: result.asset, outputFileType: .mp4) {
                    selectedPreset = preset
                    break
                }
                try Task.checkCancellation()
            }
            guard let preset = selectedPreset,
                  let session = AVAssetExportSession(asset: result.asset, presetName: preset) else {
                throw CompositionError.message("这组素材暂时无法导出为兼容的 MP4 视频，请检查素材格式。")
            }
            guard session.supportedFileTypes.contains(.mp4) else {
                throw CompositionError.message("系统不支持将这组素材导出为 MP4。")
            }
            let directory = destination.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw CompositionError.message("导出文件夹不存在，请重新选择保存位置。")
            }
            let temporary = directory.appendingPathComponent(".jingdu-export-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temporary) }
            session.outputURL = temporary
            session.outputFileType = .mp4
            session.videoComposition = result.videoComposition
            session.audioMix = result.audioMix
            session.shouldOptimizeForNetworkUse = true
            let duration = try await result.asset.load(.duration)
            session.timeRange = CMTimeRange(start: .zero, duration: duration)
            let control = ExportControl(session)
            progress(0.03)
            let reporter = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    progress(0.03 + min(1, max(0, control.progress)) * 0.95)
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }
            defer { reporter.cancel() }
            try await withTaskCancellationHandler {
                try await control.run()
            } onCancel: {
                control.cancel()
            }
            reporter.cancel()
            await reporter.value
            try Task.checkCancellation()
            if session.status == .cancelled { throw CancellationError() }
            guard session.status == .completed else {
                throw CompositionError.underlying("视频导出失败", session.error)
            }
            // Recheck immediately before the only operation that can replace the destination.
            guard !sourceURLs.contains(where: { sameFile($0, destination) }) else {
                throw CompositionError.message("保存位置现在指向源素材，已停止替换。请换一个文件名。")
            }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            progress(1)
        }
    }

    private struct SourceVideo {
        let title: String
        let asset: AVURLAsset
        let track: AVAssetTrack
        let audio: AVAssetTrack?
        let selection: CMTimeRange
        let trackRange: CMTimeRange
        let transform: CGAffineTransform
        let bounds: CGRect
        let nominalFrameRate: Double
    }

    private static func assemble(_ project: FilmProject) async throws -> CompositionResult {
        try Task.checkCancellation()
        let placements = project.clipPlacements
        guard !placements.isEmpty else { throw CompositionError.message("请先添加至少一段视频素材。") }
        var sources: [SourceVideo] = []
        for placement in placements {
            try Task.checkCancellation()
            let clip = placement.clip
            let url = URL(fileURLWithPath: clip.sourcePath)
            try checkFile(url, title: clip.title)
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw CompositionError.message("《\(clip.title)》没有可读取的视频画面。")
            }
            let duration = try await asset.load(.duration)
            let selection = try selectedRange(clip.sourceIn, clip.sourceOut, duration: duration, title: clip.title)
            let trackRange = try await video.load(.timeRange)
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw CompositionError.message("无法读取《\(clip.title)》的画面尺寸或旋转信息。")
            }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let rate = Double(try await video.load(.nominalFrameRate))
            sources.append(SourceVideo(title: clip.title, asset: asset, track: video, audio: audio,
                                       selection: selection, trackRange: trackRange, transform: transform,
                                       bounds: bounds, nominalFrameRate: rate))
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.message("无法创建视频时间轴。")
        }
        videoTrack.naturalTimeScale = 600_000
        let first = sources[0].bounds
        let downscale = min(1, 1920 / max(first.width, first.height))
        let canvas = CGSize(width: max(2, (first.width * downscale / 2).rounded() * 2),
                            height: max(2, (first.height * downscale / 2).rounded() * 2))
        var originalTrack: AVMutableCompositionTrack?
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            guard placements[index].start.isFinite, abs(placements[index].start - cursor.seconds) < 0.001 else {
                throw CompositionError.message("视频片段的时间轴不连续，请重新排列片段后再试。")
            }
            let overlap = CMTimeRangeGetIntersection(source.selection, otherRange: source.trackRange)
            guard overlap.isValid, overlap.duration.isNumeric, CMTimeCompare(overlap.duration, .zero) > 0 else {
                throw CompositionError.message("《\(source.title)》选中的范围没有视频画面。")
            }
            let leading = CMTimeSubtract(overlap.start, source.selection.start)
            let trailing = CMTimeSubtract(source.selection.end, overlap.end)
            if CMTimeCompare(leading, .zero) > 0 {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: leading))
            }
            try videoTrack.insertTimeRange(overlap, of: source.track, at: CMTimeAdd(cursor, leading))
            if CMTimeCompare(trailing, .zero) > 0 {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: CMTimeAdd(cursor, CMTimeAdd(leading, overlap.duration)), duration: trailing))
            }
            if let audio = source.audio {
                if originalTrack == nil {
                    originalTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    originalTrack?.naturalTimeScale = 600_000
                }
                guard let destination = originalTrack else { throw CompositionError.message("无法创建原声音轨。") }
                try await insertAudio(audio, selection: source.selection, into: destination, at: cursor)
            }
            let fit = min(canvas.width / source.bounds.width, canvas.height / source.bounds.height)
            let x = (canvas.width - source.bounds.width * fit) / 2
            let y = (canvas.height - source.bounds.height * fit) / 2
            let transform = source.transform
                .concatenating(CGAffineTransform(translationX: -source.bounds.minX, y: -source.bounds.minY))
                .concatenating(CGAffineTransform(scaleX: fit, y: fit))
                .concatenating(CGAffineTransform(translationX: x, y: y))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(transform, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: source.selection.duration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = CMTimeAdd(cursor, source.selection.duration)
        }

        var parameters: [AVAudioMixInputParameters] = []
        if let originalTrack {
            let input = AVMutableAudioMixInputParameters(track: originalTrack)
            input.setVolume(try volume(project.originalVolume), at: .zero)
            parameters.append(input)
        }
        for music in project.music {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: music.sourcePath)
            try checkFile(url, title: music.title)
            let asset = AVURLAsset(url: url)
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
                throw CompositionError.message("音乐《\(music.title)》没有可读取的音轨。")
            }
            let duration = try await asset.load(.duration)
            var selection = try selectedRange(music.sourceIn, music.sourceOut, duration: duration, title: music.title)
            guard music.timelineStart.isFinite, music.timelineStart >= 0, music.timelineStart < cursor.seconds else {
                throw CompositionError.message("音乐《\(music.title)》的起点超出作品时长，请先调整位置。")
            }
            let start = CMTime(seconds: music.timelineStart, preferredTimescale: 600_000)
            let remaining = CMTimeSubtract(cursor, start)
            if CMTimeCompare(selection.duration, remaining) > 0 {
                selection.duration = remaining
            }
            guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CompositionError.message("无法创建音乐音轨。")
            }
            destination.naturalTimeScale = 600_000
            try await insertAudio(audio, selection: selection, into: destination, at: start)
            let input = AVMutableAudioMixInputParameters(track: destination)
            input.setVolume(try volume(music.volume), at: .zero)
            parameters.append(input)
        }

        // Keep CMTime values throughout. The composition track may quantize edits to its
        // own time scale; its actual final duration is the authoritative instruction end.
        let actualDuration = try await composition.load(.duration)
        guard actualDuration.isNumeric, CMTimeCompare(actualDuration, .zero) > 0,
              let last = instructions.last, CMTimeCompare(actualDuration, last.timeRange.start) > 0 else {
            throw CompositionError.message("无法生成有效的视频时间轴。")
        }
        last.timeRange = CMTimeRange(start: last.timeRange.start, duration: CMTimeSubtract(actualDuration, last.timeRange.start))
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        let rate = sources.map(\.nominalFrameRate).filter { $0.isFinite && $0 >= 1 }.max() ?? 30
        videoComposition.frameDuration = CMTime(seconds: 1 / min(60, rate), preferredTimescale: 60_000)
        videoComposition.instructions = instructions
        let valid = try await videoComposition.isValid(for: composition,
                                                       timeRange: CMTimeRange(start: .zero, duration: actualDuration),
                                                       validationDelegate: nil)
        guard valid else { throw CompositionError.message("视频时间轴校验未通过，请检查片段的入点与出点。") }
        try Task.checkCancellation()
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        return CompositionResult(asset: composition, videoComposition: videoComposition,
                                 audioMix: parameters.isEmpty ? nil : audioMix)
    }

    private static func insertAudio(_ source: AVAssetTrack, selection: CMTimeRange,
                                    into destination: AVMutableCompositionTrack, at start: CMTime) async throws {
        let available = try await source.load(.timeRange)
        let overlap = CMTimeRangeGetIntersection(selection, otherRange: available)
        guard overlap.isValid, overlap.duration.isNumeric, CMTimeCompare(overlap.duration, .zero) > 0 else { return }
        let offset = CMTimeSubtract(overlap.start, selection.start)
        try destination.insertTimeRange(overlap, of: source, at: CMTimeAdd(start, offset))
    }

    private static func selectedRange(_ sourceIn: Double, _ sourceOut: Double, duration: CMTime, title: String) throws -> CMTimeRange {
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
              sourceIn.isFinite, sourceOut.isFinite, sourceIn >= 0, sourceOut > sourceIn,
              sourceOut <= duration.seconds + 0.000_01, sourceIn < duration.seconds,
              sourceOut < Double(Int64.max) / 600_000 else {
            throw CompositionError.message("《\(title)》的入点或出点超出实际素材时长，文件可能已经发生变化。")
        }
        let start = sourceIn == 0 ? CMTime.zero : CMTime(seconds: sourceIn, preferredTimescale: 600_000)
        let end = abs(sourceOut - duration.seconds) <= 0.000_01
            ? duration : CMTime(seconds: sourceOut, preferredTimescale: 600_000)
        guard CMTimeCompare(end, start) > 0 else { throw CompositionError.message("《\(title)》选中的片段太短。") }
        return CMTimeRange(start: start, end: end)
    }

    private static func volume(_ value: Double) throws -> Float {
        guard value.isFinite else { throw CompositionError.message("音量设置无效，请重新调整音量。") }
        return Float(min(1, max(0, value)))
    }

    private static func checkFile(_ url: URL, title: String) throws {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
            throw CompositionError.message("找不到或无法读取素材《\(title)》。请确认文件仍在原位置：\(url.path)")
        }
    }

    private static func sameFile(_ left: URL, _ right: URL) -> Bool {
        let a = left.standardizedFileURL.resolvingSymlinksInPath()
        let b = right.standardizedFileURL.resolvingSymlinksInPath()
        if a.path.caseInsensitiveCompare(b.path) == .orderedSame { return true }
        guard let first = try? FileManager.default.attributesOfItem(atPath: a.path),
              let second = try? FileManager.default.attributesOfItem(atPath: b.path),
              let firstNode = first[.systemFileNumber] as? NSNumber,
              let secondNode = second[.systemFileNumber] as? NSNumber,
              let firstVolume = first[.systemNumber] as? NSNumber,
              let secondVolume = second[.systemNumber] as? NSNumber else { return false }
        return firstNode == secondNode && firstVolume == secondVolume
    }

    /// AVFoundation permits observing progress and cancelling an active export from
    /// another queue. Keep that narrow cross-task access separate from configuration.
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
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Starting and cancellation must be serialized. Cancelling an idle
                // AVAssetExportSession and subsequently starting it raises an Obj-C exception.
                started = true
                session.exportAsynchronously { continuation.resume(returning: ()) }
                lock.unlock()
            }
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let shouldCancelSession = started
            lock.unlock()
            if shouldCancelSession { session.cancelExport() }
        }
    }

    private static func background<Value>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await task.value
            } onCancel: { task.cancel() }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CompositionError {
            throw error
        } catch {
            throw CompositionError.underlying("素材处理失败", error)
        }
    }

    private enum CompositionError: LocalizedError {
        case message(String)
        case underlying(String, Error?)
        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            case let .underlying(action, error):
                return "\(action)。\(error.map { " \($0.localizedDescription)" } ?? "请检查素材格式和保存位置。")"
            }
        }
    }
}
