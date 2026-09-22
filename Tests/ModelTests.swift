import Foundation

@main
struct ModelTests {
    static func main() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let original = FilmProject(
            title: "测试 | 学习", sourcePath: "/tmp/example.mp4", duration: 10,
            frameRate: 30, width: 1920, height: 1080, cuts: [], notes: [],
            createdAt: date, updatedAt: date
        )
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
        }
        func rejects(_ project: FilmProject, _ phrase: String) {
            do {
                _ = try ProjectPersistence.encodeProject(project)
                fatalError("Should reject: \(phrase)")
            } catch {
                expect(error.localizedDescription.contains(phrase), "Missing understandable validation error: \(error)")
            }
        }

        expect(original.shots == [StudyShot(index: 0, start: 0, end: 10)], "An unsplit clip has one complete shot")
        let dirtyCuts: [Double] = [.nan, -.infinity, .infinity, -1, 0, 0.001, 2.001, 2.009, 5, 9.999, 10, 11]
        expect(ProjectLogic.normalizedCuts(dirtyCuts, duration: 10, frameRate: 30) == [2, 5], "Normalize duplicate, frame, edge and invalid cuts")
        expect(ProjectLogic.normalizedCuts([1], duration: .nan, frameRate: 30).isEmpty, "Invalid duration must not crash")
        let project = ProjectLogic.split(ProjectLogic.split(original, at: 2.001), at: 5)
        expect(project.cuts == [2, 5], "Split snaps to source frame")
        expect(project.shots.map(\.duration) == [2, 3, 5], "Shots cover the complete clip with no gaps")
        expect(ProjectLogic.split(project, at: 2.01) == project, "Repeated split is idempotent")
        expect(ProjectLogic.split(project, at: 0) == project, "Clip start cannot create a shot")
        expect(ProjectLogic.split(project, at: 10) == project, "Clip end cannot create a shot")
        expect(ProjectLogic.shotIndex(project, at: 0) == 0, "First frame belongs to first shot")
        expect(ProjectLogic.shotIndex(project, at: 1.999) == 0, "Before cut remains in previous shot")
        expect(ProjectLogic.shotIndex(project, at: 2) == 1, "Cut belongs to new shot")
        expect(ProjectLogic.shotIndex(project, at: 10) == 2, "Playback end belongs to final shot")
        expect(ProjectLogic.shotIndex(project, at: .infinity) == 2, "Beyond end clamps to final shot")
        expect(ProjectLogic.shotIndex(project, at: .nan) == 0, "NaN seek is handled safely")
        expect(ProjectLogic.removeCut(project, at: 2.001).cuts == [5], "Remove uses matching frame")
        expect(ProjectLogic.removeCut(project, at: 3).cuts == [2, 5], "Remove does not delete an unrelated nearby cut")
        let fractional = ProjectLogic.normalizedCuts([1.02, 1.021], duration: 3, frameRate: 23.976)
        expect(fractional.count == 1 && abs(fractional[0] * 23.976 - 24) < 0.000001, "Fractional source FPS uses exact source frames")
        expect(timecode(1) == "00:00:01:00", "Whole-second timecode")
        expect(timecode(1.0 / 30) == "00:00:00:01", "Single-frame timecode")
        expect(timecode(3661) == "01:01:01:00", "Long-duration timecode")
        expect(timecode(.nan) == "00:00:00:00", "Invalid timecode is safe")
        expect(timecode(1, frameRate: 0) == "00:00:01:00", "Invalid FPS uses fallback")

        var withNotes = project
        withNotes.notes = [
            StudyNote(start: 1, end: 3, track: .camera, title: "构图 | 视线", body: "观察主体的位置。", takeaway: "让切镜前后的视线延续。"),
            StudyNote(start: 10, end: 10, track: .sound, title: "结束点", body: "留白。", takeaway: "")
        ]
        // JSON dates use second precision, so give the fixture an exact second.
        withNotes.updatedAt = date
        let encoded = try ProjectPersistence.encodeProject(withNotes)
        let decoded = try ProjectPersistence.decodeProject(encoded)
        expect(decoded == withNotes, "Project export/import roundtrip preserves all learning data")
        expect(withNotes.notes[0].id == decoded.notes[0].id, "Stable note IDs survive roundtrip")
        let markdown = ProjectLogic.exportMarkdown(withNotes)
        expect(NoteTrack.allCases.allSatisfy { markdown.contains("## \($0.title)") }, "Export contains all four learning tracks")
        expect(markdown.contains("构图 \\| 视线"), "Markdown tables escape user pipes")
        expect(markdown.contains("可复用的创作启发") && markdown.contains(withNotes.notes[0].takeaway), "Reusable insights are exported")
        expect(markdown.contains("00:00:10:00"), "End markers appear in export")
        let prompt = ProjectLogic.exportAnalysisPrompt(withNotes)
        expect(prompt.contains("提交真实视频文件") && prompt.contains("不得编造"), "Model prompt requires real media and honest audio limits")

        var bad = original
        bad.duration = 0; rejects(bad, "时长")
        bad = original; bad.duration = .infinity; rejects(bad, "时长")
        bad = original; bad.frameRate = 0; rejects(bad, "帧率")
        bad = original; bad.width = 0; rejects(bad, "宽高")
        bad = original; bad.sourcePath = "https://example.com/video.mp4"; rejects(bad, "本机绝对路径")
        bad = original; bad.notes = [StudyNote(start: -1, end: 2, track: .story, title: "", body: "", takeaway: "")]; rejects(bad, "第 1 条笔记")
        bad.notes[0].start = 4; rejects(bad, "第 1 条笔记")
        bad.notes[0].start = 0; bad.notes[0].end = 11; rejects(bad, "第 1 条笔记")
        bad = withNotes; bad.notes.append(bad.notes[0]); rejects(bad, "笔记 ID 重复")
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["duration"] = -1
        do {
            _ = try ProjectPersistence.decodeProject(JSONSerialization.data(withJSONObject: object))
            fatalError("Import must validate values, not just JSON syntax")
        } catch { expect(error.localizedDescription.contains("时长"), "Imported invalid values explain reason in Chinese") }
        do {
            _ = try ProjectPersistence.decodeProject(Data("not json".utf8))
            fatalError("Invalid JSON should fail")
        } catch { expect(error.localizedDescription.contains("JSON"), "Malformed JSON explains format") }
        print("Model boundary, export, and import validation tests passed.")
    }
}
