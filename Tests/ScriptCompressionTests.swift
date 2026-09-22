import Foundation
import AVFoundation
import AppKit
import Vision
import Darwin

/// Offline integration: generated geometry, local subtitle text and sine waves.
/// xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O Sources/Models.swift Sources/MediaAnalyzer.swift Sources/CompositionBuilder.swift Sources/ScriptCompression.swift Tests/ScriptCompressionTests.swift -o /tmp/jingdu-script-compression-tests
/// /tmp/jingdu-script-compression-tests
@main struct ScriptCompressionTests {
    private static var assertions = 0

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jingdu-compression-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtures = try makeFixtures(folder)
        let originals = try fixtures.map { ($0, try Data(contentsOf: $0)) }
        let first = try await clip(fixtures[0], start: 1, end: 4)
        let portrait = try await clip(fixtures[1], start: 0, end: 2)
        let tail = try await clip(fixtures[2])
        var project = SequenceLogic.makeProject(title: "压缩时序测试", clips: [first, portrait, tail], kind: .remix)
        project.originalVolume = 0.5
        project.music = [MusicClip(title: "测试配乐", sourcePath: fixtures[3].path, sourceDuration: 6,
                                  sourceIn: 0, sourceOut: 3, timelineStart: 2, volume: 0.5)]
        let built = try await CompositionBuilder.build(project)
        let originalFrameDuration = built.videoComposition!.frameDuration
        let log = ProgressLog()
        let destination = folder.appendingPathComponent("selected.mp4")
        print("Checking selected range across mixed clips...")
        let result = try await ScriptCompression.export(asset: built.asset, videoComposition: built.videoComposition,
            audioMix: built.audioMix, timeRange: range(0.5, 4.5), outputURL: destination, progress: { log.append($0) })
        expect(abs(result.duration - 4) <= 1 / 15.0 && result.frameRate <= 15.01, "Selection keeps its duration while actually reducing frame rate")
        expect(result.width == 1280 && result.height == 720 && result.hasAudio, "1080p mixed content keeps 720p and its mixed audio")
        let bytes = try Data(contentsOf: destination)
        expect(result.byteCount == bytes.count && result.byteCount <= 11_000_000, "Reported bytes match the actual bounded upload file")
        expect(CMTimeCompare(built.videoComposition!.frameDuration, originalFrameDuration) == 0, "Upload preparation never changes the playback composition's source frame rate")
        let asset = AVURLAsset(url: destination)
        let red = try await pixel(asset, at: 0.2, x: 0.5, y: 0.5)
        let blue = try await pixel(asset, at: 1, x: 0.5, y: 0.5)
        let green = try await pixel(asset, at: 3, x: 0.5, y: 0.5)
        let pillar = try await pixel(asset, at: 3, x: 0.1, y: 0.5)
        expect(red.0 > 170 && red.2 < 50, "Source trim plus selection offset starts in the correct red shot")
        expect(blue.2 > 170 && blue.0 < 50, "The next blue shot retains its timeline position")
        expect(green.1 > 70 && green.0 < 50 && green.2 < 50, "The rotated second clip remains present after its seam")
        expect(max(pillar.0, pillar.1, pillar.2) < 25, "Portrait content stays fitted without cropping")
        let waveform = try await MediaAnalyzer.waveform(destination, bins: 160)
        func rms(_ seconds: Double) -> Double { waveform[min(waveform.count - 1, Int(seconds / result.duration * Double(waveform.count)))] }
        expect(rms(0.2) > 0.035 && rms(0.2) < 0.055, "Original sound keeps the requested half volume")
        expect(rms(3) > 0.035 && rms(3) < 0.055, "The music mix continues over the silent clip at its original timeline location")
        expect(log.values.first == 0 && log.values.last == 1 && zip(log.values, log.values.dropFirst()).allSatisfy { $0 <= $1 }, "Progress covers the complete operation and never moves backwards")

        let endURL = folder.appendingPathComponent("fractional-end.mp4")
        print("Checking fractional audio tail...")
        let exactEnd = try await built.asset.load(.duration)
        let ending = try await ScriptCompression.export(asset: built.asset, videoComposition: built.videoComposition,
            audioMix: built.audioMix, timeRange: CMTimeRange(start: CMTime(seconds: 4.7, preferredTimescale: 600_000), end: exactEnd),
            outputURL: endURL, progress: { _ in })
        expect(abs(ending.duration - (exactEnd.seconds - 4.7)) <= 1 / 15.0, "Fractional audio tails export completely without changing the exact selection end")
        let yellow = try await pixel(AVURLAsset(url: endURL), at: 0.7, x: 0.5, y: 0.5)
        expect(yellow.0 > 160 && yellow.1 > 160 && yellow.2 < 60, "The final shot is still present near the selected endpoint")

