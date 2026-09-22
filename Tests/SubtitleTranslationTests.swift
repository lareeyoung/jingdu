import Foundation

/// swiftc -swift-version 5 Sources/Models.swift Sources/SubtitleModels.swift Sources/ScriptRelay.swift Sources/SubtitleTranslation.swift Tests/SubtitleTranslationTests.swift -o /tmp/jingdu-subtitle-translation-tests
/// All requests are intercepted by URLProtocol; only a literal dummy key is used.
@main
struct SubtitleTranslationTests {
    private static var assertions = 0
    private static let dummyKey = "subtitle-tests-NOT-A-REAL-KEY"

    static func main() async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [SubtitleRelayMock.self]
        settings.urlCache = nil; settings.httpCookieStorage = nil
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let client = ScriptRelayClient(session: session)
        let translator = SubtitleTranslator(client: client)
        try parserContract()
        try await requestContract(client)
        try await sixLanguageMapping(translator)
        try await chineseOnly(translator)
        try await batching(translator)
        try await cancellation(translator)
        print("Subtitle translation tests passed (\(assertions) assertions; mock relay only, no network/keychain/media).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1; precondition(condition(), message)
    }
    private static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Must reject: \(message)") }
        catch { expect(!error.localizedDescription.isEmpty && !error.localizedDescription.contains(dummyKey), message) }
    }
    private static func config(_ route: ScriptRelayConfiguration.Route = .passthrough) -> ScriptRelayConfiguration {
        var config = ScriptRelayConfiguration()
        config.baseURL = "https://subtitle-relay.invalid/proxy/v1"
        config.appID = "isolated-subtitle-tests"; config.modelID = "mock-model"
        config.route = route; config.thinkingMode = .deep
        return config
    }
    private static func response(_ items: [[String: Any]]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: ["translations": items]), encoding: .utf8)!
    }
    private static func envelope(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": text]]]])
    }
    private static func fixture() -> [SubtitleCue] {
        let texts = ["中文原句，不改写。", " Don't touch it! ", "ここに来てください。", "이리 와 주세요.", "¡Ven aquí!", "Viens ici, s’il te plaît."]
        return SubtitleLanguage.allCases.enumerated().map { index, language in
            SubtitleCue(start: Double(index) * 2.1, end: Double(index) * 2.1 + 0.777,
                        language: language, text: texts[index], chineseText: language == .zh ? "" : "旧译文")
        }
    }

    private static func parserContract() throws {
        let parsed = try SubtitleTranslator.parse(response([["id": 9, "chinese": "  后一句。 \n"], ["id": 2, "chinese": "前一句！"]]), expected: [2, 9])
        expect(parsed == [2: "前一句！", 9: "后一句。"], "Replies map by ID even when provider changes array order")
        let invalid: [String] = [
            try response([["id": 2, "chinese": "缺了后句"]]),
            try response([["id": 2, "chinese": "前句"], ["id": 2, "chinese": "重复"]]),
            try response([["id": 2, "chinese": "前句"], ["id": 8, "chinese": "未知编号"]]),
            try response([["id": 2, "chinese": "前句"], ["id": 9, "chinese": " \n "]]),
            try response([["id": 2, "chinese": "前句"], ["id": 9, "chinese": "English only"]]),
            try response([["id": 2, "chinese": "前句"], ["id": 9, "chinese": String(repeating: "字", count: 5_001)]]),
            #"{"translations":[{"id":"2","chinese":"前句"},{"id":9,"chinese":"后句"}]}"#,
            #"{"translations":[{"id":2,"chinese":null},{"id":9,"chinese":"后句"}]}"#,
            #"{"translations":[{"id":2.5,"chinese":"前句"},{"id":9,"chinese":"后句"}]}"#,
            "```json\n{}\n```", "not JSON", String(repeating: "x", count: 300_001)
        ]
        for (index, value) in invalid.enumerated() {
            rejects("Invalid translation reply \(index) is rejected rather than partially merged") {
                _ = try SubtitleTranslator.parse(value, expected: [2, 9])
            }
        }
    }

    private static func requestContract(_ client: ScriptRelayClient) async throws {
        for route in ScriptRelayConfiguration.Route.allCases {
            SubtitleRelayMock.reset([.init(data: try envelope("测试文本回复"))])
            let result = try await client.completeText(configuration: config(route), key: dummyKey, prompt: "只翻译这句话。")
            let request = SubtitleRelayMock.requests[0]
            let object = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            let messages = object["messages"] as! [[String: Any]]
            expect(result == "测试文本回复", "Text completion reads model content")
            expect(messages.count == 1 && messages[0]["role"] as? String == "user" && messages[0]["content"] as? String == "只翻译这句话。", "Request contains only text, without image/audio/video attachments")
            expect(object["thinking"] as? [String: String] == ["type": "disabled"], "Translation disables expensive deep thinking regardless of script setting")
            expect(object["stream"] as? Bool == false && object["max_tokens"] as? Int == 8000, "Translation uses bounded nonstreaming output")
            expect(request.request.url?.path == (route == .passthrough ? "/proxy/v1/model/generations" : "/proxy/v1/chat/completions"), "Both configured relay routes accept text-only requests")
            expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer " + dummyKey && request.request.value(forHTTPHeaderField: "Appid") == config(route).appID, "Credentials remain in request headers")
            expect(!String(data: request.body, encoding: .utf8)!.contains(dummyKey), "Request text and JSON contain no key")
        }
    }

    private static func sixLanguageMapping(_ translator: SubtitleTranslator) async throws {
        let input = fixture()
        let reply = try response((1..<6).reversed().map { ["id": $0, "chinese": "中文译文\($0)。"] })
        SubtitleRelayMock.reset([.init(data: try envelope(reply))])
        let progress = ProgressRecorder()
        let output = try await translator.translate(input, configuration: config(), key: dummyKey, progress: { progress.append($0) })
        expect(output.count == input.count && output[0] == input[0], "Chinese source is not translated or rewritten")
        for index in input.indices {
            expect(output[index].id == input[index].id && output[index].start == input[index].start && output[index].end == input[index].end && output[index].language == input[index].language && output[index].text == input[index].text,
                   "Translation preserves original text, language, cue ID and exact timing for \(input[index].language)")
            if index > 0 { expect(output[index].chineseText == "中文译文\(index)。", "Foreign response ID maps to its original cue position") }
        }
        expect(input == fixtureWithIdentities(from: input), "Input value is never mutated by translation")
        let object = try JSONSerialization.jsonObject(with: SubtitleRelayMock.requests[0].body) as! [String: Any]
        let prompt = (object["messages"] as! [[String: Any]])[0]["content"] as! String
        let payload = prompt.components(separatedBy: "输入：").last!
        let items = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [[String: Any]]
        expect(items.map { $0["id"] as! Int } == [1, 2, 3, 4, 5], "Only foreign cue indices are sent")
        expect(items.map { $0["language"] as! String } == ["en", "ja", "ko", "es", "fr"], "Original language identifiers accompany text")
        expect(items.allSatisfy { Set($0.keys) == Set(["id", "language", "text"]) }, "Translation receives no timestamps, media, or source paths")
        expect(progress.values == [1], "One complete batch reports completion exactly once")
    }

    private static func fixtureWithIdentities(from input: [SubtitleCue]) -> [SubtitleCue] {
        var original = fixture()
        for index in original.indices { original[index].id = input[index].id }
        return original
    }

    private static func chineseOnly(_ translator: SubtitleTranslator) async throws {
        SubtitleRelayMock.reset([])
        let chinese = [fixture()[0]]
        let output = try await translator.translate(chinese, configuration: ScriptRelayConfiguration(), key: "", progress: { _ in })
        expect(output == chinese && SubtitleRelayMock.requests.isEmpty, "Chinese-only subtitles require neither model configuration nor a request")
        let empty = try await translator.translate([], configuration: ScriptRelayConfiguration(), key: "", progress: { _ in })
        expect(empty.isEmpty && SubtitleRelayMock.requests.isEmpty, "Empty subtitles do not invoke the relay")
    }

    private static func batching(_ translator: SubtitleTranslator) async throws {
        let input = (0..<71).map { SubtitleCue(start: Double($0), end: Double($0) + 0.5, language: .en, text: "Line \($0)", chineseText: "旧译文") }
        let replies = try stride(from: 0, to: input.count, by: 35).map { start in
            SubtitleRelayMock.Stub(data: try envelope(response((start..<min(start + 35, input.count)).map { ["id": $0, "chinese": "译文\($0)"] })))
        }
        SubtitleRelayMock.reset(replies)
        let progress = ProgressRecorder()
        let output = try await translator.translate(input, configuration: config(), key: dummyKey, progress: { progress.append($0) })
        expect(output.enumerated().allSatisfy { $0.element.chineseText == "译文\($0.offset)" }, "All batches merge only after successful ID validation")
        expect(SubtitleRelayMock.requests.count == 3 && progress.values == [35.0 / 71, 70.0 / 71, 1], "71 foreign cues use 35/35/1 bounded batches")
        SubtitleRelayMock.reset([replies[0], .init(status: 500, data: Data("{}".utf8))])
        var partial: [SubtitleCue]?
        do {
            partial = try await translator.translate(input, configuration: config(), key: dummyKey, progress: { _ in })
            fatalError("A failed second batch must throw")
        } catch {
            expect(partial == nil && input.allSatisfy { $0.chineseText == "旧译文" }, "Batch failure exposes no partial translated value and preserves original subtitles")
            expect(SubtitleRelayMock.requests.count == 2, "Failed batches are not silently retried and later batches are not requested")
        }
    }

    private static func cancellation(_ translator: SubtitleTranslator) async throws {
        SubtitleRelayMock.reset([.init(data: try envelope(response([["id": 0, "chinese": "你好"]])), delay: 2)])
        let cue = SubtitleCue(start: 0, end: 1, language: .en, text: "Hello", chineseText: "")
        let task = Task { try await translator.translate([cue], configuration: config(), key: dummyKey, progress: { _ in }) }
        for _ in 0..<100 {
            if !SubtitleRelayMock.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        expect(SubtitleRelayMock.requests.count == 1, "Cancellation test reaches the intercepted request")
        task.cancel()
        do { _ = try await task.value; fatalError("Cancelled request must not return translated captions") }
        catch is CancellationError { expect(true, "In-flight relay cancellation propagates as cancellation") }
        expect(SubtitleRelayMock.requests.count == 1, "Cancellation does not trigger another request")
        SubtitleRelayMock.reset([])
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await translator.translate([cue], configuration: config(), key: dummyKey, progress: { _ in })
        }
        do { _ = try await alreadyCancelled.value; fatalError("Pre-cancelled translation must stop") }
        catch is CancellationError { expect(SubtitleRelayMock.requests.isEmpty, "Pre-cancelled translation stops before network") }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class SubtitleRelayMock: URLProtocol {
    struct Stub { var status = 200; var data: Data; var delay = 0.0 }
    struct Capture { var request: URLRequest; var body: Data }
    private static let lock = NSLock()
    private static var stubs: [Stub] = []
    private static var captures: [Capture] = []
    private let cancelLock = NSLock()
    private var stopped = false
    static var requests: [Capture] { lock.lock(); defer { lock.unlock() }; return captures }
    static func reset(_ values: [Stub]) { lock.lock(); defer { lock.unlock() }; stubs = values; captures = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        Self.lock.lock()
        Self.captures.append(Capture(request: request, body: body))
        let stub = Self.stubs.isEmpty ? Stub(status: 599, data: Data()) : Self.stubs.removeFirst()
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay) { [self] in
            cancelLock.lock(); let cancelled = stopped; cancelLock.unlock()
            guard !cancelled else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { cancelLock.lock(); stopped = true; cancelLock.unlock() }
}
