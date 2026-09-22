import Foundation
import AVFoundation

/// Injected credentials and URLProtocol only. No system authorization, keychain,
/// real service, user library, or user media is accessed by this integration test.
final class AuthorizationWorkflowHTTP: URLProtocol, @unchecked Sendable {
    static let fakeKey = "authorization-workflow-FAKE-KEY"
    static let modelID = "authorization-fixture-model"
    private static let lock = NSLock()
    private static var count = 0
    private static var correctHeaders = true
    static var scriptJSON = ""
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    static var allHeadersMatch: Bool { lock.lock(); defer { lock.unlock() }; return correctHeaders }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.correctHeaders = Self.correctHeaders && request.value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.fakeKey
        Self.lock.unlock()
        let object: [String: Any] = request.httpMethod == "GET"
            ? ["data": [["id": Self.modelID]]]
            : ["choices": [["finish_reason": "stop", "message": ["content": Self.scriptJSON]]]]
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct ScriptAuthorizationWorkflowTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(condition(), message)
    }
    @MainActor final class CredentialFixture {
        var reads = 0, authorizations = 0, writes = 0
        var cancelAuthorization = false
        func session() -> ScriptCredentialSession {
            ScriptCredentialSession(read: { [self] _ in
                reads += 1; throw ScriptCredentialError.authorizationRequired
            }, write: { [self] _, _ in writes += 1 }, exists: { _ in true }, authorize: { [self] _ in
                authorizations += 1
                if cancelAuthorization { throw ScriptCredentialError.cancelled }
                return AuthorizationWorkflowHTTP.fakeKey
            })
        }
    }
    @MainActor final class Harness {
        let studio = StudioModel(persistent: false)
        let credentials = CredentialFixture()
        let scripts: ScriptWorkspaceModel
        init(_ project: FilmProject) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AuthorizationWorkflowHTTP.self]
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            scripts = ScriptWorkspaceModel(persistent: false,
                client: ScriptRelayClient(session: URLSession(configuration: configuration)),
                credentials: credentials.session(),
                subtitles: SubtitleWorkspaceModel(transcribe: { _, _, _ in throw SubtitleTranscriber.Failure.noSpeech }))
            scripts.configuration.baseURL = "https://relay.example.test"
            scripts.configuration.appID = "authorization-fixture-app"
            scripts.configuration.modelID = AuthorizationWorkflowHTTP.modelID
            scripts.saveConfiguration()
            scripts.workspaceProjectID = project.id
            scripts.rangeStart = 1; scripts.rangeEnd = 4
            studio.projects = [project]; studio.selectedID = project.id; studio.mediaAvailable = true
        }
    }
    static func finish(_ scripts: ScriptWorkspaceModel) async throws {
        for _ in 0..<600 {
            if !scripts.isRunning && !scripts.isFetchingModels { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        preconditionFailure("Offline authorization workflow timed out")
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a disposable synthetic MP4 fixture") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let original = try Data(contentsOf: url)
        let info = try await MediaAnalyzer.inspect(url)
        let project = SequenceLogic.makeProject(title: "离线授权回归", clips: [VideoClip(title: "synthetic", sourcePath: url.path,
            sourceDuration: info.duration, sourceIn: 0, sourceOut: info.duration,
            frameRate: info.frameRate, width: info.width, height: info.height)])
        AuthorizationWorkflowHTTP.scriptJSON = String(data: try JSONSerialization.data(withJSONObject: [
            "title": "授权后生成", "synopsis": "合成响应", "structure": "合成结构", "caveats": "离线验证",
            "segments": [["start": 0, "end": 3, "screenplay": "合成画面。", "visual": "画面", "action": "动作",
                "dialogue": "待核对", "sound": "待核对", "camera": "固定", "transition": "无", "reasoning": "测试", "uncertainty": "测试"]]
        ]), encoding: .utf8)!

        let h = Harness(project)
        check(h.scripts.keyIsSaved && h.credentials.reads == 0 && h.credentials.writes == 0, "Saving configuration alone preserves an inaccessible existing key without reading or replacing it")
        let requestsBefore = AuthorizationWorkflowHTTP.requests
        h.scripts.fetchModels()
        check(h.scripts.credentialNeedsAuthorization && h.scripts.error != nil && !h.scripts.isFetchingModels, "Model listing exposes explicit authorization action after a silent read fails")
        h.scripts.analyze(studio: h.studio)
        check(h.scripts.credentialNeedsAuthorization && h.scripts.error != nil && !h.scripts.isRunning, "Manual analysis refuses to start while authorization is required")
        h.scripts.analyze(studio: h.studio, automatic: true)
        check(!h.scripts.isRunning && h.scripts.credentialNeedsAuthorization, "Automatic analysis also stops without interactive authorization")
        do { _ = try h.scripts.subtitleTranslationAccess(); preconditionFailure("Translation must require authorization") }
        catch { check(error as? ScriptCredentialError == .authorizationRequired, "Subtitle translation preserves the typed silent-read authorization error") }
        check(h.credentials.reads == 4 && h.credentials.authorizations == 0 && h.credentials.writes == 0,
              "Listing, manual/automatic analysis and translation use only silent reads")
        check(AuthorizationWorkflowHTTP.requests == requestsBefore && h.studio.project!.scriptAnalyses.isEmpty,
              "Failed silent reads issue no requests and do not add a script")

        h.scripts.authorizeSavedKey()
        check(h.credentials.authorizations == 1 && h.scripts.keyIsSaved && !h.scripts.credentialNeedsAuthorization && h.scripts.error == nil,
              "The explicit settings action authorizes once and clears the recovery state")
        check(AuthorizationWorkflowHTTP.requests == requestsBefore, "Authorization itself never starts a model request")
        h.scripts.fetchModels(); try await finish(h.scripts)
        check(h.scripts.error == nil && h.scripts.availableModels == [AuthorizationWorkflowHTTP.modelID], "Listing reuses the authorized session")
        h.scripts.analyze(studio: h.studio); try await finish(h.scripts)
        check(h.scripts.error == nil && h.studio.project!.scriptAnalyses.count == 1, "Analysis reuses authorization and saves its offline result")
        let (savedConfiguration, key) = try h.scripts.subtitleTranslationAccess()
        check(key == AuthorizationWorkflowHTTP.fakeKey && savedConfiguration == h.scripts.configuration, "Subtitle translation receives the same authorized key and saved account")
        check(h.credentials.reads == 4 && h.credentials.authorizations == 1 && h.credentials.writes == 0,
              "All successful paths reuse the cache without another read, authorization, or write")
        check(AuthorizationWorkflowHTTP.requests == requestsBefore + 2 && AuthorizationWorkflowHTTP.allHeadersMatch,
              "Only explicit listing and analysis reach the mock transport with the authorized key")

        let cancelled = Harness(project)
        cancelled.credentials.cancelAuthorization = true
        cancelled.scripts.fetchModels()
        let cancelRequests = AuthorizationWorkflowHTTP.requests
        cancelled.scripts.authorizeSavedKey()
        check(cancelled.scripts.keyIsSaved && cancelled.scripts.credentialNeedsAuthorization && cancelled.scripts.error == ScriptCredentialError.cancelled.localizedDescription,
              "Cancellation preserves the saved-key indicator and provides a retryable error")
        check(cancelled.credentials.authorizations == 1 && cancelled.credentials.writes == 0 && AuthorizationWorkflowHTTP.requests == cancelRequests,
              "Cancellation never overwrites a key or starts network work")
        cancelled.scripts.analyze(studio: cancelled.studio)
        check(!cancelled.scripts.isRunning && cancelled.credentials.authorizations == 1 && AuthorizationWorkflowHTTP.requests == cancelRequests,
              "Retrying analysis after cancellation still cannot trigger authorization implicitly")
        cancelled.scripts.configuration.appID = "different-authorization-fixture-app"
        check(!cancelled.scripts.credentialNeedsAuthorization, "Switching accounts clears the prior account's authorization indicator")
        let after = try Data(contentsOf: url)
        check(after == original, "Synthetic input media remains unchanged")
        print("Script authorization workflow tests passed (\(checks) assertions; fake credentials, mock HTTP, no system UI/keychain/user data).")
    }
}
