import Foundation
import Security
import Darwin

// Compile only; signing and running require a separately approved fixed identity.
// xcrun swiftc -swift-version 5 -O -parse-as-library Tests/FixedIdentityKeychainProbe.swift -framework Security -o /tmp/jingdu-fixed-probe-original
// xcrun swiftc -swift-version 5 -O -DUPDATED_SIGNATURE -parse-as-library Tests/FixedIdentityKeychainProbe.swift -framework Security -o /tmp/jingdu-fixed-probe-updated
// Sign both with the same explicit certificate + designated requirement. Then:
// original create /tmp/jingdu-fixed-id-test-<unique-suffix>
// updated read /tmp/jingdu-fixed-id-test-<unique-suffix>
// updated cleanup /tmp/jingdu-fixed-id-test-<unique-suffix>
// Use an empty directory, or let create make it. All successful modes print PASS.
// No login/default keychain, user search list, trust setting, network or UI is used.
@main struct FixedIdentityKeychainProbe {
    private static let manager = FileManager.default
    private static let directoryPrefix = "jingdu-fixed-id-test-"
    private static let markerName = "owned-probe.json"
    private static let keychainName = "fake-only.keychain-db"
    private static let fakePassword = "JINGDU-TEST-ONLY-KEYCHAIN-PASSWORD-v1"
    private static let fakeData = Data("JINGDU-TEST-ONLY-FAKE-API-KEY-v1".utf8)
    private static let fakeService = "local.jingdu.test.fixed-identity.fake-only"
    private static let fakeAccount = "fixture-account-not-a-user"
    #if UPDATED_SIGNATURE
    private static let buildVariant = "updated-build"
    #else
    private static let buildVariant = "original-build"
    #endif

    private struct Marker: Codable, Equatable {
        let format: String
        let directory: String
        let keychain: String
        let fixture: String
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == errSecSuccess else {
            throw Failure(description: "\(operation) failed (OSStatus \(status))")
        }
    }

    static func main() {
        do {
            try require(CommandLine.arguments.count == 3, "Expected create/read/cleanup and an owned temporary directory")
            let mode = CommandLine.arguments[1]
            try require(["create", "read", "cleanup"].contains(mode), "Unknown mode")
            let directory = try safeDirectory(CommandLine.arguments[2], creating: mode == "create")
            // This legacy-Keychain process-wide setting also forbids the classic
            // password/ACL dialogs; no LocalAuthentication fallback is allowed.
            try check(SecKeychainSetUserInteractionAllowed(false), "Disable interaction")
            switch mode {
            case "create": try create(in: directory)
            case "read": try read(in: directory)
            case "cleanup": try cleanup(in: directory)
            default: throw Failure(description: "Unknown mode")
            }
            print("PASS")
        } catch {
            // This compile-time label also guarantees the two builds contain
            // different code/data while their credential fixture stays equal.
            let message = "FAIL (\(buildVariant)): \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func safeDirectory(_ argument: String, creating: Bool) throws -> URL {
        let requested = URL(fileURLWithPath: argument).standardizedFileURL
        let temporaryParent = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        let name = requested.lastPathComponent
        try require(name.hasPrefix(directoryPrefix) && name.count > directoryPrefix.count,
                    "Temporary directory must use the fixture prefix")
        try require(name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" },
                    "Invalid temporary directory name")
        try require(requested.deletingLastPathComponent().resolvingSymlinksInPath().path == temporaryParent.path,
                    "Fixture directory must be directly inside /tmp")
        let directory = temporaryParent.appendingPathComponent(name, isDirectory: true)
        if creating && !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        }
        try validateOwned(directory, type: .typeDirectory, permissions: 0o700)
        return directory
    }