        let portraitProject = SequenceLogic.makeProject(title: "竖屏小素材", clips: [portrait])
        print("Checking small portrait footage...")
        let portraitBuilt = try await CompositionBuilder.build(portraitProject)
        let portraitURL = folder.appendingPathComponent("portrait-output.mp4")
        let portraitResult = try await ScriptCompression.export(asset: portraitBuilt.asset, videoComposition: portraitBuilt.videoComposition,
            audioMix: portraitBuilt.audioMix, timeRange: range(0, 2), outputURL: portraitURL, progress: { _ in })
        expect(portraitResult.height > portraitResult.width && portraitResult.width <= 320 && portraitResult.height <= 480, "Small portrait footage preserves orientation and is never upscaled")
        expect(!portraitResult.hasAudio, "Silent footage stays silent")

        let nativeURL = folder.appendingPathComponent("native-composition.mp4")
        print("Checking native asset without supplied composition...")
        let nativeResult = try await ScriptCompression.export(asset: AVURLAsset(url: fixtures[1]), videoComposition: nil,
            audioMix: nil, timeRange: range(0, 2), outputURL: nativeURL, progress: { _ in })
        expect(nativeResult.width <= 320 && nativeResult.height <= 480 && nativeResult.height > nativeResult.width && nativeResult.frameRate <= 15.01, "The optional-composition path preserves rotation and enforces the same frame limit")

        let pattern = try await clip(fixtures[4], start: 0, end: 2)
        let originalSubtitle = try recognizedText(try await image(AVURLAsset(url: fixtures[4]), at: 0.5))
        expect(originalSubtitle.contains("JINGDU") && originalSubtitle.contains("SUBTITLE") && originalSubtitle.contains("221"), "The generated source fixture itself contains a readable subtitle")
        var copies = (0..<111).map { _ -> VideoClip in var c = pattern; c.id = UUID(); return c }
        copies[110].sourceOut = 1
        let longProject = SequenceLogic.makeProject(title: "221秒压缩回归", clips: copies)
        let longBuilt = try await CompositionBuilder.build(longProject)
        let longOriginalFrameDuration = longBuilt.videoComposition!.frameDuration
        let longURL = folder.appendingPathComponent("221-seconds.mp4")
        print("Checking 221 seconds of 720p motion, subtitle text and audio...")
        let long = try await ScriptCompression.export(asset: longBuilt.asset, videoComposition: longBuilt.videoComposition,
            audioMix: longBuilt.audioMix, timeRange: range(0, 221), outputURL: longURL, progress: { _ in })
        expect(abs(long.duration - 221) <= 1 / 15.0, "The whole 221-second timeline survives size-limited encoding")
        expect(long.width == 1280 && long.height == 720 && abs(long.frameRate - 6) < 0.01 && long.hasAudio, "Long-form upload remains 720p with an actual 6 fps cadence and audio")
        expect(CMTimeCompare(longBuilt.videoComposition!.frameDuration, longOriginalFrameDuration) == 0, "Long-form downsampling also leaves the source playback composition unchanged")
        expect(long.byteCount > 0 && long.byteCount <= 11_000_000, "Real 221-second output stays inside the 11 MB hard video budget")
        let envelopeBytes = 4 * ((long.byteCount + 2) / 3) + 200_000
        expect(envelopeBytes < 16_000_000, "Base64 plus a conservative prompt envelope stays under the 16 MB request budget")
        let lastFrame = try await image(AVURLAsset(url: longURL), at: 220.5)
        let subtitle = try recognizedText(lastFrame)
        expect(subtitle.contains("JINGDU") && subtitle.contains("SUBTITLE") && subtitle.contains("221"), "Local OCR can still read the generated subtitle near the end of the compressed 720p movie")
        print("221-second result: \(long.byteCount) bytes, \(long.width)x\(long.height), \(long.frameRate) fps, duration \(long.duration); subtitle OCR passed.")

