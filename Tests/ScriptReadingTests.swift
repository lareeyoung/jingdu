import Foundation

/// swiftc -swift-version 5 Sources/Models.swift Sources/ScriptModels.swift Sources/ScriptReading.swift Sources/ScriptPrompt.swift Tests/ScriptReadingTests.swift -o /tmp/jingdu-script-reading-tests
@main
struct ScriptReadingTests {
    private static var assertions = 0
    private static let project = FilmProject(title: "阅读测试", sourcePath: "/tmp/reading-fixture.mp4",
        duration: 30, frameRate: 25, width: 1280, height: 720, cuts: [], notes: [])
    private static let response = #"""
    {"title":"雨夜的告别","synopsis":"两人在站台告别。","structure":"相遇、决定、离开。","caveats":"字幕来源，时间需回看核对。","segments":[
      {"start":0,"end":4,"screenplay":"雨落在站台边缘。中景里，穿红衣的女孩走近男子，镜头随她缓缓向前。","visual":"雨夜站台","action":"女孩走近男子","dialogue":"画面字幕：我无法离开。那就留下。","dialogueCues":[{"start":1,"end":2,"speaker":"女孩","text":"我无法离开。"},{"start":2,"end":3.5,"speaker":"男子","text":"那就留下。"}],"sound":"待核对：未取得可靠音频证据","camera":"中景向前","transition":"切到列车","reasoning":"分析：推近可能强化两人的关系。","uncertainty":"说话人由字幕和画面估计。"},
      {"start":5,"end":8,"screenplay":"列车缓缓驶离，窗边只剩女孩的倒影。镜头停在空下来的站台，故事留在无声的等待中；原声内容仍需核对。","visual":"列车驶离","action":"女孩望向窗外","dialogue":"待核对：未取得可靠语音转写","dialogueCues":[],"sound":"待核对","camera":"固定远景","transition":"黑场","reasoning":"分析：空景可能延续情绪。","uncertainty":"未确认人物的后续去向。"}
    ]}
    """#

    static func main() throws {
        try parsingAndMigration()
        try invalidCues()
        try persistenceValidation()
        try readingAndTiming()
        try followingDialogue()
        try bilingualDialogueFormatting()
        try exportingAndPrompt()
        print("Script reading tests passed (\(assertions) assertions; no network or library I/O).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }

    private static func parse(_ text: String = response) throws -> ScriptAnalysis {
        try ScriptAnalysisParser.parse(text, project: project, rangeStart: 10, rangeEnd: 18,
                                       modelID: "seed2.1", inputMode: "video")
    }

    private static func changingFirst(_ mutation: (inout [String: Any]) -> Void) throws -> String {
        var object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]
        var segments = object["segments"] as! [[String: Any]]
        mutation(&segments[0]); object["segments"] = segments
        return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private static func changingCues(_ mutation: (inout [[String: Any]]) -> Void) throws -> String {
        try changingFirst { item in
            var cues = item["dialogueCues"] as! [[String: Any]]
            mutation(&cues); item["dialogueCues"] = cues
        }
    }

    private static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Must reject: \(message)") }
        catch { expect(!error.localizedDescription.isEmpty, message) }
    }

    private static func parsingAndMigration() throws {
        let analysis = try parse()
        let first = analysis.segments[0]
        expect(first.start == 10 && first.end == 14, "Segment times use absolute project seconds")
        expect(first.dialogueCues.map(\.start) == [11, 12] && first.dialogueCues.map(\.end) == [12, 13.5], "Sentence times offset from submitted video exactly once")
        expect(first.screenplay.hasPrefix("雨落在站台"), "Continuous narrative survives response parsing")
        expect(first.dialogueCues.map(\.speaker) == ["女孩", "男子"], "Speakers and original transcript stay separate")
        expect(Set(first.dialogueCues.map(\.id)).count == 2, "Cue identities are locally assigned")
        expect(analysis.segments[1].dialogueCues.isEmpty, "Unknown dialogue does not create fake cues")
        let encoded = try JSONEncoder().encode(analysis)
        let roundTrip = try JSONDecoder().decode(ScriptAnalysis.self, from: encoded)
        expect(roundTrip == analysis, "All prose, cue identities and absolute timestamps survive a round trip")

        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var segments = object["segments"] as! [[String: Any]]
        for i in segments.indices {
            segments[i].removeValue(forKey: "screenplay")
            segments[i].removeValue(forKey: "dialogueCues")
        }
        object["segments"] = segments
        let legacy = try JSONDecoder().decode(ScriptAnalysis.self, from: JSONSerialization.data(withJSONObject: object))
        expect(legacy.segments.allSatisfy { $0.screenplay.isEmpty && $0.dialogueCues.isEmpty }, "Old stored scripts decode with empty new fields")
        expect(legacy.segments[0].dialogue == first.dialogue && legacy.segments[0].id == first.id, "Migration preserves old dialogue and segment identity")
        let oldResponse = try changingFirst { $0.removeValue(forKey: "screenplay"); $0.removeValue(forKey: "dialogueCues") }
        let oldParsed = try parse(oldResponse)
        expect(oldParsed.segments[0].screenplay.isEmpty && oldParsed.segments[0].dialogueCues.isEmpty, "Old provider payloads remain valid")
        var storedAnalysis = analysis; storedAnalysis.createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        var storedProject = project; storedProject.scriptAnalyses = [storedAnalysis]
        let restoredProject = try ProjectPersistence.decodeProject(ProjectPersistence.encodeProject(storedProject))
        expect(restoredProject.scriptAnalyses == [storedAnalysis], "Project persistence retains new reader data")
    }

    private static func invalidCues() throws {
        rejects("Cue starts before its segment") { _ = try parse(changingCues { $0[0]["start"] = -0.1 }) }
        rejects("Cue ends after its segment") { _ = try parse(changingCues { $0[1]["end"] = 4.1 }) }
        rejects("Overlapping cues") { _ = try parse(changingCues { $0[1]["start"] = 1.9 }) }
        rejects("Unsorted cues") { _ = try parse(changingCues { $0.reverse() }) }
        rejects("Zero-length cues") { _ = try parse(changingCues { $0[0]["end"] = 1 }) }
        rejects("String times are not converted") { _ = try parse(changingCues { $0[0]["start"] = "1" }) }
        rejects("Unknown cue fields stay strict") { _ = try parse(changingCues { $0[0]["confidence"] = 1 }) }
        rejects("Provider cannot inject cue identities") { _ = try parse(changingCues { $0[0]["id"] = UUID().uuidString }) }
        rejects("Null cue text") { _ = try parse(changingCues { $0[0]["text"] = NSNull() }) }
        rejects("Missing cue speaker") { _ = try parse(changingCues { $0[0].removeValue(forKey: "speaker") }) }
        rejects("Empty cue text") { _ = try parse(changingCues { $0[0]["text"] = "  \n" }) }
        rejects("Long cue text") { _ = try parse(changingCues { $0[0]["text"] = String(repeating: "字", count: 5_001) }) }
        rejects("Long cue speaker") { _ = try parse(changingCues { $0[0]["speaker"] = String(repeating: "字", count: 201) }) }
        rejects("Explicit null optional narrative") { _ = try parse(changingFirst { $0["screenplay"] = NSNull() }) }
        rejects("Explicit null optional cues") { _ = try parse(changingFirst { $0["dialogueCues"] = NSNull() }) }
        rejects("Oversized narrative") { _ = try parse(changingFirst { $0["screenplay"] = String(repeating: "字", count: 20_001) }) }
        rejects("Duplicate cue JSON keys") { _ = try parse(response.replacingOccurrences(of: "\"speaker\":\"女孩\"", with: "\"speaker\":\"女孩\",\"speaker\":\"男子\"")) }
    }

    private static func persistenceValidation() throws {
        var analysis = try parse()
        analysis.segments[0].dialogueCues[0].start = .nan
        rejects("Nonfinite persisted cue") { try ProjectPersistence.validateScriptAnalysis(analysis) }
        analysis = try parse(); analysis.segments[0].dialogueCues[0].end = .infinity
        rejects("Infinite persisted cue") { try ProjectPersistence.validateScriptAnalysis(analysis) }
        analysis = try parse(); analysis.segments[0].dialogueCues[1].id = analysis.segments[0].dialogueCues[0].id
        rejects("Duplicate persisted cue identity") { try ProjectPersistence.validateScriptAnalysis(analysis) }
        analysis = try parse(); analysis.segments[1].dialogueCues = [ScriptDialogueCue(id: analysis.segments[0].dialogueCues[0].id, start: 15, end: 16, speaker: "", text: "同一个 ID")]
        rejects("Cue identities unique across segments") { try ProjectPersistence.validateScriptAnalysis(analysis) }
        analysis = try parse(); analysis.segments[0].dialogueCues = (0..<201).map { i in
            ScriptDialogueCue(start: 10 + Double(i) / 100, end: 10 + Double(i + 1) / 100, speaker: "", text: "测试")
        }
        rejects("Excessive cue count in one segment") { try ProjectPersistence.validateScriptAnalysis(analysis) }
    }

    private static func readingAndTiming() throws {
        let analysis = try parse()
        let first = analysis.segments[0]
        let cues = ScriptReading.cues(in: analysis)
        expect(cues.count == 2 && cues.allSatisfy { !$0.isParagraphFallback }, "Only real new cues appear in dialogue filter")
        expect(cues[0].id == first.dialogueCues[0].id && cues[0].segmentID == first.id, "Reader identities map directly to storage and segment")
        expect(ScriptReading.range(for: cues[0]) == 11...12 && ScriptReading.range(for: first) == 10...14, "Explicit selection ranges match the requested content")
        expect(ScriptReading.cue(at: 11, in: analysis)?.id == cues[0].id, "Cue start belongs to the cue")
        expect(ScriptReading.cue(at: 12, in: analysis)?.id == cues[1].id, "Boundary moves to next cue rather than previous one")
        expect(ScriptReading.cue(at: 13.5, in: analysis)?.id == cues[1].id, "Last cue includes its final endpoint")
        expect(ScriptReading.cue(at: 14, in: analysis) == nil && ScriptReading.cue(at: 10, in: analysis) == nil, "No cue is invented in gaps")
        expect(ScriptReading.segment(at: 14, in: analysis) == nil && ScriptReading.segment(at: 15, in: analysis)?.id == analysis.segments[1].id, "Scene gaps and later starts are respected")
        expect(ScriptReading.segment(at: 18, in: analysis)?.id == analysis.segments[1].id, "Final scene includes its ending endpoint")
        expect(ScriptReading.segment(at: .nan, in: analysis) == nil && ScriptReading.cue(at: .infinity, in: analysis) == nil, "Nonfinite seeks cannot match a cue")
        expect(ScriptReading.narrative(for: first) == first.screenplay, "New narrative remains continuous and unchanged")
        for placeholder in ["", " \n", "无", "无台词。", "待核对", "待核对：未取得可靠语音转写", "—", "N/A"] {
            var segment = first; segment.dialogueCues = []; segment.dialogue = placeholder
            expect(ScriptReading.displayCues(for: segment).isEmpty, "Exact placeholder is excluded: \(placeholder)")
        }
        for dialogue in ["无论如何，我都要走。", "我无法离开。", "待核对：‘无论如何，我都要走。’（画面字幕）", "“无”", "无对白，但画面字幕写着‘再见’", "无台词是你自己说的"] {
            var segment = first; segment.dialogueCues = []; segment.dialogue = dialogue; segment.screenplay = ""
            let fallback = ScriptReading.displayCues(for: segment)
            expect(fallback.count == 1 && fallback[0].text == dialogue && fallback[0].id == segment.id && fallback[0].isParagraphFallback, "Real legacy dialogue is retained with paragraph timing: \(dialogue)")
        }
        var legacy = first; legacy.screenplay = ""; legacy.dialogueCues = []
        let prose = ScriptReading.narrative(for: legacy)
        expect([legacy.visual, legacy.action, legacy.sound, legacy.camera, legacy.transition].allSatisfy { prose.contains($0) }, "Legacy full narrative retains all visual and sound records")
    }

    private static func followingDialogue() throws {
        var analysis = try parse()
        analysis.segments[1].dialogueCues = [
            ScriptDialogueCue(start: 17, end: 17.5, speaker: "女孩", text: "再见。")
        ]
        let items = ScriptReading.cues(in: analysis)
        expect(ScriptReading.followCue(at: 10, in: analysis)?.id == items[0].id,
               "The absolute analysis start leads into the first line")
        expect(ScriptReading.followCue(at: 10.75, in: analysis)?.id == items[0].id,
               "Silence before dialogue follows the first upcoming line")
        expect(ScriptReading.followCue(at: 11.25, in: analysis)?.id == items[0].id,
               "During speech the follow destination is the active line")
        expect(ScriptReading.followCue(at: 12, in: analysis)?.id == items[1].id,
               "A shared boundary follows the incoming line")
        for time in [13.5, 14, 14.5, 16.9] {
            expect(ScriptReading.followCue(at: time, in: analysis)?.id == items[2].id,
                   "Silent gaps within and between scenes follow the next line at \(time)")
            expect(ScriptReading.cue(at: time, in: analysis) == nil,
                   "Following a future line does not mark it active at \(time)")
        }
        expect(ScriptReading.followCue(at: 17, in: analysis)?.id == items[2].id,
               "The later line becomes the destination exactly at its start")
        for time in [17.5, 17.75, 18] {
            expect(ScriptReading.followCue(at: time, in: analysis)?.id == items[2].id,
                   "The reader stays at the final line through the analysis endpoint")
        }
        expect(ScriptReading.cue(at: 17.75, in: analysis) == nil,
               "Trailing silence never becomes active speech")
        let scrubs: [Double] = [17.25, 14.5, 12.25, 11.25, 10, 17.1]
        let expected = [items[2].id, items[2].id, items[1].id, items[0].id, items[0].id, items[2].id]
        expect(scrubs.map { ScriptReading.followCue(at: $0, in: analysis)?.id } == expected.map(Optional.some),
               "Backwards and forwards scrubbing depends only on the requested time")
        for time in [9.999, 18.001, -1, .nan, .infinity, -.infinity] {
            expect(ScriptReading.followCue(at: time, in: analysis) == nil,
                   "Invalid or out-of-analysis positions do not scroll to a line")
        }

        var legacy = analysis
        legacy.segments[0].dialogueCues = []
        let fallback = ScriptReading.followCue(at: 10.25, in: legacy)
        expect(fallback?.id == legacy.segments[0].id && fallback?.isParagraphFallback == true,
               "Legacy dialogue remains a paragraph-level follow destination")
        expect(fallback?.start == 10 && fallback?.end == 14,
               "Legacy follow timing preserves absolute project coordinates")
        expect(ScriptReading.followCue(at: 14.25, in: legacy)?.id == items[2].id,
               "Following can move from a legacy paragraph into a timed line")

        var empty = try parse()
        empty.segments = [empty.segments[1]]
        expect(ScriptReading.followCue(at: 16, in: empty) == nil,
               "Placeholder-only dialogue has no follow destination")
        empty.segments = []
        expect(ScriptReading.followCue(at: 10, in: empty) == nil,
               "An empty analysis has no follow destination")
    }

    private static func bilingualDialogueFormatting() throws {
        let pairs: [(String, [String])] = [
            ("看来今年选拔标准降了不少 they really lowered the standards this year",
             ["看来今年选拔标准降了不少", "they really lowered the standards this year"]),
            ("今天不是你来选择龙 today you do not choose a dragon",
             ["今天不是你来选择龙", "today you do not choose a dragon"]),
            ("而是龙来选择你 you wait for a dragon to choose you",
             ["而是龙来选择你", "you wait for a dragon to choose you"]),
            ("别摸它 don't touch it", ["别摸它", "don't touch it"]),
            ("Don't touch it! 别摸它！", ["Don't touch it!", "别摸它！"]),
            ("别摸它。Don't touch it!", ["别摸它。", "Don't touch it!"]),
            ("Don't touch it!别摸它！", ["Don't touch it!", "别摸它！"]),
            ("“别摸它！”  ‘don’t touch it!’", ["“别摸它！”", "‘don’t touch it!’"]),
            ("they really lowered the standards this year 看来今年选拔标准降了不少",
             ["they really lowered the standards this year", "看来今年选拔标准降了不少"]),
            ("我看见你了\tI can see you.", ["我看见你了", "I can see you."])
            ,("嗨 hi", ["嗨", "hi"])
            ,("它会咬人 it bites", ["它会咬人", "it bites"])
            ,("它们还真会自己选啊 they actually pick for themselves", ["它们还真会自己选啊", "they actually pick for themselves"])
            ,("又怎么了？what now", ["又怎么了？", "what now"])
            ,("认真的吗？seriously?", ["认真的吗？", "seriously?"])
            ,("Seriously? 认真的吗？", ["Seriously?", "认真的吗？"])
        ]
        for (text, expected) in pairs {
            expect(ScriptReading.dialogueLines(text) == expected, "Clear bilingual clauses become distinct display lines: \(text)")
            let nonWhitespace: (String) -> String = { String($0.filter { !$0.isWhitespace }) }
            expect(nonWhitespace(ScriptReading.dialogueLines(text).joined()) == nonWhitespace(text),
                   "Display formatting neither removes punctuation nor invents transcript words")
        }
        for text in ["NPC还会阴阳人", "用自己的 Cast Builder Skill", "他们都是我在LibTV里",
                     "他们都是我在 LibTV 里", "用自己的 cast builder skill", "使用 GPT-4o 来分析",
                     "请写 I love you", "字幕：Don't touch it", "这个项目叫 This Is Love",
                     "你好 HELLO WORLD", "我和你 you and I", "他叫嗨 hi", "标签 seriously", "纯中文台词。", "Don't touch it!",
                     "\"特别的标点……\"", "  原有前后空白  "] {
            expect(ScriptReading.dialogueLines(text) == [text], "Names, mixed expressions, and ambiguous text stay intact: \(text)")
        }
        expect(ScriptReading.dialogueLines("").isEmpty, "Empty input yields no display lines")
        expect(ScriptReading.dialogueLines("中文\nEnglish\n\n后一行") == ["中文", "English", "", "后一行"],
               "Explicit line breaks and blank lines retain their positions")
        expect(ScriptReading.dialogueLines("  中文\r\nEnglish  \r最后一行\u{2028}结束") == ["  中文", "English  ", "最后一行", "结束"],
               "CRLF is one line break and explicit indentation is preserved")
        expect(ScriptReading.dialogueLines("别摸它 don't touch it\n作者已分行") == ["别摸它 don't touch it", "作者已分行"],
               "Existing multiline content takes precedence over legacy single-line heuristics")

        var analysis = try parse()
        analysis.segments[0].dialogueCues[0].text = pairs[0].0
        let original = analysis
        let cue = ScriptReading.cues(in: analysis)[0]
        expect(ScriptReading.dialogueLines(cue.text) == pairs[0].1, "Stored mixed-language cues need no model regeneration")
        let dialogue = analysis.exportDialogueMarkdown()
        let full = analysis.exportMarkdown()
        let formatted = "看来今年选拔标准降了不少  \n> they really lowered the standards this year"
        expect(dialogue.contains(formatted) && full.contains(formatted),
               "Both exports use separate Markdown hard-break lines for bilingual dialogue")
        expect(analysis == original && cue.text == original.segments[0].dialogueCues[0].text,
               "Formatting and export preserve original text, cue identity, and timestamps")
        let prompt = ScriptPrompt.make(project: project, start: 10, end: 18, style: .screenplay, focus: "", transcript: "")
        expect(prompt.contains("同一个 dialogueCues 条目的 text") && prompt.contains("不补造翻译") &&
               prompt.contains("英文名称或缩写不拆行"), "New responses keep evidenced bilingual lines within one timed cue")
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let sample = pairs[index % pairs.count]
            precondition(ScriptReading.dialogueLines(sample.0) == sample.1, "Concurrent display cache access preserves exact output")
        }
        expect(true, "Concurrent playback/display callers can safely reuse the bounded cache")
    }

    private static func exportingAndPrompt() throws {
        let analysis = try parse()
        let full = analysis.exportMarkdown()
        let dialogue = analysis.exportDialogueMarkdown()
        expect(full.contains("## 完整脚本") && !full.contains("| --- |"), "Full script uses document paragraphs rather than a wide table")
        expect(analysis.segments.allSatisfy { full.contains($0.screenplay) && full.contains($0.reasoning) && full.contains($0.uncertainty) && full.contains($0.sound) }, "Full export retains every scene, explanation, uncertainty and sound description")
        expect(full.contains("我无法离开。") && full.contains("那就留下。") && full.contains(analysis.segments[0].dialogue), "Dialogue appears in full text and original provenance remains present")
        expect(dialogue.contains("00:00:11:00–00:00:12:00") && dialogue.contains("女孩") && dialogue.contains("我无法离开。"), "Dialogue export preserves speaker, text and exact stored range")
        expect(!dialogue.contains(analysis.segments[0].screenplay) && !dialogue.contains(analysis.segments[0].reasoning), "Dialogue export is a separate focused extraction")
        var legacy = analysis; legacy.segments[0].dialogueCues = []
        expect(legacy.exportDialogueMarkdown().contains("段落定位") && legacy.exportDialogueMarkdown().contains("00:00:10:00–00:00:14:00"), "Legacy export explicitly identifies coarse paragraph timing")
        var empty = analysis; empty.segments = [analysis.segments[1]]
        expect(empty.exportDialogueMarkdown().contains("没有可提取"), "An empty dialogue extraction explains its state")
        let prompt = ScriptPrompt.make(project: project, start: 10, end: 18, style: .screenplay, focus: "", transcript: "")
        expect(prompt.contains("screenplay") && prompt.contains("dialogueCues") && prompt.contains("完整的故事与视听表达"), "Model prompt requests continuous story and timed dialogue")
        expect(prompt.contains("不是相对所属 segment 的起点") && prompt.contains("不要硬造逐句时间") && prompt.contains("不能声称逐帧精确"), "Prompt protects time offsets and honest alignment claims")
    }
}
