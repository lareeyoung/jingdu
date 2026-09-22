import Foundation
import Security
import LocalAuthentication
import Darwin

// Offline by default: all Security calls are injected fakes.
// xcrun swiftc -swift-version 5 Sources/ScriptCredentials.swift Sources/ScriptKeychain.swift Tests/KeychainPolicyTests.swift -o /tmp/jingdu-keychain-policy-tests
// /tmp/jingdu-keychain-policy-tests
// Optional integration test, using only an owned /tmp keychain and fake key:
// codesign --force --sign - /tmp/jingdu-keychain-policy-tests
// /tmp/jingdu-keychain-policy-tests --isolated-probe
// The probe disables interaction before creating its fixture, never calls
// authorize(), never uses the default keychain, and removes its fixture.
@main @MainActor struct KeychainPolicyTests {
    static var assertions = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        assertions += 1
        do { let passed = try value(); precondition(passed, message) }
        catch { preconditionFailure("\(message): \(error)") }
    }
    static func expect(_ error: ScriptCredentialError, _ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected \(error)") }
        catch let actual as ScriptCredentialError { check(actual == error, "Typed error remains precise: expected \(error), got \(actual)") }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }

    final class Fake {
        var allowed = true
        var getStatus: OSStatus = errSecSuccess
        var setResults: [OSStatus] = []
        var copyStatus: OSStatus = errSecSuccess
        var copyResult: CFTypeRef? = Data("FAKE-KEY-ONLY".utf8) as CFData
        var updateStatus: OSStatus = errSecSuccess
        var addStatus: OSStatus = errSecSuccess
        var changes: [Bool] = []
        var operations: [(String, Bool, [String: Any])] = []
        var store: ScriptKeychainStore {
            ScriptKeychainStore(operations: ScriptKeychainOperations(copy: { [self] q in
                operations.append(("copy", allowed, q)); return (copyStatus, copyResult)
            }, update: { [self] q, values in
                precondition(values[kSecValueData as String] != nil, "Update passes the replacement data")
                operations.append(("update", allowed, q)); return updateStatus
            }, add: { [self] q in
                operations.append(("add", allowed, q)); return addStatus
            }, interaction: { [self] in (getStatus, allowed) }, setInteraction: { [self] value in
                changes.append(value)
                let status = setResults.isEmpty ? errSecSuccess : setResults.removeFirst()
                if status == errSecSuccess { allowed = value }
                return status
            }))
        }
    }

    static func main() throws {
        if CommandLine.arguments.contains("--isolated-probe") {
            try isolatedProbe()
            print("Isolated fake-keychain probe passed (\(assertions) checks; no user key, authorization UI or network).")
            return
        }
        try silentReadAndPresence()
        try explicitAuthorization()
        try writesAndPolicyFailures()
        try sessionSeparation()
        print("Keychain policy passed (\(assertions) assertions; injected fake keys, no Security calls).")
    }

    static func silentReadAndPresence() throws {
        let fake = Fake(), account = "fixture-account"
        let loaded = try fake.store.load(account: account)
        check(loaded == "FAKE-KEY-ONLY", "Valid data is readable silently")
        check(fake.allowed && fake.changes == [false, true], "The caller's interaction setting is restored")
        let query = fake.operations[0].2
        check(!fake.operations[0].1, "Secret read executes with legacy interaction disabled")
        check((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true,
              "The modern per-query context also forbids UI")
        check(query[kSecAttrAccount as String] as? String == account, "Secret lookup remains scoped to the exact account")
        check(query[kSecAttrService as String] as? String == "local.jingdu.studio.script-relay", "Existing stored service is preserved")
        check(query[kSecUseDataProtectionKeychain as String] == nil, "Existing legacy items are not silently migrated")
        check(fake.store.contains(account: account), "Successful attributes lookup confirms presence")
        check(fake.operations.last?.2[kSecReturnData as String] == nil, "Presence checks never request secret bytes")
        check(fake.operations.last?.2[kSecReturnAttributes as String] as? Bool == true, "Presence uses attributes only")
        fake.copyStatus = errSecItemNotFound
        let missing = try fake.store.load(account: account)
        check(missing == nil && !fake.store.contains(account: account), "Only item-not-found proves a missing key")
        for status in [errSecInteractionNotAllowed, errSecInteractionRequired] {
            fake.copyStatus = status
            expect(.authorizationRequired) { _ = try fake.store.load(account: account) }
            check(fake.store.contains(account: account), "An authorization requirement is not reported as an absent key")
            check(fake.allowed, "Rejected read restores interaction")
        }
        fake.copyStatus = errSecNotAvailable
        expect(.unavailable(errSecNotAvailable)) { _ = try fake.store.load(account: account) }
        check(fake.store.contains(account: account), "Unavailable storage is not proof of absent credentials")
        fake.copyStatus = errSecAuthFailed
        expect(.authorizationRequired) { _ = try fake.store.load(account: account) }
        fake.copyStatus = errSecSuccess
        for data: Data in [Data(), Data([0xff]), Data("contains space".utf8), Data(repeating: 97, count: 513)] {
            fake.copyResult = data as CFData
            expect(.invalidData) { _ = try fake.store.load(account: account) }
        }
        check(fake.operations.allSatisfy { !$0.1 }, "No normal load or presence path enables UI")
    }

    static func explicitAuthorization() throws {
        let fake = Fake(); fake.allowed = false
        let key = try fake.store.authorize(account: "fixture")
        check(key == "FAKE-KEY-ONLY", "Explicit authorization can retrieve the saved key")
        check(fake.operations[0].1 && fake.changes == [true, false] && !fake.allowed,
              "Only the explicit read enables interaction, then restores a disabled prior setting")
        let context = fake.operations[0].2[kSecUseAuthenticationContext as String] as? LAContext
        check(context?.interactionNotAllowed == false, "Explicit authorization enables its LAContext")
        fake.copyStatus = errSecUserCanceled
        expect(.cancelled) { _ = try fake.store.authorize(account: "fixture") }
        check(!fake.allowed, "Cancellation restores the exact previous policy")
        fake.copyStatus = errSecAuthFailed
        expect(.unavailable(errSecAuthFailed)) { _ = try fake.store.authorize(account: "fixture") }
        check(fake.operations.allSatisfy { $0.0 == "copy" }, "Authorization never changes or deletes a stored item")
    }

    static func writesAndPolicyFailures() throws {
        let fake = Fake()
        try fake.store.save("FAKE-REPLACEMENT", account: "fixture")
        check(fake.operations.map(\.0) == ["update"], "Existing keys update without a duplicate insert")
        fake.operations = []; fake.updateStatus = errSecItemNotFound
        try fake.store.save("FAKE-NEW", account: "new")
        check(fake.operations.map(\.0) == ["update", "add"], "Only actual absence inserts a new item")
        check(fake.operations.last?.2[kSecAttrAccess as String] == nil, "The item retains the platform's creator ACL")
        check(fake.operations.last?.2[kSecAttrAccessGroup as String] == nil, "No broad access group is introduced")
        fake.operations = []; fake.updateStatus = errSecInteractionNotAllowed
        expect(.authorizationRequired) { try fake.store.save("FAKE-NEW", account: "fixture") }
        check(fake.operations.map(\.0) == ["update"], "Denied update neither inserts, deletes nor falls back to UI")
        check(fake.allowed, "Failed write restores the original interaction policy")
        expect(.invalidData) { try fake.store.save("", account: "fixture") }
        check(fake.operations.count == 1, "Invalid data is rejected before storage access")
        check(fake.operations.allSatisfy { !$0.1 }, "Saving is also silent")

        let getFailure = Fake(); getFailure.getStatus = errSecNotAvailable
        expect(.unavailable(errSecNotAvailable)) { _ = try getFailure.store.load(account: "fixture") }
        check(getFailure.operations.isEmpty && getFailure.changes.isEmpty, "Policy-read failure prevents the item call")
        let setFailure = Fake(); setFailure.setResults = [errSecNotAvailable, errSecSuccess]
        expect(.unavailable(errSecNotAvailable)) { _ = try setFailure.store.load(account: "fixture") }
        check(setFailure.operations.isEmpty && setFailure.changes == [false, true], "Policy-install failure fails closed and attempts restoration")
        let restoreFailure = Fake(); restoreFailure.setResults = [errSecSuccess, errSecNotAvailable]
        expect(.unavailable(errSecNotAvailable)) { _ = try restoreFailure.store.load(account: "fixture") }
        check(restoreFailure.operations.count == 1 && !restoreFailure.allowed, "Restoration errors are visible; secret use does not continue")
    }

    static func sessionSeparation() throws {
        var reads = 0, authorizations = 0
        var cancel = true
        let session = ScriptCredentialSession(read: { _ in
            reads += 1; throw ScriptCredentialError.authorizationRequired
        }, write: { _, _ in }, exists: { _ in true }, authorize: { account in
            authorizations += 1
            if cancel { throw ScriptCredentialError.cancelled }
            return "FAKE-\(account)"
        })
        check(session.contains(account: "a") && reads == 0 && authorizations == 0, "Status does not ask for authorization")
        for _ in 0..<3 { expect(.authorizationRequired) { _ = try session.key(for: "a") } }
        check(reads == 3 && authorizations == 0, "Repeated background attempts never escalate to authorization")
        expect(.cancelled) { _ = try session.authorize(account: "a") }
        expect(.authorizationRequired) { _ = try session.key(for: "a") }
        cancel = false
        let allowed = try session.authorize(account: "a")
        check(allowed == "FAKE-a" && authorizations == 2, "A later explicit retry authorizes and caches the right account")
        for _ in 0..<3 { check(try session.key(for: "a") == "FAKE-a", "Subsequent workflows reuse the authorized cache") }
        check(reads == 4 && authorizations == 2, "Listing, analysis and translation need no repeated Keychain access")
        expect(.authorizationRequired) { _ = try session.key(for: "b") }
        check(authorizations == 2, "Account changes cannot silently authorize or use another account's key")
        try session.save("FAKE-SAVED-B", account: "b")
        check(try session.key(for: "b") == "FAKE-SAVED-B", "An explicit successful save also populates the cache")
        cancel = true
        expect(.cancelled) { _ = try session.authorize(account: "a") }
        check(try session.key(for: "a") == "FAKE-a", "A cancelled explicit reauthorization preserves successful session data")
        var defaultReads = 0
        let compatible = ScriptCredentialSession(read: { _ in defaultReads += 1; return "FAKE-DEFAULT" },
                                                  write: { _, _ in }, exists: { _ in true })
        check(try compatible.authorize(account: "a") == "FAKE-DEFAULT" && defaultReads == 1,
              "Existing injected sessions retain their compatible default authorization closure")
    }

    static func isolatedProbe() throws {
        func verify(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw ProbeFailure(description: message) }
            assertions += 1
        }
        var previous: DarwinBoolean = false
        let get = SecKeychainGetUserInteractionAllowed(&previous)
        guard get == errSecSuccess else { throw ScriptCredentialError.unavailable(get) }
        let disable = SecKeychainSetUserInteractionAllowed(false)
        guard disable == errSecSuccess else { throw ScriptCredentialError.unavailable(disable) }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("jingdu-keychain-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fake-only.keychain-db")
        let password = Data("FAKE-KEYCHAIN-PASSWORD-NOT-A-USER-SECRET".utf8)
        var fixture: SecKeychain?
        let created = password.withUnsafeBytes { SecKeychainCreate(url.path, UInt32($0.count), $0.baseAddress, false, nil, &fixture) }
        guard created == errSecSuccess, let fixture else { throw ScriptCredentialError.unavailable(created) }
        defer { _ = SecKeychainDelete(fixture) }
        let store = ScriptKeychainStore(keychain: fixture, service: "local.jingdu.test.policy.fake-only")
        try store.save("FAKE-KEY-ONLY", account: "fixture")
        try verify(store.contains(account: "fixture"), "Owned fixture is present")
        try verify(try store.load(account: "fixture") == "FAKE-KEY-ONLY", "Owned fixture can be read with interaction disabled")
        try store.save("FAKE-REPLACEMENT", account: "fixture")
        try verify(try store.load(account: "fixture") == "FAKE-REPLACEMENT", "Owned fixture updates without UI")
        try verify(!store.contains(account: "absent-fixture"), "Missing fixture account is distinct from denied access")
        let lock = SecKeychainLock(fixture)
        guard lock == errSecSuccess else { throw ScriptCredentialError.unavailable(lock) }
        do {
            _ = try store.load(account: "fixture")
            throw ProbeFailure(description: "A locked fixture unexpectedly returned its key")
        } catch let error as ScriptCredentialError {
            print("Locked fake-keychain read returned: \(error)")
            guard error == .authorizationRequired else { throw error }
            assertions += 1
        }
        try verify(store.contains(account: "fixture"), "Locked fake keychain does not make the saved key appear missing")
        do {
            try store.save("FAKE-DENIED-REPLACEMENT", account: "fixture")
            throw ProbeFailure(description: "A locked fixture unexpectedly accepted a replacement")
        } catch let error as ScriptCredentialError {
            guard error == .authorizationRequired else { throw error }
            assertions += 1
        }
        let unlocked = password.withUnsafeBytes { SecKeychainUnlock(fixture, UInt32($0.count), $0.baseAddress, true) }
        guard unlocked == errSecSuccess else { throw ScriptCredentialError.unavailable(unlocked) }
        try verify(try store.load(account: "fixture") == "FAKE-REPLACEMENT", "Denied replacement preserves the previous fake key")
        var current: DarwinBoolean = true
        try verify(SecKeychainGetUserInteractionAllowed(&current) == errSecSuccess && !current.boolValue,
              "Every probe operation preserved the no-interaction guard")
    }
    struct ProbeFailure: Error, CustomStringConvertible { let description: String }
}
