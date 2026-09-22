import Foundation
import AVFoundation
import CoreGraphics
import Darwin

/// Real-media integration tests. FFmpeg is used only for disposable fixtures.
/// swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/Models.swift Sources/MediaAnalyzer.swift Sources/CompositionBuilder.swift Tests/CompositionTests.swift -o /tmp/jingdu-composition-tests
/// /tmp/jingdu-composition-tests
@main
struct CompositionTests {
    private static var assertions = 0
    private static var failures: [String] = []

    @MainActor
    static func main() async {
        let directory = URL(fileURLWithPath: "/tmp/jingdu-composition-regression-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixtures = try makeFixtures(directory)
            let firstInfo = try await MediaAnalyzer.inspect(fixtures.first)
            let rotatedInfo = try await MediaAnalyzer.inspect(fixtures.rotated)
            let tailInfo = try await MediaAnalyzer.inspect(fixtures.tail)
            let musicDuration = try await CompositionBuilder.inspectAudio(fixtures.music)
            check(abs(musicDuration - 3) < 0.001, "Audio inspection returns real WAV duration")
            check(rotatedInfo.height > rotatedInfo.width, "Second source carries an actual portrait rotation transform")
            check(tailInfo.duration > 1.07 && tailInfo.duration < 1.071, "Final source has a fractional audio tail")
            let clips = [
                clip("蓝色裁剪", fixtures.first, firstInfo, 2, 4),
                clip("竖屏旋转", fixtures.rotated, rotatedInfo, 0.5, 2.5),
                clip("分数尾长", fixtures.tail, tailInfo, 0, tailInfo.duration)
            ]
            var project = FilmProject(title: "临时组合回归", sourcePath: fixtures.first.path,
                                      duration: clips.reduce(0) { $0 + $1.duration }, frameRate: 30,
                                      width: 320, height: 180, cuts: [], notes: [], kind: .remix,
                                      clips: clips, music: [], originalVolume: 0)
            project.music = [
                MusicClip(title: "早入音乐", sourcePath: fixtures.music.path, sourceDuration: musicDuration,
                          sourceIn: 0.4, sourceOut: 2.4, timelineStart: 1, volume: 0.3),
                MusicClip(title: "重叠音乐", sourcePath: fixtures.music2.path, sourceDuration: musicDuration,
                          sourceIn: 0.2, sourceOut: 2.2, timelineStart: 2, volume: 0.6)
            ]
            let result = try await CompositionBuilder.build(project)
            let actualDuration = try await result.asset.load(.duration)
            check(abs(actualDuration.seconds - project.duration) < 0.000_01, "Trimmed clips preserve the complete fractional timeline duration")
            guard let videoComposition = result.videoComposition else { throw TestFailure("Missing video composition") }
            let valid = try await videoComposition.isValid(for: result.asset,
                                                           timeRange: CMTimeRange(start: .zero, duration: actualDuration),
                                                           validationDelegate: nil)
            check(valid, "All instructions cover the exact full asset range without -11841")
            check(videoComposition.instructions.count == 3, "Each clip has its own transform instruction")
            let ranges = videoComposition.instructions.map(\.timeRange)
            check(CMTimeCompare(ranges[0].start, .zero) == 0, "Composition instructions begin at zero")
            check(CMTimeCompare(ranges[0].end, ranges[1].start) == 0 && CMTimeCompare(ranges[1].end, ranges[2].start) == 0,
                  "Every internal instruction boundary is continuous")
            check(CMTimeCompare(ranges.last!.end, actualDuration) == 0, "Last instruction ends at the original CMTime of the composition")
            check(result.audioMix?.inputParameters.count == 3, "Original audio and both overlapping music clips get independent mix inputs")
            await checkPictures(asset: result.asset, composition: videoComposition, label: "Playback")

            let output = directory.appendingPathComponent("combined.mp4")
            try Data("Existing destination must be replaced only after export succeeds".utf8).write(to: output)
            let progress = ProgressLog()
            try await CompositionBuilder.export(project, to: output, progress: { progress.append($0) })
            let exported = AVURLAsset(url: output)
            let outputDuration = try await exported.load(.duration).seconds
            check(abs(outputDuration - project.duration) < 0.05, "MP4 duration matches the trimmed timeline within one output frame")
            let tracks = try await exported.loadTracks(withMediaType: .video)
            let descriptions = try await tracks[0].load(.formatDescriptions)
            check(descriptions.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }, "Export uses H.264 video")
            let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
            check(!exportedAudio.isEmpty, "Export includes the mixed music audio track")
            await checkPictures(asset: exported, composition: nil, label: "Export")
            let waveform = try await MediaAnalyzer.waveform(output, bins: 100)
            func rms(at seconds: Double) -> Double {
                waveform[min(waveform.count - 1, Int(seconds / outputDuration * Double(waveform.count)))]
            }
            check(rms(at: 0.5) < 0.002, "Muting original audio leaves the initial half-second silent")
            check(rms(at: 1.5) > 0.018 && rms(at: 1.5) < 0.04, "First music clip enters at its independent timeline start and gain")
            check(rms(at: 2.5) > rms(at: 1.5) * 1.7, "Overlapping music clips are both mixed into the exported audio")
            check(rms(at: 3.5) > 0.04 && rms(at: 3.5) < 0.065, "Second music clip continues after the first ends")
            check(rms(at: 4.6) < 0.002, "Trimmed music stops at its timeline endpoint")
            let updates = progress.values
            check(updates.first == 0 && updates.last == 1, "Export progress reports start and committed completion")
            check(updates.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "Progress remains bounded")

            await checkProtection(project, source: fixtures.first, directory: directory)
            await checkErrors(project, noAudio: fixtures.rotated)
            await checkCancellation(project, directory: directory)
            await checkActiveCancellation(project, directory: directory)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            check(!leftovers.contains(where: { $0.hasPrefix(".jingdu-export-") }), "Exports clean up temporary output files")
        } catch {
            failures.append("Test setup or integration failed: \(error.localizedDescription)")
        }
        if failures.isEmpty {
            print("Composition real-media regressions passed (\(assertions) assertions; all fixtures temporary).")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            fputs("Composition regressions failed: \(failures.count) failures, \(assertions) assertions.\n", stderr)
            exit(1)
        }
    }

    private static func clip(_ title: String, _ url: URL, _ info: MediaInfo, _ sourceIn: Double, _ sourceOut: Double) -> VideoClip {
        VideoClip(title: title, sourcePath: url.path, sourceDuration: info.duration, sourceIn: sourceIn,
                  sourceOut: sourceOut, frameRate: info.frameRate, width: info.width, height: info.height)
    }

    private static func checkPictures(asset: AVAsset, composition: AVVideoComposition?, label: String) async {
        do {
            let blue = try await pixel(asset, composition, at: 0.5, x: 160, y: 90)
            let pillar = try await pixel(asset, composition, at: 2.5, x: 60, y: 90)
            let green = try await pixel(asset, composition, at: 2.5, x: 160, y: 90)
            let yellow = try await pixel(asset, composition, at: 4.5, x: 160, y: 90)
            check(blue.2 > 160 && blue.0 < 60, "\(label): first clip honors sourceIn=2 and starts in blue")
            check(max(pillar.0, pillar.1, pillar.2) < 25, "\(label): rotated portrait is fitted with the expected pillarboxes")
            check(green.1 > 70 && green.0 < 60 && green.2 < 60, "\(label): rotated clip remains visible at the center")
            check(yellow.0 > 160 && yellow.1 > 160 && yellow.2 < 70, "\(label): third source follows the second hard cut")
        } catch { failures.append("\(label) frame verification: \(error.localizedDescription)") }
    }

    private static func pixel(_ asset: AVAsset, _ composition: AVVideoComposition?, at seconds: Double,
                              x: Int, y: Int) async throws -> (Int, Int, Int) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        let values = bytes.withUnsafeMutableBytes { raw -> (Int, Int, Int) in
            let context = CGContext(data: raw.baseAddress, width: 320, height: 180, bitsPerComponent: 8,
                                    bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
            let p = raw.bindMemory(to: UInt8.self)
            let offset = (y * 320 + x) * 4
            return (Int(p[offset]), Int(p[offset + 1]), Int(p[offset + 2]))
        }
        return values
    }

    private static func checkProtection(_ project: FilmProject, source: URL, directory: URL) async {
        do {
            let original = try Data(contentsOf: source)
            await expectError("Direct source export is rejected", contains: "源素材") {
                try await CompositionBuilder.export(project, to: source, progress: { _ in })
            }
            let alias = directory.appendingPathComponent("hardlink-source.mp4")
            try FileManager.default.linkItem(at: source, to: alias)
            await expectError("Hardlinked source export is rejected", contains: "源素材") {
                try await CompositionBuilder.export(project, to: alias, progress: { _ in })
            }
            try check(try Data(contentsOf: source) == original, "Source bytes remain unchanged after export protection checks")
        } catch { failures.append("Source protection setup: \(error.localizedDescription)") }
    }

    private static func checkErrors(_ project: FilmProject, noAudio: URL) async {
        var missingVideo = project
        missingVideo.clips[0].sourcePath += ".missing"
        await expectError("Missing video reports an actionable Chinese error", contains: "找不到") {
            _ = try await CompositionBuilder.build(missingVideo)
        }
        var missingMusic = project
        missingMusic.music[0].sourcePath += ".missing"
        await expectError("Missing music is not silently dropped", contains: "找不到") {
            _ = try await CompositionBuilder.build(missingMusic)
        }
        var invalidRange = project
        invalidRange.clips[0].sourceOut = 999
        await expectError("Out-of-range source trim is rejected", contains: "超出") {
            _ = try await CompositionBuilder.build(invalidRange)
        }
        await expectError("Audio inspection rejects a silent video file", contains: "没有") {
            _ = try await CompositionBuilder.inspectAudio(noAudio)
        }
    }

    private static func checkCancellation(_ project: FilmProject, directory: URL) async {
        let output = directory.appendingPathComponent("cancelled.mp4")
        let control = CancellationControl()
        let task = Task {
            try await CompositionBuilder.export(project, to: output, progress: { value in
                if value >= 0.03 { control.cancel() }
            })
        }
        control.install(task)
        do {
            try await task.value
            check(false, "Cancelled export must throw CancellationError")
        } catch is CancellationError {
            check(true, "Export cancellation propagates")
        } catch { check(false, "Cancellation returned a different error: \(error.localizedDescription)") }
        check(!FileManager.default.fileExists(atPath: output.path), "Cancelled export does not commit an output file")
    }

    private static func checkActiveCancellation(_ project: FilmProject, directory: URL) async {
        var longer = project
        longer.clips = (0..<80).map { _ in
            var clip = project.clips[0]
            clip.id = UUID()
            return clip
        }
        longer.music = []
        longer.duration = longer.clips.reduce(0) { $0 + $1.duration }
        let output = directory.appendingPathComponent("cancelled-active.mp4")
        let sentinel = Data("Preserve the existing destination while cancelling an active export".utf8)
        do { try sentinel.write(to: output) }
        catch { failures.append("Cancellation fixture: \(error.localizedDescription)"); return }
        let control = CancellationControl()
        let progress = ProgressLog()
        let task = Task {
            try await CompositionBuilder.export(longer, to: output, progress: { value in
                progress.append(value)
                if value > 0.031 && value < 1 { control.cancel() }
            })
        }
        control.install(task)
        do {
            try await task.value
            check(false, "Actively encoding export must respond to cancellation")
        } catch is CancellationError {
            check(true, "Cancellation during encoding propagates")
        } catch { check(false, "Active cancellation returned \(error.localizedDescription)") }
        check(progress.values.contains(where: { $0 > 0.031 && $0 < 1 }), "Active cancellation happens after encoding makes measurable progress")
        do { try check(try Data(contentsOf: output) == sentinel, "Cancelling active encoding preserves the previous destination bytes") }
        catch { failures.append("Cancelled destination: \(error.localizedDescription)") }
    }

    private static func expectError(_ label: String, contains: String, operation: () async throws -> Void) async {
        do { try await operation(); check(false, label) }
        catch { check(error.localizedDescription.contains(contains), "\(label): \(error.localizedDescription)") }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        assertions += 1
        if try !condition() { failures.append(message) }
    }

    private static func makeFixtures(_ directory: URL) throws -> (first: URL, rotated: URL, tail: URL, music: URL, music2: URL) {
        let paths = [ProcessInfo.processInfo.environment["FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TestFailure("FFmpeg is required only to create these test fixtures; set FFMPEG to its executable path.")
        }
        let first = directory.appendingPathComponent("landscape.mp4")
        let base = directory.appendingPathComponent("rotation-base.mp4")
        let rotated = directory.appendingPathComponent("portrait.mp4")
        let tail = directory.appendingPathComponent("fractional-tail.mov")
        let music = directory.appendingPathComponent("music-880.wav")
        let music2 = directory.appendingPathComponent("music-660.wav")
        try run(executable, ["-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=2",
                             "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=30:d=2",
                             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4",
                             "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]", "-map", "2:a",
                             "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", first.path])
        try run(executable, ["-f", "lavfi", "-i", "color=c=green:s=240x160:r=24:d=3", "-an",
                             "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", base.path])
        try run(executable, ["-display_rotation:v:0", "90", "-i", base.path, "-c", "copy", rotated.path])
        try run(executable, ["-f", "lavfi", "-i", "color=c=yellow:s=160x90:r=30:d=1",
                             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                             "-filter_complex", "[1:a]atrim=end_sample=47209,asetpts=PTS-STARTPTS[a]",
                             "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-preset", "ultrafast",
                             "-pix_fmt", "yuv420p", "-video_track_timescale", "30000", "-movie_timescale", "44100",
                             "-c:a", "pcm_s16le", tail.path])
        for (url, frequency) in [(music, 880), (music2, 660)] {
            try run(executable, ["-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=44100:duration=3", "-c:a", "pcm_s16le", url.path])
        }
        return (first, rotated, tail, music, music2)
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
        guard process.terminationStatus == 0 else {
            throw TestFailure(String(data: errors, encoding: .utf8) ?? "Fixture generation failed")
        }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class CancellationControl: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Error>?
        func install(_ task: Task<Void, Error>) { lock.lock(); self.task = task; lock.unlock() }
        func cancel() { lock.lock(); let value = task; lock.unlock(); value?.cancel() }
    }

    private struct TestFailure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
