# Generate keys on your device

Implemented in this PR. The change is independent of ProxyJump.

## Use

1. Open **Keys → + → Generate Key**.
2. Enter an optional name and tap **Create**.
3. Copy or share the public key from the details screen.
4. Add the public key to the server's `~/.ssh/authorized_keys`.
5. Select the key in a saved host's **Private Keys** section.

Tap an existing key to view its public key and SHA256 fingerprint. This also
works for supported imported keys. Deleting a key shows the affected saved hosts
and removes their references after confirmation. It does not change servers.

## Storage and format

The app generates Ed25519 keys through the existing Crypto dependency. It stores
private material in Keychain with `AfterFirstUnlockThisDeviceOnly` protection.
Private keys do not sync through iCloud or restore from backups. Keep another way
to access your servers if you lose this device.

The private key uses the unencrypted OpenSSH format already accepted by the app.
Keychain protects the stored secret. The app uses a software key. Generation requires no network access or external process.

The app derives the public key from the stored private key. Copy and Share contain
only the OpenSSH public line. Public-key comments use a single line with control
characters removed. Metadata contains the key ID, name, and type, never its secret.
A failed Keychain write leaves no metadata entry and permits retry.

This change adds Ed25519 generation. Other generated algorithms, private-key
export, agent forwarding, and automatic public-key installation remain outside
its scope. Existing imported key types remain supported.

## Validation

Generate the Xcode project with `xcodegen generate` before testing.

- `gtermTests` covers generation, parser compatibility, distinct identities,
  comment handling, storage failure and retry, and local SSH authentication.
- `gtermKeyTests` adds macOS interoperability checks with `ssh-keygen -y` across
  padding boundaries. These tests create and delete disposable keys.
- `KeyGenerationValidation` runs app-hosted Keychain attribute checks and UI
  checks for creation, duplicate taps, public-key display, persistence, and deletion.

Example: `xcodebuild -project gterm.xcodeproj -scheme gtermKeyTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`.

The serializer accepts a Crypto-generated key instead of raw key bytes. Invalid
raw serializer input is outside its interface. Public-key derivation
still rejects malformed stored private material.
