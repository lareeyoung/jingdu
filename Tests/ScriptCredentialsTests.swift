import Foundation

// swiftc -swift-version 5 Sources/ScriptCredentials.swift Tests/ScriptCredentialsTests.swift -o /tmp/jingdu-credentials-tests
@main @MainActor struct ScriptCredentialsTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(value(), message)
    }
    enum Failure: Error { case denied, writeFailed }
    static func main() throws {
        var reads = 0, writes = 0, existenceChecks = 0
        var values = ["service-a|account": "fixture-a", "service-b|account": "fixture-b"]
        var denyRead = false, denyWrite = false
        let session = ScriptCredentialSession(read: { account in
            reads += 1
            if denyRead { throw Failure.denied }
            return values[account]
        }, write: { key, account in
            writes += 1
            if denyWrite { throw Failure.writeFailed }
            values[account] = key
        }, exists: { account in existenceChecks += 1; return values[account] != nil })
        expect(session.contains(account: "service-a|account"), "A presence check can find an existing item")
        expect(reads == 0, "Presence checking never asks to read the secret")
        let a = try session.key(for: "service-a|account")
        expect(a == "fixture-a", "The first explicit use reads the authorized key")
        let again = try session.key(for: "service-a|account")
        expect(again == a && reads == 1, "Repeated operations reuse one authorization in this session")
        let checksBefore = existenceChecks
        expect(session.contains(account: "service-a|account"), "A cached authorization counts as available")
        expect(existenceChecks == checksBefore, "Refreshing UI does not query the keychain again after authorization")
        let b = try session.key(for: "service-b|account")
        expect(b == "fixture-b" && reads == 2, "A different service resolves its own key")
        let returned = try session.key(for: "service-a|account")
        expect(returned == a && reads == 2, "Returning to the original account reuses only its own key")
        try session.save("replacement-a", account: "service-a|account")
        let replaced = try session.key(for: "service-a|account")
        expect(replaced == "replacement-a" && writes == 1 && reads == 2, "A successful save is immediately reusable without a keychain read")
        denyWrite = true
        do { try session.save("failed-replacement", account: "service-a|account"); preconditionFailure("Expected write failure") }
        catch Failure.writeFailed {}
        let afterFailure = try session.key(for: "service-a|account")
        expect(afterFailure == "replacement-a" && values["service-a|account"] == "replacement-a", "Failed saving does not replace the previous credential")
        denyRead = true
        do { _ = try session.key(for: "new-service|account"); preconditionFailure("Expected denied read") }
        catch Failure.denied {}
        denyRead = false; values["new-service|account"] = "later-authorized"
        let allowedLater = try session.key(for: "new-service|account")
        expect(allowedLater == "later-authorized", "A denied read never caches a failure or another account's key")
        let missing = try session.key(for: "missing")
        expect(missing == nil, "Missing credentials stay missing")
        values["missing"] = "created-later"
        let created = try session.key(for: "missing")
        expect(created == "created-later", "Absence is not cached across a subsequent save elsewhere")
        session.forget(account: "service-a|account")
        values["service-a|account"] = "external-change"
        let refreshed = try session.key(for: "service-a|account")
        expect(refreshed == "external-change", "An explicit reset reloads that account only")
        let bAfterReset = try session.key(for: "service-b|account")
        expect(bAfterReset == b, "Resetting one account leaves another authorized account intact")
        let ephemeral = ScriptCredentialSession.memoryOnly()
        try ephemeral.save("memory-a", account: "a")
        expect(ephemeral.contains(account: "a") && !ephemeral.contains(account: "b"), "Offline storage is scoped by account")
        let noLeak = try ephemeral.key(for: "b")
        expect(noLeak == nil, "Offline credentials cannot leak to a different account")
        let freshSession = ScriptCredentialSession.memoryOnly()
        expect(!freshSession.contains(account: "a"), "A new process/session has no persisted key cache")
        print("Script credential session passed (\(checks) assertions; fake keys, no keychain access).")
    }
}
