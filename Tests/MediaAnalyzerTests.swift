import Foundation
import AVFoundation
import Darwin

/// Real AVFoundation integration regressions. FFmpeg is used only to synthesize
/// disposable test media; it is not linked to or required by the application.
/// swiftc -swift-version 5 Sources/MediaAnalyzer.swift Tests/MediaAnalyzerTests.swift -o /tmp/jingdu-media-tests
/// /tmp/jingdu-media-tests
@main
struct MediaAnalyzerTests {
    private static var assertions = 0
    private static var failures: [String] = []

    @MainActor
    static func main() async {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("jingdu-media-regression-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ffmpeg = try locateFFmpeg()
            let tail = directory.appendingPathComponent("fractional-audio-tail.mov")
            let delayed = directory.appendingPathComponent("delayed-fractional-audio.mov")
            // 400009 / 44100 = 9.070498866... seconds. Rounding this to 1/600
            // rounds DOWN, exposing an instruction ending before the asset.
            try makeFixture(ffmpeg: ffmpeg, output: tail, delaySamples: 0, sampleCount: 400_009)
            // The same fractional asset end, but with a real delayed audio track
            // (50141 / 44100 = 1.136984... seconds) rather than padded silence.
            try makeFixture(ffmpeg: ffmpeg, output: delayed, delaySamples: 50_141, sampleCount: 349_868)

            await checkFixture(tail, expectsDelay: false)
            await checkFixture(delayed, expectsDelay: true)
            await checkCancellation(tail)
        } catch {
            failures.append("Fixture setup failed: \(error.localizedDescription)")
        }
        if failures.isEmpty {
            print("MediaAnalyzer real-media regressions passed (\(assertions) assertions; all fixtures were temporary).")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            fputs("MediaAnalyzer regressions failed: \(failures.count) failure(s), \(assertions) assertions.\n", stderr)
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    private static func locateFFmpeg() throws -> URL {
        let candidates = [ProcessInfo.processInfo.environment["FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TestFailure("Creating test fixtures requires FFmpeg; set FFMPEG to its executable path. The app itself does not require FFmpeg.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func makeFixture(ffmpeg: URL, output: URL, delaySamples: Int, sampleCount: Int) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=3",
            "-f", "lavfi", "-i", "color=c=green:s=320x180:r=30:d=3",
            "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=30:d=3",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
            "-filter_complex", "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v];[3:a]atrim=end_sample=\(sampleCount),asetpts=PTS-STARTPTS+\(delaySamples)[a]",
            "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "24", "-threads", "2", "-bf", "0", "-g", "30", "-pix_fmt", "yuv420p",
            "-video_track_timescale", "30000", "-movie_timescale", "44100", "-use_editlist", "1",
            "-c:a", "pcm_s16le", output.path
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure("FFmpeg fixture creation failed: \(String(data: errorData, encoding: .utf8) ?? "unknown error")")
        }
    }

    private static func checkFixture(_ url: URL, expectsDelay: Bool) async {
        let name = url.lastPathComponent
        do {
            let asset = AVURLAsset(url: url)
            let exactDuration = try await asset.load(.duration)
            guard let video = try await asset.loadTracks(withMediaType: .video).first,
                  let audio = try await asset.loadTracks(withMediaType: .audio).first else {
                throw TestFailure("\(name): generated fixture must have both tracks")
            }
            let videoRange = try await video.load(.timeRange)
            let audioRange = try await audio.load(.timeRange)
            let audioSegments = try await audio.load(.segments)
            let firstAudioMediaStart = audioSegments.first(where: { !$0.isEmpty })?.timeMapping.target.start.seconds ?? 0
            let roundedDuration = CMTime(seconds: exactDuration.seconds, preferredTimescale: 600)
            print("\(name): asset=\(exactDuration.value)/\(exactDuration.timescale) (\(exactDuration.seconds)s), videoEnd=\(videoRange.end.seconds)s, firstAudioMedia=\(firstAudioMediaStart)s, audioEnd=\(audioRange.end.seconds)s")
            check(abs(videoRange.end.seconds - 9) < 0.000_001, "\(name): video must end at the exact 9-second frame boundary")
            check(exactDuration.seconds > videoRange.end.seconds, "\(name): audio must extend the overall asset beyond video")
            check(abs(exactDuration.seconds * 600 - (exactDuration.seconds * 600).rounded()) > 0.01, "\(name): asset duration must NOT be a multiple of 1/600 second")
            check(CMTimeCompare(roundedDuration, exactDuration) < 0, "\(name): regression requires 600-timescale rounding to shorten the instruction")
            if expectsDelay {
                // MOV track timeRange includes its empty leading edit. The first
                // nonempty segment locates the actual audio sample timeline.
                check(firstAudioMediaStart > 1, "\(name): audio must have delayed media, not only encoded silence")
            }

            let info = try await MediaAnalyzer.inspect(url)
            check(abs(info.duration - exactDuration.seconds) < 0.000_001, "\(name): metadata preserves the full asset duration")
            check(info.width == 320 && info.height == 180 && abs(info.frameRate - 30) < 0.001 && info.hasAudio, "\(name): metadata reports video geometry, FPS and audio")
            let image = await MediaAnalyzer.thumbnail(url, at: 4, width: 160, exact: true)
            check(image != nil, "\(name): exact frame thumbnail must decode")
            let waveform = try await MediaAnalyzer.waveform(url, bins: 180)
            check(waveform.count == 180 && waveform.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(name): waveform must contain valid amplitude bins")
            check(waveform.contains(where: { $0 > 0.01 }), "\(name): generated sine wave must produce nonzero waveform")
            if expectsDelay {
                check(waveform.prefix(15).allSatisfy { $0 == 0 }, "\(name): delayed audio leaves the first waveform bins silent")
                check(waveform.dropFirst(30).contains(where: { $0 > 0.01 }), "\(name): delayed audio appears after its timestamp")
            }

            let progress = ProgressLog()
            do {
                let cuts = try await MediaAnalyzer.detectCuts(url, sensitivity: 0.25) { progress.append($0) }
                check(cuts.count == 2, "\(name): expect exactly two hard cuts, received \(cuts)")
                check(cuts == cuts.sorted() && Set(cuts).count == cuts.count, "\(name): cut candidates must be strictly ordered and unique")
                check(cuts.allSatisfy { $0.isFinite && $0 > 0 && $0 < videoRange.end.seconds }, "\(name): cuts must stay within actual video")
                check(cuts.contains(where: { abs($0 - 3) <= 0.16 }), "\(name): a cut must be near 3 seconds")
                check(cuts.contains(where: { abs($0 - 6) <= 0.16 }), "\(name): a cut must be near 6 seconds")
                let values = progress.values
                check(values.last == 1 && values == values.sorted() && values.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(name): progress must finish monotonically at 1")
                print("\(name): detected cuts \(cuts)")
            } catch {
                failures.append("\(name): detectCuts must complete without AVFoundation -11841; received \(error.localizedDescription)")
            }
        } catch {
            failures.append("\(name): metadata/thumbnail/waveform regression failed: \(error.localizedDescription)")
        }
    }

    private static func checkCancellation(_ url: URL) async {
        let holder = CancellationHandle()
        let progress = ProgressLog()
        let task = Task {
            try await MediaAnalyzer.detectCuts(url, sensitivity: 0.25) { value in
                progress.append(value)
                // Cancel after reading has started, rather than only canceling an
                // unstarted task. The handle covers either task scheduling order.
                if value > 0 && value < 1 { holder.requestCancellation() }
            }
        }
        holder.install(task)
        do {
            let cuts = try await task.value
            failures.append("Cancellation must throw CancellationError, not return successful candidates \(cuts)")
        } catch is CancellationError {
            check(holder.wasRequested, "Cancellation fixture must cancel after real read progress")
            check(progress.values.last != 1, "Canceled analysis must not publish successful completion")
            print("In-flight cancellation: CancellationError, no successful completion.")
        } catch {
            failures.append("Cancellation must report CancellationError, received \(error.localizedDescription)")
        }
    }
}

private struct TestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    func append(_ value: Double) { lock.lock(); recorded.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<[Double], Error>?
    private var requested = false
    func install(_ task: Task<[Double], Error>) {
        lock.lock(); self.task = task; let shouldCancel = requested; lock.unlock()
        if shouldCancel { task.cancel() }
    }
    func requestCancellation() {
        lock.lock(); requested = true; let current = task; lock.unlock()
        current?.cancel()
    }
    var wasRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}
