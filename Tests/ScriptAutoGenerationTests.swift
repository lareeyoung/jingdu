import Foundation
import AVFoundation

// Offline only: every HTTP request is intercepted and all credentials are fake.
// xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library Sources/Models.swift Sources/ScriptModels.swift Sources/ScriptReading.swift Sources/ScriptResponseArchive.swift Sources/MediaAnalyzer.swift Sources/CompositionBuilder.swift Sources/ScriptCompression.swift Sources/ScriptMediaPreparer.swift Sources/AppModel.swift Sources/ScriptRelay.swift Sources/ScriptPrompt.swift Sources/ScriptCredentials.swift Sources/ScriptWorkspaceModel.swift Tests/ScriptAutoGenerationTests.swift -framework SwiftUI -framework AVKit -framework AVFoundation -framework AppKit -framework Security -framework LocalAuthentication -o /tmp/jingdu-script-auto-tests
// /tmp/jingdu-script-auto-tests /tmp/jingdu-script-ui/验证样例.mp4

final class ScriptAutoHTTP: URLProtocol, @unchecked Sendable {
    enum Mode { case success, failure, hold }
    struct Captured {
        let method: String
        let host: String
        let path: String
        let model: String
        let authorization: String
        let prompt: String
    }
    private static let lock = NSLock()
    private static var mode: Mode = .success
    private static var body = Data()
    private static var recorded: [Captured] = []
    private static var held: [ScriptAutoHTTP] = []
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false
    private var responseBody = Data()
    private var responseStatus = 200

