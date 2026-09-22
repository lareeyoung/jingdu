import Foundation

enum ScriptCredentialError: LocalizedError, Equatable {
    case authorizationRequired
    case cancelled
    case unavailable(Int32)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return "已保存的 Key 需要授权读取。请在模型设置中点击“授权读取已存 Key”，再重试。"
        case .cancelled:
            return "已取消钥匙串授权。已存 Key 保留，可在模型设置中重新授权。"
        case .unavailable(let status):
            return "暂时无法访问 macOS 钥匙串（错误码 \(status)）。已存 Key 保留，请稍后重试。"
        case .invalidData:
            return "钥匙串中的 Key 格式无效，请在模型设置中检查并重新保存。"
        }
    }
}

/// One session belongs to one app process. Successful authorization is reused
/// only for the same service/account; keys are never serialized by this type.
@MainActor final class ScriptCredentialSession {
    private var cached: [String: String] = [:]
    private let read: (String) throws -> String?
    private let write: (String, String) throws -> Void
    private let exists: (String) -> Bool
    private let authorizeRead: (String) throws -> String?

    init(read: @escaping (String) throws -> String?,
         write: @escaping (String, String) throws -> Void,
         exists: @escaping (String) -> Bool,
         authorize: ((String) throws -> String?)? = nil) {
        self.read = read; self.write = write; self.exists = exists
        self.authorizeRead = authorize ?? read
    }

    /// The settings button is the only caller allowed to request system UI.
    /// Success is shared by model listing, analysis and subtitle translation.
    func authorize(account: String) throws -> String? {
        guard let key = try authorizeRead(account), !key.isEmpty else { return nil }
        cached[account] = key
        return key
    }

    func key(for account: String) throws -> String? {
        if let key = cached[account] { return key }
        guard let key = try read(account), !key.isEmpty else { return nil }
        cached[account] = key
        return key
    }

    func save(_ key: String, account: String) throws {
        try write(key, account)
        cached[account] = key
    }

    func contains(account: String) -> Bool { cached[account] != nil || exists(account) }
    func forget(account: String) { cached.removeValue(forKey: account) }

    static func memoryOnly() -> ScriptCredentialSession {
        var values: [String: String] = [:]
        return ScriptCredentialSession(read: { values[$0] }, write: { values[$1] = $0 }, exists: { values[$0] != nil })
    }
}
