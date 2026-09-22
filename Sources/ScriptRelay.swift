import Foundation
import Security
import LocalAuthentication

struct ScriptRelayConfiguration: Codable, Equatable {
    enum Route: String, Codable, CaseIterable {
        case passthrough, chatCompletions
        var title: String { self == .passthrough ? "供应商原格式（推荐）" : "Chat Completions" }
    }
    enum ThinkingMode: String, Codable, CaseIterable, Identifiable {
        case standard, deep
        var id: String { rawValue }
        var title: String { self == .standard ? "标准生成" : "深度分析" }
    }
    var baseURL = ""
    var appID = ""
    var modelID = "doubao-seed-2-1-pro-260628"
    var providerModel = ""
    var route: Route = .passthrough
    var timeout = 300
    var thinkingMode: ThinkingMode = .standard

    func validatedBaseURL() throws -> URL {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw ScriptRelayError.message("请填写完整的服务地址，不要在地址里附带 Key、参数或账号。") }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let decimalIPv4 = labels.count == 4 && labels.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0.count == 1 || $0.first != "0")
        }
        let octets = labels.compactMap { Int($0) }
        let privateIP = decimalIPv4 && octets.count == 4 && octets.allSatisfy({ (0...255).contains($0) }) &&
            (octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168) ||
             (octets[0] == 172 && (16...31).contains(octets[1])))
        guard scheme == "https" || privateIP || host.lowercased() == "localhost" || ["::1", "[::1]"].contains(host.lowercased()) else {
            throw ScriptRelayError.message("HTTP 仅用于内网地址；公网服务请使用 HTTPS。")
        }
        guard (30...900).contains(timeout) else { throw ScriptRelayError.message("请求超时需在 30–900 秒之间。") }
        return url
    }
    func validate(requireModel: Bool = true) throws {
        _ = try validatedBaseURL()
        guard Self.validHeader(appID), !appID.isEmpty else { throw ScriptRelayError.message("请填写分配给你的 AppID。") }
        if requireModel && modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ScriptRelayError.message("请选择或填写 Seed2.1 的实际模型名称。")
        }
        guard modelID.count <= 200, providerModel.count <= 250,
              !modelID.contains("\0"), !providerModel.contains("\0") else { throw ScriptRelayError.message("模型名称过长或包含无效字符。") }
    }
    static func validHeader(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 512 && text.unicodeScalars.allSatisfy { (33...126).contains(Int($0.value)) }
    }
    func endpoint(_ path: String, provider: String? = nil) throws -> URL {
        let base = try validatedBaseURL()
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw ScriptRelayError.message("服务地址无法识别。") }
        var basePath = parts.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        if basePath.hasSuffix("/v1") { basePath = String(basePath.dropLast(3)) }
        parts.path = basePath + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let provider, !provider.isEmpty { parts.queryItems = [URLQueryItem(name: "provider_model", value: provider)] }
        guard let url = parts.url else { throw ScriptRelayError.message("服务地址无法识别。") }; return url
    }
    var credentialAccount: String {
        let address = (try? validatedBaseURL().absoluteString) ?? baseURL
        return address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + appID
    }
}

extension ScriptRelayConfiguration {
    private enum CodingKeys: String, CodingKey {
        case baseURL, appID, modelID, providerModel, route, timeout, thinkingMode
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        appID = try values.decode(String.self, forKey: .appID)
        modelID = try values.decode(String.self, forKey: .modelID)
        providerModel = try values.decode(String.self, forKey: .providerModel)
        route = try values.decode(Route.self, forKey: .route)
        timeout = try values.decode(Int.self, forKey: .timeout)
        thinkingMode = values.contains(.thinkingMode) ? try values.decode(ThinkingMode.self, forKey: .thinkingMode) : .standard
    }
}

enum ScriptRelayError: LocalizedError {
    case message(String)
    case incompleteResponse(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .incompleteResponse:
            return "模型回复被长度限制截断，脚本未完成；已接收的原文已保留，未保存为完整脚本。请缩短视频范围后重新生成。"
        }
    }
}