    static var requests: [Captured] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func configure(body: Data, mode: Mode = .success) {
        lock.lock(); defer { lock.unlock() }
        precondition(held.isEmpty, "Previous held requests must be released before resetting the fixture")
        self.body = body; self.mode = mode; recorded = []
    }
    static func releaseHeld() {
        lock.lock(); let pending = held; held = []; mode = .success; lock.unlock()
        pending.forEach { $0.deliver() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let length = stream.read(&buffer, maxLength: buffer.count)
                if length <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(length))
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        let prompt = content?.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        Self.lock.lock()
        Self.recorded.append(Captured(method: request.httpMethod ?? "", host: request.url?.host ?? "",
            path: request.url?.path ?? "", model: object?["model"] as? String ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization") ?? "", prompt: prompt))
        let mode = Self.mode
        responseStatus = mode == .failure ? 500 : 200
        responseBody = mode == .failure ? Data("{\"error\":{\"message\":\"offline fixture failure\"}}".utf8) : Self.body
        if mode == .hold { Self.held.append(self) }
        Self.lock.unlock()
        if mode != .hold { deliver() }
    }
    private func deliver() {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        guard !stopped else { return }
        stopped = true
        let response = HTTPURLResponse(url: request.url!, statusCode: responseStatus, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { deliveryLock.lock(); stopped = true; deliveryLock.unlock() }
}

@main @MainActor struct ScriptAutoGenerationTests {
    static var checks = 0
    static let savedKey = "fixture-saved-automatic-key"
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(condition(), message)
    }
    static func settle() async throws { try await Task.sleep(nanoseconds: 700_000_000) }
    static func wait(_ message: String, until condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Timed out: \(message)")
    }
    @MainActor final class Credentials {
        var reads = 0
        var saved = true
        var denied = false
        enum FixtureError: Error { case denied }
        func session() -> ScriptCredentialSession {
            ScriptCredentialSession(read: { [self] _ in
                reads += 1
                if denied { throw FixtureError.denied }
                return saved ? ScriptAutoGenerationTests.savedKey : nil
            }, write: { _, _ in preconditionFailure("Automatic generation must never write a credential") },
               exists: { [self] _ in saved })
        }
    }
    @MainActor final class Harness {
        let studio = StudioModel(persistent: false)
        let credentials = Credentials()
        let scripts: ScriptWorkspaceModel
        init(_ projects: [FilmProject], saveConfiguration: Bool = true) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ScriptAutoHTTP.self]
            configuration.urlCache = nil
            scripts = ScriptWorkspaceModel(persistent: false,
                client: ScriptRelayClient(session: URLSession(configuration: configuration)),
                credentials: credentials.session(),
                subtitles: SubtitleWorkspaceModel(transcribe: { _, _, _ in throw SubtitleTranscriber.Failure.noSpeech }))
            scripts.configuration.baseURL = "https://automatic-fixture.example"
            scripts.configuration.appID = "fixture-app-id"
            if saveConfiguration { scripts.saveConfiguration() }
            studio.projects = projects; studio.mediaAvailable = true
        }
        func open(_ project: FilmProject) {
            studio.selectedID = project.id
            scripts.projectDidOpen(studio: studio)
        }
        func resume() { scripts.resumeAutomaticGeneration(studio: studio) }
        func enabled(_ value: Bool) {
            scripts.autoGenerateOnOpen = value
            scripts.automaticGenerationPreferenceChanged(studio: studio)
        }
        func resultCount(_ id: UUID) -> Int { studio.projects.first { $0.id == id }?.scriptAnalyses.count ?? 0 }
    }
    static func fresh(_ original: FilmProject, title: String) -> FilmProject {
        var result = original; result.id = UUID(); result.title = title; result.scriptAnalyses = []
        return result
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a disposable local MP4 fixture") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let originalBytes = try Data(contentsOf: url)
        let info = try await MediaAnalyzer.inspect(url)
        let clip = VideoClip(title: "自动生成离线夹具", sourcePath: url.path, sourceDuration: info.duration,
            sourceIn: 0, sourceOut: info.duration, frameRate: info.frameRate, width: info.width, height: info.height)
        let project = SequenceLogic.makeProject(title: "自动生成离线项目", clips: [clip])
        let json = String(data: try JSONSerialization.data(withJSONObject: [
            "title": "自动生成离线结果", "synopsis": "假响应", "structure": "测试结构", "caveats": "非模型生成",
            "segments": [["start": 0, "end": project.duration, "visual": "夹具画面", "action": "夹具动作",
                "dialogue": "待核对", "sound": "待核对", "camera": "固定机位", "transition": "无",
                "reasoning": "离线测试", "uncertainty": "测试内容", "screenplay": "仅供离线验证的脚本。", "dialogueCues": []]]
        ]), encoding: .utf8)!
        let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": json]]]])
        let existing = try ScriptAnalysisParser.parse(json, project: project, rangeStart: 0, rangeEnd: project.duration,
            modelID: "fixture-model", inputMode: "离线验证")

        try await successfulOpen(project, body: body)
        try await readinessAndPreferences(project, body: body)
        try await ineligibleProjects(project, existing: existing, body: body)
        try await credentialGuards(project, body: body)
        try await configurationRecovery(project, body: body)
        try await unsavedConfigurationChanges(project, body: body)
        try await latestProjectOnly(project, body: body)
        try await queuedProjectReplacement(project, existing: existing, body: body)
        try await disableDuringRequest(project, body: body)
        try await failedAndCancelledAttempts(project, body: body)
        try await manualGenerationTakesPriority(project, body: body)
        let afterBytes = try Data(contentsOf: url)
        check(afterBytes == originalBytes, "Input fixture bytes remain unchanged")
        print("Automatic generation passed (\(checks) assertions; mocked HTTP, fake credentials, persistence disabled).")
    }

    static func successfulOpen(_ project: FilmProject, body: Data) async throws {
        ScriptAutoHTTP.configure(body: body, mode: .hold)
        let harness = Harness([project])
        check(harness.scripts.autoGenerateOnOpen, "Automatic generation is enabled by default in a fresh session")
        harness.studio.isPlaying = true
        let focusReset = harness.studio.focusReset
        harness.open(project)
        harness.scripts.rangeStart = 1; harness.scripts.rangeEnd = 2
        harness.scripts.focus = "PREVIOUS_MANUAL_FOCUS"; harness.scripts.transcript = "PREVIOUS_MANUAL_TRANSCRIPT"
        harness.scripts.keyDraft = "fixture-unsaved-draft-must-not-be-sent"
        try await Task.sleep(nanoseconds: 100_000_000)
        check(ScriptAutoHTTP.requests.isEmpty && harness.credentials.reads == 0, "Opening is debounced before reading credentials or sending video")
        try await wait("automatic request starts") { ScriptAutoHTTP.requests.count == 1 }
        let request = ScriptAutoHTTP.requests[0]
        check(request.method == "POST" && request.host == "automatic-fixture.example", "The automatic path uses only the mocked configured service")
        check(request.authorization == "Bearer \(savedKey)", "Automatic generation uses the saved key even when a different unsaved draft is present")
        check(!request.prompt.isEmpty && !request.prompt.contains("PREVIOUS_MANUAL_"), "Automatic generation does not transmit stale manual focus or transcript")
        check(harness.scripts.rangeStart == 0 && harness.scripts.rangeEnd == project.duration, "Automatic generation covers the full project instead of a previous manual range")
        check(harness.studio.isPlaying && harness.studio.focusReset == focusReset, "Automatic startup preserves playback and text focus")
        check(!harness.scripts.showWorkspace && !harness.scripts.showConfiguration, "Automatic startup never opens a modal configuration or generation sheet")
        ScriptAutoHTTP.releaseHeld()
        try await wait("automatic result stored") { !harness.scripts.isRunning && harness.resultCount(project.id) == 1 }
        check(harness.scripts.error == nil && harness.credentials.reads == 1, "Automatic generation saves one successful result using one credential read")
        harness.open(project); harness.resume(); try await settle()
        check(ScriptAutoHTTP.requests.count == 1, "Reopening a project with a saved result does not generate another script")
    }

    static func readinessAndPreferences(_ project: FilmProject, body: Data) async throws {
        ScriptAutoHTTP.configure(body: body)
        let harness = Harness([project])
        harness.studio.mediaAvailable = false; harness.studio.busy = true
        harness.scripts.isFetchingModels = true; harness.scripts.isRunning = true
        harness.open(project); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty && harness.credentials.reads == 0, "A project waits while media, analysis or model listing is not ready")
        harness.studio.mediaAvailable = true; harness.resume(); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty, "Media readiness alone does not bypass the remaining busy guards")
        harness.studio.busy = false; harness.scripts.isRunning = false; harness.resume(); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty, "An active model-list request still defers automatic generation")
        harness.scripts.isFetchingModels = false; harness.scripts.showWorkspace = true
        harness.resume(); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty, "Editing generation parameters in the sheet defers the automatic job")
        harness.scripts.showWorkspace = false; harness.resume()
        harness.enabled(false); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty && harness.credentials.reads == 0, "Disabling clears a pending automatic start before credential access")
        harness.open(project); harness.resume(); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty, "Opening while disabled stays manual")
        harness.enabled(true)
        try await wait("enabled pending project completes") { harness.resultCount(project.id) == 1 && !harness.scripts.isRunning }
        check(ScriptAutoHTTP.requests.count == 1, "Enabling resumes the current eligible project once it is ready")
        harness.enabled(false)
        let freshHarness = Harness([project])
        check(freshHarness.scripts.autoGenerateOnOpen, "A persistence-disabled preference change does not affect a fresh instance")
    }

    static func ineligibleProjects(_ project: FilmProject, existing: ScriptAnalysis, body: Data) async throws {
        var saved = fresh(project, title: "已有脚本"); saved.scriptAnalyses = [existing]
        var zero = fresh(project, title: "零时长"); zero.duration = 0; zero.clips = []
        var long = fresh(project, title: "超过五分钟"); long.duration = 301
        var invalid = fresh(project, title: "无效时长"); invalid.duration = .nan
        for item in [saved, zero, long, invalid] {
            ScriptAutoHTTP.configure(body: body)
            let harness = Harness([item]); harness.open(item); harness.resume(); try await settle()
            check(ScriptAutoHTTP.requests.isEmpty && harness.credentials.reads == 0, "Ineligible project \(item.title) neither reads credentials nor sends a request")
            check(!harness.scripts.showWorkspace && !harness.scripts.isRunning, "Ineligible project \(item.title) remains quiet and idle")
            harness.enabled(false)
        }
        ScriptAutoHTTP.configure(body: body)
        var remix = fresh(project, title: "有视频的灵感空间"); remix.kind = .remix
        let harness = Harness([remix]); harness.open(remix)
        try await wait("remix result") { harness.resultCount(remix.id) == 1 && !harness.scripts.isRunning }
        check(ScriptAutoHTTP.requests.count == 1, "An inspiration/remix project with video supports automatic generation")
    }

    static func credentialGuards(_ project: FilmProject, body: Data) async throws {
        ScriptAutoHTTP.configure(body: body)
        let missing = Harness([project]); missing.credentials.saved = false
        missing.scripts.refreshKeyStatus(); missing.scripts.keyDraft = "fixture-draft-only"
        missing.open(project); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty && missing.credentials.reads == 0, "A draft without a saved key is never used for background generation")
        check(missing.scripts.automaticGenerationHint != nil && !missing.scripts.showWorkspace, "Missing credentials are explained inline without opening a sheet")
        missing.enabled(false)

        let invalid = Harness([project]); invalid.scripts.configuration.appID = ""
        invalid.open(project); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty && invalid.credentials.reads == 0, "Invalid configuration blocks automatic generation before any secret read")
        invalid.enabled(false)

        let denied = Harness([project]); denied.credentials.denied = true
        denied.open(project)
        try await wait("denied fake credential access") { denied.credentials.reads == 1 }
        denied.resume(); denied.open(project); try await settle()
        check(denied.credentials.reads == 1 && ScriptAutoHTTP.requests.isEmpty, "Denied authorization is attempted only once per project in this session")
        check(!denied.scripts.showWorkspace && !denied.scripts.showConfiguration, "A failed background credential read does not open settings")
        denied.enabled(false)
    }

    static func configurationRecovery(_ project: FilmProject, body: Data) async throws {
        ScriptAutoHTTP.configure(body: body)
        let harness = Harness([project], saveConfiguration: false); harness.credentials.saved = false
        harness.scripts.configuration.appID = ""
        harness.open(project); try await settle()
        check(ScriptAutoHTTP.requests.isEmpty && harness.credentials.reads == 0, "Unconfigured opening preserves a quiet pending candidate")
        harness.scripts.configuration.appID = "fixture-app-id"
        harness.credentials.saved = true; harness.scripts.refreshKeyStatus(); harness.resume()
        try await settle()
        check(ScriptAutoHTTP.requests.isEmpty && harness.credentials.reads == 0,
              "Repairing draft configuration and key status still waits for an explicit configuration save")
        check(harness.scripts.automaticGenerationHint?.contains("保存") == true,
              "A valid configuration without a saved snapshot explains the required save inline")
        harness.scripts.saveConfiguration(); harness.resume()
        try await wait("candidate resumes after configuration recovery") {
            harness.resultCount(project.id) == 1 && !harness.scripts.isRunning
        }
        check(ScriptAutoHTTP.requests.count == 1 && harness.credentials.reads == 1, "Restoring valid configuration and a saved key resumes the same project without reopening")
        check(harness.scripts.workspaceProjectID == project.id && !harness.scripts.showWorkspace,
              "Configuration recovery completes in the current project without a sheet")
    }

    static func unsavedConfigurationChanges(_ project: FilmProject, body: Data) async throws {
        for changeRoute in [false, true] {
            ScriptAutoHTTP.configure(body: body)
            let harness = Harness([project])
            harness.open(project)
            // Change during the debounce too: readiness must be rechecked at dispatch.
            try await Task.sleep(nanoseconds: 100_000_000)
            if changeRoute { harness.scripts.configuration.route = .chatCompletions }
            else { harness.scripts.configuration.modelID = "fixture-new-saved-model" }
            try await settle()
            check(ScriptAutoHTTP.requests.isEmpty && harness.credentials.reads == 0,
                  "An unsaved \(changeRoute ? "route" : "model") change cannot dispatch a pending automatic request")
            check(harness.scripts.automaticGenerationHint?.contains("保存") == true,
                  "The pending project explains that changed settings must be saved")
            harness.scripts.saveConfiguration(); harness.resume()
            try await wait("saved modified configuration resumes the pending project") {
                harness.resultCount(project.id) == 1 && !harness.scripts.isRunning
            }
            check(ScriptAutoHTTP.requests.count == 1 && harness.credentials.reads == 1,
                  "Saving the modified configuration resumes the same candidate without consuming an earlier attempt")
            let request = ScriptAutoHTTP.requests[0]
            if changeRoute {
                check(request.path == "/v1/chat/completions", "The resumed request uses the explicitly saved route")
            } else {
                check(request.model == "fixture-new-saved-model", "The resumed request uses the explicitly saved model")
            }
        }
    }

    static func latestProjectOnly(_ project: FilmProject, body: Data) async throws {
        ScriptAutoHTTP.configure(body: body)
        let a = fresh(project, title: "快速切换A"), b = fresh(project, title: "快速切换B")
        let harness = Harness([a, b]); harness.open(a)
        try await Task.sleep(nanoseconds: 100_000_000)
        harness.open(b)
        try await wait("latest debounced project") { harness.resultCount(b.id) == 1 && !harness.scripts.isRunning }
        check(ScriptAutoHTTP.requests.count == 1 && harness.resultCount(a.id) == 0, "Rapid switching cancels the earlier pending project before upload")
        check(harness.scripts.workspaceProjectID == b.id, "The automatically generated script belongs to the currently selected project")
    }

    static func queuedProjectReplacement(_ project: FilmProject, existing: ScriptAnalysis, body: Data) async throws {
        for destinationHasScript in [false, true] {
            ScriptAutoHTTP.configure(body: body, mode: .hold)
            let a = fresh(project, title: "在途A"), b = fresh(project, title: "离开B")
            var c = fresh(project, title: "最后C")
            if destinationHasScript { c.scriptAnalyses = [existing] }
            let harness = Harness([a, b, c]); harness.open(a)
            try await wait("first held automatic request") { ScriptAutoHTTP.requests.count == 1 }
            harness.open(b); harness.open(c); try await settle()
            check(ScriptAutoHTTP.requests.count == 1, "Switching during a request queues no parallel model calls")
            ScriptAutoHTTP.releaseHeld()
            try await wait("first request completes") { harness.resultCount(a.id) == 1 }
            harness.resume()
            if destinationHasScript {
                try await settle()
                check(ScriptAutoHTTP.requests.count == 1 && harness.resultCount(c.id) == 1, "An already-scripted destination clears an older pending project")
            } else {
                try await wait("latest queued project completes") { harness.resultCount(c.id) == 1 && !harness.scripts.isRunning }
                check(ScriptAutoHTTP.requests.count == 2, "Only the latest eligible destination runs after the first request")
            }
            check(harness.resultCount(b.id) == 0 && harness.studio.selectedID == c.id, "Completing A never generates or selects the departed intermediate B")
            harness.enabled(false)
        }
    }

    static func disableDuringRequest(_ project: FilmProject, body: Data) async throws {
        ScriptAutoHTTP.configure(body: body, mode: .hold)
        let a = fresh(project, title: "关闭开关时在途A"), b = fresh(project, title: "关闭开关时待处理B")
        let harness = Harness([a, b]); harness.open(a)
        try await wait("request sent before disabling") { ScriptAutoHTTP.requests.count == 1 }
        harness.open(b); harness.enabled(false)
        check(harness.scripts.isRunning, "Turning off the preference does not cancel a submitted generation")
        ScriptAutoHTTP.releaseHeld()
        try await wait("in-flight result preserved") { harness.resultCount(a.id) == 1 && !harness.scripts.isRunning }
        harness.resume(); try await settle()
        check(ScriptAutoHTTP.requests.count == 1 && harness.resultCount(b.id) == 0, "Disabling retains the in-flight result and clears the queued next project")
    }

    static func failedAndCancelledAttempts(_ project: FilmProject, body: Data) async throws {
        ScriptAutoHTTP.configure(body: body, mode: .failure)
        let failed = Harness([project]); failed.open(project)
        try await wait("failed automatic request") { ScriptAutoHTTP.requests.count == 1 && !failed.scripts.isRunning }
        check(failed.scripts.error != nil && failed.resultCount(project.id) == 0, "A failed automatic request never inserts a partial script")
        failed.resume(); failed.open(project); failed.enabled(false); failed.enabled(true)
        try await settle()
        check(ScriptAutoHTTP.requests.count == 1, "Failure is not retried by reopening, readiness events or toggling within the same session")
        failed.enabled(false)

        ScriptAutoHTTP.configure(body: body, mode: .hold)
        let cancelled = Harness([project]); cancelled.open(project)
        try await wait("automatic request ready to cancel") { ScriptAutoHTTP.requests.count == 1 }
        cancelled.scripts.cancel()
        try await wait("automatic cancellation completes") { !cancelled.scripts.isRunning }
        ScriptAutoHTTP.releaseHeld()
        cancelled.resume(); cancelled.open(project); try await settle()
        check(ScriptAutoHTTP.requests.count == 1 && cancelled.resultCount(project.id) == 0, "A cancelled automatic attempt is not retried or saved from a late response")
        cancelled.enabled(false)
    }

    static func manualGenerationTakesPriority(_ project: FilmProject, body: Data) async throws {
        ScriptAutoHTTP.configure(body: body, mode: .hold)
        let harness = Harness([project]); harness.open(project)
        harness.scripts.focus = "EXPLICIT_MANUAL_REQUEST"
        harness.scripts.analyze(studio: harness.studio)
        try await wait("manual request starts before pending automatic job") { ScriptAutoHTTP.requests.count == 1 }
        try await settle()
        check(ScriptAutoHTTP.requests.count == 1 && harness.scripts.isRunning,
              "An explicit manual generation takes precedence over a debounced automatic candidate")
        check(ScriptAutoHTTP.requests[0].prompt.contains("EXPLICIT_MANUAL_REQUEST"),
              "The pending automatic task does not rewrite an explicit manual prompt")
        harness.scripts.cancel()
        try await wait("manual cancellation releases generation state") { !harness.scripts.isRunning }
        ScriptAutoHTTP.releaseHeld()
        harness.resume(); harness.open(project); try await settle()
        check(ScriptAutoHTTP.requests.count == 1 && harness.resultCount(project.id) == 0,
              "Cancelling a manual generation never immediately restarts it through automatic generation")
        harness.enabled(false)
    }
}
