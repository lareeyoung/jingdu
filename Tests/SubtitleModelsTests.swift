import Foundation

/// swiftc -swift-version 5 Sources/Models.swift Sources/SubtitleModels.swift Tests/SubtitleModelsTests.swift -o /tmp/jingdu-subtitle-model-tests
@main
struct SubtitleModelsTests {
    private static var assertions = 0
    private static let date = Date(timeIntervalSince1970: 1_750_000_000)

    static func main() throws {
        try migrationAndRoundTrip()
        try validation()
        try snapshotAndEditing()
        try timingAndExport()
        print("Subtitle model tests passed (\(assertions) assertions; no network, media, or library I/O).")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(value(), message)
    }

    private static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Must reject: \(message)") }
        catch { expect(!error.localizedDescription.isEmpty, message) }
    }

    private static func fixture() -> FilmProject {
        let clips = ["first", "second"].map { name in
            VideoClip(title: name, sourcePath: "/subtitle-fixture/\(name).mp4", sourceDuration: 9,
                      sourceIn: 1, sourceOut: 7, frameRate: 24, width: 640, height: 360)
        }
        var project = SequenceLogic.makeProject(title: "独立字幕", clips: clips)
        project.createdAt = date; project.updatedAt = date
        return project
    }

    private static func track(_ project: FilmProject) -> SubtitleTrack {
        let originals = ["你好", "Hello", "こんにちは", "안녕하세요", "Hola", "Bonjour"]
        let cues = SubtitleLanguage.allCases.enumerated().map { index, language in
            SubtitleCue(start: Double(index * 2), end: Double(index * 2) + 1.5,
                        language: language, text: originals[index], chineseText: language == .zh ? "" : "你好")
        }
        return SubtitleTrack(createdAt: date, sourceClips: project.videoClips, cues: cues,
                             sourceDescription: "隔离测试：原声转写与中文翻译")
    }

    private static func migrationAndRoundTrip() throws {
        var project = fixture()
        var legacy = try JSONSerialization.jsonObject(with: ProjectPersistence.encodeProject(project)) as! [String: Any]
        legacy.removeValue(forKey: "subtitleTrack")
        let old = try ProjectPersistence.decodeProject(JSONSerialization.data(withJSONObject: legacy))
        expect(old.subtitleTrack == nil && old.id == project.id, "Old projects decode without creating fake subtitles")
        legacy["subtitleTrack"] = NSNull()
        let explicitNull = try ProjectPersistence.decodeProject(JSONSerialization.data(withJSONObject: legacy))
        expect(explicitNull.subtitleTrack == nil, "Explicit null subtitle tracks remain absent")
        project.subtitleTrack = track(project)
        let restored = try ProjectPersistence.decodeProject(ProjectPersistence.encodeProject(project))
        expect(restored == project, "Project round trip preserves subtitle text, IDs, source snapshots, language, and timestamps")
        expect(SubtitleLanguage.allCases.map(\.rawValue) == ["zh", "en", "ja", "ko", "es", "fr"], "Six requested language identifiers are stable")
        expect(SubtitleLanguage.allCases.allSatisfy { !$0.title.isEmpty }, "Every language has a readable title")
        var object = try JSONSerialization.jsonObject(with: ProjectPersistence.encodeProject(project)) as! [String: Any]
        var subtitle = object["subtitleTrack"] as! [String: Any]
        var cues = subtitle["cues"] as! [[String: Any]]
        cues[0]["language"] = "invented"
        subtitle["cues"] = cues; object["subtitleTrack"] = subtitle
        rejects("Unknown persisted language is not guessed") {
            _ = try ProjectPersistence.decodeProject(JSONSerialization.data(withJSONObject: object))
        }
    }

    private static func validation() throws {
        let project = fixture(), valid = track(fixture())
        try ProjectPersistence.validateSubtitleTrack(valid)
        func invalid(_ label: String, _ change: (inout SubtitleTrack) -> Void) {
            var value = valid; change(&value)
            rejects(label) { try ProjectPersistence.validateSubtitleTrack(value) }
            var stored = project; stored.subtitleTrack = value
            rejects("Project persistence rejects \(label)") { _ = try ProjectPersistence.encodeProject(stored) }
        }
        invalid("nonfinite start") { $0.cues[0].start = .nan }
        invalid("infinite end") { $0.cues[0].end = .infinity }
        invalid("negative start") { $0.cues[0].start = -1 }
        invalid("empty interval") { $0.cues[0].end = $0.cues[0].start }
        invalid("reversed interval") { $0.cues[0].end = -1 }
        invalid("beyond original snapshot") { $0.cues[5].end = 12.001 }
        invalid("overlapping cues") { $0.cues[1].start = 1 }
        invalid("unsorted cues") { $0.cues.swapAt(0, 1) }
        invalid("duplicate cue IDs") { $0.cues[1].id = $0.cues[0].id }
        invalid("empty original text") { $0.cues[0].text = " \n " }
        invalid("original text exceeds 5000 characters") { $0.cues[0].text = String(repeating: "字", count: 5_001) }
        invalid("Chinese text exceeds 5000 characters") { $0.cues[1].chineseText = String(repeating: "字", count: 5_001) }
        invalid("foreign subtitle lacks Chinese") { $0.cues[1].chineseText = " \n " }
        invalid("foreign subtitle repeats only foreign text") { $0.cues[1].chineseText = "Hello" }
        invalid("Chinese subtitle has conflicting second translation") { $0.cues[0].chineseText = "完全不同的内容" }
        invalid("text contains a null character") { $0.cues[0].text += "\0" }
        invalid("invalid creation date") { $0.createdAt = Date(timeIntervalSince1970: .infinity) }
        invalid("empty provenance") { $0.sourceDescription = " " }
        invalid("missing snapshot") { $0.sourceClips = [] }
        invalid("duplicate snapshot IDs") { $0.sourceClips[1].id = $0.sourceClips[0].id }
        invalid("nonfinite source duration") { $0.sourceClips[0].sourceDuration = .nan }
        invalid("invalid source range") { $0.sourceClips[0].sourceOut = 10 }
        invalid("relative source path") { $0.sourceClips[0].sourcePath = "video.mp4" }

        var boundary = valid
        boundary.cues[0].text = String(repeating: "字", count: 5_000)
        boundary.cues[1].chineseText = String(repeating: "字", count: 5_000)
        try ProjectPersistence.validateSubtitleTrack(boundary)
        expect(true, "Exactly 5000 text characters are allowed")
        boundary = valid; boundary.cues[0].chineseText = boundary.cues[0].text
        try ProjectPersistence.validateSubtitleTrack(boundary)
        expect(boundary.cues[0].lines(mode: .bilingual) == ["你好"], "Duplicate Chinese transcript remains one displayed line")
        boundary = valid
        boundary.sourceClips = [VideoClip(title: "long", sourcePath: "/subtitle-fixture/long.mp4",
            sourceDuration: 10_002, sourceIn: 0, sourceOut: 10_002, frameRate: 24, width: 640, height: 360)]
        boundary.cues = (0..<5_000).map { SubtitleCue(start: Double($0 * 2), end: Double($0 * 2 + 1),
                                                   language: .zh, text: "测试", chineseText: "") }
        try ProjectPersistence.validateSubtitleTrack(boundary)
        expect(true, "Exactly 5000 unique sorted cues are allowed")
        boundary.cues.append(SubtitleCue(start: 10_000, end: 10_001, language: .zh, text: "超限", chineseText: ""))
        rejects("More than 5000 cues are rejected") { try ProjectPersistence.validateSubtitleTrack(boundary) }
        var silent = valid; silent.cues = []
        try ProjectPersistence.validateSubtitleTrack(silent)
        let silentExport = try silent.exportSRT()
        expect(silentExport.isEmpty, "Silence can retain an empty track without inventing dialogue")
    }

    private static func snapshotAndEditing() throws {
        var project = fixture(); let original = track(project); project.subtitleTrack = original
        expect(original.isCurrent(for: project), "Fresh subtitles match their original video sequence")
        var renamed = project
        renamed.title = "新项目名称"; renamed.clips[0].title = "新素材名称"; renamed.clips[0].id = UUID()
        renamed.clips[0].sourceProjectTitle = "新来源名"
        renamed.originalVolume = 0
        renamed.music = [MusicClip(title: "music", sourcePath: "/subtitle-fixture/music.wav", sourceDuration: 2,
                                  sourceIn: 0, sourceOut: 2, timelineStart: 0)]
        expect(original.isCurrent(for: renamed), "Rename, new clip IDs, background music, and playback volume do not stale original speech")
        let split = ProjectLogic.split(project, at: 3)
        expect(original.isCurrent(for: split), "Marking a shot boundary does not change subtitle timing")
        let trimmed = SequenceLogic.trimClip(project, id: project.videoClips[0].id, sourceIn: 2, sourceOut: 7)
        expect(trimmed.subtitleTrack == original && !original.isCurrent(for: trimmed), "Trim retains the historical track but marks it stale")
        _ = try ProjectPersistence.encodeProject(trimmed)
        expect(true, "Stale subtitles validate against original source duration rather than the shortened project")
        let reordered = SequenceLogic.moveClip(project, id: project.videoClips[0].id, delta: 1)
        expect(!original.isCurrent(for: reordered), "Reordering source clips invalidates the current association")
        var appended = project; var extra = project.clips[0]; extra.id = UUID(); appended.clips.append(extra)
        appended = SequenceLogic.recalculate(appended)
        expect(!original.isCurrent(for: appended), "Appending footage invalidates the old full-sequence snapshot")
        let extracted = SequenceLogic.makeProject(title: "灵感片段", clips: SequenceLogic.extract(project, start: 2, end: 5), kind: .remix)
        expect(extracted.subtitleTrack == nil, "Extracted remix projects do not inherit incorrectly offset source subtitles")
        var replaced = project; replaced.clips[0].sourcePath = "/subtitle-fixture/replacement.mp4"
        expect(!original.isCurrent(for: replaced), "Replacing a source path invalidates the association")
    }

    private static func timingAndExport() throws {
        var value = track(fixture())
        let first = value.cues[0], second = value.cues[1]
        expect(value.activeCue(at: 0)?.id == first.id && value.activeCue(at: 1)?.id == first.id, "Cue begins inclusively")
        expect(value.activeCue(at: 1.5) == nil && value.activeCue(at: 1.9) == nil, "Cue end and following silence have no subtitle")
        expect(value.activeCue(at: 2)?.id == second.id, "Later cue starts match exactly")
        expect(value.activeCue(at: 11.5) == nil && value.activeCue(at: 12) == nil, "Final cue end is exclusive")
        for time in [Double.nan, .infinity, -.infinity, -1] { expect(value.activeCue(at: time) == nil, "Invalid playback time has no caption") }
        value.cues = [SubtitleCue(start: 0.001, end: 1.001, language: .en, text: "Don't touch it!", chineseText: "别摸它！"),
                      SubtitleCue(start: 1.9996, end: 3.125, language: .zh, text: "你好", chineseText: "你好")]
        let bilingual = try value.exportSRT(mode: .bilingual)
        expect(bilingual == "1\n00:00:00,001 --> 00:00:01,001\nDon't touch it!\n别摸它！\n\n2\n00:00:02,000 --> 00:00:03,125\n你好\n",
               "SRT uses numbered blocks, rounded milliseconds, bilingual lines, and one Chinese line")
        let original = try value.exportSRT(mode: .original), chinese = try value.exportSRT(mode: .chinese)
        expect(original.contains("Don't touch it!") && !original.contains("别摸它！") && original.contains("你好"), "Original export preserves each cue's source language")
        expect(chinese.contains("别摸它！") && !chinese.contains("Don't touch it!") && chinese.contains("你好"), "Chinese export uses translations and original Chinese")
        value.cues[0].end = .nan
        rejects("SRT export rejects invalid time rather than inventing a timestamp") { _ = try value.exportSRT() }
        value.cues[0].start = 0; value.cues[0].end = 0.0001
        rejects("Unrepresentable submillisecond intervals are not silently stretched") { _ = try value.exportSRT() }
    }
}
