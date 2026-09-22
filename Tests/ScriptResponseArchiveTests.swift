import Foundation
import Darwin

/// Offline archive checks. All files live in a fresh /tmp directory; no model,
/// account, media reader, app preferences, or real library is opened.
/// xcrun swiftc -swift-version 5 Sources/Models.swift Sources/ScriptModels.swift Sources/ScriptReading.swift Sources/ScriptResponseArchive.swift Tests/ScriptResponseArchiveTests.swift -o /tmp/jingdu-script-response-archive-tests
/// /tmp/jingdu-script-response-archive-tests
@main
struct ScriptResponseArchiveTests {
    private static var assertions = 0
    private static let environmentKey = "JINGDU_LIBRARY_DIRECTORY"
    private static let json = #"""
    {"title":"归档测试脚本","synopsis":"人物进入房间。","structure":"进入后停顿。","segments":[
      {"start":0,"end":2,"visual":"房门打开","action":"人物进入","dialogue":"请进。","sound":"门响","camera":"中景","transition":"硬切","reasoning":"建立空间","uncertainty":"离线测试","screenplay":"门被推开。人物走入房间，说：请进。","dialogueCues":[{"start":1,"end":2,"speaker":"人物","text":"请进。"}]},
      {"start":2,"end":6,"visual":"人物停住","action":"看向窗外","dialogue":"","sound":"","camera":"固定机位","transition":"","reasoning":"留出观察时间","uncertainty":"离线测试"}
    ],"caveats":"仅供离线测试。"}
    """#

    static func main() throws {
        let previous = ProcessInfo.processInfo.environment[environmentKey]
        let root = URL(fileURLWithPath: "/tmp/jingdu-script-response-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let resolved = root.resolvingSymlinksInPath().path
        guard resolved.hasPrefix("/private/tmp/") || resolved.hasPrefix("/tmp/") else {
            fatalError("Archive tests must remain inside /tmp")
        }
        defer {
            if let previous { setenv(environmentKey, previous, 1) }
            else { unsetenv(environmentKey) }
            try? FileManager.default.removeItem(at: root)
        }
        guard setenv(environmentKey, root.path, 1) == 0,
              ProcessInfo.processInfo.environment[environmentKey] == root.path else {
            fatalError("Refusing to run without the isolated library override")
        }

        try roundTripAndRestart(root)
        try retentionLimit(root)
        try sizeLimits(root)
        try failedParsingPreservesResponse(root)
        try incompleteAndLegacyResponses(root)
        print("Script response archive tests passed (\(assertions) assertions; isolated /tmp files, no network or credentials).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    private static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Should reject: \(message)") }
        catch { expect(error is ScriptModelError, "\(message) provides a script-specific error") }
    }

    private static func fixture() throws -> FilmProject {
        var project = FilmProject(title: "归档的原项目", sourcePath: "/jingdu-archive-fixture/video.mp4",
            duration: 10, frameRate: 30, width: 1920, height: 1080, cuts: [2, 5],
            notes: [StudyNote(start: 2, end: 3, track: .camera, title: "不应进入回复快照的笔记", body: "现有观察", takeaway: "学习记录")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001))
        project.music = [MusicClip(title: "配乐", sourcePath: "/jingdu-archive-fixture/music.wav", sourceDuration: 12,
            sourceIn: 1, sourceOut: 5, timelineStart: 2, volume: 0.4)]
        project.originalVolume = 0.7
        project.scriptAnalyses = [try ScriptAnalysisParser.parse(json, project: project, rangeStart: 2, rangeEnd: 8,
            modelID: "fixture-model", inputMode: "offline fixture")]
        return project
    }

    private static func record(project: FilmProject, text: String = json) -> ScriptResponseRecord {
        var result = ScriptResponseRecord(project: project, rangeStart: 2, rangeEnd: 8,
            modelID: "fixture-model", inputMode: "offline fixture", text: text)
        result.receivedAt = Date(timeIntervalSince1970: 1_700_000_002)
        return result
    }

    private static func file(_ record: ScriptResponseRecord, archive: ScriptResponseArchive) -> URL {
        archive.directory.appendingPathComponent(record.id.uuidString + ".json")
    }

    private static func roundTripAndRestart(_ root: URL) throws {
        let project = try fixture()
        // Preserve whitespace, escaped quotation marks, Unicode, and code fences
        // exactly as received; successful parsing must not rewrite the archive.
        let raw = " \r\n```json\r\n\(json)\r\n```\r\n "
        let response = record(project: project, text: raw)
        let archive = ScriptResponseArchive()
        expect(archive.directory == root.appendingPathComponent("ScriptResponses", isDirectory: true), "Default archive honors JINGDU_LIBRARY_DIRECTORY")
        expect(archive.load().isEmpty, "A new isolated archive starts empty")
        expect(!FileManager.default.fileExists(atPath: archive.directory.path), "Loading a missing archive does not create files")
        try archive.save(response)
        let bytesBefore = try Data(contentsOf: file(response, archive: archive))

        // Construct a new archive, rather than relying on the original value's
        // state, to exercise the same disk decoding used at the next launch.
        let restarted = ScriptResponseArchive()
        let loaded = restarted.load()
        expect(loaded.count == 1, "A fresh archive instance reloads the saved response")
        let restored = loaded[0]
        expect(restored.text == raw && Data(restored.text.utf8) == Data(raw.utf8), "Raw response text survives byte-for-byte UTF-8 round trip")
        expect(restored.id == response.id && restored.receivedAt == response.receivedAt, "Response identity and receive date survive restart")
        expect(restored.rangeStart == 2 && restored.rangeEnd == 8 && restored.modelID == response.modelID && restored.inputMode == response.inputMode, "Selected range and model context survive restart")
        var snapshot = project; snapshot.notes = []; snapshot.scriptAnalyses = []
        expect(restored.project == snapshot, "Snapshot retains project/media context while stripping notes and scripts")
        expect(project.notes.count == 1 && project.scriptAnalyses.count == 1, "Creating a response never strips notes or scripts from its source project")
        let first = try restored.parse(), second = try restored.parse()
        expect(first.id == restored.id && second.id == first.id, "Repeated local parsing keeps the stable response ID for deduplication")
        expect(first.createdAt == restored.receivedAt && second.createdAt == first.createdAt, "Local recovery preserves the original receive date")
        expect(first.segments.map(\.start) == [2, 4] && first.segments.map(\.end) == [4, 8], "Recovery restores absolute project times without double-offsetting")
        expect(first.segments[0].dialogueCues.first?.start == 3 && first.segments[0].dialogueCues.first?.end == 4, "Dialogue times recover against the archived selected range")
        expect(first.isCurrent(for: project), "Archived media context still matches its original project")
        let bytesAfter = try Data(contentsOf: file(response, archive: archive))
        expect(bytesAfter == bytesBefore, "Parsing never rewrites the response file")
        try restarted.save(restored)
        expect(restarted.load().map(\.id) == [response.id], "Re-saving the same response does not create a second archive entry")
        let explicit = ScriptResponseArchive(directory: root.appendingPathComponent("explicit", isDirectory: true))
        expect(explicit.directory.lastPathComponent == "explicit" && explicit.load().isEmpty, "An explicit archive directory is independent from the environment-backed archive")
    }

    private static func retentionLimit(_ root: URL) throws {
        let archive = ScriptResponseArchive(directory: root.appendingPathComponent("retention", isDirectory: true))
        let project = try fixture()
        var responses: [ScriptResponseRecord] = []
        for index in 0..<22 {
            var response = record(project: project, text: "原文 \(index)")
            response.receivedAt = Date(timeIntervalSince1970: Double(index))
            responses.append(response)
            try archive.save(response)
        }
        let expected = responses.suffix(20).reversed().map(\.id)
        expect(ScriptResponseArchive.limit == 20 && archive.load().count == 20, "Only the twenty most recent responses are retained")
        expect(archive.load().map(\.id) == expected, "Entries are ordered by receive time, newest first")
        let files = try FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil)
        expect(files.filter { $0.pathExtension == "json" }.count == 20, "Retention also removes old archive files from disk")
        expect(!FileManager.default.fileExists(atPath: file(responses[0], archive: archive).path) && !FileManager.default.fileExists(atPath: file(responses[1], archive: archive).path), "The two oldest responses are pruned")
        expect(ScriptResponseArchive(directory: archive.directory).load().map(\.id) == expected, "Retention order and limit remain correct after restart")
    }

    private static func sizeLimits(_ root: URL) throws {
        let archive = ScriptResponseArchive(directory: root.appendingPathComponent("size-limits", isDirectory: true))
        let project = try fixture()
        let maximum = ScriptAnalysisParser.maximumResponseBytes
        let boundary = record(project: project, text: String(repeating: "x", count: maximum))
        try archive.save(boundary)
        expect(archive.load().first?.text.utf8.count == maximum, "The exact 4 MB text boundary is accepted")
        let before = try Data(contentsOf: file(boundary, archive: archive))
        let tooMuchText = record(project: project, text: String(repeating: "界", count: maximum / 3 + 1))
        expect(tooMuchText.text.count < maximum && tooMuchText.text.utf8.count > maximum, "The oversized fixture exceeds the UTF-8 byte limit, not the character count")
        rejects("Response text over 4 MB") { try archive.save(tooMuchText) }
        expect(!FileManager.default.fileExists(atPath: file(tooMuchText, archive: archive).path), "An oversized text response is rejected before writing")

        // JSON escapes control characters, so an allowed raw-text size can
        // still exceed the separate 8 MB encoded-record limit.
        let tooMuchEncoded = record(project: project, text: String(repeating: "\u{0001}", count: 1_400_000))
        let encoded = try JSONEncoder().encode(tooMuchEncoded)
        expect(tooMuchEncoded.text.utf8.count <= maximum && encoded.count > 8 * 1024 * 1024, "Encoded-size fixture isolates the 8 MB record limit")
        rejects("Encoded response and media context over 8 MB") { try archive.save(tooMuchEncoded) }
        expect(!FileManager.default.fileExists(atPath: file(tooMuchEncoded, archive: archive).path), "An oversized encoded record is rejected before writing")
        let after = try Data(contentsOf: file(boundary, archive: archive))
        expect(after == before && archive.load().map(\.id) == [boundary.id], "Rejected saves leave the previous archive intact")

        // Simulate invalid external files without going through save(), so the
        // read path's limits are tested independently from write validation.
        try JSONEncoder().encode(tooMuchText).write(to: file(tooMuchText, archive: archive))
        try encoded.write(to: file(tooMuchEncoded, archive: archive))
        expect(ScriptResponseArchive(directory: archive.directory).load().map(\.id) == [boundary.id], "Restart ignores oversized raw and encoded response files")
    }

    private static func failedParsingPreservesResponse(_ root: URL) throws {
        let archive = ScriptResponseArchive(directory: root.appendingPathComponent("failed-parse", isDirectory: true))
        let raw = " \r\n{\"title\":\"未完成的回复 🎬\",\"segments\":[\r\n"
        let response = record(project: try fixture(), text: raw)
        try archive.save(response)
        let before = try Data(contentsOf: file(response, archive: archive))
        rejects("Malformed model text") { _ = try response.parse() }
        let loaded = ScriptResponseArchive(directory: archive.directory).load()
        expect(loaded.count == 1 && loaded[0].id == response.id && loaded[0].text == raw, "A parser failure leaves the original response recoverable after restart")
        rejects("The same malformed archive during local recovery") { _ = try loaded[0].parse() }
        let after = try Data(contentsOf: file(response, archive: archive))
        expect(before == after && archive.load()[0].text == raw, "Repeated failed recovery cannot replace or normalize raw response text")
    }

    private static func incompleteAndLegacyResponses(_ root: URL) throws {
        let archive = ScriptResponseArchive(directory: root.appendingPathComponent("incomplete", isDirectory: true))
        var response = record(project: try fixture())
        let complete = try response.parse()
        expect(complete.id == response.id, "The incomplete-response fixture contains otherwise valid script JSON")
        response.isIncomplete = true
        try archive.save(response)
        let before = try Data(contentsOf: file(response, archive: archive))
        rejects("Valid JSON marked incomplete") { _ = try response.parse() }
        let restored = ScriptResponseArchive(directory: archive.directory).load()[0]
        expect(restored.isIncomplete == true && restored.text == json && restored.id == response.id, "Incomplete status and original JSON survive an archive restart")
        rejects("An incomplete archived response after restart") { _ = try restored.parse() }
        let after = try Data(contentsOf: file(response, archive: archive))
        expect(after == before, "Refusing an incomplete result preserves its raw text for export")

        var explicitComplete = record(project: try fixture())
        explicitComplete.isIncomplete = false
        let accepted = try explicitComplete.parse()
        expect(accepted.id == explicitComplete.id, "An explicitly complete response remains parseable")
        let legacyArchive = ScriptResponseArchive(directory: root.appendingPathComponent("legacy-record", isDirectory: true))
        try FileManager.default.createDirectory(at: legacyArchive.directory, withIntermediateDirectories: false)
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(explicitComplete)) as! [String: Any]
        legacyObject.removeValue(forKey: "isIncomplete")
        expect(legacyObject["isIncomplete"] == nil, "Legacy fixture genuinely omits the new optional field")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyObject)
        try legacyBytes.write(to: file(explicitComplete, archive: legacyArchive))
        let oldRecord = ScriptResponseArchive(directory: legacyArchive.directory).load()[0]
        expect(oldRecord.isIncomplete == nil && oldRecord.text == json && oldRecord.id == explicitComplete.id, "An old archive without isIncomplete decodes with its original identity and text")
        let oldResult = try oldRecord.parse()
        expect(oldResult.id == explicitComplete.id && oldResult.createdAt == explicitComplete.receivedAt, "Legacy records remain recoverable with stable script identity and date")
    }
}
