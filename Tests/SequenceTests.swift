import Foundation

/// Model/migration tests. The default suite performs no library I/O.
/// swiftc -swift-version 5 Sources/Models.swift Tests/SequenceTests.swift -o /tmp/jingdu-sequence-tests
/// /tmp/jingdu-sequence-tests
///
/// Optional persistence smoke test, restricted to an empty /tmp test directory:
/// JINGDU_LIBRARY_DIRECTORY=/tmp/jingdu-isolated-library /tmp/jingdu-sequence-tests --isolated-storage
/// The same environment variable isolates the native app's library.json. A missing,
/// empty or relative value leaves the normal user-library location unchanged, so
/// the persistence test refuses to run unless a safe absolute /tmp path is set.
@main
struct SequenceTests {
    private static var assertions = 0

    static func main() throws {
        try migration()
        displayTitles()
        try layoutAndExtraction()
        try moveAndRemap()
        try trimAndRemove()
        try musicAndRecalculation()
        try fractionalBoundaries()
        try validation()
        if CommandLine.arguments.contains("--isolated-storage") { try isolatedStorage() }
        print("Sequence and legacy migration regressions passed (\(assertions) assertions; user library untouched).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }

    private static func clip(_ name: String, _ sourceIn: Double, _ sourceOut: Double, fps: Double = 30) -> VideoClip {
        VideoClip(title: name, sourcePath: "/tmp/jingdu-sequence-fixture-\(name).mp4", sourceDuration: 20,
                  sourceIn: sourceIn, sourceOut: sourceOut, frameRate: fps, width: 1920, height: 1080)
    }

    private static func fixture() -> FilmProject {
        let clips = [clip("A", 1, 5), clip("B", 5, 8, fps: 24), clip("C", 0, 2, fps: 60)]
        var p = SequenceLogic.makeProject(title: "镜头复用练习", clips: clips, kind: .remix)
        p.cuts = [2, 5, 8]
        p.notes = [
            StudyNote(start: 1, end: 2, track: .camera, title: "A笔记", body: "A片段原理", takeaway: "保留原画面的对应关系"),
            StudyNote(start: 4.5, end: 5.5, track: .story, title: "B笔记", body: "B片段原理", takeaway: ""),
            StudyNote(start: 3.5, end: 4.5, track: .learning, title: "跨素材", body: "前后关系", takeaway: "复用衔接方法"),
            StudyNote(start: 4, end: 4, track: .sound, title: "接缝点", body: "后一素材开头", takeaway: ""),
            StudyNote(start: 9, end: 9, track: .sound, title: "全片末尾", body: "末尾留白", takeaway: "")
        ]
        p.createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        p.updatedAt = p.createdAt
        return p
    }

    private static func migration() throws {
        // Exact 1.0.1 JSON shape: the new stored fields are genuinely absent.
        let legacy = Data("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "旧版学习笔记", "sourcePath": "/tmp/legacy.mp4",
          "duration": 10, "frameRate": 30, "width": 1920, "height": 1080,
          "cuts": [3, 6], "notes": [{
            "id": "22222222-2222-2222-2222-222222222222",
            "start": 2, "end": 4, "track": "camera", "title": "旧标题",
            "body": "旧笔记原文不能丢失。", "takeaway": "复用观察方法。"
          }],
          "createdAt": "2025-06-15T15:06:40Z", "updatedAt": "2025-06-15T15:06:40Z",
          "isDemo": false
        }
        """.utf8)
        let p = try ProjectPersistence.decodeProject(legacy)
        expect(p.kind == .study && p.clips.isEmpty && p.music.isEmpty && p.originalVolume == 1, "Old projects receive compatible defaults")
        expect(p.title == "旧版学习笔记" && p.notes[0].body == "旧笔记原文不能丢失。", "Migration preserves legacy titles and note text")
        expect(p.cuts == [3, 6] && p.shots.count == 3, "Migration preserves old cut placement")
        expect(p.videoClips.count == 1 && p.videoClips[0].id == p.id, "Legacy clip identity is the stable project ID")
        expect(p.videoClips[0] == p.videoClips[0], "Repeated compatibility access never generates a new clip ID")
        expect(p.clipPlacements[0].start == 0 && p.clipPlacements[0].end == 10, "Legacy clip placement covers the original film")
        let reloaded = try ProjectPersistence.decodeProject(ProjectPersistence.encodeProject(p))
        expect(reloaded == p, "Legacy project survives re-export and decode without data changes")

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let arrayData = Data("[".utf8) + legacy + Data("]".utf8)
        let array = try decoder.decode([FilmProject].self, from: arrayData)
        expect(array == [p], "The original library array JSON migrates without using library.load")

        let trimmed = SequenceLogic.trimClip(p, id: p.id, sourceIn: 1, sourceOut: 9)
        expect(trimmed.clips.count == 1 && trimmed.clips[0].id == p.id, "Converting a legacy clip to an explicit sequence keeps its stable identity")
        expect(trimmed.notes[0].start == 1 && trimmed.notes[0].end == 3, "Legacy notes remap by source position when the compatibility clip is trimmed")
        _ = try ProjectPersistence.encodeProject(trimmed)
    }

    private static func displayTitles() {
        var note = StudyNote(start: 2, end: 3, track: .sound, title: "  声音先入  ", body: "正文首行\n第二行", takeaway: "启发")
        expect(note.hasContent && note.displayTitle == "声音先入", "Explicit titles have priority and are trimmed")
        note.title = "\n "
        expect(note.displayTitle == "正文首行", "Untitled notes use the first body line")
        note.body = "\n  \n"
        note.takeaway = "  先让观众听见下一场景 \n 第二行"
        expect(note.displayTitle == "先让观众听见下一场景", "Takeaway supplies a title when body is blank")
        note.takeaway = " "
        expect(!note.hasContent && note.displayTitle == "声音设计 · 00:00:02:00", "An empty marker has a meaningful track and time label")
    }

    private static func layoutAndExtraction() throws {
        let p = fixture()
        expect(p.duration == 9 && p.kind == .remix, "Sequence length is the sum of source ranges")
        expect(p.sourcePath == p.clips[0].sourcePath, "Compatibility path points to the first clip")
        expect(p.clipPlacements.map(\.start) == [0, 4, 7] && p.clipPlacements.map(\.end) == [4, 7, 9], "Sequential placement has no gaps or overlaps")
        expect(p.shots.map(\.start) == [0, 2, 4, 5, 7, 8], "Source seams are mandatory shot boundaries even when not in cuts")
        expect(ProjectLogic.removeCut(p, at: 4).shots.contains(where: { $0.start == 4 }), "Removing a manual cut cannot merge across a source seam")

        let extracted = SequenceLogic.extract(p, start: 3, end: 8)
        expect(extracted.count == 3, "A cross-source extraction splits at every source seam")
        expect(extracted.map(\.sourceIn) == [4, 5, 0] && extracted.map(\.sourceOut) == [5, 8, 1], "Extraction maps timeline ranges back into the correct source coordinates")
        expect(extracted.reduce(0) { $0 + $1.duration } == 5, "Extracted pieces cover exactly the requested duration")
        expect(Set(extracted.map(\.id)).isDisjoint(with: Set(p.clips.map(\.id))), "Extracted pieces receive new identities")
        expect(extracted.allSatisfy { $0.sourceProjectID == p.id && $0.sourceProjectTitle == p.title }, "Extraction records project provenance")
        let derived = SequenceLogic.makeProject(title: "二次复用", clips: extracted, kind: .remix)
        let again = SequenceLogic.extract(derived, start: 0, end: 1)
        expect(again[0].sourceProjectID == p.id && again[0].sourceProjectTitle == p.title, "Re-extraction preserves the original provenance")
        expect(SequenceLogic.extract(p, start: 5, end: 2).isEmpty && SequenceLogic.extract(p, start: .nan, end: 4).isEmpty, "Invalid extraction ranges are safely rejected")
        expect(SequenceLogic.extract(p, start: -10, end: 100).reduce(0) { $0 + $1.duration } == 9, "Extraction bounds clamp to the available sequence")
        expect(SequenceLogic.extract(p, start: 4, end: 7).count == 1, "Exact seam extraction does not produce empty adjacent pieces")

        var mixed = SequenceLogic.makeProject(title: "混合帧率", clips: [clip("fractional", 0, 1.0 / 24, fps: 24), clip("sixty", 0, 1, fps: 60)])
        let seam = 1.0 / 24
        expect(mixed.shots.count == 2 && near(mixed.shots[1].start, seam), "Mixed-frame-rate seams retain exact source boundaries")
        mixed = ProjectLogic.split(mixed, at: seam + 1.0 / 60)
        expect(mixed.cuts.count == 1 && near(mixed.cuts[0], seam + 1.0 / 60), "Cuts snap within the target clip's source frame grid")
        expect(mixed.shots.allSatisfy { $0.duration > 0 }, "Mixed-rate cuts cannot create a zero-length shot")
        _ = try ProjectPersistence.encodeProject(mixed)
        _ = try ProjectPersistence.encodeProject(derived)
    }

    private static func moveAndRemap() throws {
        let p = fixture()
        let moved = SequenceLogic.moveClip(p, id: p.clips[0].id, delta: 2)
        expect(moved.clips.map(\.title) == ["B", "C", "A"], "Move changes clip order while preserving clip identity")
        expect(moved.duration == 9 && moved.cuts == [1, 4, 7], "Cuts follow their source clips through a reorder")
        let a = moved.notes.first { $0.title == "A笔记" }!
        let b = moved.notes.first { $0.title == "B笔记" }!
        expect(a.start == 6 && a.end == 7 && b.start == 0.5 && b.end == 1.5, "Notes follow each clip's source coordinates")
        let fragments = moved.notes.filter { $0.title == "跨素材" }
        expect(fragments.count == 2, "A discontiguous cross-source note becomes two valid fragments")
        expect(fragments.contains { $0.start == 0 && $0.end == 0.5 } && fragments.contains { $0.start == 8.5 && $0.end == 9 }, "Split note fragments point to the original source regions after reordering")
        expect(fragments.allSatisfy { $0.body == "前后关系" && $0.takeaway == "复用衔接方法" }, "Fragmentation preserves all written learning content")
        expect(Set(moved.notes.map(\.id)).count == moved.notes.count, "Remapped note fragments have unique IDs")
        expect(moved.notes.first(where: { $0.title == "接缝点" })?.start == 0, "An internal seam point moves with the following clip")
        expect(SequenceLogic.moveClip(p, id: UUID(), delta: 1) == p, "Unknown clip moves are safe no-ops")
        expect(SequenceLogic.moveClip(p, id: p.clips[0].id, delta: Int.min) == p, "Extreme move deltas cannot overflow")
        let secondMove = SequenceLogic.moveClip(moved, id: p.clips[0].id, delta: -2)
        expect(secondMove.notes.first(where: { $0.title == "A笔记" })?.start == 1, "A second move keeps ordinary source-anchored notes aligned")
        _ = try ProjectPersistence.encodeProject(moved)
        _ = try ProjectPersistence.encodeProject(secondMove)
    }

    private static func trimAndRemove() throws {
        let p = fixture()
        let trimmed = SequenceLogic.trimClip(p, id: p.clips[0].id, sourceIn: 2, sourceOut: 4)
        expect(trimmed.duration == 7 && trimmed.clips[0].id == p.clips[0].id, "Trim changes duration without changing the clip identity")
        expect(trimmed.cuts == [1, 3, 6], "Trim maps internal and downstream cuts to their original source frames")
        let a = trimmed.notes.first { $0.title == "A笔记" }!
        let b = trimmed.notes.first { $0.title == "B笔记" }!
        expect(a.start == 0 && a.end == 1 && b.start == 2.5 && b.end == 3.5, "Trim clips retained notes and shifts following notes")
        let cross = trimmed.notes.filter { $0.title == "跨素材" }
        expect(cross.contains { $0.start == 2 && $0.end == 2 && $0.body.contains("已裁切或移除") }, "Written content entirely trimmed away is explicitly retained as a boundary note")
        expect(cross.contains { $0.start == 2 && $0.end == 2.5 && $0.body == "前后关系" }, "The surviving portion of a cross-source note stays on its source frames")
        expect(SequenceLogic.trimClip(p, id: p.clips[0].id, sourceIn: 8, sourceOut: 2) == p, "Reversed source trim does not mutate the project")
        expect(SequenceLogic.trimClip(p, id: p.clips[0].id, sourceIn: 0, sourceOut: 21) == p, "Trim cannot exceed source duration")

        let removed = SequenceLogic.removeClip(p, id: p.clips[1].id)
        expect(removed.clips.map(\.title) == ["A", "C"] && removed.duration == 6, "Removing a middle clip closes the timeline gap")
        expect(removed.cuts == [2, 5], "Cuts in the removed clip disappear while later cuts shift correctly")
        let orphan = removed.notes.first { $0.title == "B笔记" }!
        expect(orphan.start == 4 && orphan.end == 4 && orphan.body.contains("已裁切或移除"), "Removed footage's written notes remain at the join with an explicit explanation")
        expect(removed.notes.first(where: { $0.title == "全片末尾" })?.start == 6, "End notes follow the shortened film end")
        let only = SequenceLogic.makeProject(title: "仅剩一段", clips: [p.clips[0]])
        expect(SequenceLogic.removeClip(only, id: only.clips[0].id) == only, "The last video clip cannot be removed")
        _ = try ProjectPersistence.encodeProject(trimmed)
        _ = try ProjectPersistence.encodeProject(removed)
    }

    private static func musicAndRecalculation() throws {
        var p = fixture()
        let music = MusicClip(title: "节奏", sourcePath: "/tmp/rhythm.wav", sourceDuration: 30, sourceIn: 2, sourceOut: 10, timelineStart: 3, volume: 0.6)
        p.music = [music]
        p.notes.append(StudyNote(start: 20, end: 21, track: .learning, title: "", body: "超界但不能丢的笔记", takeaway: ""))
        p.notes.append(StudyNote(start: 20, end: 21, track: .learning, title: "", body: "", takeaway: ""))
        let reconciled = SequenceLogic.recalculate(p)
        expect(reconciled.music.count == 1 && reconciled.music[0].sourceIn == 2 && reconciled.music[0].sourceOut == 8, "Music tails are trimmed to sequence duration in source coordinates")
        expect(reconciled.notes.contains { $0.body == "超界但不能丢的笔记" && $0.start == 9 && $0.end == 9 }, "Recalculation preserves out-of-range written content as an end marker")
        expect(reconciled.notes.count == p.notes.count - 1, "Out-of-range empty draft markers are discarded")
        expect(reconciled.clips == p.clips && reconciled.cuts == p.cuts, "Recalculation does not reorder or rewrite the source clips or existing cuts")

        let split = SequenceLogic.splitMusic(reconciled, id: music.id, at: 5)
        expect(split.music.count == 2 && split.music[0].id == music.id && split.music[1].id != music.id, "Music splitting preserves the left identity and creates a distinct right piece")
        expect(split.music[0].sourceIn == 2 && split.music[0].sourceOut == 4 && split.music[1].sourceIn == 4 && split.music[1].sourceOut == 8, "A timeline split maps to exact source-audio coordinates")
        expect(split.music[0].timelineStart == 3 && split.music[1].timelineStart == 5 && split.music.allSatisfy { $0.volume == 0.6 }, "Music timing and volume survive splitting")
        expect(SequenceLogic.splitMusic(reconciled, id: music.id, at: 3) == reconciled, "Splitting at a music boundary is a safe no-op")
        expect(SequenceLogic.splitMusic(reconciled, id: music.id, at: .nan) == reconciled, "Non-finite split times cannot corrupt music")

        var negative = fixture()
        negative.music = [MusicClip(title: "提前进入", sourcePath: "/tmp/lead.wav", sourceDuration: 20, sourceIn: 2, sourceOut: 8, timelineStart: -1)]
        let adjusted = SequenceLogic.recalculate(negative)
        expect(adjusted.music[0].timelineStart == 0 && adjusted.music[0].sourceIn == 3, "Music entering before zero skips the matching source prefix")
        negative.music[0].timelineStart = 12
        expect(SequenceLogic.recalculate(negative).music.isEmpty, "Music starting after the film is removed")

        let markdown = ProjectLogic.exportMarkdown(split)
        expect(markdown.contains("## 素材与来源") && markdown.contains("## 音乐编排") && markdown.contains("节奏"), "Markdown describes multiple sources and music")
        expect(markdown.contains("/tmp/rhythm.wav") && markdown.contains("混剪练习"), "Markdown retains readable source paths and project kind")
        _ = try ProjectPersistence.encodeProject(split)
        _ = try ProjectPersistence.encodeProject(adjusted)
    }

    private static func validation() throws {
        let p = fixture()
        let encoded = try ProjectPersistence.encodeProject(p)
        let decoded = try ProjectPersistence.decodeProject(encoded)
        expect(decoded == p, "New multi-source projects round-trip with provenance and IDs")
        let cases: [(String, (inout FilmProject) -> Void)] = [
            ("duplicate clip ID", { $0.clips[1].id = $0.clips[0].id }),
            ("invalid source path", { $0.clips[1].sourcePath = "https://example.com/video.mp4" }),
            ("negative source in", { $0.clips[1].sourceIn = -1 }),
            ("empty source range", { $0.clips[1].sourceOut = $0.clips[1].sourceIn }),
            ("source range past end", { $0.clips[1].sourceOut = 21 }),
            ("bad source frame rate", { $0.clips[1].frameRate = .infinity }),
            ("bad source dimensions", { $0.clips[1].height = 0 }),
            ("wrong sequence duration", { $0.duration = 15 }),
            ("stale compatibility path", { $0.sourcePath = "/tmp/wrong.mp4" }),
            ("invalid original volume", { $0.originalVolume = 1.1 }),
            ("too many clips", { $0.clips = Array(repeating: $0.clips[0], count: 10_001) })
        ]
        for (label, mutate) in cases {
            var bad = p; mutate(&bad)
            do { _ = try ProjectPersistence.encodeProject(bad); fatalError("Must reject \(label)") }
            catch { expect(error.localizedDescription.contains("项目数据无效"), "\(label) produces a Chinese validation error") }
        }
        let music = MusicClip(title: "音乐", sourcePath: "/tmp/test.wav", sourceDuration: 10, sourceIn: 0, sourceOut: 2, timelineStart: 1)
        let musicCases: [(String, (inout MusicClip) -> Void)] = [
            ("music source range", { $0.sourceOut = 11 }),
            ("music negative timeline", { $0.timelineStart = -1 }),
            ("music beyond sequence", { $0.timelineStart = 8 }),
            ("music invalid volume", { $0.volume = .nan })
        ]
        for (label, mutate) in musicCases {
            var bad = p; var changed = music; mutate(&changed); bad.music = [changed]
            do { _ = try ProjectPersistence.encodeProject(bad); fatalError("Must reject \(label)") }
            catch { expect(error.localizedDescription.contains("音乐素材"), "\(label) identifies the invalid music") }
        }
        var duplicateMusic = p; duplicateMusic.music = [music, music]
        do { _ = try ProjectPersistence.encodeProject(duplicateMusic); fatalError("Must reject duplicated music IDs") }
        catch { expect(error.localizedDescription.contains("音乐素材 ID 重复"), "Duplicate music identities are rejected") }

        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["kind"] = "unknown-kind"
        do { _ = try ProjectPersistence.decodeProject(JSONSerialization.data(withJSONObject: object)); fatalError("Unknown project kinds must not silently become study") }
        catch { expect(error.localizedDescription.contains("kind"), "Invalid present fields still fail; only absent new fields get defaults") }
    }

    private static func fractionalBoundaries() throws {
        var p = SequenceLogic.makeProject(title: "分数帧率边界", clips: [
            clip("29.97", 0, 1001.0 / 30_000, fps: 30_000.0 / 1001),
            clip("24", 0, 123.0 / 24, fps: 24),
            clip("60", 1, 1 + 13.0 / 60, fps: 60)
        ])
        let placement = p.clipPlacements[1]
        p.notes = [StudyNote(start: placement.start + 0.1, end: placement.start + 0.2,
                             track: .camera, title: "素材内部", body: "随素材移动", takeaway: "")]
        p.cuts = [placement.start + 1.0 / 24]
        p.music = [MusicClip(title: "分数时长", sourcePath: "/tmp/fractional.wav", sourceDuration: 20,
                             sourceIn: 0.137, sourceOut: 10, timelineStart: 0.217)]
        p = SequenceLogic.recalculate(p)
        expect(SequenceLogic.recalculate(p) == p, "Recalculation is idempotent at fractional source boundaries")
        _ = try ProjectPersistence.encodeProject(p)
        for delta in [-2, -1, 1, 2] {
            let moved = SequenceLogic.moveClip(p, id: placement.id, delta: delta)
            let target = moved.clipPlacements.first { $0.id == placement.id }!
            expect(near(moved.notes[0].start - target.start, 0.1) && near(moved.notes[0].end - target.start, 0.2), "Fractional source note offsets survive move delta \(delta)")
            expect(near(moved.shots.reduce(0) { $0 + $1.duration }, moved.duration), "Fractional shots cover the entire reordered sequence")
            _ = try ProjectPersistence.encodeProject(moved)
        }
        let trimmed = SequenceLogic.trimClip(p, id: placement.id, sourceIn: 1.0 / 24, sourceOut: 5)
        let target = trimmed.clipPlacements.first { $0.id == placement.id }!
        expect(near(trimmed.notes[0].start - target.start + target.clip.sourceIn, 0.1), "Fractional trim preserves the source-time anchor")
        expect(trimmed.music.allSatisfy { $0.timelineStart + $0.duration <= trimmed.duration + 0.000_000_1 }, "Fractional music tails stay within the shortened sequence")
        _ = try ProjectPersistence.encodeProject(trimmed)
        let extracted = SequenceLogic.extract(p, start: 0.001, end: p.duration)
        let derived = SequenceLogic.makeProject(title: "精确末尾提取", clips: extracted)
        expect(extracted.allSatisfy { $0.sourceIn >= 0 && $0.sourceOut <= $0.sourceDuration && $0.duration > 0 }, "Fractional extraction never exceeds a physical source range")
        _ = try ProjectPersistence.encodeProject(derived)
    }

    private static func isolatedStorage() throws {
        guard let directory = ProcessInfo.processInfo.environment["JINGDU_LIBRARY_DIRECTORY"],
              directory.hasPrefix("/tmp/") || directory.hasPrefix("/private/tmp/") else {
            throw ProjectDataError.invalid("隔离存储测试必须显式设置 /tmp 下的 JINGDU_LIBRARY_DIRECTORY；不会访问默认作品库。")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix("/private/tmp/") || root.path.hasPrefix("/tmp/") else {
            throw ProjectDataError.invalid("隔离目录解析后必须仍在 /tmp 内。")
        }
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw ProjectDataError.invalid("隔离测试要求一个不存在的新临时目录，避免覆盖已有测试或应用数据。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("keep-this-document.txt")
        let sentinel = Data("不应覆盖其他文档".utf8)
        try sentinel.write(to: unrelated)
        let empty = try ProjectPersistence.load()
        expect(empty.isEmpty, "An isolated missing library loads as an empty array")
        let project = fixture()
        try ProjectPersistence.save([project])
        expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path), "The environment override writes library.json only in the isolated directory")
        let reloaded = try ProjectPersistence.load()
        expect(reloaded == [project], "The isolated native-library format preserves new sequence data")
        let after = try Data(contentsOf: unrelated)
        expect(after == sentinel, "Atomic library replacement preserves unrelated documents in the override directory")
        print("Isolated persistence smoke test passed in \(root.path); temporary directory removed on exit.")
    }
}
