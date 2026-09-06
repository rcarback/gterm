import XCTest
import Crypto
import NIOSSH
#if SWIFT_PACKAGE
@testable import KeyHarness
#endif

final class SSHKeyGeneratorTests: XCTestCase {
    func testGeneratedKeyRoundTripsAndPublicLineMatches() throws {
        let generated = try SSHKeyGenerator.generate(name: "phone")
        let parsed = try SSHKeyParser.parse(generated.privateKey)
        XCTAssertEqual(parsed.type, "Ed25519")
        XCTAssertEqual(generated.publicKey.line, String(openSSHPublicKey: parsed.key.publicKey) + " phone")
        XCTAssertEqual(generated.publicKey.fingerprint, SSHFingerprint.sha256(ofOpenSSH: generated.publicKey.line))
        XCTAssertEqual(try SSHKeyGenerator.publicKey(privateKey: generated.privateKey, comment: "phone").line, generated.publicKey.line)
    }

    func testGenerationsAreDistinctAndCommentsAreOneLine() throws {
        let first = try SSHKeyGenerator.generate(name: "  téléphone\n\twork\u{0}\u{7} key  ")
        let second = try SSHKeyGenerator.generate(name: "")
        XCTAssertNotEqual(first.privateKey, second.privateKey)
        XCTAssertNotEqual(first.publicKey.fingerprint, second.publicKey.fingerprint)
        XCTAssertTrue(first.publicKey.line.hasSuffix(" téléphone work key"))
        XCTAssertFalse(first.publicKey.line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertEqual(second.publicKey.line.split(separator: " ").count, 2)
    }

    func testPublicDerivationRejectsMalformedPrivateMaterial() {
        XCTAssertThrowsError(try SSHKeyGenerator.publicKey(privateKey: "garbage", comment: "phone"))
    }

    #if os(macOS)
    func testOpenSSHReadsGeneratedKeysAcrossPaddingBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for length in 0...16 {
            let generated = try SSHKeyGenerator.generate(name: String(repeating: "x", count: length))
            let file = directory.appendingPathComponent("disposable")
            try generated.privateKey.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-y", "-f", file.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let line = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertEqual(Array(line.split(whereSeparator: \.isWhitespace).prefix(2)),
                           Array(generated.publicKey.line.split(separator: " ").prefix(2)))
        }
    }
    #endif
}

final class GeneratedKeyStoreTests: XCTestCase {
    func testFailedWriteLeavesNoMetadataAndRetryPersistsKey() throws {
        let suite = "key-generation-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var secrets: [String: String] = [:]
        var allowWrites = false
        let store = KeyStore(defaults: defaults, saveSecret: { text, account in
            guard allowWrites else { return false }
            secrets[account] = text
            return true
        }, readSecret: { secrets[$0] }, deleteSecret: { secrets.removeValue(forKey: $0) })
        XCTAssertThrowsError(try store.generateKey(name: "phone"))
        XCTAssertTrue(store.keys.isEmpty)
        XCTAssertNil(defaults.data(forKey: "sshKeys"))
        allowWrites = true
        let key = try store.generateKey(name: "  ")
        XCTAssertEqual(key.name, "Key 1")
        XCTAssertEqual(store.keys.count, 1)
        XCTAssertEqual(try store.publicKey(for: key).line.split(separator: " ").prefix(1), ["ssh-ed25519"])
        let persisted = try XCTUnwrap(defaults.data(forKey: "sshKeys"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("PRIVATE KEY"))
        let reloaded = KeyStore(defaults: defaults, saveSecret: { _, _ in false },
                                readSecret: { secrets[$0] }, deleteSecret: { secrets.removeValue(forKey: $0) })
        XCTAssertEqual(reloaded.keys, [key])
        XCTAssertEqual(try reloaded.publicKey(for: key).line, try store.publicKey(for: key).line)
        reloaded.delete(key)
        XCTAssertTrue(reloaded.keys.isEmpty)
        XCTAssertTrue(secrets.isEmpty)
        XCTAssertThrowsError(try reloaded.publicKey(for: key))
    }
}
