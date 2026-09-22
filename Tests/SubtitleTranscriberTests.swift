import Foundation
import AVFoundation

/*
Pure offline regression (no model, media, subprocess, network, or preferences I/O):
  xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library \
    Sources/Models.swift Sources/SubtitleModels.swift Sources/SubtitleTranscriber.swift \
    Tests/SubtitleTranscriberTests.swift -o /tmp/jingdu-subtitle-transcriber-tests
  /tmp/jingdu-subtitle-transcriber-tests

Optional full integration uses an explicitly supplied synthetic audio fixture and
an already installed/verified ggml-small.bin. It never downloads anything.
Build a disposable probe bundle so Bundle.main finds the bundled CLI:
  mkdir -p /tmp/JingduSubtitleTests.app/Contents/MacOS
  mkdir -p /tmp/JingduSubtitleTests.app/Contents/Resources
  cp -R Resources/SubtitleEngine /tmp/JingduSubtitleTests.app/Contents/Resources/
  /usr/bin/plutil -create xml1 /tmp/JingduSubtitleTests.app/Contents/Info.plist
  /usr/bin/plutil -insert CFBundleExecutable -string SubtitleTests /tmp/JingduSubtitleTests.app/Contents/Info.plist
  /usr/bin/plutil -insert CFBundleIdentifier -string test.local.jingdu.subtitles /tmp/JingduSubtitleTests.app/Contents/Info.plist
  /usr/bin/plutil -insert CFBundlePackageType -string APPL /tmp/JingduSubtitleTests.app/Contents/Info.plist
  xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library \
    Sources/Models.swift Sources/SubtitleModels.swift Sources/SubtitleTranscriber.swift \
    Tests/SubtitleTranscriberTests.swift -o /tmp/JingduSubtitleTests.app/Contents/MacOS/SubtitleTests

Generate new synthetic speech only if needed; never substitute private user media:
  /usr/bin/say -v Samantha -r 150 -o /tmp/jingdu-synthetic.aiff \
    'Today we test automatic subtitles. The camera moves slowly across the room. A woman opens the window and looks at the morning sky.'
  /tmp/JingduSubtitleTests.app/Contents/MacOS/SubtitleTests --audio /tmp/jingdu-synthetic.aiff --expect-languages en
Other optional invocations (use the same probe executable):
  --audio /tmp/jingdu-synthetic.aiff --montage --expect-languages en
  --audio /tmp/jingdu-synthetic.aiff --cancel
  --audio /tmp/synthetic-japanese-padded-tail.wav --fractional-tail --expect-languages ja
  --audio /tmp/synthetic-en-then-zh.wav --expect-languages en,zh
  --audio /tmp/synthetic-silence.wav --expect-error 静音
  --audio /tmp/synthetic-video-without-audio.mp4 --expect-error 没有原声音轨
The montage probe trims/repeats the supplied source, mutes project playback volume,
and adds a nonexistent music path to verify that only original video audio is read.
*/
@main
struct SubtitleTranscriberTests {
    private static var assertions = 0
    private typealias Segment = (from: Double, to: Double, text: String)