    private static func validateOwned(_ url: URL, type: FileAttributeType, permissions: Int) throws {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        try require(attributes[.type] as? FileAttributeType == type, "Fixture path has the wrong file type or is a symlink")
        try require((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), "Fixture path is not owned by this user")
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == permissions, "Fixture permissions do not match")
    }

    private static func marker(in directory: URL) -> Marker {
        Marker(format: "jingdu-owned-fake-keychain-probe-v1", directory: directory.path,
               keychain: keychainName, fixture: "FAKE-DATA-ONLY")
    }
    private static func validateMarker(in directory: URL) throws {
        let url = directory.appendingPathComponent(markerName)
        try validateOwned(url, type: .typeRegular, permissions: 0o600)
        let saved = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: url))
        try require(saved == marker(in: directory), "Ownership marker does not match this fixture directory")
    }
    private static func keychainURL(in directory: URL) -> URL { directory.appendingPathComponent(keychainName) }
    private static func unlock(_ keychain: SecKeychain) throws {
        let password = Data(fakePassword.utf8)
        let status = password.withUnsafeBytes {
            SecKeychainUnlock(keychain, UInt32($0.count), $0.baseAddress, true)
        }
        try check(status, "Unlock fake fixture")
    }
    private static func open(in directory: URL) throws -> SecKeychain {
        try validateMarker(in: directory)
        let url = keychainURL(in: directory)
        try validateOwned(url, type: .typeRegular, permissions: 0o600)
        var reference: SecKeychain?
        try check(SecKeychainOpen(url.path, &reference), "Open fake fixture")
        guard let reference else { throw Failure(description: "Missing explicit fixture keychain") }
        return reference
    }
    private static var itemAttributes: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: fakeService,
         kSecAttrAccount as String: fakeAccount]
    }

    private static func create(in directory: URL) throws {
        try require(try manager.contentsOfDirectory(atPath: directory.path).isEmpty,
                    "Create requires an empty fixture directory")
        let markerURL = directory.appendingPathComponent(markerName)
        try JSONEncoder().encode(marker(in: directory)).write(to: markerURL, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        try validateMarker(in: directory)
        let url = keychainURL(in: directory)
        var reference: SecKeychain?
        let password = Data(fakePassword.utf8)
        let status = password.withUnsafeBytes {
            SecKeychainCreate(url.path, UInt32($0.count), $0.baseAddress, false, nil, &reference)
        }
        try check(status, "Create fake fixture")
        guard let reference else { throw Failure(description: "Missing created fixture keychain") }
        defer { _ = SecKeychainLock(reference) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try validateOwned(url, type: .typeRegular, permissions: 0o600)
        var attributes = itemAttributes
        attributes[kSecUseKeychain as String] = reference
        attributes[kSecValueData as String] = fakeData
        // Omit kSecAttrAccess: retain the normal creator-only ACL. Never grant
        // access to all applications or add the second build to a trusted list.
        try check(SecItemAdd(attributes as CFDictionary, nil), "Add fake fixture item")
    }

    private static func read(in directory: URL) throws {
        let reference = try open(in: directory)
        defer { _ = SecKeychainLock(reference) }
        try unlock(reference)
        var query = itemAttributes
        query[kSecMatchSearchList as String] = [reference]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result), "Read fake fixture item without UI")
        try require(result as? Data == fakeData, "Fake fixture contents did not match")
    }

    private static func cleanup(in directory: URL) throws {
        try validateMarker(in: directory)
        let url = keychainURL(in: directory)
        if manager.fileExists(atPath: url.path) {
            let reference = try open(in: directory)
            try check(SecKeychainDelete(reference), "Delete owned fake fixture keychain")
        }
        let remaining = try manager.contentsOfDirectory(atPath: directory.path)
        try require(remaining == [markerName], "Unknown files remain; cleanup refuses to remove them")
        try manager.removeItem(at: directory.appendingPathComponent(markerName))
        // rmdir is intentionally nonrecursive and fails if another file appears.
        try require(rmdir(directory.path) == 0, "Could not remove empty fixture directory")
    }
}
