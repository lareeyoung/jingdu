import Foundation
import Security
import LocalAuthentication

/// Keep the existing file-based keychain and its ACL. Only an explicit settings
/// action may allow authorization UI; normal work never changes trust or ACLs.
enum ScriptKeychain {
    private static let store = ScriptKeychainStore()
    static func load(account: String) throws -> String? { try store.load(account: account) }
    static func authorize(account: String) throws -> String? { try store.authorize(account: account) }
    static func save(_ key: String, account: String) throws { try store.save(key, account: account) }
    static func contains(account: String) -> Bool { store.contains(account: account) }
}

/// Injectable Security calls keep policy tests entirely offline. The optional
/// keychain reference is used only by the isolated fake-key probe.
struct ScriptKeychainOperations {
    var copy: ([String: Any]) -> (OSStatus, CFTypeRef?)
    var update: ([String: Any], [String: Any]) -> OSStatus
    var add: ([String: Any]) -> OSStatus
    var interaction: () -> (OSStatus, Bool)
    var setInteraction: (Bool) -> OSStatus

    static var system: Self {
        Self(copy: { query in
            var result: CFTypeRef?
            return (SecItemCopyMatching(query as CFDictionary, &result), result)
        }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        add: { SecItemAdd($0 as CFDictionary, nil) }, interaction: {
            var allowed: DarwinBoolean = false
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        }, setInteraction: { SecKeychainSetUserInteractionAllowed($0) })
    }
}

struct ScriptKeychainStore {
    // The legacy switch is process-wide. Cover get/set/operation/restore with
    // one lock for every store and never suspend while holding that scope.
    private static let interactionLock = NSRecursiveLock()
    let operations: ScriptKeychainOperations
    let keychain: SecKeychain?
    let service: String

    init(operations: ScriptKeychainOperations = .system, keychain: SecKeychain? = nil,
         service: String = "local.jingdu.studio.script-relay") {
        self.operations = operations; self.keychain = keychain; self.service = service
    }

    private func withInteraction<T>(_ allowed: Bool, _ body: () throws -> T) throws -> T {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        let (getStatus, previous) = operations.interaction()
        try Self.check(getStatus)
        let setStatus = operations.setInteraction(allowed)
        guard setStatus == errSecSuccess else {
            // Fail closed: never issue an item operation if the UI policy
            // could not be installed. Still attempt to restore the old state.
            _ = operations.setInteraction(previous)
            try Self.check(setStatus)
            preconditionFailure("An unsuccessful status must throw")
        }
        let result = Result(catching: body)
        let restoreStatus = operations.setInteraction(previous)
        try Self.check(restoreStatus)
        return try result.get()
    }

    private func query(_ account: String, interactive: Bool) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let keychain { result[kSecMatchSearchList as String] = [keychain] }
        // This protects data-protection keychain queries too. It is not enough
        // for legacy items: SecItem.h explicitly limits no-UI to DP keychains.
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        if interactive { context.localizedReason = "授权镜读读取已保存的模型 Key" }
        result[kSecUseAuthenticationContext as String] = context
        return result
    }

    func load(account: String) throws -> String? { try read(account: account, interactive: false) }
    func authorize(account: String) throws -> String? { try read(account: account, interactive: true) }

    private func read(account: String, interactive: Bool) throws -> String? {
        try withInteraction(interactive) {
            var q = query(account, interactive: interactive)
            q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = operations.copy(q)
            if status == errSecItemNotFound { return nil }
            try Self.check(status, silentAuthentication: !interactive)
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8),
                  Self.validKey(key) else { throw ScriptCredentialError.invalidData }
            return key
        }
    }

    func contains(account: String) -> Bool {
        do {
            return try withInteraction(false) {
                var q = query(account, interactive: false)
                q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
                let (status, _) = operations.copy(q)
                if status == errSecItemNotFound { return false }
                try Self.check(status, silentAuthentication: true)
                return true
            }
        } catch {
            // Only an actual item-not-found result proves absence. Inaccessible
            // storage must not be advertised as missing or trigger replacement;
            // the subsequent silent read reports its precise typed error.
            return true
        }
    }

    func save(_ key: String, account: String) throws {
        guard Self.validKey(key) else { throw ScriptCredentialError.invalidData }
        try withInteraction(false) {
            let data = Data(key.utf8)
            let q = query(account, interactive: false)
            let status = operations.update(q, [kSecValueData as String: data])
            if status == errSecItemNotFound {
                var new = q
                new.removeValue(forKey: kSecMatchSearchList as String)
                if let keychain { new[kSecUseKeychain as String] = keychain }
                new[kSecValueData as String] = data
                // Retain the existing storage contract; do not migrate items,
                // rewrite their ACL, or add broadly trusted applications.
                new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try Self.check(operations.add(new), silentAuthentication: true)
            } else { try Self.check(status, silentAuthentication: true) }
        }
    }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 512 && key.unicodeScalars.allSatisfy { (33...126).contains(Int($0.value)) }
    }

    private static func check(_ status: OSStatus, silentAuthentication: Bool = false) throws {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed, errSecInteractionRequired: throw ScriptCredentialError.authorizationRequired
        // The file-keychain shim returns -25293 for locked items when legacy
        // UI is disabled. The isolated fixture probe covers this macOS behavior.
        case errSecAuthFailed where silentAuthentication: throw ScriptCredentialError.authorizationRequired
        case errSecUserCanceled: throw ScriptCredentialError.cancelled
        default: throw ScriptCredentialError.unavailable(status)
        }
    }
}
