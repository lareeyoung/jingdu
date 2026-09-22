import Foundation
import AVFoundation

// No user files, keys, or network. Recognition is injected; translation is intercepted.
final class SubtitleWorkflowHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let text = "{\"translations\":[{\"id\":0,\"chinese\":\"你好，世界。\"}]}"
        let bytes = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": text]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct SubtitleWorkflowTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(value(), message) }
    static func project(_ title: String) -> FilmProject {
        SequenceLogic.makeProject(title: title, clips: [VideoClip(title: "fixture", sourcePath: "/tmp/subtitle-offline-fixture.mp4", sourceDuration: 10, sourceIn: 0, sourceOut: 10, frameRate: 30, width: 640, height: 360)])
    }
    @MainActor final class Recognizer {
        var calls = 0
        var language: SubtitleLanguage = .zh
        func transcribe(_ project: FilmProject, _ requested: SubtitleLanguage?, _ progress: @Sendable (Double, String) -> Void) async throws -> [SubtitleCue] {
            calls += 1
            progress(0.1, "fixture")
            try await Task.sleep(nanoseconds: 100_000_000)
            return [SubtitleCue(start: 1, end: 3, language: language, text: language == .zh ? "你好，世界。" : "Hello, world.", chineseText: "")]
        }
    }
    @MainActor final class Harness {
        let studio = StudioModel(persistent: false)
        let scripts = ScriptWorkspaceModel(persistent: false)
        let recognizer = Recognizer()
        let subtitles: SubtitleWorkspaceModel
        init() {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SubtitleWorkflowHTTP.self]
            let recognizer = self.recognizer
            subtitles = SubtitleWorkspaceModel(transcribe: { project, language, progress in
                try await recognizer.transcribe(project, language, progress)
            }, translator: SubtitleTranslator(client: ScriptRelayClient(session: URLSession(configuration: config))))
            studio.projects = [project("first"), project("second")]; studio.selectedID = studio.projects[0].id
        }
        func configureTranslation() {
            scripts.configuration.baseURL = "https://offline-subtitle.example"
            scripts.configuration.modelID = "fake-model"
            scripts.configuration.appID = "fake-id"
            scripts.keyDraft = "fake-key-never-sent"; scripts.saveConfiguration()
        }
        func run(retry: Bool = false) { subtitles.generate(studio: studio, scripts: scripts, retry: retry) }
        func finish() async throws {
            for _ in 0..<200 { if !subtitles.isRunning { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            preconditionFailure("workflow timeout")
        }
    }
    static func main() async throws {
        do {
            let h = Harness(); let original = h.studio.project!
            h.run(); h.run(); try await h.finish()
            check(h.recognizer.calls == 1, "Repeated clicks do not start duplicate transcription")
            check(h.subtitles.error == nil && h.studio.project!.subtitleTrack?.cues.count == 1, "Chinese generation saves without credentials or translation")
            check(h.studio.project!.notes == original.notes && h.studio.project!.scriptAnalyses == original.scriptAnalyses, "Subtitles never alter script or notes")
            check(h.studio.project!.subtitleTrack!.cues[0].chineseText.isEmpty, "Chinese is not duplicated")
            check(h.studio.canUndo, "Subtitle result is undoable")
            h.studio.undo(); check(h.studio.project!.subtitleTrack == nil, "Undo restores previous subtitle track")
        }
        do {
            let h = Harness(); let owner = h.studio.selectedID
            h.run(); h.studio.selectedID = h.studio.projects[1].id; h.studio.showSubtitleReader = false
            try await h.finish()
            check(h.studio.projects[0].subtitleTrack != nil && h.studio.projects[1].subtitleTrack == nil, "Background completion saves only to source project")
            check(h.studio.selectedID != owner && !h.studio.showSubtitleReader, "Background completion never steals current project or reader")
        }
        do {
            let h = Harness(); h.run()
            h.studio.projects[0].clips[0].sourceIn = 1
            try await h.finish()
            check(h.studio.projects[0].subtitleTrack == nil && h.subtitles.error != nil, "Media edits during recognition reject obsolete timing")
        }
        do {
            let h = Harness(); h.run()
            h.studio.projects.removeFirst(); h.studio.selectedID = h.studio.projects[0].id
            try await h.finish()
            check(h.studio.projects[0].subtitleTrack == nil && h.subtitles.error != nil, "Deleted projects are not recreated on completion")
        }
        do {
            let h = Harness(); h.run(); h.subtitles.cancel(); try await h.finish()
            check(h.studio.project!.subtitleTrack == nil && h.subtitles.error == nil, "Cancellation commits no partial track and shows no error")
            check(!h.subtitles.canRetryTranslation, "Cancellation clears temporary recognition")
        }
        do {
            let h = Harness(); h.recognizer.language = .en; h.run(); try await h.finish()
            check(h.subtitles.error != nil && h.subtitles.retryAvailable(for: h.studio.project), "Missing translation credentials retain original text for retry")
            check(h.studio.project!.subtitleTrack == nil, "Incomplete bilingual subtitles do not replace existing track")
            h.configureTranslation(); h.run(retry: true); try await h.finish()
            check(h.subtitles.error == nil && h.recognizer.calls == 1, "Translation retry reuses local transcription")
            let cue = h.studio.project!.subtitleTrack!.cues[0]
            check(cue.text == "Hello, world." && cue.chineseText == "你好，世界。" && cue.start == 1 && cue.end == 3, "Translated text retains original and exact timing")
            check(!h.subtitles.canRetryTranslation, "Successful retry clears pending state")
            var invalid = cue; invalid.end = 11
            let previous = h.studio.project!.subtitleTrack
            check(!h.studio.saveSubtitle(invalid) && h.studio.project!.subtitleTrack == previous, "Invalid manual edits preserve the saved track")
            h.studio.error = nil
            var edited = cue; edited.chineseText = "你好！"
            check(h.studio.saveSubtitle(edited) && h.studio.project!.subtitleTrack!.cues[0].chineseText == "你好！", "Valid edits persist")
            h.studio.selectedSubtitleID = nil; h.studio.loopShot = true
            h.studio.selectSubtitle(edited)
            check(h.studio.selectedSubtitleID == edited.id && !h.studio.loopShot && h.studio.currentTime == edited.start, "Subtitle selection seeks to cue and releases shot loop")
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-save-failure-" + UUID().uuidString)
            try Data("blocked-directory".utf8).write(to: folder)
            let previous = ProcessInfo.processInfo.environment["JINGDU_LIBRARY_DIRECTORY"]
            setenv("JINGDU_LIBRARY_DIRECTORY", folder.path, 1)
            defer {
                if let previous { setenv("JINGDU_LIBRARY_DIRECTORY", previous, 1) } else { unsetenv("JINGDU_LIBRARY_DIRECTORY") }
                try? FileManager.default.removeItem(at: folder)
            }
            let studio = StudioModel(persistent: true)
            studio.projects = [project("failed disk fixture")]; studio.selectedID = studio.projects[0].id
            let scripts = ScriptWorkspaceModel(persistent: false)
            let subtitles = SubtitleWorkspaceModel(transcribe: { _, _, _ in [SubtitleCue(start: 1, end: 2, language: .zh, text: "测试字幕", chineseText: "")] })
            subtitles.generate(studio: studio, scripts: scripts)
            for _ in 0..<100 { if !subtitles.isRunning { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            check(subtitles.error != nil && !subtitles.status.hasPrefix("已生成"), "Disk failure never reports saved success")
            check(studio.currentSubtitleTrack != nil && !subtitles.canRetryTranslation, "Failed save retains result in memory for export and does not request translation again")
        }
        print("Subtitle workflow passed (\(checks) assertions; synthetic recognition, mocked relay, persistence disabled).")
    }
}
