import Foundation
import Crypto
import NIOSSH

struct SSHPublicKey {
    let line: String
    var fingerprint: String { SSHFingerprint.sha256(ofOpenSSH: line) }
}

struct GeneratedSSHKey {
    let privateKey: String
    let publicKey: SSHPublicKey
}

enum SSHKeyGenerator {
    static func generate(name: String) throws -> GeneratedSSHKey {
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
