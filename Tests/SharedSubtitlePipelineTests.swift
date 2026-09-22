import Foundation
import AVFoundation

/// All speech, translation and video-analysis responses are offline fixtures.
/// Pass only a disposable synthetic MP4, never a user's media.
final class SharedSubtitleHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var translations = 0
    private static var scripts = 0
    private static var prompts: [String] = []
    static var failScript = false
    static var failTranslation = false
    static var duration = 6.0
    static var counts: (translation: Int, script: Int, prompts: [String]) {
        lock.lock(); defer { lock.unlock() }; return (translations, scripts, prompts)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        }
        let object = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let message = (object["messages"] as! [[String: Any]])[0]
        let isTranslation = message["content"] is String
        let text: String
        let status: Int
        Self.lock.lock()
        if isTranslation {
            Self.translations += 1
            text = "{\"translations\":[{\"id\":0,\"chinese\":\"你好，世界。\"}]}"; status = Self.failTranslation ? 500 : 200
        } else {
            Self.scripts += 1
            let content = message["content"] as! [[String: Any]]
            Self.prompts.append(content.first { $0["type"] as? String == "text" }?["text"] as? String ?? "")
            status = Self.failScript ? 500 : 200
            text = String(data: try! JSONSerialization.data(withJSONObject: [
                "title": "共享证据离线测试", "synopsis": "测试", "structure": "测试", "caveats": "离线响应",
                "segments": [["start": 0, "end": Self.duration, "screenplay": "人物站在测试画面里。", "visual": "测试画面", "action": "站立", "dialogue": "", "dialogueCues": [], "sound": "待核对", "camera": "固定", "transition": "无", "reasoning": "测试", "uncertainty": "测试"]]
            ]), encoding: .utf8)!
        }
        Self.lock.unlock()
        let body: [String: Any] = status == 200 ? ["choices": [["finish_reason": "stop", "message": ["content": text]]]] : ["error": ["message": "synthetic script failure"]]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct SharedSubtitlePipelineTests {
    static var checks = 0
    static var fixture: FilmProject!
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(condition(), message) }
    static func wait(_ message: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        preconditionFailure("Timed out: " + message)
    }
    @MainActor final class Recognizer {
        var calls = 0, cancellations = 0
        var language: SubtitleLanguage = .zh
        var empty = false, fail = false, delayedCleanup = false
        func run(_ project: FilmProject, _ requested: SubtitleLanguage?, _ progress: @Sendable (Double, String) -> Void) async throws -> [SubtitleCue] {
            calls += 1; progress(0.2, "离线识别")
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch {
                cancellations += 1
                if delayedCleanup { try? await Task.detached { try await Task.sleep(nanoseconds: 150_000_000) }.value }
                throw error
            }
            if fail { throw ScriptRelayError.message("synthetic recognizer failure") }
            if empty { return [] }
            return [SubtitleCue(start: 1, end: 3, language: language, text: language == .zh ? "你好，世界。" : "Hello, world.", chineseText: "")]
        }
    }
    @MainActor final class Harness {
        let studio = StudioModel(persistent: false)
        let recognizer = Recognizer()
        let subtitles: SubtitleWorkspaceModel
        let scripts: ScriptWorkspaceModel
        init() {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SharedSubtitleHTTP.self]
            let client = ScriptRelayClient(session: URLSession(configuration: config))
            let recognizer = self.recognizer
            subtitles = SubtitleWorkspaceModel(transcribe: { try await recognizer.run($0, $1, $2) }, translator: SubtitleTranslator(client: client))
            scripts = ScriptWorkspaceModel(persistent: false, client: client, subtitles: subtitles)
            scripts.configuration.baseURL = "https://offline-shared-subtitles.example"
            scripts.configuration.appID = "fake-id"; scripts.configuration.modelID = "fixture-seed-model"
            scripts.keyDraft = "fake-key-never-leaves-urlprotocol"; scripts.saveConfiguration()
            studio.projects = [fixture]; studio.selectedID = fixture.id
            scripts.workspaceProjectID = fixture.id; scripts.rangeStart = 0; scripts.rangeEnd = fixture.duration
            scripts.showReader = false; studio.showSubtitleReader = false
        }
        func ensure() -> Task<SubtitleTrack, Error> {
            let project = studio.project!
            return Task { try await subtitles.ensureTrack(for: project, studio: studio, scripts: scripts) }
        }
        func finish() async throws { try await wait("all operations finish") { !self.subtitles.isRunning && !self.scripts.isRunning } }
        func track() -> SubtitleTrack { SubtitleTrack(sourceClips: studio.project!.videoClips, cues: [SubtitleCue(start: 1, end: 3, language: .en, text: "Hello, world.", chineseText: "你好，世界。")], sourceDescription: "本地 Whisper small / whisper.cpp 语音识别 · fixture-seed-model 中文翻译") }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a disposable synthetic MP4 fixture") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]); let bytes = try Data(contentsOf: url)
        let info = try await MediaAnalyzer.inspect(url)
        fixture = SequenceLogic.makeProject(title: "共享字幕离线夹具", clips: [VideoClip(title: "fixture", sourcePath: url.path, sourceDuration: info.duration, sourceIn: 0, sourceOut: info.duration, frameRate: info.frameRate, width: info.width, height: info.height)])
        SharedSubtitleHTTP.duration = fixture.duration
        do {
            let h = Harness(); let track = h.track(); h.studio.projects[0].subtitleTrack = track
            let before = SharedSubtitleHTTP.counts
            let result = try await h.ensure().value
            check(result == track && h.recognizer.calls == 0, "Current subtitle track is reused exactly without recognition")
            check(SharedSubtitleHTTP.counts.translation == before.translation, "Cached bilingual track performs zero translation requests")
            check(!h.studio.showSubtitleReader && !h.scripts.showReader, "Reading shared evidence never opens either sidebar")
            let prompt = ScriptPrompt.make(project: h.studio.project!, start: 2, end: 4, style: .shotScript, focus: "", transcript: "")
            check(prompt.contains("\"start\":0") && prompt.contains("\"end\":1"), "Shared subtitle times are relative to and bounded by the analysis range")
            check(prompt.contains("Hello, world.") && prompt.contains("你好，世界。") && prompt.contains("Whisper"), "Original, Chinese and actual speech source are included")
            check(prompt.contains("dialogueCues 必须为 []") && prompt.contains("dialogue 必须为空字符串"), "The script model does not duplicate the shared dialogue track")
            check(prompt.contains("没有已验证的原声、BGM 或音效理解能力"), "Speech evidence does not claim Seed hears sound effects")
            let outside = ScriptPrompt.make(project: h.studio.project!, start: 4, end: 5, style: .screenplay, focus: "", transcript: "")
            check(!outside.contains("Hello, world."), "Out-of-range subtitle text is not sent")
        }
        do {
            let h = Harness(); h.recognizer.language = .en
            let before = SharedSubtitleHTTP.counts
            h.subtitles.generate(studio: h.studio, scripts: h.scripts)
            let scriptConsumer = h.ensure()
            h.studio.showSubtitleReader = false
            let result = try await scriptConsumer.value; try await h.finish()
            check(h.recognizer.calls == 1 && SharedSubtitleHTTP.counts.translation == before.translation + 1, "Manual subtitles and script consumer share one recognition and one translation")
            check(result == h.studio.project!.subtitleTrack, "Both consumers receive the same persisted identity and timing")
            check(result.sourceDescription.contains("Whisper small / whisper.cpp") && result.sourceDescription.contains("fixture-seed-model"), "Saved source names the real configured models")
            check(!h.studio.showSubtitleReader, "Completion never reopens a sidebar the user closed")
        }
        do {
            let h = Harness()
            h.subtitles.generate(studio: h.studio, scripts: h.scripts)
            h.scripts.analyze(studio: h.studio)
            try await wait("shared recognition started") { h.recognizer.calls == 1 }
            h.scripts.cancel(); try await h.finish()
            check(h.recognizer.calls == 1 && h.recognizer.cancellations == 0, "Cancelling script leaves the explicitly requested subtitle worker running")
            check(h.studio.project!.subtitleTrack != nil && h.studio.project!.scriptAnalyses.isEmpty, "Manual subtitles finish after script cancellation, with no script result")
            check(h.scripts.error == nil, "Script cancellation is not shown as a failure")
        }
        do {
            let h = Harness(); let consumer = h.ensure()
            try await wait("sole recognition started") { h.recognizer.calls == 1 }
            consumer.cancel()
            do { _ = try await consumer.value; preconditionFailure("Cancelled consumer returned a track") } catch is CancellationError {}
            try await h.finish()
            check(h.recognizer.cancellations == 1 && h.studio.project!.subtitleTrack == nil, "Cancelling the final consumer stops recognition and commits no partial track")
        }
        do {
            let h = Harness(); h.recognizer.delayedCleanup = true
            let first = h.ensure(); try await wait("first recognition started") { h.recognizer.calls == 1 }
            first.cancel(); _ = await first.result
            try await wait("cancelled worker cleaning up") { h.recognizer.cancellations == 1 }
            let second = h.ensure(); let result = try await second.value; try await h.finish()
            check(h.recognizer.calls == 2 && result == h.studio.project!.subtitleTrack, "A new consumer waits for cancellation cleanup then gets a new worker, not the cancelled task")
        }
        do {
            let h = Harness(); let owner = h.studio.selectedID; let consumer = h.ensure()
            try await wait("recognition before project switch") { h.recognizer.calls == 1 }
            var second = fixture!; second.id = UUID(); second.title = "other"
            h.studio.projects.append(second); h.studio.selectedID = second.id
            _ = try await consumer.value; try await h.finish()
            check(h.studio.projects.first { $0.id == owner }?.subtitleTrack != nil && h.studio.project!.subtitleTrack == nil, "Switching projects saves only to the original project")
            check(!h.studio.showSubtitleReader && !h.scripts.showReader, "Background completion cannot take focus in the other project")
        }
        do {
            let h = Harness(); let consumer = h.ensure()
            try await wait("recognition before media edit") { h.recognizer.calls == 1 }
            h.studio.projects[0].clips[0].sourceIn = 0.5
            do { _ = try await consumer.value; preconditionFailure("Obsolete media result saved") } catch {}
            check(h.studio.project!.subtitleTrack == nil, "Material edits reject the old audio snapshot")
        }
        do {
            let h = Harness(); SharedSubtitleHTTP.failScript = true
            let before = SharedSubtitleHTTP.counts
            h.scripts.analyze(studio: h.studio); try await h.finish()
            let savedTrack = h.studio.project!.subtitleTrack
            check(h.scripts.error != nil && savedTrack != nil && h.recognizer.calls == 1, "Script API failure preserves successfully saved subtitles")
            SharedSubtitleHTTP.failScript = false
            h.scripts.analyze(studio: h.studio); try await h.finish()
            check(h.scripts.error == nil && h.studio.project!.scriptAnalyses.count == 1 && h.recognizer.calls == 1, "Retrying a failed script reuses subtitles without recognizing again")
            check(h.studio.project!.subtitleTrack == savedTrack && SharedSubtitleHTTP.counts.translation == before.translation, "Script retry never changes shared dialogue or sends needless translation")
            check(h.scripts.responses.last?.project.subtitleTrack == savedTrack, "Response snapshot keeps the exact shared evidence supplied to the model")
        }
        do {
            let h = Harness(); h.recognizer.empty = true
            h.scripts.analyze(studio: h.studio); try await h.finish()
            check(h.scripts.error == nil && h.studio.project!.scriptAnalyses.count == 1 && h.studio.project!.subtitleTrack == nil, "Confirmed no-speech continues with visual analysis, without invented subtitle data")
            check(h.scripts.responses.last?.inputMode.contains("未取得人声，仅依据画面") == true, "Visual-only result explicitly records the missing speech evidence")
        }
        do {
            let h = Harness(); h.recognizer.fail = true
            let before = SharedSubtitleHTTP.counts.script
            h.scripts.analyze(studio: h.studio); try await h.finish()
            check(h.scripts.error?.contains("synthetic recognizer failure") == true && SharedSubtitleHTTP.counts.script == before, "Recognition failures do not silently fall back to a video-model request")
        }
        do {
            let h = Harness(); h.recognizer.language = .en; SharedSubtitleHTTP.failTranslation = true
            h.scripts.analyze(studio: h.studio); try await h.finish()
            check(h.scripts.error != nil && h.studio.project!.subtitleTrack == nil, "Translation failure does not publish partial bilingual data")
            SharedSubtitleHTTP.failTranslation = false
            h.scripts.analyze(studio: h.studio); try await h.finish()
            check(h.scripts.error == nil && h.recognizer.calls == 1 && h.studio.project!.subtitleTrack != nil, "Script retry after translation failure reuses the pending original speech")
        }
        do {
            let h = Harness(); h.studio.projects[0].subtitleTrack = h.track()
            h.subtitles.generate(studio: h.studio, scripts: h.scripts)
            try await wait("regeneration before manual edit") { h.recognizer.calls == 1 }
            var edited = h.studio.project!.subtitleTrack!.cues[0]; edited.chineseText = "保留我的人工修订"
            check(h.studio.saveSubtitle(edited), "A manual edit during recognition remains available")
            try await h.finish()
            check(h.studio.project!.subtitleTrack!.cues[0].chineseText == edited.chineseText && h.subtitles.error?.contains("未覆盖") == true, "Regeneration detects concurrent subtitle edits and never silently overwrites them")
        }
        let afterBytes = try Data(contentsOf: url)
        check(afterBytes == bytes, "Synthetic media fixture remains byte-for-byte unchanged")
        print("Shared subtitle pipeline passed (\(checks) assertions; synthetic speech, mocked HTTP, no persistent user data).")
    }
}
