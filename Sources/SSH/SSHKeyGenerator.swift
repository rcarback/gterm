import Foundation
import Crypto
import _CryptoExtras
import NIOSSH

struct SSHPublicKey: Sendable {
    let line: String
    var fingerprint: String { SSHFingerprint.sha256(ofOpenSSH: line) }
}

struct GeneratedSSHKey: Sendable {
    let privateKey: String
    let publicKey: SSHPublicKey
}

enum SSHKeyAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case ed25519 = "Ed25519"
    case rsa = "RSA"
    var id: String { rawValue }
}

/// Serializes native generation across sheet lifetimes. The synchronous actor
/// method never suspends while Crypto is running, so only one request runs at a time.
actor SSHKeyGenerationWorker {
    static let shared = SSHKeyGenerationWorker()

    private init() {}

    func generate(name: String, algorithm: SSHKeyAlgorithm = .ed25519, rsaBits: Int = 3072) throws -> GeneratedSSHKey {
        // A canceled request may have waited behind native work that cannot stop.
        try Task.checkCancellation()
        let key = try SSHKeyGenerator.generate(name: name, algorithm: algorithm, rsaBits: rsaBits)
        try Task.checkCancellation()
        return key
    }
}

enum SSHKeyGenerator {
    static func generate(name: String, algorithm: SSHKeyAlgorithm = .ed25519, rsaBits: Int = 3072) throws -> GeneratedSSHKey {
        if algorithm != .ed25519 {
            guard isValidRSASize(rsaBits) else {
                throw SSHKeyError.malformed("RSA size must be 2048–32768 bits and a multiple of 128")
            }
            let key = try _RSA.Signing.PrivateKey(keySize: .init(bitCount: rsaBits))
            guard key.keySizeInBits == rsaBits else {
                throw SSHKeyError.malformed("the crypto provider could not generate the requested RSA size")
            }
            let text = key.pemRepresentation
            return GeneratedSSHKey(privateKey: text, publicKey: try publicKey(privateKey: text, comment: name))
        }
        let key = Curve25519.Signing.PrivateKey()
        let comment = normalizedComment(name)
        var publicBlob = Data()
        appendString(Data("ssh-ed25519".utf8), to: &publicBlob)
        appendString(key.publicKey.rawRepresentation, to: &publicBlob)

        var secret = Data()
        let check = UInt32.random(in: .min ... .max)
        appendInteger(check, to: &secret)
        appendInteger(check, to: &secret)
        appendString(Data("ssh-ed25519".utf8), to: &secret)
        appendString(key.publicKey.rawRepresentation, to: &secret)
        appendString(key.rawRepresentation + key.publicKey.rawRepresentation, to: &secret)
        appendString(Data(comment.utf8), to: &secret)
        var padding: UInt8 = 1
        while secret.count % 8 != 0 {
            secret.append(padding)
            padding += 1
        }

        var envelope = Data("openssh-key-v1\0".utf8)
        appendString(Data("none".utf8), to: &envelope) // cipher
        appendString(Data("none".utf8), to: &envelope) // KDF
        appendString(Data(), to: &envelope)
        appendInteger(1, to: &envelope)
        appendString(publicBlob, to: &envelope)
        appendString(secret, to: &envelope)
        let base64 = Array(envelope.base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: 70).map {
            String(base64[$0..<min($0 + 70, base64.count)])
        }
        let text = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n")
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
        return GeneratedSSHKey(privateKey: text, publicKey: try publicKey(privateKey: text, comment: comment))
    }
    static func isValidRSASize(_ bits: Int) -> Bool {
        bits >= 2048 && bits % 128 == 0 && bits <= 32768
    }

    static func publicKey(privateKey: String, comment: String) throws -> SSHPublicKey {
        let parsed = try SSHKeyParser.parse(privateKey)
        let normalized = normalizedComment(comment)
        let line = String(openSSHPublicKey: parsed.key.publicKey)
        return SSHPublicKey(line: line + (normalized.isEmpty ? "" : " " + normalized))
    }

    private static func normalizedComment(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func appendInteger(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ value: Data, to data: inout Data) {
        appendInteger(UInt32(value.count), to: &data)
        data.append(value)
    }

}
