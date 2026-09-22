import Foundation

/// Runs against the real StudioModel. Every instance disables persistence, and no
/// test selects media, opens a panel, installs shortcuts, or starts the app.
@main
@MainActor
struct AppModelTests {
    private static var assertions = 0

    static func main() throws {
        testNoteEditingParticipatesInUndo()
        testEditingAfterUndoInvalidatesRedo()
        testRedoRecomputesSelectedShot()
        testInvalidUpdatesPreserveTheLibrary()
        testMarkerRanges()
        print("AppModel regression tests passed (\(assertions) assertions; persistence disabled).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    private static func makeModel(cuts: [Double] = []) -> StudioModel {
        let note = StudyNote(start: 1, end: 2, track: .camera, title: "视线延续", body: "原始观察", takeaway: "连接相邻镜头的视线。")
        let fixture = FilmProject(
            title: "AppModel 回归测试", sourcePath: "/jingdu-test-no-media/fixture.mp4",
            duration: 10, frameRate: 30, width: 1920, height: 1080,
            cuts: cuts, notes: [note]
        )
        let model = StudioModel(persistent: false)
        expect(model.projects.isEmpty, "Nonpersistent initialization must not load the user's library")
        model.projects = [fixture]
        model.selectedID = fixture.id
        model.selectedNoteID = note.id
        expect(!model.mediaAvailable, "Fixture must keep all media work disabled")
        return model
    }

    private static func testNoteEditingParticipatesInUndo() {
        let model = makeModel()
        let noteID = model.selectedNoteID
        model.currentTime = 4
        model.split()
        expect(model.project?.cuts == [4], "Fixture split creates the expected cut")
        model.editNote { $0.body = "新观察：出画方向与下一镜的入画方向相接。" }
        let editedBody = model.selectedNote?.body
        expect(model.canUndo, "Note edit must be undoable")

        model.undo()
        expect(model.project?.cuts == [4], "First undo restores the note edit, not the earlier split")
        expect(model.selectedNote?.body == "原始观察", "Undo restores the exact previous note text")
        expect(model.project?.notes.count == 1 && model.selectedNoteID == noteID, "Undo must preserve the existing note and identity")

        model.redo()
        expect(model.selectedNote?.body == editedBody, "Redo restores all edited text")
        expect(model.project?.cuts == [4], "Redoing note text leaves the cut intact")

        model.undo()
        model.undo()
        expect(model.project?.cuts.isEmpty == true, "Second undo can restore the split independently")
        expect(model.selectedNote?.body == "原始观察", "Undoing a split does not remove the existing note")
        model.redo()
        model.redo()
        expect(model.project?.cuts == [4] && model.selectedNote?.body == editedBody, "Redo reconstructs both split and note edits in sequence")
    }

    private static func testEditingAfterUndoInvalidatesRedo() {
        let model = makeModel()
        model.currentTime = 4
        model.split()
        model.undo()
        expect(model.canRedo, "Undo provides a redo candidate")
        model.editNote { $0.body = "撤销后继续记录的新发现" }
        expect(!model.canRedo, "A new note edit must invalidate stale redo snapshots")
        model.redo()
        expect(model.selectedNote?.body == "撤销后继续记录的新发现", "Stale redo cannot overwrite newly entered text")
        expect(model.project?.cuts.isEmpty == true, "An invalidated redo must not resurrect the split")
    }

    private static func testRedoRecomputesSelectedShot() {
        let model = makeModel(cuts: [3, 6])
        model.currentTime = 7
        model.selectedShotIndex = 2
        model.mergePrevious()
        expect(model.shots.count == 2, "Merging the last shot reduces the count")
        model.undo()
        expect(model.shots.count == 3 && model.selectedShotIndex == 2, "Undo follows the current time in the restored shots")
        // Equivalent to reselecting the last restored shot, without touching AVPlayer.
        model.currentTime = 7
        model.selectedShotIndex = 2
        model.redo()
        expect(model.shots.count == 2, "Redo reapplies the merge")
        expect(model.selectedShotIndex == 1, "Redo must not retain an out-of-range shot index")
        expect(model.selectedShot?.start == 3 && model.selectedShot?.end == 10, "Selected shot remains the merged last shot, not a fallback to the first")
        expect(model.selectedShotIndex == ProjectLogic.shotIndex(model.project!, at: model.currentTime), "Selected shot stays aligned with the playhead")

        model.currentTime = 10
        model.undo()
        expect(model.selectedShotIndex == 2, "End-of-clip undo selects the final restored shot")
        model.redo()
        expect(model.selectedShotIndex == 1, "End-of-clip redo selects the final merged shot")
    }

    private static func testInvalidUpdatesPreserveTheLibrary() {
        let model = makeModel()
        let original = model.projects
        let invalidMutations: [(String, (inout FilmProject) -> Void)] = [
            ("empty title", { $0.title = "  " }),
            ("oversized title", { $0.title = String(repeating: "镜", count: 501) }),
            ("invalid duration", { $0.duration = .nan }),
            ("unsupported frame rate", { $0.frameRate = 480 }),
            ("invalid dimensions", { $0.width = 0 }),
            ("nonlocal source", { $0.sourcePath = "https://example.com/movie.mp4" }),
            ("negative marker", { $0.notes[0].start = -1 }),
            ("reversed marker", { $0.notes[0].start = 3 }),
            ("marker beyond clip", { $0.notes[0].end = 11 }),
            ("duplicate note ID", { $0.notes.append($0.notes[0]) })
        ]
        for (name, mutate) in invalidMutations {
            var candidate = original[0]
            mutate(&candidate)
            model.error = nil
            model.update(candidate)
            expect(model.projects == original, "Rejected \(name) must not modify the in-memory library")
            expect(model.error != nil, "Rejected \(name) must explain the error")
            expect(!model.canUndo && !model.canRedo, "Rejected \(name) must not pollute undo history")
        }

        model.error = nil
        model.editNote { $0.body = "无效操作后的有效编辑仍然正常。" }
        expect(model.error == nil && model.selectedNote?.body == "无效操作后的有效编辑仍然正常。", "Valid edits remain possible after validation failures")
        model.persist()
        model.flush()
        expect(model.error == nil, "Nonpersistent save and flush remain no-ops")
    }

    private static func testMarkerRanges() {
        let model = makeModel(cuts: [3, 6])
        model.currentTime = 9.8
        model.selectedShotIndex = 2
        model.addNote(track: .sound)
        expect(model.selectedNote?.start == 9.8 && model.selectedNote?.end == 10, "Default marker clamps to the clip end")

        model.currentTime = 10
        model.addNote(track: .learning)
        expect(model.selectedNote?.start == 10 && model.selectedNote?.end == 10, "Clip end supports a valid zero-length marker")

        model.currentTime = 8
        model.setIn()
        model.currentTime = 3
        model.setOut()
        expect(model.selectedNote?.start == 3 && model.selectedNote?.end == 8, "Reverse IN/OUT navigation produces an ordered range")
        expect(model.pendingIn == nil, "Completing a range clears the pending IN point")

        let count = model.project!.notes.count
        model.currentTime = 4
        model.setOut()
        expect(model.pendingIn == 4 && model.project?.notes.count == count, "OUT without IN establishes a start without creating a stray marker")
        model.currentTime = 4
        model.setOut()
        expect(model.selectedNote?.start == 4 && model.selectedNote?.end == 4, "Matching IN/OUT points create a valid point marker")

        let validNotes = model.project!.notes
        model.editNote { $0.end = 11 }
        expect(model.project?.notes == validNotes, "Editing a marker past clip end cannot enter the project")
        model.addNote(track: .story, start: -1, end: 2)
        expect(model.project?.notes == validNotes, "Explicit out-of-bounds marker input is rejected")
        expect(model.project!.notes.allSatisfy {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start <= $0.end && $0.end <= model.project!.duration
        }, "Every accepted marker satisfies the project time range invariant")
    }
}
