import Foundation
import AppKit

/// Exercises the real app model without loading or saving the user's library.
/// Every media path is deliberately nonexistent. Internal calls to select()
/// therefore stop before decoding media; there are no panels or live shortcuts.
/// Build with Models, AppModel, MediaAnalyzer, and CompositionBuilder sources.
@main
@MainActor
struct WorkspaceWorkflowTests {
    private static var assertions = 0
    private static var failures: [String] = []

    static func main() async throws {
        _ = NSApplication.shared
        try crossClipCapture()
        try captureFromAnotherProject()
        renamePreservesProjectContents()
        noteContentAndFocus()
        musicEditingAndUndo()
        trimPreservesLearningAndMusic()
        structuralEditsInvalidateCutCandidates()
        rejectedCaptureIsAtomic()
        await cancelledImportDoesNotReappear()
        await cutFailureDoesNotCancelNextImport()
        if failures.isEmpty {
            print("Workspace workflow regressions passed (\(assertions) assertions; persistence disabled, fixture media only).")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            fatalError("\(failures.count) of \(assertions) workspace assertions failed")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }

    private static func fixture(_ title: String = "观察项目") -> FilmProject {
        let clips = [
            VideoClip(title: "前景", sourcePath: "/jingdu-workspace-test-no-media/\(title)-A.mp4", sourceDuration: 20,
                      sourceIn: 2, sourceOut: 7, frameRate: 24, width: 1920, height: 1080),
            VideoClip(title: "后景", sourcePath: "/jingdu-workspace-test-no-media/\(title)-B.mp4", sourceDuration: 30,
                      sourceIn: 10, sourceOut: 15, frameRate: 60, width: 1080, height: 1920)
        ]
        var project = SequenceLogic.makeProject(title: title, clips: clips)
        project.cuts = [1, 4.5, 6, 8]
        project.notes = [
            StudyNote(start: 3.5, end: 6.5, track: .camera, title: "", body: "跨素材保持出入画方向\n第二行观察", takeaway: "先观察方向，再解释动机"),
            StudyNote(start: 8, end: 9, track: .sound, title: "后半段声音", body: "先听音轨", takeaway: "")
        ]
        project.createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        project.updatedAt = project.createdAt
        return project
    }

    private static func model(_ projects: [FilmProject], selected: UUID? = nil) -> StudioModel {
        let result = StudioModel(persistent: false)
        expect(result.projects.isEmpty, "Nonpersistent initialization does not load the user's projects")
        result.projects = projects
        result.selectedID = selected ?? projects.first?.id
        expect(projects.flatMap(\.videoClips).allSatisfy { !FileManager.default.fileExists(atPath: $0.sourcePath) }, "Every selected source is a nonexistent test fixture")
        return result
    }

    private static func capture(_ model: StudioModel, from start: Double, to end: Double, target: UUID? = nil, title: String = "方向衔接") {
        model.captureStart = start
        model.captureEnd = end
        model.captureTitle = title
        model.captureTargetID = target
        model.newSpaceTitle = "我的方向练习"
        model.showCapture = true
        model.captureToSpace()
    }

    private static func crossClipCapture() throws {
        let source = fixture()
        let studio = model([source])
        studio.pendingIn = 4
        capture(studio, from: 4, to: 7)
        guard let destination = studio.project, let marked = studio.projects.first(where: { $0.id == source.id }) else {
            expect(false, "Capture leaves both source and destination in the library"); return
        }
        expect(destination.kind == .remix && destination.id != source.id, "Capture creates and selects a separate remix space")
        expect(destination.videoClips.count == 2 && near(destination.duration, 3), "A cross-seam capture contains exactly three seconds in two pieces")
        expect(destination.videoClips.map(\.sourcePath) == source.videoClips.map(\.sourcePath), "Each extracted piece keeps its actual source file")
        expect(destination.videoClips.map(\.sourceIn) == [6, 10] && destination.videoClips.map(\.sourceOut) == [7, 12], "Each source interval corresponds to the selected project interval")
        expect(destination.videoClips.allSatisfy { $0.sourceProjectID == source.id && $0.sourceProjectTitle == source.title }, "Every extracted clip keeps source-project provenance")
        expect(Set(destination.videoClips.map(\.id)).isDisjoint(with: Set(source.videoClips.map(\.id))), "Destination clips never reuse source clip identities")
        expect(destination.shots.map(\.start) == [0, 0.5, 1, 2], "Copied cuts and the source seam retain their positions")
        expect(destination.notes.count == 1 && destination.notes[0].body == source.notes[0].body, "Overlapping note text is preserved; unrelated notes are excluded")
        expect(destination.notes[0].start == 0 && destination.notes[0].end == 2.5, "Copied notes clamp to the extracted range and rebase to zero")
        expect(destination.notes[0].id != source.notes[0].id, "Copied notes have separate identities")
        expect(marked.notes.filter { $0.track == .learning && $0.title.hasPrefix("已收集") }.count == 1, "The original project gets one collection marker")
        expect(marked.notes.contains { $0.track == .learning && $0.start == 4 && $0.end == 7 }, "The source marker points at the original timeline interval")
        var expected = source
        expected.notes = marked.notes
        expected.updatedAt = marked.updatedAt
        expect(marked == expected, "Adding a collection marker does not alter source clips, cuts, music, or metadata")
        expect(!studio.showCapture && studio.pendingIn == nil && !studio.mediaAvailable && !studio.playbackLoading, "Capture closes its form, clears IN, and handles absent fixture media without a loading lock")
        _ = try ProjectPersistence.encodeProject(destination)
        _ = try ProjectPersistence.encodeProject(marked)
    }

    private static func captureFromAnotherProject() throws {
        let first = fixture("来源甲")
        let second = fixture("来源乙")
        let studio = model([first, second])
        capture(studio, from: 4, to: 7)
        guard let initialSpace = studio.project else { expect(false, "First capture creates a destination"); return }
        studio.select(second.id)
        capture(studio, from: 1, to: 3, target: initialSpace.id, title: "另一个项目的回应")
        guard let result = studio.project else { expect(false, "Second capture retains a destination"); return }
        expect(studio.projects.count == 3 && result.id == initialSpace.id, "A second source appends to the same space without creating a duplicate")
        expect(near(result.duration, 5) && result.videoClips.count == 3, "Appending preserves existing duration and extends it by the new range")
        expect(Array(result.videoClips.prefix(2)) == initialSpace.videoClips, "Appending keeps prior clip identities, ranges, titles, and provenance unchanged")
        expect(result.videoClips.last?.sourceProjectID == second.id && result.videoClips.last?.sourceIn == 3 && result.videoClips.last?.sourceOut == 5, "The appended clip keeps the second project's provenance and source coordinates")
        expect(Array(result.notes.prefix(initialSpace.notes.count)) == initialSpace.notes, "Appending cannot overwrite prior learning notes in the space")
        expect(studio.projects.first(where: { $0.id == first.id })?.notes.count == first.notes.count + 1, "The first source's collection mark survives a later append")
        expect(studio.projects.first(where: { $0.id == second.id })?.notes.count == second.notes.count + 1, "The second source also receives its own collection mark")
        _ = try ProjectPersistence.encodeProject(result)
    }

    private static func renamePreservesProjectContents() {
        let source = fixture()
        let other = fixture("旁边的项目")
        let studio = model([source, other])
        studio.requestRename(other.id)
        expect(studio.selectedID == source.id && studio.showRename, "Renaming an unselected project does not switch selection")
        studio.renameDraft = "  新作品名称  "
        studio.applyRename()
        guard let renamed = studio.projects.first(where: { $0.id == other.id }) else { expect(false, "Renamed project still exists"); return }
        var expected = other
        expected.title = "新作品名称"
        expected.updatedAt = renamed.updatedAt
        expect(renamed == expected, "Rename changes only title and modification date")
        expect(studio.project == source && !studio.showRename, "Rename preserves the current project and closes the form")
        studio.requestRename(source.id)
        studio.renameDraft = " \n "
        studio.applyRename()
        expect(studio.project == source && studio.showRename && studio.error != nil, "An empty name cannot erase or replace the project")
    }

    private static func noteContentAndFocus() {
        let source = fixture()
        let studio = model([source])
        let before = studio.focusReset
        studio.selectNote(source.notes[0])
        expect(studio.focusReset > before, "Selecting a note resets the previous text focus")
        expect(studio.selectedNote?.hasContent == true && studio.selectedNote?.displayTitle == "跨素材保持出入画方向", "A note with body and no title is visibly recorded using its first body line")
        expect(studio.selectedClipID == nil && studio.selectedMusicID == nil && studio.activeTrack == .camera, "Note selection clears conflicting inspectors and selects the note track")
        studio.editNote { $0.body = "\n  更新后的首行  \n后续内容"; $0.title = " " }
        expect(studio.selectedNote?.displayTitle == "更新后的首行", "Body edits immediately update the fallback display title")
        studio.editNote { $0.body = " "; $0.takeaway = "只记录启发" }
        expect(studio.selectedNote?.hasContent == true && studio.selectedNote?.displayTitle == "只记录启发", "Takeaway-only notes remain recorded and get a useful label")
        studio.editNote { $0.takeaway = "\n " }
        expect(studio.selectedNote?.hasContent == false && studio.selectedNote?.displayTitle.contains("镜头设计") == true, "An actually empty note returns to a track-and-time label")
        studio.selectVideoClip(source.videoClips[1].id)
        expect(studio.selectedNoteID == nil && studio.selectedClipID == source.videoClips[1].id && studio.currentTime == 5, "Selecting a video clip leaves note editing and seeks its timeline start")
        let focus = studio.focusReset
        studio.dismissTextFocus()
        expect(studio.focusReset == focus + 1, "Explicit focus dismissal emits a new reset even without an active window")
    }

    private static func musicEditingAndUndo() {
        var source = fixture()
        let music = MusicClip(title: "音乐片段", sourcePath: "/jingdu-workspace-test-no-media/music.m4a", sourceDuration: 30,
                              sourceIn: 2, sourceOut: 6, timelineStart: 1, volume: 0.6)
        source.music = [music]
        let studio = model([source])
        studio.selectMusic(music.id)
        expect(studio.selectedMusicID == music.id && studio.currentTime == 1 && studio.selectedNoteID == nil, "Music selection opens its inspector and seeks the music's start")
        studio.moveMusic(music.id, to: 100)
        expect(studio.selectedMusic?.timelineStart == 6 && studio.selectedMusic?.duration == 4, "Dragging music beyond the end clamps placement without trimming its source range")
        expect(studio.selectedMusic?.sourcePath == music.sourcePath && studio.selectedMusic?.sourceIn == 2 && studio.selectedMusic?.sourceOut == 6, "Music movement keeps source identity and trim points")
        expect(studio.canUndo && !studio.playbackLoading && !studio.busy, "A music move is undoable and missing test media cannot leave a loading lock")
        studio.undo()
        expect(studio.project?.music == [music], "Undo restores the exact music before its move")
        studio.redo()
        expect(studio.selectedMusic?.timelineStart == 6, "Redo restores the moved music")
        studio.editMusic(music.id, sourceIn: 3, sourceOut: 5, timelineStart: 4, volume: 0)
        expect(studio.selectedMusic?.sourceIn == 3 && studio.selectedMusic?.sourceOut == 5 && studio.selectedMusic?.timelineStart == 4 && studio.selectedMusic?.volume == 0, "Music trim, placement, and mute commit together")
        let valid = studio.projects
        studio.editMusic(music.id, sourceIn: 5, sourceOut: 3, timelineStart: 4, volume: 0.5)
        expect(studio.projects == valid && studio.error != nil, "Invalid music trim is rejected without altering any project")
        studio.error = nil
        studio.moveMusic(music.id, to: .nan)
        expect(studio.projects == valid, "Non-finite drag input is a safe no-op")
        studio.currentTime = 5
        studio.splitSelectedMusic()
        expect(studio.project?.music.count == 2, "Splitting inside selected music creates two pieces")
        if let pieces = studio.project?.music, pieces.count == 2 {
            expect(pieces[0].sourceIn == 3 && pieces[0].sourceOut == 4 && pieces[1].sourceIn == 4 && pieces[1].sourceOut == 5, "Split pieces partition the original source range exactly")
            expect(pieces[0].timelineStart == 4 && pieces[1].timelineStart == 5 && pieces.allSatisfy { $0.volume == 0 }, "Splitting preserves timeline continuity and mute")
            expect(pieces[0].id == music.id && pieces[1].id != music.id, "Splitting retains selected left identity and creates one fresh right identity")
        }
        studio.removeSelectedMusic()
        expect(studio.project?.music.count == 1 && studio.selectedMusicID == nil, "Removing selected music clears its inspector and preserves the other piece")
    }

    private static func trimPreservesLearningAndMusic() {
        var source = fixture()
        source.music = [MusicClip(title: "尾部音乐", sourcePath: "/jingdu-workspace-test-no-media/tail.m4a", sourceDuration: 20,
                                 sourceIn: 3, sourceOut: 7, timelineStart: 6)]
        let studio = model([source])
        studio.currentTime = 9
        studio.selectedNoteID = source.notes[0].id
        studio.trimVideoClip(source.videoClips[0].id, sourceIn: 4, sourceOut: 7)
        expect(studio.project?.duration == 8 && studio.project?.videoClips[0].sourceIn == 4, "Trimming one source updates the sequence duration")
        expect(studio.project?.notes.contains(where: { $0.id == source.notes[0].id && $0.body == source.notes[0].body }) == true, "Trimming retains written learning content and the original note identity")
        expect(studio.project?.notes.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= 8 } == true, "All notes remain within the shortened timeline")
        expect(studio.project?.music.first?.timelineStart == 6 && studio.project?.music.first?.sourceOut == 5, "Tail music trims to the new project end without shifting its start")
        expect(studio.currentTime == 8 && !studio.mediaAvailable && !studio.playbackLoading, "Trim clamps the playhead and safely handles unavailable source media")
        studio.undo()
        expect(studio.project?.videoClips == source.videoClips && studio.project?.notes == source.notes && studio.project?.music == source.music, "Undo recovers video trim, original notes, and trimmed-away music together")
    }

