import Foundation
import AVFoundation
import CryptoKit
import Darwin

/// Offline, source-audio-only transcription. No network request is made at runtime.
enum SubtitleTranscriber {
    static let maximumDuration: Double = 30 * 60
    static let modelSHA1 = "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
    static let modelDefaultsKey = "subtitleModelPath"
    static var defaultModelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jingdu/SubtitleModels/ggml-small.bin")
    }
    static var modelURL: URL {
        if let path = UserDefaults.standard.string(forKey: modelDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return defaultModelURL
    }
    static var executableURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("SubtitleEngine/whisper-cli")
    }
    static var isAvailable: Bool {
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }
        return (try? validateModelHeader(modelURL)) != nil
    }
    static var availabilityMessage: String {
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return "本地字幕引擎尚未安装，请重新安装包含字幕引擎的镜读版本。"
        }
        do { try validateModelHeader(modelURL); return "本地字幕引擎已就绪，音频在本机识别。" }
        catch { return "请选择官方多语言 ggml-small.bin 模型，文件约 466 MB。" }
    }
    static func selectModelURL(_ url: URL) throws {
        try validateModelHeader(url)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = Insecure.SHA1()
        while let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == modelSHA1 else { throw Failure.message("模型校验失败。请选择完整的官方多语言 ggml-small.bin，不能使用英文专用或改名文件。") }
        UserDefaults.standard.set(url.path, forKey: modelDefaultsKey)
    }
    private static func validateModelHeader(_ url: URL) throws {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw Failure.message("本地字幕模型不存在或无法读取。")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let length = attributes[.size] as? NSNumber, length.int64Value == 487601967 else {
            throw Failure.message("字幕模型不完整，请选择官方多语言 ggml-small.bin。")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 48) ?? Data()
        func integer(_ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        guard data.count == 48, integer(0) == 0x67676d6c, integer(4) == 51865,
              integer(12) == 768, integer(20) == 12 else {
            throw Failure.message("所选文件不是受支持的 Whisper 多语言 small 模型。")
        }
    }

    static func transcribe(project: FilmProject, language: SubtitleLanguage?,
                           progress: @escaping @Sendable (Double, String) -> Void) async throws -> [SubtitleCue] {
        let worker = Task.detached(priority: .userInitiated) {
            try await perform(project: project, language: language, progress: progress)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func perform(project: FilmProject, language: SubtitleLanguage?,
                                progress: @escaping @Sendable (Double, String) -> Void) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        guard project.duration.isFinite, project.duration > 0, project.duration <= maximumDuration else {
            throw Failure.message("本次字幕识别支持 30 分钟以内的视频，请先截取需要识别的片段。")
        }
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw Failure.message(availabilityMessage)
        }
        let selectedModel = modelURL
        try validateModelHeader(selectedModel)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jingdu-subtitles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        progress(0.01, "正在提取视频原声…")
        let audio = folder.appendingPathComponent("original.wav")
        try await extractAudio(project: project, to: audio)
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        try input.seek(toOffset: 44)
        let frameCount = Int((project.duration * 16_000).rounded())
        let chunkFrames = 30 * 16_000
        let chunkCount = (frameCount + chunkFrames - 1) / chunkFrames
        var cues: [SubtitleCue] = []
        var heardSignal = false
        for index in 0..<chunkCount {
            try Task.checkCancellation()
            let frames = min(chunkFrames, frameCount - index * chunkFrames)
            let pcm = try input.read(upToCount: frames * 2) ?? Data()
            guard pcm.count == frames * 2 else { throw Failure.message("提取的原声音频不完整，请重新生成字幕。") }
            let start = Double(index * chunkFrames) / 16_000
            // PCM ends on a sample boundary; the project's final boundary may
            // fall between samples and must remain the authoritative cue end.
            let duration = min(Double(frames) / 16_000, project.duration - start)
            progress(0.1 + 0.85 * Double(index) / Double(chunkCount), "正在识别原声 \(index + 1)/\(chunkCount)…")
            guard hasAudibleSignal(pcm) else { continue }
            heardSignal = true
            let chunk = folder.appendingPathComponent("chunk-\(index).wav")
            try (waveHeader(byteCount: pcm.count) + pcm).write(to: chunk)
            let output = folder.appendingPathComponent("chunk-\(index)")
            let log = folder.appendingPathComponent("chunk-\(index).log")
            let control = ChildProcess()
            // max_len enables experimental token timestamps and can split a
            // sentence into zero-length fragments. Keep the decoder's natural
            // segments; the subtitle views already wrap text to their width.
            let arguments = ["-m", selectedModel.path, "-f", chunk.path, "-l", language?.rawValue ?? "auto",
                             "-oj", "-of", output.path, "-t", "4", "-np"]
            try await withTaskCancellationHandler {
                try await control.run(executable: executableURL, arguments: arguments, log: log)
            } onCancel: { control.cancel() }
            try Task.checkCancellation()
            let data = try Data(contentsOf: output.appendingPathExtension("json"))
            let parsed = try parse(data: data, offset: start, duration: duration, requestedLanguage: language)
            for var cue in parsed {
                // Adding a window offset back can introduce another floating-point
                // rounding step, even after duration was bounded above.
                cue.end = min(cue.end, project.duration)
                if cue.end > cue.start { cues.append(cue) }
            }
            try? FileManager.default.removeItem(at: chunk)
        }
        try Task.checkCancellation()
        guard heardSignal else { throw Failure.noSpeech }
        guard !cues.isEmpty else { throw Failure.noSpeech }
        progress(1, "原文字幕识别完成")
        return cues
    }

    /// Whisper JSON offsets are milliseconds relative to each independently decoded WAV.
    static func parse(data: Data, offset: Double, duration: Double, requestedLanguage: SubtitleLanguage?) throws -> [SubtitleCue] {
        guard offset.isFinite, duration.isFinite, offset >= 0, duration > 0, duration <= 30,
              data.count <= 5_000_000 else {
            throw Failure.message("字幕引擎返回了无效的时间范围。")
        }
        let decoded: WhisperOutput
        do { decoded = try JSONDecoder().decode(WhisperOutput.self, from: data) }
        catch { throw Failure.message("字幕引擎返回的结果格式无效，请重新识别。") }
        guard let language = SubtitleLanguage(rawValue: decoded.result.language) else {
            throw Failure.message("检测到暂不支持的语种（\(decoded.result.language.prefix(16))）。目前支持中文、英语、日语、韩语、西班牙语和法语。")
        }
        if let requestedLanguage, requestedLanguage != language {
            throw Failure.message("字幕引擎返回的语种与指定语种不一致，请重新识别。")
        }
        guard decoded.transcription.count <= 2000 else { throw Failure.message("字幕条目数量异常，已停止导入。") }
        var previousStart = 0.0
        var result: [SubtitleCue] = []
        var pendingPoint: (time: Double, text: String)?
        let tolerance = 0.020_001
        let boundary = offset + duration
        func joined(_ first: String, _ second: String) throws -> String {
            let separator = language == .zh || language == .ja || second.first.map { ",.!?;:，。！？；：、…".contains($0) } == true ? "" : " "
            let text = first + separator + second
            guard text.count <= 5000 else { throw Failure.message("字幕合并后的文字过长，请重新识别。") }
            return text
        }
        for item in decoded.transcription {
            let start = item.offsets.from / 1000
            let end = item.offsets.to / 1000
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 5000, !text.contains("\u{0000}") else {
                throw Failure.message("字幕引擎返回了无效的字幕文字，请重新识别。")
            }
            // Non-speech markers have no useful display interval; in particular
            // a zero-duration blank must not invalidate the spoken sentences.
            guard !text.isEmpty, text != "[BLANK_AUDIO]", text != "[音楽]", text != "[Music]" else { continue }
            // Each decoder pass can predict up to 30 s after its internal seek,
            // even when the input ends sooner. E.g. a 30 s input can emit a tail
            // at 28.32–30.32. Intersect with real audio, rather than rejecting an
            // entire transcription at an artificial 30.02 s ceiling.
            guard start.isFinite, end.isFinite, start >= 0, end >= start,
                  end <= duration + 30 + tolerance, start + tolerance >= previousStart else {
                throw Failure.message("部分字幕的时间信息无效，请重新识别。")
            }
            previousStart = start
            guard start < duration else { continue } // Decoder padding contains no source audio.
            let absoluteStart = offset + start
            let absoluteEnd = min(offset + end, boundary)
            if let last = result.last, absoluteStart + tolerance < last.end {
                throw Failure.message("部分字幕的时间顺序冲突，请重新识别。")
            }
            let cueStart = max(absoluteStart, result.last?.end ?? offset)
            if absoluteEnd <= cueStart {
                // Retain text from a quantized point only when a neighbouring
                // segment supplies the same boundary. Never invent a duration.
                if let last = result.last, abs(last.end - absoluteStart) <= tolerance {
                    result[result.count - 1].text = try joined(last.text, text)
                } else if let point = pendingPoint {
                    guard abs(point.time - absoluteStart) <= tolerance else {
                        throw Failure.message("部分字幕缺少可对齐的时间，请重新识别。")
                    }
                    pendingPoint = (point.time, try joined(point.text, text))
                } else { pendingPoint = (absoluteStart, text) }
                continue
            }
            var displayText = text
            if let point = pendingPoint {
                guard abs(point.time - cueStart) <= tolerance else {
                    throw Failure.message("部分字幕缺少可对齐的时间，请重新识别。")
                }
                displayText = try joined(point.text, text); pendingPoint = nil
            }
            result.append(SubtitleCue(start: cueStart, end: absoluteEnd,
                                      language: language, text: displayText, chineseText: ""))
        }
        guard pendingPoint == nil else {
            throw Failure.message("部分字幕缺少可对齐的时间，请重新识别。")
        }
        return result
    }
    private struct WhisperOutput: Decodable {
        struct Result: Decodable { let language: String }
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Double; let to: Double }
            let offsets: Offsets
            let text: String
        }
        let result: Result
        let transcription: [Segment]
    }

    /// AVFoundation decodes and mixes only original clip audio, preserving montage gaps.
    private static func extractAudio(project: FilmProject, to url: URL) async throws {
        let composition = AVMutableComposition()
        var audioTracks: [AVAssetTrack] = []
        for placement in project.clipPlacements {
            try Task.checkCancellation()
            let clip = placement.clip
            guard clip.sourceIn.isFinite, clip.sourceOut.isFinite, clip.sourceIn >= 0,
                  clip.sourceOut > clip.sourceIn, placement.start >= 0, placement.end <= project.duration + 0.05,
                  FileManager.default.isReadableFile(atPath: clip.sourcePath) else {
                throw Failure.message("视频素材不存在，或截取时间超出范围。")
            }
            let source = AVURLAsset(url: URL(fileURLWithPath: clip.sourcePath))
            guard let original = try await source.loadTracks(withMediaType: .audio).first else { continue }
            let available = try await original.load(.timeRange)
            let requested = CMTimeRange(start: CMTime(seconds: clip.sourceIn, preferredTimescale: 16000),
                                        duration: CMTime(seconds: clip.duration, preferredTimescale: 16000))
            let range = CMTimeRangeGetIntersection(available, otherRange: requested)
            guard range.duration.seconds > 0 else { continue }
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure.message("无法创建原声音轨。")
            }
            let timelineStart = placement.start + range.start.seconds - clip.sourceIn
            try track.insertTimeRange(range, of: original, at: CMTime(seconds: timelineStart, preferredTimescale: 16000))
            audioTracks.append(track)
        }
        guard !audioTracks.isEmpty else { throw Failure.noSpeech }
        let reader = try AVAssetReader(asset: composition)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.message("系统无法解码这段视频的原声。") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: project.duration, preferredTimescale: 16000))
        let byteCount = Int((project.duration * 16000).rounded()) * 2
        FileManager.default.createFile(atPath: url.path, contents: waveHeader(byteCount: byteCount))
        let file = try FileHandle(forWritingTo: url)
        defer { reader.cancelReading(); try? file.close() }
        try file.seekToEnd()
        guard reader.startReading() else { throw Failure.message("无法读取视频原声：\(reader.error?.localizedDescription ?? "解码器无法启动")") }
        var written = 0
        let silence = Data(repeating: 0, count: 32_000)
        func fill(until end: Int) throws {
            while written < end {
                try Task.checkCancellation()
                let count = min(silence.count, end - written)
                try file.write(contentsOf: silence.prefix(count))
                written += count
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.message("音频解码返回了空数据。") }
            let stamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard stamp.isFinite, stamp >= -0.05 else { throw Failure.message("音频解码返回了无效时间码。") }
            let position = max(0, Int((stamp * 16000).rounded()) * 2)
            try fill(until: min(position, byteCount))
            let length = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw Failure.message("音频解码数据读取失败。") }
            let skipped = min(length, max(0, written - position))
            let count = min(length - skipped, byteCount - written)
            if count > 0 { try file.write(contentsOf: bytes[skipped..<(skipped + count)]); written += count }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw Failure.message("原声提取失败：\(reader.error?.localizedDescription ?? "未完成解码")") }
        try fill(until: byteCount)
    }
    private static func hasAudibleSignal(_ data: Data) -> Bool {
        var energy = 0.0
        var peak: Int = 0
        data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                let sample = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                energy += Double(sample * sample)
                peak = max(peak, abs(sample))
            }
        }
        // Only reject digital silence / nearly silent tracks; speech detection remains Whisper's job.
        return peak >= 24 && sqrt(energy / Double(max(1, data.count / 2))) >= 3
    }
    private static func waveHeader(byteCount: Int) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(byteCount + 36)); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); ascii("data"); u32(UInt32(byteCount))
        return data
    }
    enum Failure: LocalizedError {
        case message(String)
        case noSpeech
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            case .noSpeech: return "未识别到可用的人声。视频可能没有音轨、仅有音乐，或人声太弱。"
            }
        }
    }
    private final class ChildProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func cancel() {
            lock.lock(); cancelled = true
            let running = process
            if running?.isRunning == true { running?.terminate() }
            lock.unlock()
            // Wait until the child exits before temp cleanup; escalate a stuck worker only.
            if let running {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    self.lock.lock(); defer { self.lock.unlock() }
                    if self.process === running, running.isRunning { kill(running.processIdentifier, SIGKILL) }
                }
            }
        }
        func run(executable: URL, arguments: [String], log: URL) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        FileManager.default.createFile(atPath: log.path, contents: nil)
                        let handle = try FileHandle(forWritingTo: log)
                        defer { try? handle.close() }
                        let child = Process()
                        child.executableURL = executable
                        child.arguments = arguments
                        child.standardOutput = handle
                        child.standardError = handle
                        self.lock.lock()
                        if self.cancelled { self.lock.unlock(); throw CancellationError() }
                        self.process = child
                        do { try child.run() } catch { self.process = nil; self.lock.unlock(); throw error }
                        self.lock.unlock()
                        child.waitUntilExit()
                        self.lock.lock()
                        let cancelled = self.cancelled
                        self.process = nil
                        self.lock.unlock()
                        if cancelled { throw CancellationError() }
                        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                            throw Failure.message("本地语音识别未能完成（退出码 \(child.terminationStatus)），请检查模型文件并重试。")
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
