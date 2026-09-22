import Foundation

/// Pure offline regression: no model calls, media reads, user defaults, or library writes.
/// xcrun swiftc -swift-version 5 -O -parse-as-library Sources/Models.swift Sources/SubtitleModels.swift Sources/ScriptReading.swift Sources/ScriptModels.swift Tests/ScriptSubtitleSharingTests.swift -o /tmp/jingdu-script-subtitle-sharing-tests
/// /tmp/jingdu-script-subtitle-sharing-tests
@main
struct ScriptSubtitleSharingTests {
    private static var assertions = 0

    static func main() throws {
        try validityAndStaleness()
        try uniqueOwnershipAndBoundaries()
        try sixLanguagesAndAuthoritativeSource()
        try playbackAndFollowing()
        try exportsAndImmutability()
        print("Script subtitle sharing tests passed (\(assertions) assertions; no network, media, or user data I/O).")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            fatalError(message)
        }
    }
    private static func scene(_ start: Double, _ end: Double, _ name: String) -> ScriptSegment {
        ScriptSegment(start: start, end: end, visual: "\(name)画面观察", action: "\(name)动作", dialogue: "待核对：未取得可靠语音转写",
                      sound: "\(name)声音观察", camera: "\(name)镜头", transition: "\(name)转场", reasoning: "\(name)推测", uncertainty: "\(name)不确定性",
                      screenplay: "\(name)原始叙事保持不变。", dialogueCues: [])
    }
    private static func fixture() -> (FilmProject, ScriptAnalysis, SubtitleTrack) {
        var project = FilmProject(title: "合成字幕共享测试", sourcePath: "/synthetic/shared-dialogue.mp4", duration: 30,
                                  frameRate: 25, width: 640, height: 360, cuts: [], notes: [])
        let analysis = ScriptAnalysis(modelID: "synthetic-analysis", sourceClips: project.videoClips, rangeStart: 5, rangeEnd: 25,
                                      title: "字幕共享", synopsis: "合成故事梗概", structure: "合成结构分析",
                                      segments: [scene(6, 10, "第一段"), scene(12, 16, "第二段"), scene(20, 24, "第三段")],
                                      caveats: "原始分析限制保持不变", inputMode: "synthetic")
        let track = SubtitleTrack(sourceClips: project.videoClips, cues: [
            SubtitleCue(start: 0, end: 4, language: .zh, text: "范围外之前", chineseText: ""),
            SubtitleCue(start: 4, end: 6.5, language: .zh, text: "起点穿越完整中文句。", chineseText: ""),
            SubtitleCue(start: 9, end: 13.5, language: .ko, text: "장면을 가로지르는 완전한 문장입니다.", chineseText: "跨越场景的完整句子。"),
            SubtitleCue(start: 16.5, end: 19, language: .en, text: "A sentence entirely in the gap.", chineseText: "完全落在间隙中的句子。"),
            SubtitleCue(start: 23, end: 27, language: .fr, text: "Une phrase complète à la fin.", chineseText: "跨越结尾的完整句子。"),
            SubtitleCue(start: 27, end: 29, language: .zh, text: "范围外之后", chineseText: "")
        ], sourceDescription: "合成测试的本地字幕来源")
        project.subtitleTrack = track
        return (project, analysis, track)
    }

    private static func validityAndStaleness() throws {
        let (project, analysis, track) = fixture()
        try ProjectPersistence.validateSubtitleTrack(track)
        try ProjectPersistence.validateScriptAnalysis(analysis)
        expect(ScriptReading.usableSubtitleTrack(for: analysis, project: project)?.id == track.id, "Current analysis and current subtitle snapshots share the track")
        var renamed = project
        renamed.title = "改名不改变素材"
        renamed.clips = project.videoClips
        renamed.clips[0].id = UUID(); renamed.clips[0].title = "素材新名字"
        expect(ScriptReading.usableSubtitleTrack(for: analysis, project: renamed)?.id == track.id, "Project/clip names and regenerated IDs do not invalidate matching material")
        var missing = project; missing.subtitleTrack = nil
        expect(ScriptReading.usableSubtitleTrack(for: analysis, project: missing) == nil, "No subtitle track remains the legacy path")
        var changed = project; changed.originalVolume = 0.2
        expect(track.isCurrent(for: changed), "Subtitle track itself is independent of playback volume")
        expect(ScriptReading.usableSubtitleTrack(for: analysis, project: changed) == nil, "An analysis made with different sound settings cannot borrow current subtitles")
        changed = project
        changed.music = [MusicClip(title: "合成配乐", sourcePath: "/synthetic/music.wav", sourceDuration: 2,
                                   sourceIn: 0, sourceOut: 2, timelineStart: 1)]
        expect(ScriptReading.usableSubtitleTrack(for: analysis, project: changed) == nil, "An analysis with stale music settings does not adopt current subtitles")
        for field in ["path", "trim", "rate", "dimensions", "duration"] {
            var stale = track
            switch field {
            case "path": stale.sourceClips[0].sourcePath = "/synthetic/other.mp4"
            case "trim": stale.sourceClips[0].sourceIn = 0.25
            case "rate": stale.sourceClips[0].frameRate = 24
            case "dimensions": stale.sourceClips[0].width = 1280
            default: stale.sourceClips[0].sourceDuration = 31
            }
            var p = project; p.subtitleTrack = stale
            expect(ScriptReading.usableSubtitleTrack(for: analysis, project: p) == nil, "Stale subtitle snapshot is rejected: \(field)")
            expect(ScriptReading.matchingSubtitleTrack(stale, for: analysis) == nil, "Direct display/export cannot bypass stale snapshot checks: \(field)")
        }
        var outdated = analysis; outdated.sourceClips[0].sourcePath = "/synthetic/old-analysis.mp4"
        expect(ScriptReading.usableSubtitleTrack(for: outdated, project: project) == nil, "A stale analysis does not adopt a current subtitle track")
        var invalid = track; invalid.cues[2].start = invalid.cues[1].start
        expect(ScriptReading.matchingSubtitleTrack(invalid, for: analysis) == nil, "Malformed subtitle timing cannot enter the shared reader")
        invalid = track; invalid.cues[2].chineseText = ""
        expect(ScriptReading.matchingSubtitleTrack(invalid, for: analysis) == nil, "An incomplete foreign subtitle track is not represented as bilingual")
    }

    private static func uniqueOwnershipAndBoundaries() throws {
        let (_, analysis, track) = fixture()
        let cues = ScriptReading.cues(in: analysis, subtitles: track)
        expect(cues.map(\.id) == Array(track.cues[1...4]).map(\.id), "Analysis overlap selects whole sentences with original stable UUIDs")
        expect(cues[0].start == 5 && cues[0].end == 6.5, "Only analysis start clips the incoming cue")
        expect(cues[3].start == 23 && cues[3].end == 25, "Only analysis end clips the outgoing cue")
        expect(cues[1].start == 9 && cues[1].end == 13.5, "A cross-segment sentence retains its entire interval")
        expect(cues[1].segmentID == analysis.segments[1].id, "Maximum temporal overlap owns a cross-segment sentence")
        expect(cues[2].segmentID == analysis.segments[1].id, "A gap sentence belongs to the nearest segment")
        let perSegment = analysis.segments.flatMap { ScriptReading.displayCues(for: $0, in: analysis, subtitles: track) }
        expect(perSegment.map(\.id) == cues.map(\.id), "Every shared subtitle appears exactly once across narrative segments")
        expect(Set(perSegment.map(\.id)).count == cues.count, "Cross-segment and gap cues are never duplicated")
        expect(cues.allSatisfy { $0.speaker.isEmpty && !$0.isParagraphFallback }, "No speaker is guessed and subtitle timing remains sentence timing")

        var variants = track
        variants.cues = [SubtitleCue(start: 9, end: 13, language: .zh, text: "等长交叠", chineseText: "")]
        expect(ScriptReading.cues(in: analysis, subtitles: variants)[0].segmentID == analysis.segments[0].id, "Equal overlap deterministically chooses the earlier segment")
        variants.cues = [SubtitleCue(start: 17, end: 19, language: .zh, text: "等距间隙", chineseText: "")]
        expect(ScriptReading.cues(in: analysis, subtitles: variants)[0].segmentID == analysis.segments[1].id, "Equal gap distance deterministically chooses the earlier segment")
        variants.cues = [SubtitleCue(start: 5, end: 5.5, language: .zh, text: "叙事之前", chineseText: ""),
                         SubtitleCue(start: 24.5, end: 25, language: .zh, text: "叙事之后", chineseText: "")]
        let edgeGaps = ScriptReading.cues(in: analysis, subtitles: variants)
        expect(edgeGaps[0].segmentID == analysis.segments.first!.id && edgeGaps[1].segmentID == analysis.segments.last!.id, "Analysis head/tail gaps are retained once with nearby narrative")
        variants.cues = [SubtitleCue(start: 4, end: 5, language: .zh, text: "刚好结束", chineseText: ""),
                         SubtitleCue(start: 25, end: 26, language: .zh, text: "刚好开始", chineseText: "")]
        expect(ScriptReading.cues(in: analysis, subtitles: variants).isEmpty, "Touching an analysis boundary without positive overlap does not create a subtitle")
        var noScenes = analysis; noScenes.segments = []
        expect(ScriptReading.cues(in: noScenes, subtitles: track).map(\.id) == cues.map(\.id), "Even missing legacy narrative cannot discard real in-range subtitles")
        expect(noScenes.exportMarkdown(subtitles: track).contains(track.cues[2].text), "Orphan subtitles remain visible once in full export")
    }

    private static func sixLanguagesAndAuthoritativeSource() throws {
        let (_, originalAnalysis, originalTrack) = fixture()
        var analysis = originalAnalysis
        analysis.rangeStart = 0; analysis.rangeEnd = 30
        analysis.segments = [scene(0, 30, "整段")]
        analysis.segments[0].dialogue = "旧模型整段台词不得混入"
        analysis.segments[0].dialogueCues = [ScriptDialogueCue(start: 1, end: 2, speaker: "旧模型猜测人物", text: "旧模型逐句台词不得混入")]
        let sourceText: [(SubtitleLanguage, String, String)] = [
            (.zh, "只有中文原文", ""), (.en, "English original", "英语译文"), (.ja, "日本語の原文", "日语译文"),
            (.ko, "한국어 원문", "韩语译文"), (.es, "Texto español", "西班牙语译文"), (.fr, "Texte français", "法语译文")
        ]
        var track = originalTrack
        track.cues = sourceText.enumerated().map { index, item in
            SubtitleCue(start: Double(index * 4), end: Double(index * 4 + 2), language: item.0, text: item.1, chineseText: item.2)
        }
        let cues = ScriptReading.cues(in: analysis, subtitles: track)
        let full = analysis.exportMarkdown(subtitles: track)
        let dialogue = analysis.exportDialogueMarkdown(subtitles: track)
        expect(cues.count == 6, "All six language subtitle formats share the same reader path")
        for (index, source) in sourceText.enumerated() {
            let expected = source.0 == .zh ? source.1 : source.1 + "\n" + source.2
            expect(cues[index].text == expected, "Original and Chinese are separate lines, without adding a second Chinese line: \(source.0)")
            expect(cues[index].id == track.cues[index].id && cues[index].speaker.isEmpty, "All languages retain subtitle identity and no guessed speaker")
            expect(full.components(separatedBy: source.1).count - 1 == 1 && dialogue.components(separatedBy: source.1).count - 1 == 1,
                   "Both export modes include the original once for each supported language: \(source.0)")
        }
        expect(!cues.contains { $0.text.contains("旧模型") }, "The valid subtitle track is the sole dialogue source")
        let legacy = ScriptReading.cues(in: analysis)
        expect(legacy.count == 1 && legacy[0].speaker == "旧模型猜测人物", "No-track reading preserves exact legacy behavior")
        var empty = track; empty.cues = []
        expect(ScriptReading.cues(in: analysis, subtitles: empty).isEmpty, "An authoritative empty track does not resurrect stale model dialogue")
        var outOfRange = originalTrack
        outOfRange.cues = [SubtitleCue(start: 0, end: 2, language: .zh, text: "范围外", chineseText: "")]
        var fallbackAnalysis = originalAnalysis; fallbackAnalysis.segments[0].dialogue = "旧记录"
        expect(ScriptReading.cues(in: fallbackAnalysis, subtitles: outOfRange).isEmpty, "A valid track without in-range cues is still authoritative")
        var stale = track; stale.sourceClips[0].sourcePath += ".old"
        expect(ScriptReading.cues(in: analysis, subtitles: stale) == legacy, "A stale directly supplied track falls back to legacy dialogue")
    }

    private static func playbackAndFollowing() throws {
        let (_, analysis, track) = fixture()
        let cues = ScriptReading.cues(in: analysis, subtitles: track)
        expect(ScriptReading.cue(at: 5, in: analysis, subtitles: track)?.id == cues[0].id, "The analysis-clipped start is active")
        expect(ScriptReading.cue(at: 10.5, in: analysis, subtitles: track)?.id == cues[1].id, "A sentence remains active while it crosses a narrative gap")
        expect(ScriptReading.cue(at: 19, in: analysis, subtitles: track) == nil, "A shared cue's end is exclusive")
        expect(ScriptReading.cue(at: 25, in: analysis, subtitles: track) == nil, "The shared final endpoint remains exclusive like the subtitle player")
        expect(ScriptReading.followCue(at: 7, in: analysis, subtitles: track)?.id == cues[1].id, "Silent passages follow the next subtitle")
        expect(ScriptReading.followCue(at: 25, in: analysis, subtitles: track)?.id == cues.last!.id, "Following can remain at the last sentence without marking it active")
        for time in [4.99, 25.01, Double.nan, Double.infinity, -1] {
            expect(ScriptReading.followCue(at: time, in: analysis, subtitles: track) == nil, "Out-of-range/nonfinite following does not choose a subtitle")
        }
        let times = [24.0, 17.0, 10.0, 5.5, 23.5]
        let expected = [cues[3].id, cues[2].id, cues[1].id, cues[0].id, cues[3].id]
        expect(times.map { ScriptReading.cue(at: $0, in: analysis, subtitles: track)?.id } == expected.map(Optional.some), "Scrubbing uses current absolute time, not cached prior ownership")
    }

    private static func exportsAndImmutability() throws {
        let (project, analysis, track) = fixture()
        let beforeProject = project, beforeAnalysis = analysis, beforeTrack = track
        let full = analysis.exportMarkdown(subtitles: track)
        let dialogue = analysis.exportDialogueMarkdown(frameRate: 25, subtitles: track)
        for cue in Array(track.cues[1...4]) {
            expect(full.components(separatedBy: cue.text).count - 1 == 1, "Full export includes each original sentence once")
            expect(dialogue.components(separatedBy: cue.text).count - 1 == 1, "Dialogue export includes each original sentence once")
            if cue.language != .zh {
                expect(full.contains("> \(cue.text)  \n> \(cue.chineseText)"), "Full export keeps bilingual lines together")
                expect(dialogue.contains("> \(cue.text)  \n> \(cue.chineseText)"), "Dialogue export keeps bilingual lines together")
            }
        }
        expect(!full.contains("未取得可靠语音转写") && !dialogue.contains("未取得可靠语音转写"), "Shared exports do not re-export obsolete missing-transcription dialogue placeholders")
        expect(full.contains("台词来源：当前素材的字幕轨") && dialogue.contains(track.sourceDescription), "Both exports state the actual shared subtitle provenance")
        expect(!full.contains(track.cues[0].text) && !dialogue.contains(track.cues[5].text), "Out-of-analysis subtitles are not exported")
        for segment in analysis.segments {
            expect(full.contains(segment.screenplay) && full.contains(segment.visual) && full.contains(segment.action) &&
                   full.contains(segment.camera) && full.contains(segment.sound) && full.contains(segment.transition) &&
                   full.contains(segment.reasoning) && full.contains(segment.uncertainty), "Narrative, observations and explanations are unchanged")
        }
        expect(full.contains(analysis.structure) && full.contains(analysis.caveats), "Analysis structure and original caveats remain intact")
        expect(dialogue.contains("00:00:09:00–00:00:13:13"), "A cross-segment sentence exports its full range at the chosen frame rate")
        expect(analysis.exportMarkdown().contains("未取得可靠语音转写"), "The default no-track export preserves old provenance")
        var stale = track; stale.sourceClips[0].sourcePath += ".stale"
        expect(analysis.exportMarkdown(subtitles: stale) == analysis.exportMarkdown(), "Direct full export rejects a mismatched subtitle snapshot")
        expect(analysis.exportDialogueMarkdown(subtitles: stale) == analysis.exportDialogueMarkdown(), "Direct dialogue export rejects a mismatched subtitle snapshot")
        expect(project == beforeProject && analysis == beforeAnalysis && track == beforeTrack, "Reading/exporting never migrates or modifies source project, analysis or subtitles")
    }
}
