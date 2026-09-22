import Foundation

/// No networking or library I/O. Existing ModelTests/SequenceTests still compile
/// with Models.swift alone; this parser/export suite also needs the reader helpers.
/// swiftc -swift-version 5 Sources/Models.swift Sources/ScriptModels.swift Sources/ScriptReading.swift Sources/ScriptPrompt.swift Tests/ScriptModelsTests.swift -o /tmp/jingdu-script-model-tests
/// /tmp/jingdu-script-model-tests
@main
struct ScriptModelsTests {
    private static var assertions = 0
    private static let json = #"""
    {"title":"雨夜追逐脚本","synopsis":"人物在雨夜离开街道。","structure":"开场建立环境，随后跟随动作。","segments":[
      {"start":0,"end":1,"visual":"雨夜街道 | 霓虹","action":"人物转身","dialogue":"\"快走\"（需核对字幕）","sound":"可听见雨声","camera":"中景","transition":"硬切","reasoning":"可能用于增加紧迫感","uncertainty":"无法判断人物的目的"},
      {"start":3,"end":6,"visual":"人物离开画面","action":"向右移动","dialogue":"","sound":"","camera":"固定机位","transition":"","reasoning":"离场可能为下一场铺垫","uncertainty":"留白处未提供可靠判断"}
    ],"caveats":"台词需要对照原音轨核实。"}
    """#

    static func main() throws {
        try parseAndOffset()
        try decimalEndpointRounding()
        try strictResponses()
        try currentness()
        try persistenceAndMigration()
        try markdown()
        print("Script model, parser, migration and export tests passed (\(assertions) assertions; no network or library I/O).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    private static func fixture() -> FilmProject {
        var p = FilmProject(title: "原项目", sourcePath: "/tmp/script-test-video.mp4", duration: 10,
                            frameRate: 30, width: 1920, height: 1080, cuts: [3], notes: [])
        p.createdAt = Date(timeIntervalSince1970: 1_750_000_000); p.updatedAt = p.createdAt
        p.music = [MusicClip(title: "原配乐", sourcePath: "/tmp/script-test-music.wav", sourceDuration: 20,
                             sourceIn: 1, sourceOut: 3, timelineStart: 2, volume: 0.4)]
        return p
    }

    private static func parse(_ text: String = json, project: FilmProject? = nil) throws -> ScriptAnalysis {
        try ScriptAnalysisParser.parse(text, project: project ?? fixture(), rangeStart: 2, rangeEnd: 8,
                                       modelID: "seed2.1", inputMode: "video_with_audio")
    }

    private static func encoded(_ object: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Should reject: \(label)") }
        catch {
            expect(error.localizedDescription.contains("脚本") || error.localizedDescription.contains("项目数据无效"), "\(label) has an understandable validation error")
        }
    }

    private static func parseAndOffset() throws {
        let p = fixture()
        let result = try parse(project: p)
        expect(result.rangeStart == 2 && result.rangeEnd == 8, "Analysis stores the requested project range")
        expect(result.segments.map(\.start) == [2, 5] && result.segments.map(\.end) == [3, 8], "Relative model seconds are offset exactly once into absolute project seconds")
        expect(result.segments.count == 2, "Unobserved gaps remain gaps; the parser never invents extra segments")
        expect(result.sourceClips == p.videoClips && result.sourceMusic == p.music && result.originalVolume == p.originalVolume, "Snapshots come from local video and audio settings")
        expect(result.modelID == "seed2.1" && result.inputMode == "video_with_audio", "Transport-supplied model and input mode are preserved")
        expect(result.timelineNoteIDs.isEmpty && Set(result.segments.map(\.id)).count == 2, "Local IDs are new and no notes are marked as already inserted")
        expect(result.segments[0].dialogue.contains("快走") && result.segments[0].reasoning.contains("可能"), "The parser preserves observations and reasoning in distinct fields")
        let fenced = try parse(" \n```json\n\(json)\n```\n ", project: p)
        expect(fenced.segments.map(\.start) == [2, 5], "A single JSON Markdown code fence is accepted")
        let plainFence = try parse("```\r\n\(json)\r\n```", project: p)
        expect(plainFence.title == result.title, "Plain and CRLF code fences are supported")
        let dataResult = try ScriptAnalysisParser.parse(Data(json.utf8), project: p, rangeStart: 2, rangeEnd: 8, modelID: "seed2.1", inputMode: "video")
        expect(dataResult.segments[1].end == 8, "Data overload uses the same relative-time contract")
        var spoofed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        spoofed["timelineNoteIDs"] = ["model-must-not-decide-linked-note-ids"]
        let ignored = try parse(encoded(spoofed), project: p)
        expect(ignored.timelineNoteIDs.isEmpty, "Model-provided linked note IDs are ignored")

        var fractional = spoofed
        var items = fractional["segments"] as! [[String: Any]]
        items = [items[0]]; items[0]["end"] = 0.2; fractional["segments"] = items
        let fractionalResult = try ScriptAnalysisParser.parse(encoded(fractional), project: p, rangeStart: 0.1, rangeEnd: 0.3, modelID: "seed2.1", inputMode: "video")
        expect(fractionalResult.segments[0].start == 0.1 && fractionalResult.segments[0].end == 0.3, "Binary floating-point representation does not reject a mathematically exact selected range")
    }

    private static func strictResponses() throws {
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("missing time", { root in var s = root["segments"] as! [[String: Any]]; s[0].removeValue(forKey: "start"); root["segments"] = s }),
            ("numeric string", { root in var s = root["segments"] as! [[String: Any]]; s[0]["start"] = "0"; root["segments"] = s }),
            ("timecode string", { root in var s = root["segments"] as! [[String: Any]]; s[0]["start"] = "00:00:00"; root["segments"] = s }),
            ("boolean time", { root in var s = root["segments"] as! [[String: Any]]; s[0]["start"] = false; root["segments"] = s }),
            ("negative time", { root in var s = root["segments"] as! [[String: Any]]; s[0]["start"] = -0.1; root["segments"] = s }),
            ("zero length", { root in var s = root["segments"] as! [[String: Any]]; s[0]["end"] = 0; root["segments"] = s }),
            ("reversed time", { root in var s = root["segments"] as! [[String: Any]]; s[0]["start"] = 2; root["segments"] = s }),
            ("out of submitted range", { root in var s = root["segments"] as! [[String: Any]]; s[1]["end"] = 6.001; root["segments"] = s }),
            ("overlap", { root in var s = root["segments"] as! [[String: Any]]; s[1]["start"] = 0.5; root["segments"] = s }),
            ("out of order", { root in root["segments"] = (root["segments"] as! [[String: Any]]).reversed().map { $0 } }),
            ("null description", { root in var s = root["segments"] as! [[String: Any]]; s[0]["visual"] = NSNull(); root["segments"] = s }),
            ("missing description", { root in var s = root["segments"] as! [[String: Any]]; s[0].removeValue(forKey: "uncertainty"); root["segments"] = s }),
            ("unknown field", { $0["invented_schema"] = "unexpected" }),
            ("missing synopsis", { $0.removeValue(forKey: "synopsis") }),
            ("non-string structure", { $0["structure"] = ["act one", "act two"] }),
            ("no segments", { $0["segments"] = [[String: Any]]() })
        ]
        for (label, mutate) in cases {
            var changed = original; mutate(&changed)
            rejects(label) { _ = try parse(encoded(changed)) }
        }
        rejects("duplicate start key") { _ = try parse(json.replacingOccurrences(of: "\"start\":0", with: "\"start\":0,\"start\":0")) }
        rejects("escaped duplicate key") { _ = try parse(json.replacingOccurrences(of: "\"start\":0", with: "\"start\":0,\"\\u0073tart\":0")) }
        rejects("unrepresentable number") { _ = try parse(json.replacingOccurrences(of: "\"end\":1", with: "\"end\":1e999")) }
        rejects("prose around JSON") { _ = try parse("这是结果：\n" + json) }
        rejects("prose after fence") { _ = try parse("```json\n\(json)\n```\n结束") }
        rejects("wrong fence language") { _ = try parse("```swift\n\(json)\n```") }
        rejects("empty response") { _ = try parse(" \n") }
        rejects("oversized response") { _ = try parse(String(repeating: "x", count: ScriptAnalysisParser.maximumResponseBytes + 1)) }
        rejects("invalid UTF8") { _ = try ScriptAnalysisParser.parse(Data([0xFF]), project: fixture(), rangeStart: 0, rangeEnd: 1, modelID: "seed2.1", inputMode: "video") }
        rejects("nonfinite selected range") { _ = try ScriptAnalysisParser.parse(json, project: fixture(), rangeStart: .nan, rangeEnd: 8, modelID: "seed2.1", inputMode: "video") }
        rejects("selected range past project end") { _ = try ScriptAnalysisParser.parse(json, project: fixture(), rangeStart: 2, rangeEnd: 11, modelID: "seed2.1", inputMode: "video") }
    }

    private static func decimalEndpointRounding() throws {
        let duration = 6.766666666666667
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        func response(end: Double, cueEnd: Double? = nil, start: Double = 3,
                      cueStart: Double = 3, secondCueStart: Double? = nil) throws -> String {
            var object = original
            var segments = object["segments"] as! [[String: Any]]
            segments[1]["start"] = start; segments[1]["end"] = end
            if let cueEnd {
                var cues: [[String: Any]] = [["start":cueStart, "end":cueEnd, "speaker":"字幕", "text":"保留原句"]]
                if let secondCueStart { cues.append(["start":secondCueStart, "end":end, "speaker":"字幕", "text":"第二句"]) }
                segments[1]["dialogueCues"] = cues
            }
            object["segments"] = segments
            return try encoded(object)
        }
        func parseBounded(_ text: String, start: Double = 0, length: Double = duration) throws -> ScriptAnalysis {
            try ScriptAnalysisParser.parse(text, project: fixture(), rangeStart: start, rangeEnd: start + length,
                                           modelID: "seed2.1", inputMode: "video")
        }
        for roundedEnd in [6.77, 6.767, 6.7667] {
            for offset in [0.0, 1.125] {
                let result = try parseBounded(response(end: roundedEnd, cueEnd: roundedEnd), start: offset)
                expect(result.segments[1].end == offset + duration, "A known 2/3/4-decimal rounded overshoot aligns only the final scene endpoint")
                expect(result.segments[1].dialogueCues[0].end == offset + duration, "A cue sharing the rounded parent endpoint aligns to the same actual endpoint")
                expect(result.segments[0].start == offset && result.segments[0].end == offset + 1 && result.segments[1].start == offset + 3 && result.segments[1].dialogueCues[0].start == offset + 3, "Endpoint normalization never changes start times, internal cuts or gaps")
                expect(result.caveats.contains("片尾小数时间已对齐实际选段终点") && result.caveats.contains("台词需要对照原音轨核实"), "Alignment is disclosed while preserving the model's original caveats")
            }
        }
        let mixedPrecision = try parseBounded(response(end: 6.77, cueEnd: 6.7667))
        expect(mixedPrecision.segments[1].end == duration && mixedPrecision.segments[1].dialogueCues[0].end == duration, "Different endpoint precisions normalize when the raw cue is still inside its raw parent")
        let shorter = try parseBounded(response(end: 6.766, cueEnd: 6.766))
        expect(shorter.segments[1].end == 6.766 && shorter.segments[1].dialogueCues[0].end == 6.766, "Valid shorter endpoints remain unextended even when close to the end")
        expect(!shorter.caveats.contains("片尾小数时间已对齐"), "Unchanged timing does not claim an adjustment")
        let exact = try parseBounded(response(end: duration, cueEnd: duration))
        expect(exact.segments[1].end == duration && !exact.caveats.contains("片尾小数时间已对齐"), "Exact native endpoints remain unchanged without a normalization notice")

        for badEnd in [6.768, 6.769, 6.7701, 6.8, 7] {
            rejects("A nearby or large overshoot without exact decimal-rounding evidence") { _ = try parseBounded(response(end: badEnd)) }
        }
        rejects("Existing 6.001 > 6 remains an error") { _ = try parseBounded(response(end: 6.001), length: 6) }
        rejects("A rounded parent does not allow a non-rounding cue overshoot") { _ = try parseBounded(response(end: 6.77, cueEnd: 6.768)) }
        rejects("A rounded cue cannot exceed its raw parent's declared range") { _ = try parseBounded(response(end: 6.7667, cueEnd: 6.77)) }
        rejects("A cue beyond an exact raw parent is still invalid") { _ = try parseBounded(response(end: duration, cueEnd: 6.77)) }
        rejects("Rounded endpoints never repair overlapping scene starts") { _ = try parseBounded(response(end: 6.77, start: 0.5)) }
        rejects("Normalization cannot turn an out-of-range start into a valid segment") { _ = try parseBounded(response(end: 6.77, start: 6.7667)) }
        rejects("Normalization cannot turn a cue starting after the actual end into a valid cue") { _ = try parseBounded(response(end: 6.77, cueEnd: 6.77, cueStart: 6.7667)) }
        rejects("Rounded endpoint permission does not repair overlapping cues") { _ = try parseBounded(response(end: 6.77, cueEnd: 5.001, secondCueStart: 5)) }
        var overlapping = original
        var items = overlapping["segments"] as! [[String: Any]]
        items[0]["end"] = 3.334; items[1]["start"] = 3.333; items[1]["end"] = 6.77
        overlapping["segments"] = items
        rejects("Internal decimal cut mismatch is not mistaken for an end-of-video adjustment") { _ = try parseBounded(encoded(overlapping)) }

        do {
            _ = try parseBounded(response(end: 6.768))
            fatalError("Must reject a non-rounded overshoot")
        } catch {
            let detail = error.localizedDescription
            expect(detail.contains("start=3.0") && detail.contains("end=6.768") && detail.contains("上一段 end=1.0") && detail.contains(String(duration)), "Segment errors report actual start/end, previous end and true upper bound")
        }
        do {
            _ = try parseBounded(response(end: 6.77, cueEnd: 5.001, secondCueStart: 5))
            fatalError("Must reject an overlapping cue")
        } catch {
            let detail = error.localizedDescription
            expect(detail.contains("start=5.0") && detail.contains("end=6.77") && detail.contains("上一句 end=5.001") && detail.contains("原始段落范围") && detail.contains("归一后范围"), "Cue errors retain raw and normalized context for diagnosis")
        }
        let prompt = ScriptPrompt.make(project: fixture(), start: 0, end: duration, style: .shotScript, focus: "", transcript: "")
        expect(prompt.contains("附带视频时长 \(duration) 秒") && !prompt.contains("6.7667") && !prompt.contains("6.767"), "Fractional duration and cut hints never advertise an unreachable rounded upper bound")
        expect(prompt.contains("不要四舍五入到更大的值") && prompt.contains("不要用舍入制造重叠"), "Prompt explicitly keeps endpoints within the actual range without suggesting overlap repair")
        let simplePrompt = ScriptPrompt.make(project: fixture(), start: 2, end: 8, style: .shotScript, focus: "", transcript: "")
        expect(simplePrompt.contains("附带视频时长 6.0000 秒") && simplePrompt.contains("镜头 1：0.000–1.000 秒"), "Exactly representable whole-second hints retain their familiar concise formatting")
    }

    private static func currentness() throws {
        let p = fixture()
        let result = try parse(project: p)
        expect(result.isCurrent(for: p), "Fresh result matches its video and audio snapshots")
        var changed = p; changed.title = "只修改项目名称"
        expect(result.isCurrent(for: changed), "Legacy compatibility clip renaming does not invalidate content")
        changed.notes.append(StudyNote(start: 0, end: 1, track: .story, title: "人工观察", body: "", takeaway: "")); changed.cuts = [1, 3, 5]
        expect(result.isCurrent(for: changed), "Manual notes and cut annotations do not change analyzed media")
        changed.music[0].title = "只修改音乐名称"; changed.music[0].id = UUID()
        expect(result.isCurrent(for: changed), "Renaming music or changing an identity alone does not change the soundtrack")
        changed = p; changed.sourcePath = "/tmp/different-video.mp4"
        expect(!result.isCurrent(for: changed), "Replacing source video invalidates the result")
        changed = p; changed.clips = p.videoClips; changed.clips[0].sourceIn = 1
        expect(!result.isCurrent(for: changed), "Source trimming invalidates the result")
        changed = p; changed.duration = 5
        expect(!result.isCurrent(for: changed), "A range outside a shortened project cannot be current")
        changed = p; changed.music[0].volume = 0.7
        expect(!result.isCurrent(for: changed), "Music volume changes invalidate the soundtrack snapshot")
        changed = p; changed.music[0].timelineStart = 3
        expect(!result.isCurrent(for: changed), "Moving music invalidates the soundtrack snapshot")
        changed = p; changed.music = []
        expect(!result.isCurrent(for: changed), "Removing music invalidates the result")
        changed = p; changed.originalVolume = 0.3
        expect(!result.isCurrent(for: changed), "Original-audio volume changes invalidate the result")

        var a = p.videoClips[0]; a.sourceOut = 5
        var b = a; b.id = UUID(); b.sourcePath = "/tmp/second-video.mp4"
        let multi = SequenceLogic.makeProject(title: "双素材", clips: [a, b])
        let multiResult = try parse(project: multi)
        var reversed = multi; reversed.clips.reverse()
        expect(!multiResult.isCurrent(for: reversed), "Reordering distinct video clips invalidates the visual snapshot")
    }

    private static func persistenceAndMigration() throws {
        var p = fixture()
        let oldData = try ProjectPersistence.encodeProject(p)
        var oldObject = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        oldObject.removeValue(forKey: "scriptAnalyses")
        let migrated = try ProjectPersistence.decodeProject(JSONSerialization.data(withJSONObject: oldObject))
        expect(migrated.scriptAnalyses.isEmpty && migrated.notes == p.notes && migrated.music == p.music, "Existing project JSON without scriptAnalyses receives an empty default")

        var result = try parse(project: p)
        result.createdAt = p.createdAt
        result.timelineNoteIDs = [UUID()]
        p.scriptAnalyses = [result]
        let encodedProject = try ProjectPersistence.encodeProject(p)
        let restored = try ProjectPersistence.decodeProject(encodedProject)
        expect(restored == p, "Edited analysis fields and local linked-note IDs survive a project round trip")
        var object = try JSONSerialization.jsonObject(with: encodedProject) as! [String: Any]
        var histories = object["scriptAnalyses"] as! [[String: Any]]
        histories[0].removeValue(forKey: "sourceMusic"); histories[0].removeValue(forKey: "originalVolume"); histories[0].removeValue(forKey: "timelineNoteIDs")
        object["scriptAnalyses"] = histories
        let compatible = try ProjectPersistence.decodeProject(JSONSerialization.data(withJSONObject: object))
        expect(compatible.scriptAnalyses[0].sourceMusic.isEmpty && compatible.scriptAnalyses[0].originalVolume == 1 && compatible.scriptAnalyses[0].timelineNoteIDs.isEmpty, "Optional analysis snapshot and linked-note fields have migration defaults")

        var shortened = p
        shortened.duration = 5
        shortened.music = []
        let stale = try ProjectPersistence.decodeProject(ProjectPersistence.encodeProject(shortened))
        expect(stale.scriptAnalyses.count == 1 && !stale.scriptAnalyses[0].isCurrent(for: stale), "Outdated history remains saved against its original snapshot after the project is shortened")
        let independentNote = StudyNote(id: result.timelineNoteIDs[0], start: 2, end: 3, track: .story, title: "从脚本加入", body: "独立笔记", takeaway: "")
        p.notes = [independentNote]; p.scriptAnalyses.removeAll()
        let noHistory = try ProjectPersistence.decodeProject(ProjectPersistence.encodeProject(p))
        expect(noHistory.notes == [independentNote], "Removing script history never removes independently inserted timeline notes")

        var twenty = fixture()
        twenty.scriptAnalyses = (0..<20).map { _ in var copy = result; copy.id = UUID(); return copy }
        _ = try ProjectPersistence.encodeProject(twenty)
        expect(twenty.scriptAnalyses.count == 20, "Twenty histories are accepted without automatic deletion")
        var over = twenty; var copy = result; copy.id = UUID(); over.scriptAnalyses.append(copy)
        rejects("over twenty analyses") { _ = try ProjectPersistence.encodeProject(over) }
        var duplicate = fixture(); duplicate.scriptAnalyses = [result, result]
        rejects("duplicate analysis ID") { _ = try ProjectPersistence.encodeProject(duplicate) }
        var badSegment = result; badSegment.segments[1].id = badSegment.segments[0].id
        rejects("duplicate segment ID") { try ProjectPersistence.validateScriptAnalysis(badSegment) }
        var badTime = result; badTime.segments[0].start = .nan
        rejects("nonfinite persisted segment") { try ProjectPersistence.validateScriptAnalysis(badTime) }
        var badSnapshot = result; badSnapshot.sourceMusic[0].sourcePath = "https://example.com/music.wav"
        rejects("invalid audio snapshot source") { try ProjectPersistence.validateScriptAnalysis(badSnapshot) }
        var badLinked = result; badLinked.timelineNoteIDs.append(badLinked.timelineNoteIDs[0])
        rejects("duplicate linked note ID") { try ProjectPersistence.validateScriptAnalysis(badLinked) }
    }

    private static func markdown() throws {
        var result = try parse()
        result.segments[0].action = "转身\n离开"
        let output = result.exportMarkdown()
        expect(output.contains("00:00:02:00–00:00:03:00") && output.contains("00:00:05:00–00:00:08:00"), "Markdown exports absolute project timecodes")
        expect(output.contains("完整脚本") && output.contains("模型转写，待核对") && output.contains("设计解释（推测）") && output.contains("不确定性") && !output.contains("| --- |"), "Readable screenplay preserves transcript, reasoning and uncertainty without a wide table")
        expect(output.contains("雨夜街道 | 霓虹") && output.contains("转身\n离开"), "Paragraph Markdown preserves pipes and original line breaks without table escaping")
        expect(output.contains("/tmp/script-test-video.mp4") && output.contains("/tmp/script-test-music.wav"), "Export includes the source video and music snapshots")
        expect(output.contains(result.caveats) && output.contains(result.modelID) && output.contains(result.inputMode), "Export retains model, input mode and limitations")
    }
}
