import Foundation
import Darwin

/// Uses the real StudioModel and ProjectPersistence, but redirects every library
/// operation to a unique /tmp directory before constructing any persistent model.
/// No app, shortcuts, media selection, network, or user-library access is started.
///
/// swiftc -swift-version 5 Sources/Models.swift Sources/ScriptModels.swift \
///   Sources/MediaAnalyzer.swift Sources/CompositionBuilder.swift \
///   Sources/AppModel.swift Tests/ScriptPersistenceTests.swift \
///   -o /tmp/jingdu-script-persistence-tests
@main
@MainActor
struct ScriptPersistenceTests {
    private static var assertions = 0
    private static let environmentKey = "JINGDU_LIBRARY_DIRECTORY"

    static func main() async throws {
        let previous = ProcessInfo.processInfo.environment[environmentKey]
        let root = URL(fileURLWithPath: "/tmp/jingdu-script-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let resolved = root.resolvingSymlinksInPath().path
        guard resolved.hasPrefix("/private/tmp/") || resolved.hasPrefix("/tmp/") else {
            fatalError("Persistence tests must remain inside /tmp")
        }
        defer {
            if let previous { setenv(environmentKey, previous, 1) }
            else { unsetenv(environmentKey) }
            try? FileManager.default.removeItem(at: root)
        }

        try await savesSynchronouslyAndPreservesOtherProjects(root)
        try await writeFailureKeepsResultsAndCancelsDeferredSave(root)
        try await unreadableOriginalLibraryIsNeverOverwritten(root)
        try await nonpersistentModelNeverLoadsOrWrites(root)
        try invalidUpdatesDoNotChangeMemoryOrDisk(root)
        print("Script persistence tests passed (\(assertions) assertions; isolated /tmp libraries only).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    private static func useDirectory(_ root: URL, _ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        guard setenv(environmentKey, directory.path, 1) == 0,
              ProcessInfo.processInfo.environment[environmentKey] == directory.path else {
            fatalError("Refusing to run without an active isolated library directory")
        }
        return directory.appendingPathComponent("library.json")
    }

    private static func project(_ title: String) -> FilmProject {
        FilmProject(title: title, sourcePath: "/jingdu-test-no-media/fixture.mp4",
            duration: 10, frameRate: 30, width: 1920, height: 1080, cuts: [3, 6],
            notes: [StudyNote(start: 1, end: 2, track: .camera, title: "现有笔记", body: "保留原始观察", takeaway: "保留学习心得")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func addingScript(to project: FilmProject) -> FilmProject {
        var result = project
        result.scriptAnalyses.append(ScriptAnalysis(
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            modelID: "local-test-model", sourceClips: project.videoClips,
            rangeStart: 2, rangeEnd: 8, title: "临时测试脚本", synopsis: "观察人物进入画面。",
            structure: "进入、停顿、离开。",
            segments: [ScriptSegment(start: 2, end: 4, visual: "人物站在门边", action: "走入画面",
                dialogue: "待核对", sound: "待核对", camera: "固定机位", transition: "直接切换",
                reasoning: "可能用停顿形成期待。", uncertainty: "时间位置需要人工核对。")],
            caveats: "测试夹具，没有调用模型。", inputMode: "local fixture"))
        return result
    }

    private static func freshModel() -> StudioModel {
        let model = StudioModel()
        expect(model.projects.isEmpty, "A new isolated library must start empty")
        expect(model.error == nil, "A missing library is valid and writable")
        expect(!model.mediaAvailable, "Tests must not initiate media selection")
        return model
    }

    private static func savesSynchronouslyAndPreservesOtherProjects(_ root: URL) async throws {
        let library = try useDirectory(root, "successful-save")
        let model = freshModel()
        let original = project("待分析作品"), other = project("其他作品")
        model.projects = [original, other]
        model.selectedID = original.id
        let candidate = addingScript(to: original)
        expect(model.updateAndSave(candidate), "Successful synchronous save must return true")
        expect(FileManager.default.fileExists(atPath: library.path), "The library must exist before updateAndSave returns")
        let savedBytes = try Data(contentsOf: library)
        let loaded = try ProjectPersistence.load()
        expect(loaded.count == 2, "Saving one script must retain every library project")
        expect(loaded[0].scriptAnalyses == candidate.scriptAnalyses, "The complete script must already be on disk")
        expect(loaded[0].notes == original.notes && loaded[0].cuts == original.cuts, "Saving a script must preserve existing study edits")
        expect(loaded[1] == other, "An unrelated project must remain byte-equivalent after decoding")
        expect(model.project?.scriptAnalyses == candidate.scriptAnalyses, "The selected in-memory project contains the saved result")
        expect(model.canUndo, "Synchronous saving retains update's undo behavior")
        expect(model.error == nil, "A successful write must have no failure status")

        // A deferred closure left alive by update() would read this later memory
        // edit and overwrite the confirmed saved version after its 250 ms delay.
        model.projects[0].title = "只在内存中的探针修改"
        try await Task.sleep(nanoseconds: 400_000_000)
        let afterDelay = try Data(contentsOf: library)
        expect(afterDelay == savedBytes, "No delayed save may run after the synchronous save returns")
    }

    private static func writeFailureKeepsResultsAndCancelsDeferredSave(_ root: URL) async throws {
        let library = try useDirectory(root, "failed-save")
        let model = freshModel()
        let original = project("磁盘失败测试"), other = project("不可丢失的其他作品")
        model.projects = [original, other]
        model.selectedID = original.id
        let candidate = addingScript(to: original)
        // A directory at the final file path forces a real atomic-write failure,
        // regardless of permissions or whether tests run with elevated access.
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let sentinel = library.appendingPathComponent("keep.txt")
        let sentinelBytes = Data("原有目录内容不能被破坏".utf8)
        try sentinelBytes.write(to: sentinel)
        expect(!model.updateAndSave(candidate), "A real filesystem failure must return false")
        expect(model.project?.scriptAnalyses == candidate.scriptAnalyses, "A failed save must retain the new script in memory")
        expect(model.projects[1] == other, "A failed save must retain unrelated in-memory projects")
        expect(model.error?.contains("保存失败") == true && model.error?.contains("导出") == true, "A write failure must explain export recovery")
        let intactSentinel = try Data(contentsOf: sentinel)
        expect(intactSentinel == sentinelBytes, "Atomic-write failure cannot destroy the obstructing directory")
        let export = try ProjectPersistence.encodeProject(model.projects[0])
        let exported = try ProjectPersistence.decodeProject(export)
        expect(exported.scriptAnalyses == candidate.scriptAnalyses, "The unsaved result remains exportable")

        try FileManager.default.removeItem(at: library)
        try await Task.sleep(nanoseconds: 400_000_000)
        expect(!FileManager.default.fileExists(atPath: library.path), "Failed synchronous save must cancel the queued automatic write")
        // No content difference remains after failure: this also checks that a
        // retry still writes when update() returns early for an unchanged value.
        expect(model.updateAndSave(model.projects[0]), "The same in-memory result can be retried after disk recovery")
        let retried = try ProjectPersistence.load()
        expect(retried[0].scriptAnalyses == candidate.scriptAnalyses, "Retry must persist the previously unsaved script")
        expect(retried[1] == other, "Retry must still preserve the other project")
        expect(model.error == nil, "A successful retry must clear the previous save failure")
    }

    private static func unreadableOriginalLibraryIsNeverOverwritten(_ root: URL) async throws {
        let library = try useDirectory(root, "unreadable-original")
        let originalBytes = Data("{ 原库损坏，但必须保留以供恢复 }".utf8)
        try originalBytes.write(to: library)
        let model = StudioModel()
        expect(model.projects.isEmpty, "A malformed isolated library must not produce projects")
        expect(model.error?.contains("读取失败") == true, "Initialization must report the unreadable original")
        let original = project("读取失败后新建的临时作品")
        model.projects = [original]
        model.selectedID = original.id
        let candidate = addingScript(to: original)
        expect(!model.updateAndSave(candidate), "Read-failure protection must reject a claimed durable save")
        expect(model.project?.scriptAnalyses == candidate.scriptAnalyses, "Read-failure protection must still keep the new result for export")
        expect(model.error?.contains("尚未保存") == true, "The status must explicitly say the result is unsaved")
        let currentBytes = try Data(contentsOf: library)
        expect(currentBytes == originalBytes, "The original unreadable library must remain exactly intact")
        let export = try ProjectPersistence.encodeProject(model.projects[0])
        expect(!export.isEmpty, "Read-protected results must remain exportable")
        try await Task.sleep(nanoseconds: 400_000_000)
        let laterBytes = try Data(contentsOf: library)
        expect(laterBytes == originalBytes, "No deferred save may overwrite the unreadable original")
    }

    private static func nonpersistentModelNeverLoadsOrWrites(_ root: URL) async throws {
        let library = try useDirectory(root, "nonpersistent")
        let diskProject = project("临时磁盘中的已有作品")
        try ProjectPersistence.save([diskProject])
        let originalBytes = try Data(contentsOf: library)
        let model = StudioModel(persistent: false)
        expect(model.projects.isEmpty, "Nonpersistent initialization must not load even the isolated library")
        let original = project("仅内存作品")
        model.projects = [original]
        model.selectedID = original.id
        let candidate = addingScript(to: original)
        expect(model.updateAndSave(candidate), "Nonpersistent mode acknowledges a valid memory-only update")
        expect(model.project?.scriptAnalyses == candidate.scriptAnalyses, "Nonpersistent mode must still update all script fields")
        expect(model.canUndo, "Nonpersistent updates retain undo semantics")
        expect(model.error == nil, "Nonpersistent mode does not invent a disk failure")
        try await Task.sleep(nanoseconds: 400_000_000)
        let after = try Data(contentsOf: library)
        expect(after == originalBytes, "Nonpersistent updateAndSave must never write the library")
        let unchanged = try ProjectPersistence.load()
        expect(unchanged == [diskProject], "The unrelated disk library remains unchanged")
    }

    private static func invalidUpdatesDoNotChangeMemoryOrDisk(_ root: URL) throws {
        let library = try useDirectory(root, "invalid-input")
        let model = freshModel()
        let original = project("有效原作品")
        model.projects = [original]
        model.selectedID = original.id
        expect(model.updateAndSave(original), "An unchanged valid project can be saved for the first time")
        let originalBytes = try Data(contentsOf: library)
        var invalid = addingScript(to: original)
        invalid.scriptAnalyses[0].segments[0].end = 20
        expect(!model.updateAndSave(invalid), "Invalid script timing must fail validation")
        expect(model.projects == [original], "Validation failure must not place an invalid script in memory")
        expect(model.error != nil, "Validation failure must provide an explanation")
        expect(!model.canUndo, "Validation failures must not pollute undo history")
        let afterInvalid = try Data(contentsOf: library)
        expect(afterInvalid == originalBytes, "Validation failure must not alter the saved library")
        var missing = original
        missing.id = UUID()
        expect(!model.updateAndSave(missing), "A project not present in the library must not be silently appended")
        expect(model.projects == [original], "A missing project ID must not change the library")
    }
}