    private static func rejectedCaptureIsAtomic() {
        let source = fixture()
        let studio = model([source])
        studio.captureStart = 4; studio.captureEnd = 7
        studio.captureTitle = "不应半途保存"
        studio.newSpaceTitle = " "
        studio.showCapture = true
        studio.captureToSpace()
        expect(studio.projects == [source] && studio.selectedID == source.id, "Invalid destination validation cannot leave an orphan source collection marker")
        expect(studio.showCapture && studio.error != nil, "A rejected capture remains editable and reports why it failed")
        studio.error = nil
        studio.newSpaceTitle = "有效名称"
        studio.captureStart = -1
        studio.captureToSpace()
        expect(studio.projects == [source], "An invalid source interval cannot mutate either project")
        studio.captureStart = 4; studio.captureEnd = 7
        studio.captureToSpace()
        expect(studio.projects.count == 2 && !studio.showCapture, "Correcting capture input allows a successful retry")
    }

    private static func structuralEditsInvalidateCutCandidates() {
        let cases: [(String, (StudioModel, FilmProject) -> Void)] = [
            ("trim", { studio, source in studio.trimVideoClip(source.videoClips[0].id, sourceIn: 4, sourceOut: 7) }),
            ("move", { studio, source in studio.moveVideoClip(source.videoClips[0].id, delta: 1) }),
            ("remove", { studio, source in studio.removeVideoClip(source.videoClips[1].id) })
        ]
        for (name, edit) in cases {
            let source = fixture("切镜快照-\(name)")
            let studio = model([source])
            studio.candidateCuts = [2.5, 7.5]
            studio.showAnalysis = true
            edit(studio, source)
            expect(studio.project?.videoClips != source.videoClips, "The \(name) fixture actually changes source layout")
            expect(studio.candidateCuts == nil && !studio.showAnalysis, "A successful \(name) invalidates old cut candidates and closes their confirmation sheet")
            expect(!studio.busy && !studio.playbackLoading, "The \(name) path leaves neither an analysis lock nor a missing-media loading lock")
        }
    }