    static func main() async throws {
        try originalLanguagesAndOffsets()
        try observedPaddingRegression()
        try zeroDurationBoundaryRegression()
        try emptyAndMarkerResults()
        try rejectedResponses()
        print("Subtitle transcriber offline tests passed (\(assertions) assertions; no model or media required).")
        if CommandLine.arguments.count > 1 { try await integration(arguments: Array(CommandLine.arguments.dropFirst())) }
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(value(), message)
    }
    private static func near(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 0.000_001 }
    private static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Must reject: \(message)") }
        catch { expect(!error.localizedDescription.isEmpty, message) }
    }
    private static func output(_ language: String = "en", _ segments: [Segment]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "result": ["language": language],
            "transcription": segments.map { ["offsets": ["from": $0.from, "to": $0.to], "text": $0.text] as [String: Any] }
        ])
    }
    private static func parse(_ language: String = "en", _ segments: [Segment], offset: Double = 0,
                              duration: Double = 10, requested: SubtitleLanguage? = nil) throws -> [SubtitleCue] {
        try SubtitleTranscriber.parse(data: output(language, segments), offset: offset, duration: duration,
                                       requestedLanguage: requested)
    }

    private static func originalLanguagesAndOffsets() throws {
        // These strings are from the six synthetic-voice trials, not fabricated translations.
        let originals: [(SubtitleLanguage, String)] = [
            (.zh, "今天我们测试自动字幕。"), (.en, "Today we are testing automatic subtitles."),
            (.ja, "今日は自動字幕のテストを行います"), (.ko, "오늘은 자동 자막 기능을 테스트 합니다."),
            (.es, "probamos los subtítulos automáticos."), (.fr, "Aujourd'hui nous testons les sous-titres automatiques.")
        ]
        for (language, text) in originals {
            let cues = try parse(language.rawValue, [(1000, 2500, "  \(text)\n")], offset: 30, duration: 4)
            expect(cues.count == 1, "Each of six supported language identifiers is accepted")
            expect(cues[0].language == language && cues[0].text == text, "Original language/text is preserved, with boundary whitespace trimmed")
            expect(near(cues[0].start, 31) && near(cues[0].end, 32.5), "Millisecond offsets become project seconds")
            expect(cues[0].chineseText.isEmpty, "ASR never fabricates a Chinese translation, including for Chinese input")
        }
        let english = try parse("en", [(0, 2920, "Today we are testing automatic subtitles.")], duration: 30)
        let chinese = try parse("zh", [(0, 14800, "今天我们测试自动字幕。")], offset: 30, duration: 14.8988125)
        expect(english[0].language == .en && chinese[0].language == .zh, "Different windows keep different detected languages")
        expect(near(chinese[0].start, 30) && near(chinese[0].end, 44.8), "Chinese second-window cues receive exactly one window offset")
        expect(english[0].id != chinese[0].id, "Separate cues receive distinct identities")
        let override = try parse("fr", [(0, 1000, "Bonjour")], requested: .fr)
        expect(override[0].language == .fr, "A matching explicit language is accepted")
        let fractional = try parse("en", [(1250, 2875, "Fractional timing")], offset: 60.125)
        expect(near(fractional[0].start, 61.375) && near(fractional[0].end, 63), "Fractional project offsets are retained")
    }

    private static func observedPaddingRegression() throws {
        // Actual short Japanese synthetic WAV: 15.5500625 s. Whisper predicted
        // a final end of 17.36 s because the model operates on a padded 30 s window.
        let japanese = try parse("ja", [(0, 8300, "今日は自動字幕のテストを行います"),
                                        (8300, 17360, "女性が窓を開けて朝の空を見ています")],
                                 offset: 60, duration: 15.5500625)
        expect(japanese.count == 2, "A real padded Japanese tail is retained")
        expect(near(japanese[0].end, 68.3) && near(japanese[1].start, 68.3), "Interior Japanese boundary is unchanged")
        expect(near(japanese[1].end, 75.5500625), "Padded end is clipped to actual source duration")
        let french = try parse("fr", [(0, 3000, "Aujourd'hui nous testons les sous-titres automatiques."),
                                      (3000, 7000, "Cet enregistrement a été créé pour tester un logiciel."),
                                      (7000, 10000, "La caméra se déplace lentement dans la pièce."),
                                      (10000, 14000, "Une femme ouvre la fenêtre.")], duration: 13.51025)
        expect(near(french.last!.end, 13.51025), "Observed French padding is clipped too")
        let betweenSamples = try parse("ja", [(8300, 17360, "女性が窓を開けて朝の空を見ています")],
                                       offset: 30, duration: 15.5500525)
        expect(betweenSamples[0].end <= 45.5500525, "Padding respects a true source end between 16 kHz sample boundaries")
        let quantized = try parse("en", [(0, 2000, "First"), (1990, 3000, "Second")])
        expect(near(quantized[1].start, 2), "One timestamp-quantization step is normalized without an overlap")
        expect(zip(japanese, japanese.dropFirst()).allSatisfy { $0.end <= $1.start }, "Normalized output stays ordered and disjoint")
        // The following raw timestamps reproduce the observed failure. All text is
        // synthetic placeholder content; no user transcript is stored in this test.
        let observed: [(from: Double, to: Double, offset: Double)] = [
            (28320, 30320, 30), (29320, 30400, 60), (28640, 30080, 90)
        ]
        for (index, timing) in observed.enumerated() {
            let cues = try parse("zh", [(timing.from, timing.to, "合成占位末句\(index + 1)")],
                                 offset: timing.offset, duration: 30)
            expect(cues.count == 1, "A slightly overflowing decoded tail is retained")
            expect(near(cues[0].start, timing.offset + timing.from / 1000), "The real tail start is unchanged")
            expect(near(cues[0].end, timing.offset + 30), "Observed 30.32/30.40/30.08 ends clip to the local 30-second boundary")
        }
        let severalPadded = try parse("ja", [(0, 17360, "valid prefix"), (17360, 18000, "padding only")],
                                     duration: 15.5500625)
        expect(severalPadded.count == 1 && severalPadded[0].text == "valid prefix", "A nonfinal segment is clipped and a wholly padded successor is discarded")
        expect(near(severalPadded[0].end, 15.5500625), "Nonfinal padding never extends the subtitle beyond actual audio")
        let overflowThenPadding = try parse("zh", [(28320, 30320, "合成有效末句"), (30320, 31400, "合成补齐区间文本")], duration: 30)
        expect(overflowThenPadding.count == 1 && near(overflowThenPadding[0].end, 30), "The valid intersection survives even with subsequent padded segments")
        let allPadding = try parse("en", [(10000, 11000, "outside the audio"), (11000, 12000, "also outside")], duration: 10)
        expect(allPadding.isEmpty, "Captions beginning at or after real duration have no display interval")
        let shiftedWindow = try parse("en", [(29000, 60000, "synthetic decoder-window tail")], duration: 30)
        expect(shiftedWindow.count == 1 && near(shiftedWindow[0].end, 30), "An internal seek plus one decoder window is bounded and clipped")
        rejects("Raw time beyond actual duration plus one decoder window") {
            _ = try parse("ja", [(8300, 46000, "tail")], duration: 15.5500625)
        }
        rejects("Raw time beyond the maximum bound for a full input window") {
            _ = try parse("en", [(29000, 61000, "tail")], duration: 30)
        }
    }

    private static func zeroDurationBoundaryRegression() throws {
        let trailing = try parse("en", [(0, 2000, "First"), (2000, 2000, "second"), (2000, 3000, "Third")])
        expect(trailing.count == 2, "A zero-duration fragment at a shared boundary merges into its predecessor")
        expect(trailing[0].text.contains("First") && trailing[0].text.contains("second") && trailing[1].text == "Third", "Trailing fragment text is retained without duplication")
        expect(near(trailing[0].start, 0) && near(trailing[0].end, 2) && near(trailing[1].start, 2), "Merging text does not create or extend any interval")
        let leading = try parse("en", [(1000, 1000, "First"), (1000, 2500, "second")], offset: 30)
        expect(leading.count == 1 && leading[0].text.contains("First") && leading[0].text.contains("second"), "A leading fragment joins the following cue at the same boundary")
        expect(near(leading[0].start, 31) && near(leading[0].end, 32.5), "Leading fragment receives only its neighbor's real interval")
        let chain = try parse("en", [(1000, 1000, "First"), (1000, 1000, "second"), (1000, 2000, "third")])
        expect(chain.count == 1 && ["First", "second", "third"].allSatisfy { chain[0].text.contains($0) }, "Consecutive same-boundary fragments preserve all text")
        let nearPrevious = try parse("en", [(0, 2000, "First"), (2010, 2010, "second")])
        expect(nearPrevious.count == 1 && near(nearPrevious[0].end, 2), "A fragment within 20 ms of the previous boundary does not lengthen it")
        let nearNext = try parse("en", [(1000, 1000, "First"), (1010, 2000, "second")])
        expect(nearNext.count == 1 && near(nearNext[0].start, 1.01), "A leading fragment within 20 ms uses the next actual start")
        expect(leading[0].language == .en && leading[0].chineseText.isEmpty, "Boundary repair changes neither language nor translation")
        for (label, segments) in [
            ("isolated zero-duration text", [(1000.0, 1000.0, "isolated")]),
            ("zero-duration text distant from predecessor", [(0.0, 1000.0, "first"), (1500.0, 1500.0, "distant")]),
            ("zero-duration text distant from successor", [(1000.0, 1000.0, "distant"), (2000.0, 3000.0, "next")]),
            ("zero-duration text within a cue but away from its boundary", [(0.0, 2000.0, "first"), (1500.0, 1500.0, "inside")])
        ] {
            rejects(label) { _ = try parse("en", segments) }
        }
        rejects("Boundary merge cannot exceed the caption text limit") {
            _ = try parse("en", [(0, 2000, String(repeating: "x", count: 4999)), (2000, 2000, "additional text")])
        }
    }

    private static func emptyAndMarkerResults() throws {
        let empty = try parse("en", [])
        expect(empty.isEmpty, "An empty response stays empty for the pipeline's explicit no-speech error")
        let markers = try parse("en", [(0, 500, " \n "), (500, 1000, "[BLANK_AUDIO]"),
                                      (1000, 1500, "[Music]"), (1500, 2000, "[音楽]")])
        expect(markers.isEmpty, "Silence and known music markers do not become speech captions")
        let emptyTimes = try parse("en", [(0, 0, " "), (0, 0, "[BLANK_AUDIO]"),
                                         (0, 0, "[Music]"), (0, 0, "[音楽]"), (0, 1000, "Real speech")])
        expect(emptyTimes.count == 1 && emptyTimes[0].text == "Real speech", "Non-speech zero-duration markers are filtered before interval validation")
        let markerAtTail = try parse("en", [(30000, 30000, "[BLANK_AUDIO]"), (0, 1000, "Real speech")], duration: 30)
        expect(markerAtTail.count == 1 && near(markerAtTail[0].start, 0), "Skipped markers cannot advance chronology or invalidate later real speech")
    }

    private static func rejectedResponses() throws {
        for identifier in ["de", "unknown", "", "en-US"] {
            rejects("Unsupported language \(identifier) is not silently mapped to English") {
                _ = try parse(identifier, [(0, 1000, "speech")])
            }
        }
        rejects("Explicit source-language mismatch") { _ = try parse("en", [(0, 1000, "hello")], requested: .ja) }
        let invalid: [(String, [Segment])] = [
            ("negative start", [(-1, 1000, "speech")]),
            ("zero duration without a matching neighbor", [(1000, 1000, "speech")]),
            ("reversed range", [(2000, 1000, "speech")]),
            ("large model-window overrun", [(0, 99000, "speech")]),
            ("overlap beyond quantization tolerance", [(0, 2000, "first"), (1900, 3000, "second")]),
            ("reverse chronological order", [(3000, 4000, "later"), (0, 2000, "earlier")]),
            ("oversized caption", [(0, 1000, String(repeating: "字", count: 5001))]),
            ("null byte in caption", [(0, 1000, "bad\u{0000}text")])
        ]
        for (label, segments) in invalid { rejects(label) { _ = try parse("en", segments) } }
        for (offset, duration) in [(Double.nan, 10.0), (Double.infinity, 10), (-1, 10),
                                   (0, Double.nan), (0, Double.infinity), (0, 0), (0, -1), (0, 30.001)] {
            rejects("Invalid offset/duration \(offset)/\(duration)") {
                _ = try parse("en", [(0, 1000, "speech")], offset: offset, duration: duration)
            }
        }
        for text in ["not json", "{}", #"{"result":{"language":"en"}}"#,
                     #"{"result":{"language":"en"},"transcription":[{"offsets":{"from":"0","to":1000},"text":"bad"}]}"#,
                     #"{"result":{"language":"en"},"transcription":[{"offsets":{"from":NaN,"to":1000},"text":"bad"}]}"#] {
            rejects("Malformed or incomplete response") {
                _ = try SubtitleTranscriber.parse(data: Data(text.utf8), offset: 0, duration: 10, requestedLanguage: nil)
            }
        }
        rejects("More than 2000 segments in one window") {
            _ = try parse("en", Array(repeating: (0, 1, "x"), count: 2001))
        }
        rejects("Oversized JSON input") {
            _ = try SubtitleTranscriber.parse(data: Data(repeating: 32, count: 5_000_001), offset: 0,
                                               duration: 10, requestedLanguage: nil)
        }
    }

    private static func integration(arguments: [String]) async throws {
        var audio: String?, expectedError: String?, languages: Set<SubtitleLanguage> = []
        var cancel = false, montage = false, fractionalTail = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]; index += 1
            if argument == "--cancel" { cancel = true; continue }
            if argument == "--montage" { montage = true; continue }
            if argument == "--fractional-tail" { fractionalTail = true; continue }
            guard ["--audio", "--expect-error", "--expect-languages"].contains(argument), index < arguments.count else {
                throw ProbeError("Unknown option or missing value: \(argument)")
            }
            let value = arguments[index]; index += 1
            switch argument {
            case "--audio": audio = value
            case "--expect-error": expectedError = value
            default:
                for code in value.split(separator: ",") {
                    guard let language = SubtitleLanguage(rawValue: String(code)) else { throw ProbeError("Unsupported expected language: \(code)") }
                    languages.insert(language)
                }
            }
        }
        guard let audio, !cancel || expectedError == nil else { throw ProbeError("Use --audio PATH and at most one of --cancel/--expect-error") }
        let url = URL(fileURLWithPath: audio)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        var project = FilmProject(title: "Explicit synthetic subtitle fixture", sourcePath: url.path,
                                  duration: duration, frameRate: 30, width: 320, height: 180, cuts: [], notes: [])
        if montage {
            guard duration > 1 else { throw ProbeError("Montage fixture must exceed one second") }
            let selection = min(9, duration)
            project.clips = [(0.0, selection), (duration - selection, duration)].enumerated().map { index, range in
                VideoClip(title: "Synthetic trim \(index)", sourcePath: url.path, sourceDuration: duration,
                          sourceIn: range.0, sourceOut: range.1, frameRate: 30, width: 320, height: 180)
            }
            project.duration = selection * 2
            project.originalVolume = 0
            project.music = [MusicClip(title: "Must not be opened", sourcePath: "/missing-jingdu-test-music/\(UUID().uuidString).wav",
                                      sourceDuration: 10, sourceIn: 0, sourceOut: 10, timelineStart: 0)]
        }
        if fractionalTail {
            guard duration > 1, !montage else { throw ProbeError("Fractional-tail fixture must exceed one second and cannot combine with --montage") }
            // Choose a boundary just before a real PCM sample. The previous engine
            // rounded it up and could return a final padded cue beyond the project.
            project.duration = floor(duration * 16_000) / 16_000 - 0.000_01
            project.clips = [VideoClip(title: "Synthetic fractional tail", sourcePath: url.path, sourceDuration: duration,
                                      sourceIn: 0, sourceOut: project.duration, frameRate: 30, width: 320, height: 180)]
        }
        let initialTemporaryFolders = temporaryFolders()
        let task = Task {
            try await SubtitleTranscriber.transcribe(project: project, language: nil) { progress, message in
                print(String(format: "%.2f", progress), message)
            }
        }
        if cancel { try await Task.sleep(nanoseconds: 400_000_000); task.cancel() }
        do {
            let cues = try await task.value
            expect(!cancel && expectedError == nil, "Requested cancellation/error must not return successful subtitles")
            expect(!cues.isEmpty, "Actual ASR produced original subtitles")
            expect(cues.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= project.duration && $0.chineseText.isEmpty },
                   "Actual ASR cues have valid project bounds and no fabricated translations")
            expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start }, "Actual ASR output is ordered without overlaps")
            if !languages.isEmpty { expect(Set(cues.map(\.language)) == languages, "Detected languages match the synthetic fixture") }
            if fractionalTail {
                expect(cues.last!.end <= project.duration, "Padded final cue cannot round beyond a non-sample-aligned project end")
                expect(near(cues.last!.end, project.duration), "The fractional-tail fixture must exercise a padded final cue")
                let storageCues = cues.map { cue -> SubtitleCue in
                    var value = cue
                    // Explicit test-only placeholder supplies the separate translation
                    // field so persistence can exercise the actual snapshot time bound.
                    if value.language != .zh { value.chineseText = "时间边界回归的测试占位译文" }
                    return value
                }
                let track = SubtitleTrack(sourceClips: project.videoClips, cues: storageCues,
                                          sourceDescription: "Synthetic fractional-tail persistence regression")
                try ProjectPersistence.validateSubtitleTrack(track)
                expect(true, "The final cue passes persistence's exact source-snapshot duration check")
                print("Fractional tail: project=\(project.duration), final cue=\(cues.last!.end)")
            }
            for cue in cues { print(cue.start, cue.end, cue.language.rawValue, cue.text) }
        } catch is CancellationError {
            expect(cancel, "Cancellation was explicitly requested")
            print("PASS: cancellation")
        } catch {
            guard let expectedError else { throw error }
            expect(error.localizedDescription.contains(expectedError), "Expected failure reason, not an unrelated engine/model error")
            print("PASS: expected error:", error.localizedDescription)
        }
        expect(temporaryFolders().subtracting(initialTemporaryFolders).isEmpty, "No extracted audio or result directory remains after completion/failure/cancellation")
        print("Subtitle transcriber integration passed; fixture only, no network.")
    }
    private static func temporaryFolders() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(contents.filter { $0.hasPrefix("jingdu-subtitles-") })
    }
    private struct ProbeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