        await expectFailure("Existing destination is never overwritten") {
            _ = try await ScriptCompression.export(asset: built.asset, videoComposition: built.videoComposition,
                audioMix: built.audioMix, timeRange: range(0, 1), outputURL: destination, progress: { _ in })
        }
        let protected = try Data(contentsOf: destination)
        expect(protected == bytes, "Rejecting an existing output retains its exact bytes")
        let invalid = folder.appendingPathComponent("invalid.mp4")
        await expectFailure("A range outside the asset is rejected") {
            _ = try await ScriptCompression.export(asset: built.asset, videoComposition: built.videoComposition,
                audioMix: built.audioMix, timeRange: range(0, 100), outputURL: invalid, progress: { _ in })
        }
        expect(!FileManager.default.fileExists(atPath: invalid.path), "A rejected range leaves no upload file")
        await cancellation(built, duration: 4, destination: folder.appendingPathComponent("cancel-before.mp4"), duringExport: false)
        await cancellation(longBuilt, duration: 221, destination: folder.appendingPathComponent("cancel-active.mp4"), duringExport: true)
        for (source, original) in originals {
            let current = try Data(contentsOf: source)
            expect(current == original, "Source bytes and names remain unchanged: \(source.lastPathComponent)")
        }
        print("Script compression tests passed (\(assertions) assertions; only generated local fixtures).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        guard condition() else { fatalError(label) }
    }
    private static func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000), end: CMTime(seconds: end, preferredTimescale: 600_000))
    }
    private static func clip(_ url: URL, start: Double = 0, end: Double? = nil) async throws -> VideoClip {
        let info = try await MediaAnalyzer.inspect(url)
        return VideoClip(title: url.lastPathComponent, sourcePath: url.path, sourceDuration: info.duration,
                         sourceIn: start, sourceOut: end ?? info.duration, frameRate: info.frameRate, width: info.width, height: info.height)
    }
    private static func image(_ asset: AVAsset, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600_000)).image
    }
    private static func pixel(_ asset: AVAsset, at seconds: Double, x: Double, y: Double) async throws -> (Int, Int, Int) {
        let image = try await image(asset, at: seconds)
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        return bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
            let pixels = raw.bindMemory(to: UInt8.self), offset = (Int(y * 180) * 320 + Int(x * 320)) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }
    }
    private static func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
    private static func expectFailure(_ label: String, operation: () async throws -> Void) async {
        do { try await operation(); expect(false, label) }
        catch { expect(true, label) }
    }
    private static func cancellation(_ built: CompositionResult, duration: Double, destination: URL, duringExport: Bool) async {
        let control = CancellationControl(), log = ProgressLog()
        let task = Task {
            try await ScriptCompression.export(asset: built.asset, videoComposition: built.videoComposition, audioMix: built.audioMix,
                timeRange: range(0, duration), outputURL: destination, progress: { value in
                    log.append(value)
                    if duringExport ? value > 0.01 && value < 1 : value == 0 { control.cancel() }
                })
        }
        control.install(task)
        do { _ = try await task.value; expect(false, "Cancellation propagates") }
        catch is CancellationError { expect(true, "Cancellation propagates") }
        catch { expect(false, "Cancellation must remain a cancellation: \(error.localizedDescription)") }
        expect(!FileManager.default.fileExists(atPath: destination.path), "Cancellation removes the partial upload file")
        if duringExport { expect(log.values.contains { $0 > 0.01 && $0 < 1 }, "Active cancellation happens after encoding reports progress") }
    }
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    private final class CancellationControl: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<ScriptCompression.Result, Error>?
        func install(_ task: Task<ScriptCompression.Result, Error>) { lock.lock(); self.task = task; lock.unlock() }
        func cancel() { lock.lock(); let value = task; lock.unlock(); value?.cancel() }
    }

    @MainActor private static func makeFixtures(_ folder: URL) throws -> [URL] {
        let candidates = [ProcessInfo.processInfo.environment["FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "CompressionTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set FFMPEG to create disposable media; the app itself uses Apple export."])
        }
        let urls = ["landscape.mp4", "portrait.mp4", "fractional-tail.mov", "music.wav", "motion.mp4"].map { folder.appendingPathComponent($0) }
        let base = folder.appendingPathComponent("rotation-base.mp4")
        try run(executable, ["-f", "lavfi", "-i", "color=c=red:s=1920x1080:r=30:d=2", "-f", "lavfi", "-i", "color=c=blue:s=1920x1080:r=30:d=2",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4", "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
            "-map", "[v]", "-map", "2:a", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", urls[0].path])
        try run(executable, ["-f", "lavfi", "-i", "color=c=green:s=480x320:r=24:d=3", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", base.path])
        try run(executable, ["-display_rotation:v:0", "90", "-i", base.path, "-c", "copy", urls[1].path])
        try run(executable, ["-f", "lavfi", "-i", "color=c=yellow:s=320x180:r=24:d=1", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
            "-filter_complex", "[1:a]atrim=end_sample=47209,asetpts=PTS-STARTPTS[a]", "-map", "0:v", "-map", "[a]",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-movie_timescale", "44100", "-c:a", "pcm_s16le", urls[2].path])
        try run(executable, ["-f", "lavfi", "-i", "sine=frequency=880:sample_rate=44100:duration=6", "-c:a", "pcm_s16le", urls[3].path])
        let subtitleURL = folder.appendingPathComponent("subtitle.png")
        // An explicit bitmap keeps this fixture at 1280x720 on Retina displays;
        // NSImage.lockFocus otherwise makes a 2560x1440 overlay and crops the text.
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1280, height: 720).fill(using: .copy)
        NSColor.black.setFill(); NSRect(x: 0, y: 18, width: 1280, height: 80).fill()
        ("JINGDU TEST SUBTITLE 221" as NSString).draw(at: NSPoint(x: 180, y: 34), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        try image.representation(using: .png, properties: [:])!.write(to: subtitleURL)
        try run(executable, ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=2", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2",
            "-loop", "1", "-i", subtitleURL.path, "-filter_complex", "[0:v][2:v]overlay=0:0[v]", "-map", "[v]", "-map", "1:a", "-t", "2",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", urls[4].path])
        return urls
    }
    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + arguments
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errors = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CompressionTest", code: 2, userInfo: [NSLocalizedDescriptionKey: String(data: errors, encoding: .utf8) ?? "Fixture creation failed"])
        }
    }
}
