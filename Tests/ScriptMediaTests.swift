import Foundation
import AVFoundation
import CoreGraphics
import Darwin

/// Uses only disposable geometric media, never the user's library or a network.
/// swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/Models.swift Sources/MediaAnalyzer.swift Sources/CompositionBuilder.swift Sources/ScriptCompression.swift Sources/ScriptMediaPreparer.swift Tests/ScriptMediaTests.swift -o /tmp/jingdu-script-media-tests
@main
struct ScriptMediaTests {
    private static var assertions = 0
    private static var failures: [String] = []

    @MainActor
    static func main() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jingdu-script-tests-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let fixtures = try makeFixtures(folder)
            let originals = try fixtures.map { ($0, try Data(contentsOf: $0)) }
            let a = try await clip(fixtures[0], start: 1, end: 4)
            let b = try await clip(fixtures[1], start: 0, end: 2)
            let tail = try await clip(fixtures[2])
            var project = SequenceLogic.makeProject(title: "本地测试", clips: [a, b, tail], kind: .remix)
            project.originalVolume = 0.5
            project.music = [
                MusicClip(title: "音乐 A", sourcePath: fixtures[3].path, sourceDuration: 6,
                          sourceIn: 0.5, sourceOut: 4.5, timelineStart: 1, volume: 0.5),
                MusicClip(title: "音乐 B", sourcePath: fixtures[4].path, sourceDuration: 6,
                          sourceIn: 0, sourceOut: 3, timelineStart: 2, volume: 0.25)
            ]
            let log = ProgressLog()
            let media = try await ScriptMediaPreparer.prepare(project, rangeStart: 0.5, rangeEnd: 4.5,
                                                              progress: { log.append($0) })
            defer { media.cleanup() }
            let url = media.videoURL
            check(FileManager.default.fileExists(atPath: url.path), "Successful preparation remains available to caller")
            check(url.pathExtension == "mp4" && !fixtures.contains(url), "Output is a new temporary MP4")
            check(media.byteCount > 0 && media.byteCount <= ScriptMediaPreparer.maximumByteCount, "Actual output respects the 40 MB limit")
            try check(media.byteCount == Data(contentsOf: url).count, "Reported size equals actual file bytes")
            check(abs(media.duration - 4) < 0.05, "Partial selection exports four seconds across a clip seam")
            check(media.hasAudio, "Original sound and timeline music are preserved")
            let asset = AVURLAsset(url: url)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            let size = try await video.load(.naturalSize)
            check(size.width == 1280 && size.height == 720, "1080p landscape is reduced to 720p")
            let format = try await video.load(.formatDescriptions)
            check(format.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }, "Temporary video is H.264")
            let audio = try await asset.loadTracks(withMediaType: .audio)[0]
            let audioFormat = try await audio.load(.formatDescriptions)
            check(audioFormat.contains { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }, "Mixed sound is AAC")
            let red = try await pixel(asset, at: 0.2, x: 0.5, y: 0.5)
            let blue = try await pixel(asset, at: 1, x: 0.5, y: 0.5)
            let green = try await pixel(asset, at: 3, x: 0.5, y: 0.5)
            let pillar = try await pixel(asset, at: 3, x: 0.1, y: 0.5)
            check(red.0 > 170 && red.2 < 50, "The source trim and selected range start in red")
            check(blue.2 > 170 && blue.0 < 50, "The later source frame remains blue")
            check(green.1 > 70 && green.0 < 50 && green.2 < 50, "The rotated second clip is visible after the seam")
            check(max(pillar.0, pillar.1, pillar.2) < 25, "Portrait footage remains fitted without cropping")
            let waveform = try await MediaAnalyzer.waveform(url, bins: 160)
            func rms(_ seconds: Double) -> Double { waveform[min(waveform.count - 1, Int(seconds / media.duration * Double(waveform.count)))] }
            check(rms(0.2) > 0.035 && rms(0.2) < 0.055, "Selected segment preserves original sound at half volume")
            check(rms(1) > rms(0.2) * 1.2, "Music enters at its original timeline position after the selected range offset")
            check(rms(3) > 0.04 && rms(3) < 0.06, "Both music tracks continue over the otherwise silent second video")
            check(log.values.first == 0 && log.values.last == 1, "Progress reports preparation and successful completion")
            check(zip(log.values, log.values.dropFirst()).allSatisfy { $0 <= $1 }, "Progress never moves backwards")

            let endMedia = try await ScriptMediaPreparer.prepare(project, rangeStart: 4.7, rangeEnd: project.duration, progress: { _ in })
            defer { endMedia.cleanup() }
            check(endMedia.videoURL != media.videoURL, "Every preparation gets a unique temporary directory")
            check(abs(endMedia.duration - (project.duration - 4.7)) < 0.05, "The fractional exact endpoint exports without -11841")
            let yellow = try await pixel(AVURLAsset(url: endMedia.videoURL), at: 0.7, x: 0.5, y: 0.5)
            check(yellow.0 > 160 && yellow.1 > 160 && yellow.2 < 60, "The final source is present in the end selection")
            endMedia.cleanup()
            endMedia.cleanup()
            check(!FileManager.default.fileExists(atPath: endMedia.videoURL.deletingLastPathComponent().path), "Explicit cleanup is idempotent and removes the private directory")
            check(FileManager.default.fileExists(atPath: media.videoURL.path), "Cleaning one result preserves another result")

            let silent = SequenceLogic.makeProject(title: "静音竖屏", clips: [b])
            let silentMedia = try await ScriptMediaPreparer.prepare(silent, rangeStart: 0, rangeEnd: 2, progress: { _ in })
            defer { silentMedia.cleanup() }
            check(!silentMedia.hasAudio, "Silent footage reports no audio")
            let portraitVideo = try await AVURLAsset(url: silentMedia.videoURL).loadTracks(withMediaType: .video)[0]
            let portraitSize = try await portraitVideo.load(.naturalSize)
            check(portraitSize.height > portraitSize.width && portraitSize.width <= 320 && portraitSize.height <= 480,
                  "Portrait-only output preserves orientation and does not upscale")

            await expectError("Negative range is rejected", contains: "范围") {
                _ = try await ScriptMediaPreparer.prepare(project, rangeStart: -1, rangeEnd: 2, progress: { _ in })
            }
            await expectError("Nonfinite range is rejected", contains: "范围") {
                _ = try await ScriptMediaPreparer.prepare(project, rangeStart: 0, rangeEnd: .nan, progress: { _ in })
            }
            await expectError("Empty range is rejected", contains: "范围") {
                _ = try await ScriptMediaPreparer.prepare(project, rangeStart: 2, rangeEnd: 2, progress: { _ in })
            }
            await expectError("A range beyond the timeline is rejected", contains: "超出") {
                _ = try await ScriptMediaPreparer.prepare(project, rangeStart: 0, rangeEnd: 20, progress: { _ in })
            }
            await expectError("Selections beyond five minutes are rejected", contains: "5 分钟") {
                _ = try await ScriptMediaPreparer.prepare(project, rangeStart: 0, rangeEnd: 301, progress: { _ in })
            }
            var missing = project
            missing.clips[0].sourcePath += ".missing"
            await expectError("Missing source is reported without being dropped", contains: "找不到") {
                _ = try await ScriptMediaPreparer.prepare(missing, rangeStart: 0, rangeEnd: 2, progress: { _ in })
            }

            let pattern = try await clip(fixtures[5], start: 0, end: 2)
            let repetitions = (0..<90).map { _ -> VideoClip in var value = pattern; value.id = UUID(); return value }
            let longProject = SequenceLogic.makeProject(title: "三分钟测试", clips: repetitions, kind: .remix)
            print("Checking a real 180-second moving-pattern preparation...")
            let longMedia = try await ScriptMediaPreparer.prepare(longProject, rangeStart: 0, rangeEnd: 180, progress: { _ in })
            defer { longMedia.cleanup() }
            check(abs(longMedia.duration - 180) < 0.05 && longMedia.byteCount <= ScriptMediaPreparer.maximumByteCount,
                  "A full three-minute moving pattern fits the request budget without truncation")
            print("180-second file: \(longMedia.byteCount) bytes, duration \(longMedia.duration).")
            await checkCancellation(project, afterEncodingBegins: false)
            await checkCancellation(longProject, afterEncodingBegins: true)
            for (source, bytes) in originals {
                try check(Data(contentsOf: source) == bytes, "Source bytes and names remain unchanged: \(source.lastPathComponent)")
            }
            media.cleanup()
            check(!FileManager.default.fileExists(atPath: url.path), "The main prepared copy is deleted on request")
        } catch { failures.append("Integration setup or execution failed: \(error.localizedDescription)") }
        if failures.isEmpty { print("Script media regressions passed (\(assertions) assertions; all fixtures temporary).") }
        else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fputs("Script media regressions failed: \(failures.count) failures, \(assertions) assertions.\n", stderr)
            exit(1)
        }
    }

    private static func clip(_ url: URL, start: Double = 0, end: Double? = nil) async throws -> VideoClip {
        let info = try await MediaAnalyzer.inspect(url)
        return VideoClip(title: url.lastPathComponent, sourcePath: url.path, sourceDuration: info.duration,
                         sourceIn: start, sourceOut: end ?? info.duration, frameRate: info.frameRate, width: info.width, height: info.height)
    }

    private static func pixel(_ asset: AVAsset, at seconds: Double, x: Double, y: Double) async throws -> (Int, Int, Int) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600_000)).image
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        return bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
            let p = raw.bindMemory(to: UInt8.self)
            let offset = (Int(y * 180) * 320 + Int(x * 320)) * 4
            return (Int(p[offset]), Int(p[offset + 1]), Int(p[offset + 2]))
        }
    }

    private static func checkCancellation(_ project: FilmProject, afterEncodingBegins: Bool) async {
        func leftovers() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
                .filter { $0.hasPrefix("jingdu-script-") }
        }
        let before = leftovers()
        let control = CancellationControl()
        let log = ProgressLog()
        let task = Task {
            try await ScriptMediaPreparer.prepare(project, rangeStart: 0, rangeEnd: project.duration, progress: { value in
                log.append(value)
                if afterEncodingBegins ? value > 0.045 && value < 1 : value >= 0.04 { control.cancel() }
            })
        }
        control.install(task)
        do { let unexpected = try await task.value; unexpected.cleanup(); check(false, "Cancellation should throw") }
        catch is CancellationError { check(true, "Cancellation propagates before/during encoding") }
        catch { check(false, "Unexpected cancellation error: \(error.localizedDescription)") }
        check(leftovers() == before, "Cancellation removes every directory created by preparation")
        if afterEncodingBegins { check(log.values.contains { $0 > 0.045 && $0 < 1 }, "Active cancellation occurred during measured encoding progress") }
    }

    private static func expectError(_ label: String, contains: String, operation: () async throws -> Void) async {
        do { try await operation(); check(false, label) }
        catch { check(error.localizedDescription.contains(contains), "\(label): \(error.localizedDescription)") }
    }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
        assertions += 1
        if try !condition() { failures.append(label) }
    }
    private static func makeFixtures(_ folder: URL) throws -> [URL] {
        let candidates = [ProcessInfo.processInfo.environment["FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TestFailure("Set FFMPEG to generate disposable test fixtures; the app does not need FFmpeg.")
        }
        let names = ["landscape.mp4", "portrait.mp4", "fractional-tail.mov", "music-a.wav", "music-b.wav", "moving-pattern.mp4"]
        let urls = names.map { folder.appendingPathComponent($0) }
        let base = folder.appendingPathComponent("rotation-base.mp4")
        try run(executable, ["-f", "lavfi", "-i", "color=c=red:s=1920x1080:r=24:d=2", "-f", "lavfi", "-i", "color=c=blue:s=1920x1080:r=24:d=2",
                             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4", "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
                             "-map", "[v]", "-map", "2:a", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", urls[0].path])
        try run(executable, ["-f", "lavfi", "-i", "color=c=green:s=480x320:r=24:d=3", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", base.path])
        try run(executable, ["-display_rotation:v:0", "90", "-i", base.path, "-c", "copy", urls[1].path])
        try run(executable, ["-f", "lavfi", "-i", "color=c=yellow:s=320x180:r=24:d=1", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                             "-filter_complex", "[1:a]atrim=end_sample=47209,asetpts=PTS-STARTPTS[a]", "-map", "0:v", "-map", "[a]",
                             "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-movie_timescale", "44100", "-c:a", "pcm_s16le", urls[2].path])
        for (index, frequency) in [(3, 880), (4, 660)] {
            try run(executable, ["-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=44100:duration=6", "-c:a", "pcm_s16le", urls[index].path])
        }
        try run(executable, ["-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=24:d=2", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", urls[5].path])
        return urls
    }
    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errors = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestFailure(String(data: errors, encoding: .utf8) ?? "Fixture creation failed") }
    }
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    private final class CancellationControl: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<PreparedScriptMedia, Error>?
        func install(_ value: Task<PreparedScriptMedia, Error>) { lock.lock(); task = value; lock.unlock() }
        func cancel() { lock.lock(); let value = task; lock.unlock(); value?.cancel() }
    }
    private struct TestFailure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
