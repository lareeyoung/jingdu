import Foundation
import AVFoundation

/// Independent offline workflow check. Supply only a disposable media fixture.
/// xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -parse-as-library Sources/Models.swift Sources/ScriptModels.swift Sources/ScriptReading.swift Sources/ScriptResponseArchive.swift Sources/MediaAnalyzer.swift Sources/CompositionBuilder.swift Sources/ScriptCompression.swift Sources/ScriptMediaPreparer.swift Sources/AppModel.swift Sources/ScriptRelay.swift Sources/ScriptPrompt.swift Sources/ScriptCredentials.swift Sources/ScriptWorkspaceModel.swift Tests/ScriptWorkflowTests.swift -framework SwiftUI -framework AVKit -framework AVFoundation -framework AppKit -framework Security -framework LocalAuthentication -o /tmp/jingdu-script-workflow-tests
/// /tmp/jingdu-script-workflow-tests /tmp/jingdu-script-ui/验证样例.mp4

final class ScriptWorkflowProtocol: URLProtocol, @unchecked Sendable {
    static var body = Data()
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Captures only the synthetic credential headers needed by this integration
/// check. Every request is handled locally; uploaded video bodies are not kept.
final class ScriptCredentialWorkflowProtocol: URLProtocol, @unchecked Sendable {
    struct Captured {
        let method: String
        let host: String
        let appID: String
        let authorization: String
    }
    private static let lock = NSLock()
    private static var captures: [Captured] = []
    static var scriptJSON = ""
    static var modelID = ""
    static var requests: [Captured] { lock.lock(); defer { lock.unlock() }; return captures }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.captures.append(Captured(method: request.httpMethod ?? "", host: request.url?.host ?? "",
            appID: request.value(forHTTPHeaderField: "Appid") ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization") ?? ""))
        Self.lock.unlock()
        let body: [String: Any] = request.httpMethod == "GET"
            ? ["data": [["id": Self.modelID]]]
            : ["choices": [["finish_reason": "stop", "message": ["content": Self.scriptJSON]]]]
        let bytes = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct ScriptWorkflowTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(value(), message) }
    static func wait(_ model: ScriptWorkspaceModel) async throws {
        for _ in 0..<500 { if !model.isRunning { return }; try await Task.sleep(nanoseconds: 100_000_000) }
        preconditionFailure("Workflow timed out")
    }
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else { fatalError("Pass a disposable MP4 fixture path") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]); let original = try Data(contentsOf: url)
        let info = try await MediaAnalyzer.inspect(url)
        let clip = VideoClip(title: "验证样例", sourcePath: url.path, sourceDuration: info.duration, sourceIn: 0, sourceOut: info.duration, frameRate: info.frameRate, width: info.width, height: info.height)
        let project = SequenceLogic.makeProject(title: "离线回归项目", clips: [clip])
        let studio = StudioModel(persistent: false); studio.projects = [project]; studio.selectedID = project.id
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScriptWorkflowProtocol.self]
        let scripts = ScriptWorkspaceModel(persistent: false, client: ScriptRelayClient(session: URLSession(configuration: config)),
            subtitles: SubtitleWorkspaceModel(transcribe: { _, _, _ in throw SubtitleTranscriber.Failure.noSpeech }))
        scripts.configuration.baseURL = "https://relay.example"; scripts.configuration.appID = "app-local-tests"
        scripts.keyDraft = "local-fixture-not-a-real-key"; scripts.workspaceProjectID = project.id
        scripts.showReader = false
        check(scripts.outputFocusID == nil, "No result-focus event exists before generation")
        scripts.rangeStart = 1; scripts.rangeEnd = 4
        func segment(_ start: Double, _ end: Double) -> [String: Any] {
            ["start":start,"end":end,"visual":"本地测试画面","action":"测试动作","dialogue":"待核对","sound":"待核对",
             "camera":"固定机位","transition":"切换","reasoning":"分析示例","uncertainty":"时间需核对"]
        }
        let payload: [String:Any] = ["title":"明确标记的离线测试结果","synopsis":"测试摘要","structure":"测试结构","caveats":"离线夹具，非模型生成","segments":[segment(0,1),segment(1,3)]]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        ScriptWorkflowProtocol.body = try JSONSerialization.data(withJSONObject: ["choices":[["finish_reason":"stop","message":["content":json]]]])
        scripts.analyze(studio: studio); check(scripts.isRunning, "Start exposes a running state")
        try await wait(scripts)
        check(scripts.error == nil, "Successful response persists")
        check(ScriptWorkflowProtocol.requests == 1, "One explicit analysis creates one request")
        check(studio.project!.scriptAnalyses.count == 1, "One script is saved")
        let result = studio.project!.scriptAnalyses[0]
        check(result.rangeStart == 1 && result.rangeEnd == 4, "Selected range remains absolute")
        check(result.segments.map(\.start) == [1,2] && result.segments.map(\.end) == [2,4], "Relative results map to source timeline")
        check(studio.project!.notes.isEmpty, "Analysis does not silently insert timeline notes")
        check(scripts.selectedAnalysisID == result.id, "Completed script is selected")
        check(scripts.outputFocusID == result.id, "Same-project completion emits the actual new result identity")
        check(scripts.showReader, "Same-project completion opens the main-window script reader")
        check(!scripts.showWorkspace, "A completed background generation does not open a generation sheet")
        successfulLocalRecovery(studio: studio, scripts: scripts, result: result, raw: json)
        try syncProjectSelection(project: project, result: result)
        try copiedProjectDraftIsolation(project: project, result: result)
        scripts.addToTimeline(result, studio: studio)
        check(studio.project!.notes.count == 2, "Explicit timeline action creates notes")
        check(studio.project!.notes.allSatisfy {$0.track == .story}, "Script notes use story track")
        check(studio.project!.scriptAnalyses[0].timelineNoteIDs == studio.project!.notes.map(\.id), "Inserted notes are recorded")
        scripts.addToTimeline(result, studio: studio)
        check(studio.project!.notes.count == 2, "Repeating insert with stale view value does not duplicate notes")
        var edited = studio.project!.scriptAnalyses[0]; edited.title = "人工修订的脚本"
        scripts.saveAnalysis(edited, studio: studio)
        check(studio.project!.scriptAnalyses[0].title == edited.title, "Manual edits persist")
        let retained = studio.project!
        ScriptWorkflowProtocol.body = try JSONSerialization.data(withJSONObject: ["choices":[["message":["content":"not JSON"]]]])
        scripts.analyze(studio: studio); try await wait(scripts)
        check(scripts.error != nil && studio.project == retained, "Invalid model content preserves existing project exactly")
        check(scripts.outputFocusID == result.id, "A failed response does not emit a new focus event")
        failedLocalRecoveryAndProjectIsolation(studio: studio, scripts: scripts, retained: retained)
        let failedResponseID = scripts.responses[0].id
        scripts.error = nil; let previousCalls = ScriptWorkflowProtocol.requests
        scripts.analyze(studio: studio); scripts.cancel(); try await wait(scripts)
        check(studio.project == retained, "Cancellation preserves previous results and notes")
        check(ScriptWorkflowProtocol.requests == previousCalls, "Immediate cancellation never sends video")
        check(!scripts.isRunning, "Cancelled request releases running state")
        check(scripts.outputFocusID == result.id, "Cancellation does not move the main reader to another result")
        var changed = studio.project!; changed.originalVolume = 0.4; _ = studio.update(changed)
        scripts.addToTimeline(result, studio: studio)
        check(scripts.error != nil && studio.project!.notes.count == 2, "Stale media cannot add misaligned notes")
        scripts.rangeEnd = 301; scripts.analyze(studio: studio)
        check(!scripts.isRunning, "Out-of-range analysis is rejected before preparation")
        // A background completion must not select a result in a different project's workspace.
        var other = project; other.id = UUID(); other.title = "第二个隔离项目"
        studio.projects.append(other); studio.selectedID = project.id
        scripts.workspaceProjectID = project.id; scripts.rangeStart = 1; scripts.rangeEnd = 4
        ScriptWorkflowProtocol.body = try JSONSerialization.data(withJSONObject: ["choices":[["message":["content":json]]]])
        var draft = result; draft.title = "尚未保存的编辑"
        let draftKey = ScriptDraftKey(projectID: project.id, analysisID: result.id)
        scripts.drafts[draftKey] = draft; scripts.transcript = "只属于第一个项目的字幕"
        scripts.showWorkspace = false; scripts.showReader = false
        let previousFocus = scripts.outputFocusID
        scripts.analyze(studio: studio)
        studio.selectedID = other.id; studio.isPlaying = true
        scripts.syncProject(studio: studio)
        check(scripts.transcript.isEmpty, "Changing project clears the previous project's supplied transcript")
        check(scripts.drafts[draftKey] == draft, "Changing workspace preserves each script's unsaved draft")
        check(studio.isPlaying, "Pure project synchronization does not pause current playback")
        check(!scripts.showWorkspace && !scripts.showReader, "Pure project synchronization neither opens a sheet nor changes reader visibility")
        try await wait(scripts)
        check(scripts.workspaceProjectID == other.id && scripts.selectedAnalysisID == nil, "Background result never changes another workspace selection")
        check(studio.projects.first {$0.id == project.id}!.scriptAnalyses.count == 2, "Background result is saved to its original project")
        check(scripts.outputFocusID == previousFocus, "Cross-project completion leaves the current result-focus signal unchanged")
        check(!scripts.showReader && !scripts.showWorkspace, "Cross-project completion never reveals a reader or generation sheet")
        studio.selectedID = project.id; scripts.syncProject(studio: studio)
        check(scripts.selectedAnalysisID == result.id, "Returning restores the older selected history instead of replacing it with the background result")
        check(scripts.responses[0].id != failedResponseID && studio.project!.scriptAnalyses.contains { $0.id == scripts.responses[0].id }, "The newest response is a successfully saved script")
        check(scripts.recoverableResponse(studio: studio)?.id == failedResponseID && scripts.recoverableResponse(studio: studio)?.text == "not JSON", "A newer successful response never hides an older failed response's local recovery and export entry")
        scripts.saveAnalysis(draft, studio: studio)
        check(scripts.drafts[draftKey] == nil, "Successful explicit save clears the cached draft")
        check(scripts.unsavedAnalysisIDs.isEmpty, "Successful storage leaves no unsaved-result flags")
        try await incompleteResponseWorkflow(project: project, result: result, json: json)
        try await credentialSessionWorkflow(project: project, json: json)
        try normalizedCredentialSaveWorkflow()
        let after = try Data(contentsOf: url)
        check(after == original, "Fixture file is byte-for-byte unchanged")
        print("Script workflow passed (\(checks) assertions, mocked HTTP, persistence disabled).")
    }

    static func successfulLocalRecovery(studio: StudioModel, scripts: ScriptWorkspaceModel, result: ScriptAnalysis, raw: String) {
        check(scripts.responses.count == 1, "Successful generation retains its raw response before parsing")
        let response = scripts.responses[0]
        check(response.text == raw && response.id == result.id && response.receivedAt == result.createdAt, "Saved script identity and creation time come from its unchanged response record")
        check(scripts.recoverableResponse(studio: studio) == nil, "A response already saved as a script is not offered for duplicate recovery")
        let previousCalls = ScriptWorkflowProtocol.requests
        // Simulate a received response whose script was not retained by the
        // project, without injecting or changing the private response array.
        studio.projects[0].scriptAnalyses = []
        scripts.showReader = false
        check(scripts.recoverableResponse(studio: studio)?.id == response.id, "An archived response without a saved script becomes locally recoverable")
        scripts.recoverResponse(studio: studio)
        check(scripts.error == nil && studio.project!.scriptAnalyses.count == 1, "Local recovery saves one script without requesting the model")
        check(studio.project!.scriptAnalyses[0].id == result.id && studio.project!.scriptAnalyses[0].createdAt == result.createdAt, "Recovery reuses the original stable script identity and receive date")
        check(scripts.selectedAnalysisID == result.id && scripts.outputFocusID == result.id && scripts.showReader, "Successful local recovery selects and reveals the restored result")
        check(studio.project!.notes.isEmpty, "Local recovery does not silently create timeline notes")
        let recovered = studio.project!
        scripts.recoverResponse(studio: studio)
        check(studio.project == recovered && studio.project!.scriptAnalyses.count == 1, "Repeated recovery is idempotent and never adds a second script")
        check(ScriptWorkflowProtocol.requests == previousCalls, "Both local recovery attempts make zero HTTP requests")
        check(scripts.responses.count == 1 && scripts.responses[0].text == raw && scripts.responses[0].id == response.id, "Successful recovery keeps the original raw response unchanged")
        check(scripts.recoverableResponse(studio: studio) == nil, "The restored response is no longer pending recovery")
    }

    static func failedLocalRecoveryAndProjectIsolation(studio: StudioModel, scripts: ScriptWorkspaceModel, retained: FilmProject) {
        check(scripts.responses.count == 2, "A parser failure still retains one new response alongside previous successful responses")
        let response = scripts.responses[0]
        check(response.text == "not JSON" && response.project.id == retained.id, "The failed response preserves the exact model text and originating project")
        check(response.project.notes.isEmpty && response.project.scriptAnalyses.isEmpty, "Response snapshots exclude pre-existing notes and saved analyses")
        check(response.project.videoClips == retained.videoClips && response.project.music == retained.music, "Failure records retain the original media context needed for local recovery")
        check(scripts.recoverableResponse(studio: studio)?.id == response.id, "The newest failed response is offered for local recovery")
        let previousCalls = ScriptWorkflowProtocol.requests
        scripts.recoverResponse(studio: studio)
        check(scripts.error != nil && studio.project == retained, "A failed local parse leaves every saved script and note untouched")
        scripts.recoverResponse(studio: studio)
        check(studio.project == retained && ScriptWorkflowProtocol.requests == previousCalls, "Repeated failed recovery makes no request and cannot alter the project")
        check(scripts.responses.count == 2 && scripts.responses[0].text == response.text && scripts.responses[0].id == response.id && scripts.responses[0].receivedAt == response.receivedAt, "Failed recovery never replaces, normalizes, or re-dates the retained raw response")

        var other = retained; other.id = UUID(); other.title = "本地恢复隔离项目"
        studio.projects.append(other); studio.selectedID = other.id; scripts.syncProject(studio: studio)
        check(scripts.recoverableResponse(studio: studio) == nil, "A project copy with identical media cannot access another project's response")
        scripts.recoverResponse(studio: studio)
        check(studio.project == other && studio.projects.first { $0.id == retained.id } == retained, "A recovery action in another project changes neither project")
        check(ScriptWorkflowProtocol.requests == previousCalls, "Cross-project recovery cannot trigger a model request")
        studio.selectedID = retained.id; scripts.syncProject(studio: studio)
        studio.projects.removeAll { $0.id == other.id }
        check(scripts.recoverableResponse(studio: studio)?.id == response.id && scripts.responses[0].text == response.text, "Returning to the source project restores access to its unchanged failed response")
    }

    static func incompleteResponseWorkflow(project: FilmProject, result: ScriptAnalysis, json: String) async throws {
        var fixture = project
        fixture.scriptAnalyses = [result]
        fixture.notes = [StudyNote(start: 1, end: 2, track: .camera, title: "保留现有笔记", body: "原有观察", takeaway: "原有学习记录")]
        let studio = StudioModel(persistent: false); studio.projects = [fixture]; studio.selectedID = fixture.id
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScriptWorkflowProtocol.self]
        let scripts = ScriptWorkspaceModel(persistent: false, client: ScriptRelayClient(session: URLSession(configuration: config)),
            subtitles: SubtitleWorkspaceModel(transcribe: { _, _, _ in throw SubtitleTranscriber.Failure.noSpeech }))
        scripts.configuration.baseURL = "https://relay.example"; scripts.configuration.appID = "app-local-tests"
        scripts.keyDraft = "local-fixture-not-a-real-key"; scripts.workspaceProjectID = fixture.id
        scripts.selectedAnalysisID = result.id; scripts.showReader = false
        scripts.rangeStart = 1; scripts.rangeEnd = 4
        let previousCalls = ScriptWorkflowProtocol.requests
        // A syntactically valid JSON body is still incomplete when the service
        // explicitly reports a length cutoff. Exercise the real relay client.
        ScriptWorkflowProtocol.body = try JSONSerialization.data(withJSONObject: ["choices":[["finish_reason":"length","message":["content":json]]]])
        scripts.analyze(studio: studio); try await wait(scripts)
        check(ScriptWorkflowProtocol.requests == previousCalls + 1, "A length-cutoff response comes from one explicit mocked HTTP request")
        check(scripts.error != nil && studio.project == fixture, "Length cutoff cannot replace existing scripts or notes, even when the returned JSON is valid")
        check(scripts.responses.count == 1, "The workflow retains the body of a length-cutoff model reply")
        let incomplete = scripts.responses[0]
        check(incomplete.text == json && incomplete.isIncomplete == true && incomplete.project.id == fixture.id, "The retained raw reply preserves its exact text, incomplete flag, and originating project")
        check(scripts.selectedAnalysisID == result.id && scripts.outputFocusID == nil && !scripts.showReader, "A truncated reply cannot focus or reveal a new complete script")
        check(scripts.recoverableResponse(studio: studio)?.id == incomplete.id, "The incomplete raw reply remains available for local inspection and export")
        scripts.recoverResponse(studio: studio)
        check(scripts.error?.contains("不能作为完整脚本保存") == true && studio.project == fixture, "Local recovery cannot turn an incomplete reply into a complete script")
        check(ScriptWorkflowProtocol.requests == previousCalls + 1 && scripts.responses[0].text == json && scripts.responses[0].isIncomplete == true, "Refusing incomplete recovery makes no request and preserves the original response")

        ScriptWorkflowProtocol.body = try JSONSerialization.data(withJSONObject: ["choices":[["finish_reason":"stop","message":["content":json]]]])
        scripts.analyze(studio: studio); try await wait(scripts)
        check(ScriptWorkflowProtocol.requests == previousCalls + 2 && scripts.error == nil, "A later complete response is generated only by an explicit second request")
        check(studio.project!.scriptAnalyses.count == 2 && studio.project!.notes == fixture.notes, "Only the complete reply adds one saved script while preserving existing notes")
        check(scripts.responses.count == 2 && scripts.responses[0].isIncomplete != true && scripts.responses[0].id != incomplete.id, "Complete and incomplete replies retain separate identities and completion states")
        check(scripts.recoverableResponse(studio: studio)?.id == incomplete.id && scripts.recoverableResponse(studio: studio)?.text == json, "A newer saved result does not hide the older incomplete reply's export and recovery entry")
        let saved = studio.project!
        scripts.recoverResponse(studio: studio)
        check(studio.project == saved && ScriptWorkflowProtocol.requests == previousCalls + 2, "Reopening the older incomplete reply neither overwrites the newer script nor calls the model")
    }

    static func credentialSessionWorkflow(project: FilmProject, json: String) async throws {
        var first = ScriptRelayConfiguration()
        first.baseURL = "https://credential-a.example"; first.appID = "fixture-app-a"
        var second = first; second.baseURL = "https://credential-b.example"
        var third = second; third.appID = "fixture-app-b"
        let keyA = "fixture-key-a", keyB = "fixture-key-b", keyC = "fixture-key-c"
        var stored = [first.credentialAccount: keyA, second.credentialAccount: keyB]
        var reads: [String] = [], writes: [(key: String, account: String)] = [], existenceChecks: [String] = []
        let credentials = ScriptCredentialSession(read: { account in
            reads.append(account); return stored[account]
        }, write: { key, account in
            writes.append((key, account)); stored[account] = key
        }, exists: { account in
            existenceChecks.append(account); return stored[account] != nil
        })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptCredentialWorkflowProtocol.self]
        ScriptCredentialWorkflowProtocol.scriptJSON = json
        ScriptCredentialWorkflowProtocol.modelID = first.modelID
        let requestStart = ScriptCredentialWorkflowProtocol.requests.count
        let scripts = ScriptWorkspaceModel(persistent: false,
            client: ScriptRelayClient(session: URLSession(configuration: config)), credentials: credentials,
            subtitles: SubtitleWorkspaceModel(transcribe: { _, _, _ in throw SubtitleTranscriber.Failure.noSpeech }))
        let studio = StudioModel(persistent: false); studio.projects = [project]; studio.selectedID = project.id
        scripts.configuration = first; scripts.workspaceProjectID = project.id
        scripts.rangeStart = 1; scripts.rangeEnd = 4
        check(scripts.keyIsSaved && reads.isEmpty && existenceChecks.contains(first.credentialAccount), "Credential status uses the injected existence check without reading the secret")

        func fetch() async throws {
            scripts.fetchModels()
            for _ in 0..<500 {
                if !scripts.isFetchingModels { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("Mocked model listing timed out")
        }
        try await fetch()
        check(scripts.error == nil && scripts.availableModels == [first.modelID] && reads == [first.credentialAccount], "The first model listing reads the fake saved key exactly once")
        scripts.analyze(studio: studio); try await wait(scripts)
        scripts.analyze(studio: studio); try await wait(scripts)
        check(scripts.error == nil && studio.project!.scriptAnalyses.count == 2 && Set(studio.project!.scriptAnalyses.map(\.id)).count == 2, "Two explicit analyses complete through the injected credential session and mocked transport")
        check(reads == [first.credentialAccount], "Model listing followed by two analyses reuses one authorized secret read for the same account")
        let initial = Array(ScriptCredentialWorkflowProtocol.requests.dropFirst(requestStart))
        check(initial.map(\.method) == ["GET", "POST", "POST"], "The integrated path performs exactly one listing and two generation requests")
        check(initial.allSatisfy { $0.host == "credential-a.example" && $0.appID == first.appID && $0.authorization == "Bearer \(keyA)" }, "All initial requests use only the first account's fake credential")

        scripts.keyDraft = "unsaved-draft-for-a"
        scripts.configuration.baseURL = second.baseURL
        check(scripts.keyDraft.isEmpty && scripts.keyIsSaved && scripts.configuration.credentialAccount == second.credentialAccount, "Changing the base URL clears the previous account's draft and refreshes saved-key status")
        try await fetch()
        let afterBaseChange = ScriptCredentialWorkflowProtocol.requests.last!
        check(scripts.error == nil && reads == [first.credentialAccount, second.credentialAccount], "A different base URL resolves its own saved key once")
        check(afterBaseChange.host == "credential-b.example" && afterBaseChange.appID == second.appID && afterBaseChange.authorization == "Bearer \(keyB)", "The new service never receives the previous service's draft or cached key")

        scripts.keyDraft = "unsaved-draft-for-b"
        scripts.configuration.appID = third.appID
        check(scripts.keyDraft.isEmpty && !scripts.keyIsSaved && scripts.configuration.credentialAccount == third.credentialAccount, "Changing AppID also clears the prior draft and does not inherit saved-key status")
        let beforeMissing = ScriptCredentialWorkflowProtocol.requests.count
        try await fetch()
        check(scripts.error != nil && ScriptCredentialWorkflowProtocol.requests.count == beforeMissing, "An account without a key fails locally before creating any HTTP request")
        check(reads == [first.credentialAccount, second.credentialAccount, third.credentialAccount], "A missing new account never falls back to a previous account's cached secret")

        scripts.keyDraft = keyC; scripts.saveConfiguration()
        check(writes.count == 1 && writes[0].account == third.credentialAccount && writes[0].key == keyC && scripts.keyDraft.isEmpty && scripts.keyIsSaved, "Explicit saving writes only the current fake account and clears its draft")
        try await fetch()
        let afterSave = ScriptCredentialWorkflowProtocol.requests.last!
        check(scripts.error == nil && afterSave.host == "credential-b.example" && afterSave.appID == third.appID && afterSave.authorization == "Bearer \(keyC)", "The newly saved account uses its own credential in the real request-building path")
        check(reads.filter { $0 == third.credentialAccount }.count == 1, "Saving the new key populates the session cache without another secret read")

        scripts.keyDraft = "unsaved-draft-for-c"; scripts.configuration = first
        try await fetch()
        let returned = ScriptCredentialWorkflowProtocol.requests.last!
        check(scripts.error == nil && scripts.keyDraft.isEmpty && returned.host == "credential-a.example" && returned.appID == first.appID && returned.authorization == "Bearer \(keyA)", "Returning to the first account restores only its own cached credential")
        check(reads.filter { $0 == first.credentialAccount }.count == 1 && writes.count == 1, "Returning to a previously authorized account neither rereads nor rewrites its key")
    }

    static func normalizedCredentialSaveWorkflow() throws {
        enum FixtureError: Error { case denied }
        var normalized = ScriptRelayConfiguration()
        normalized.baseURL = "https://trim-credential.example"; normalized.appID = "fixture-trim-app"
        var untrimmed = normalized
        untrimmed.baseURL = "  \(normalized.baseURL) \n"
        untrimmed.appID = " \(normalized.appID)\n"
        var stored: [String: String] = [:]
        var reads = 0, denyWrite = false
        var writes: [(key: String, account: String)] = []
        let credentials = ScriptCredentialSession(read: { account in
            reads += 1; return stored[account]
        }, write: { key, account in
            writes.append((key, account))
            if denyWrite { throw FixtureError.denied }
            stored[account] = key
        }, exists: { stored[$0] != nil })
        let scripts = ScriptWorkspaceModel(persistent: false, credentials: credentials)
        scripts.configuration = untrimmed; scripts.keyDraft = "fixture-trim-key"
        scripts.saveConfiguration()
        check(scripts.configuration == normalized && scripts.error == nil, "Saving trims the account before validating and storing its key")
        check(writes.count == 1 && writes[0].account == normalized.credentialAccount && writes[0].key == "fixture-trim-key", "An explicit key draft survives account normalization and is written once to the normalized account")
        check(stored.count == 1 && stored[untrimmed.credentialAccount] == nil && stored[normalized.credentialAccount] == "fixture-trim-key", "No credential is written to the untrimmed account")
        check(scripts.keyDraft.isEmpty && scripts.keyIsSaved, "Successful normalized saving clears the draft and refreshes saved-key status")
        let saved = try credentials.key(for: normalized.credentialAccount)
        check(saved == "fixture-trim-key" && reads == 0, "Successful normalized saving populates the session cache without reading a secret")

        scripts.configuration = untrimmed; scripts.keyDraft = "fixture-replacement-key"
        denyWrite = true; scripts.saveConfiguration()
        check(scripts.configuration == normalized && scripts.error != nil && scripts.keyDraft == "fixture-replacement-key", "A denied save retains the explicit draft after normalization for retry")
        check(writes.count == 2 && writes[1].account == normalized.credentialAccount && stored[normalized.credentialAccount] == "fixture-trim-key", "Failed replacement targets only the normalized account and preserves its stored key")
        let afterDenied = try credentials.key(for: normalized.credentialAccount)
        check(afterDenied == "fixture-trim-key" && reads == 0, "A denied replacement never overwrites the previously authorized cache")
        denyWrite = false; scripts.saveConfiguration()
        let afterRetry = try credentials.key(for: normalized.credentialAccount)
        check(scripts.error == nil && scripts.keyDraft.isEmpty && afterRetry == "fixture-replacement-key", "Retrying a retained draft saves and clears it only after success")
        check(writes.count == 3 && stored.count == 1 && stored[normalized.credentialAccount] == "fixture-replacement-key" && reads == 0, "Retry updates only the intended account and its in-memory cache")

        var invalid = untrimmed; invalid.baseURL = "invalid-service-address"
        scripts.configuration = invalid; scripts.keyDraft = "fixture-invalid-config-key"
        let writesBeforeInvalid = writes.count
        scripts.saveConfiguration()
        check(scripts.error != nil && scripts.keyDraft == "fixture-invalid-config-key" && writes.count == writesBeforeInvalid, "Validation failure retains the draft without any credential write")
        var other = normalized; other.appID = "fixture-other-app"
        scripts.configuration = other
        check(scripts.keyDraft.isEmpty, "An explicit account change still discards the previous account's failed draft")
        scripts.saveConfiguration()
        check(scripts.error == nil && !scripts.keyIsSaved && writes.count == writesBeforeInvalid && stored[other.credentialAccount] == nil, "Saving the new account cannot transfer the prior account's retained draft")
    }

    static func syncProjectSelection(project: FilmProject, result: ScriptAnalysis) throws {
        let studio = StudioModel(persistent: false)
        let scripts = ScriptWorkspaceModel(persistent: false)
        var first = project
        var older = result; older.id = UUID(); older.title = "较早历史"
        var newer = result; newer.id = UUID(); newer.title = "最近历史"
        first.scriptAnalyses = [older, newer]
        var second = project; second.id = UUID(); second.title = "同步测试的另一项目"
        var secondHistory = result; secondHistory.id = UUID(); secondHistory.title = "另一项目的脚本"
        second.scriptAnalyses = [secondHistory]
        studio.projects = [first, second]; studio.selectedID = first.id; studio.isPlaying = true
        scripts.showReader = false
        let initialFocusReset = studio.focusReset
        scripts.syncProject(studio: studio)
        check(scripts.workspaceProjectID == first.id && scripts.selectedAnalysisID == newer.id, "First sync chooses the project's latest history")
        check(!scripts.showWorkspace && !scripts.showConfiguration && !scripts.showReader, "First sync leaves all visibility choices unchanged")
        check(studio.isPlaying && studio.focusReset == initialFocusReset, "First sync leaves playback and text focus untouched")
        check(scripts.outputFocusID == nil, "Selecting a saved history does not emit a generation completion signal")

        scripts.selectedAnalysisID = older.id
        scripts.rangeStart = 1; scripts.rangeEnd = 4
        scripts.focus = "项目一的研究主题"; scripts.transcript = "项目一的台词"
        scripts.syncProject(studio: studio)
        check(scripts.selectedAnalysisID == older.id && scripts.rangeStart == 1 && scripts.rangeEnd == 4, "Repeated sync within one project preserves selected history and draft range")
        check(scripts.focus == "项目一的研究主题" && scripts.transcript == "项目一的台词", "Repeated sync does not clear the current project's request inputs")

        studio.selectedID = second.id; scripts.syncProject(studio: studio)
        check(scripts.selectedAnalysisID == secondHistory.id, "Switching selects the destination project's history")
        check(scripts.focus.isEmpty && scripts.transcript.isEmpty, "Switching projects clears source-specific request text")
        check(scripts.rangeStart == 0 && scripts.rangeEnd == min(second.duration, 300), "Switching resets the generation range to the destination project")
        check(!scripts.showWorkspace && !scripts.showReader && studio.isPlaying, "Switching alone keeps the sheet closed, reader hidden, and playback state untouched")

        scripts.showReader = true
        studio.selectedID = first.id; scripts.syncProject(studio: studio)
        check(scripts.selectedAnalysisID == older.id, "Returning to a project restores its specifically selected older history")
        check(scripts.showReader && !scripts.showWorkspace && studio.isPlaying, "Visible reader stays visible without opening a sheet or pausing on return")
        check(scripts.outputFocusID == nil, "History restoration remains separate from result-focus events")

        studio.selectedID = nil; scripts.syncProject(studio: studio)
        check(scripts.workspaceProjectID == nil && scripts.selectedAnalysisID == nil, "Removing the selection clears project and script selection")
        check(scripts.showReader && !scripts.showWorkspace && studio.isPlaying, "An empty project selection does not mutate visibility or playback")
    }

    static func copiedProjectDraftIsolation(project: FilmProject, result: ScriptAnalysis) throws {
        let studio = StudioModel(persistent: false)
        let scripts = ScriptWorkspaceModel(persistent: false)
        var first = project; first.scriptAnalyses = [result]
        // A separately imported copy retains the nested analysis identity.
        var second = try ProjectPersistence.decodeProject(ProjectPersistence.encodeProject(first))
        second.id = UUID(); second.title = "含相同脚本 ID 的项目副本"
        studio.projects = [first, second]
        let keyA = ScriptDraftKey(projectID: first.id, analysisID: result.id)
        let keyB = ScriptDraftKey(projectID: second.id, analysisID: result.id)
        var draftA = first.scriptAnalyses[0]; draftA.title = "只属于项目 A 的修订"
        var draftB = second.scriptAnalyses[0]; draftB.title = "只属于项目 B 的修订"
        scripts.drafts[keyA] = draftA; scripts.drafts[keyB] = draftB
        check(keyA != keyB && scripts.drafts.count == 2, "Copied analyses with identical IDs have distinct project-scoped draft keys")

        studio.selectedID = first.id; scripts.syncProject(studio: studio)
        check(scripts.selectedAnalysisID == result.id && scripts.drafts[keyA] == draftA, "Project A resolves only its own draft for the shared analysis ID")
        studio.selectedID = second.id; scripts.syncProject(studio: studio)
        check(scripts.selectedAnalysisID == result.id && scripts.drafts[keyB] == draftB, "The copied project resolves its independently edited draft")
        scripts.saveAnalysis(draftB, studio: studio)
        check(scripts.error == nil && studio.project!.scriptAnalyses[0] == draftB, "Saving project B writes B's revised script")
        check(studio.projects.first { $0.id == first.id }!.scriptAnalyses[0] == result, "Saving the copy never changes the original project's saved script")
        check(scripts.drafts[keyB] == nil && scripts.drafts[keyA] == draftA, "Saving project B clears only B's cache and retains A's unsaved draft")

        studio.selectedID = first.id; scripts.syncProject(studio: studio)
        check(scripts.drafts[keyA] == draftA && scripts.selectedAnalysisID == result.id, "Returning to A keeps its unsaved revision after saving B")
        scripts.saveAnalysis(draftA, studio: studio)
        check(studio.project!.scriptAnalyses[0] == draftA && studio.projects.first { $0.id == second.id }!.scriptAnalyses[0] == draftB, "The two imported copies keep independent saved revisions")
        check(scripts.drafts.isEmpty, "Saving each project clears each corresponding cache")

        scripts.drafts[keyA] = draftA; scripts.drafts[keyB] = draftB
        studio.selectedID = second.id; scripts.syncProject(studio: studio)
        scripts.addToTimeline(draftB, studio: studio)
        check(studio.project!.notes.count == draftB.segments.count, "The copied project's script can independently create timeline notes")
        check(scripts.drafts[keyB] == nil && scripts.drafts[keyA] == draftA, "Adding B to the timeline does not clear A's cached draft with the same analysis ID")
    }
}