/// Refuse redirects so a relay cannot forward the app's credentials to another host.
final class ScriptRelayRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ScriptRelayClient {
    static let maximumVideoByteCount = 11_000_000
    static let maximumRequestByteCount = 16_000_000
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil
            config.timeoutIntervalForResource = 930
            self.session = URLSession(configuration: config, delegate: ScriptRelayRedirectPolicy(), delegateQueue: nil)
        }
    }
    func models(configuration: ScriptRelayConfiguration, key: String) async throws -> [String] {
        try configuration.validate(requireModel: false)
        var request = try makeRequest(configuration: configuration, key: key, path: "v1/models")
        request.httpMethod = "GET"; request.timeoutInterval = 30
        let data = try await send(request, key: key)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { throw ScriptRelayError.message("服务返回的模型列表格式无法识别，请手动填写模型名称。") }
        return Array(Set(entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })).sorted()
    }
    func analyze(configuration: ScriptRelayConfiguration, key: String, videoURL: URL, prompt: String) async throws -> String {
        try Task.checkCancellation(); try configuration.validate()
        let size = (try videoURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size > 0, size <= Self.maximumVideoByteCount else { throw ScriptRelayError.message("分析视频超过 11 MB，请缩短选段后重试。") }
        let video = try Data(contentsOf: videoURL, options: .mappedIfSafe)
        let request = try analysisRequest(configuration: configuration, key: key, video: video, prompt: prompt)
        try Task.checkCancellation()
        let data = try await send(request, key: key)
        return try Self.responseText(data)
    }
    func completeText(configuration: ScriptRelayConfiguration, key: String, prompt: String) async throws -> String {
        try Task.checkCancellation(); try configuration.validate()
        let provider = configuration.providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configuration.route == .passthrough ? "v1/model/generations" : "v1/chat/completions"
        var request = try makeRequest(configuration: configuration, key: key, path: path,
            provider: configuration.route == .passthrough ? (provider.isEmpty ? configuration.modelID : provider) : provider)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.modelID, "stream": false, "max_tokens": 8000,
            "thinking": ["type": "disabled"],
            "messages": [["role": "user", "content": prompt]]
        ])
        guard (request.httpBody?.count ?? 0) <= 500_000 else { throw ScriptRelayError.message("本次翻译文本过长，请分段处理。") }
        return try Self.responseText(try await send(request, key: key))
    }
    func analysisRequest(configuration: ScriptRelayConfiguration, key: String, video: Data, prompt: String) throws -> URLRequest {
        try configuration.validate()
        guard !video.isEmpty, video.count <= Self.maximumVideoByteCount else { throw ScriptRelayError.message("分析视频为空或超过 11 MB，请缩短选段。") }
        let path = configuration.route == .passthrough ? "v1/model/generations" : "v1/chat/completions"
        let provider = configuration.providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = try makeRequest(configuration: configuration, key: key, path: path,
            provider: configuration.route == .passthrough ? (provider.isEmpty ? configuration.modelID : provider) : provider)
        let body: [String: Any] = [
            "model": configuration.modelID, "stream": false, "max_tokens": 16000,
            "thinking": ["type": configuration.thinkingMode == .standard ? "disabled" : "enabled"],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": prompt],
                // fps is optional. Omit it: the relay expects a string while the provider expects a number.
                ["type": "video_url", "video_url": ["url": "data:video/mp4;base64," + video.base64EncodedString()]]
            ]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        guard (request.httpBody?.count ?? 0) <= Self.maximumRequestByteCount else { throw ScriptRelayError.message("请求内容过大，请缩短选段。") }
        return request
    }
    private func makeRequest(configuration: ScriptRelayConfiguration, key: String, path: String, provider: String? = nil) throws -> URLRequest {
        guard ScriptRelayConfiguration.validHeader(key) else { throw ScriptRelayError.message("请在模型设置中填写有效 Key。") }
        var request = URLRequest(url: try configuration.endpoint(path, provider: provider))
        request.httpMethod = "POST"; request.timeoutInterval = Double(configuration.timeout + 20)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue(configuration.appID, forHTTPHeaderField: "Appid")
        request.setValue(String(configuration.timeout), forHTTPHeaderField: "X-Model-Timeout")
        request.setValue(String(UInt64.random(in: 1...UInt64.max)), forHTTPHeaderField: "X_BD_LOGID")
        return request
    }
    private func send(_ request: URLRequest, key: String) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ScriptRelayError.message("服务没有返回有效的 HTTP 响应。") }
            guard (200...299).contains(http.statusCode) else {
                let explanation: String
                let upstreamMessage = Self.errorMessage(data)?.lowercased() ?? ""
                if http.statusCode == 500, upstreamMessage.contains("read_req_body") || upstreamMessage.contains("read req body"),
                   upstreamMessage.contains("timeout") || upstreamMessage.contains("timed out") {
                    explanation = "视频上传阶段超时。请检查内网或 VPN 连接，或缩短选段后重试；没有自动重试。"
                } else if http.statusCode == 500,
                   upstreamMessage.contains("client_timeout_exceeded_while_awaiting_headers") {
                    explanation = "中转服务等待模型回复超时。请缩短选段，或切换到“标准生成”后手动重试；没有自动重试。"
                } else {
                    switch http.statusCode {
                    case 401, 403: explanation = "AppID 或 Key 无效，或尚未获得该模型的调用权限。"
                    case 404: explanation = "接口或模型不存在，请检查接口方式与模型名称。"
                    case 413: explanation = "中转服务认为视频过大，请缩短选段。"
                    case 429: explanation = "调用频率或额度达到限制，请稍后手动重试。"
                    case 300...399: explanation = "服务要求跳转地址；请在设置中填写最终地址后重试。"
                    default: explanation = "服务未完成本次分析。"
                    }
                }
                let detail = Self.safeErrorDetail(data, key: key)
                throw ScriptRelayError.message("\(explanation)（HTTP \(http.statusCode)）" + (detail.isEmpty ? "" : "\n" + detail))
            }
            guard data.count <= 8 * 1024 * 1024 else { throw ScriptRelayError.message("服务返回内容过大，请缩短视频范围后重试。") }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw ScriptRelayError.message("中转请求超时。没有自动重试，可缩短视频范围后再分析。") }
            throw ScriptRelayError.message("无法连接中转服务，请确认已接入公司内网或 VPN，并检查服务地址。")
        }
    }
    static func responseText(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScriptRelayError.message("中转没有返回 JSON，请确认接口方式和模型名称。")
        }
        guard root["error"] == nil || root["error"] is NSNull else { throw ScriptRelayError.message("模型返回了错误结果，请检查权限、额度和模型参数。") }
        guard let choices = root["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any] else { throw ScriptRelayError.message("返回格式与当前接口不匹配：未找到模型回复。请确认使用透传或 Chat Completions 接口。") }
        if choice["finish_reason"] as? String == "content_filter" { throw ScriptRelayError.message("服务未返回可用内容，未保存脚本。") }
        let text: String
        if let content = message["content"] as? String { text = content }
        else if let parts = message["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        else { text = "" }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScriptRelayError.message("模型没有返回脚本正文，请稍后重试或缩短范围。") }
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw ScriptRelayError.message("模型回复正文超过 4 MB，请缩短视频范围后重新生成。") }
        if choice["finish_reason"] as? String == "length" { throw ScriptRelayError.incompleteResponse(text) }
        return text
    }
    static func safeErrorDetail(_ data: Data, key: String) -> String {
        guard let message = errorMessage(data) else { return "" }
        var safe = message.replacingOccurrences(of: key, with: "[已隐藏]")
        safe = safe.replacingOccurrences(of: "(?i)Bearer\\s+[^\\s\"']+", with: "Bearer [已隐藏]", options: .regularExpression)
        return String(safe.prefix(350))
    }
    private static func errorMessage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