    private static func cancelledImportDoesNotReappear() async {
        let source = fixture()
        let studio = model([source])
        studio.importURLs = [URL(fileURLWithPath: "/jingdu-workspace-test-no-media/import.mp4")]
        studio.performImport(.append)
        expect(studio.busy && !studio.showImportOptions, "Import enters a cancelable busy state")
        studio.cancelAnalysis()
        expect(!studio.busy && studio.progress == 0 && studio.projects == [source], "Canceling import immediately clears busy state without modifying existing projects")
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(!studio.busy && studio.error == nil && studio.projects == [source], "A canceled import cannot later add clips or publish a stale failure")
    }

    private static func cutFailureDoesNotCancelNextImport() async {
        let source = fixture("分析失败后的导入")
        let studio = model([source])
        // Deliberately let analysis inspect a nonexistent fixture, to exercise
        // its genuine asynchronous failure path without reading any user media.
        studio.mediaAvailable = true
        studio.detectCuts()
        for _ in 0..<100 {
            if !studio.busy { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        expect(!studio.busy && studio.error != nil, "A failed cut analysis exits its busy state and explains the failure")
        studio.error = nil
        studio.importURLs = [URL(fileURLWithPath: "/jingdu-workspace-test-no-media/next-import.mp4")]
        studio.performImport(.append)
        expect(studio.busy, "Another import may begin after failed cut analysis")
        studio.trimVideoClip(source.videoClips[0].id, sourceIn: 4, sourceOut: 7)
        expect(studio.busy, "Cut snapshot invalidation must not cancel a subsequent unrelated import")
        studio.cancelAnalysis()
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(!studio.busy && studio.error == nil && studio.project?.videoClips.count == 2, "Cleanup cancels only the fixture import and prevents its stale error or result")
    }
}
