# Generate keys on your device

Implemented in this PR. The change is independent of ProxyJump.

## Use

1. Open **Keys → + → Generate Key**.
2. Enter an optional name, select Ed25519 or RSA, and tap **Create**.
   For RSA, enter the size in bits (default 3072, range 2048–32768, multiples of 128).
   Custom sizes including 8192 and larger are accepted.
3. Copy or share the public key from the details screen.
4. Add the public key to the server's `~/.ssh/authorized_keys`.
5. Select the key in a saved host's **Private Keys** section.

Tap an existing key to view its public key and SHA256 fingerprint. This also
works for supported imported keys. Deleting a key shows the affected saved hosts
and removes their references after confirmation. It does not change servers.

## Storage and format

The app generates Ed25519 and RSA keys through Swift Crypto. It stores
private material in Keychain with `AfterFirstUnlockThisDeviceOnly` protection.
Private keys do not sync through iCloud or restore from backups. Keep another way
to access your servers if you lose this device.

Ed25519 uses unencrypted OpenSSH format. RSA uses unencrypted PKCS#1 PEM.
RSA imports also accept PKCS#8 PEM and OpenSSH format.
Keychain protects the stored secret. The app uses a software key. Generation requires no network access or external process.

The app derives the public key from the stored private key. Copy and Share contain
only the OpenSSH public line. Public-key comments use a single line with control
characters removed. Metadata contains the key ID, name, and type, never its secret.
A failed Keychain write leaves no metadata entry and permits retry.

A shared worker runs one generation at a time off the UI thread.
Canceled queued requests exit before native generation starts. Cancel dismisses the sheet and discards the
result. Native RSA generation already in progress can finish in the background.
RSA authentication uses RSA-SHA2-512 by default. The SSH engine also supports
RSA-SHA2-256. The app retries SHA256 if the server rejects SHA512.
Legacy SHA1 signatures remain disabled.

Other generated algorithms, private-key
export, agent forwarding, and automatic public-key installation remain outside
its scope. Existing imported key types remain supported.

## Validation

Generate the Xcode project with `xcodegen generate` before testing.

- `gtermTests` covers generation, parser compatibility, distinct identities,
  comment handling, storage failure and retry, and local SSH authentication.
- `gtermKeyTests` adds macOS interoperability checks with `ssh-keygen -y` across
  padding boundaries, plus an 8320-bit RSA key and conversion to OpenSSH format. These tests create and delete disposable keys.
- `KeyGenerationValidation` runs app-hosted Keychain attribute checks and UI
  checks for creation, duplicate taps, public-key display, persistence, deletion,
  and custom 8192-bit RSA generation with invalid-size rejection.

Example: `xcodebuild -project gterm.xcodeproj -scheme gtermKeyTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`.

The serializer accepts a Crypto-generated key instead of raw key bytes. Invalid
raw serializer input is outside its interface. Public-key derivation
still rejects malformed stored private material.

## RSA dependencies

The SSH engine fork adds RSA-SHA2 authentication and host-key support. A separate
Swift Crypto fork raises the RSA size limit to 32768 bits. It keeps the original
8192-bit assembly cutoff and uses the existing portable arithmetic for larger
operands. The app validates the size before generation and verifies the returned
size, since the provider otherwise rounds down to multiples of 128.

Both forks are pinned to reviewed commits in `project.yml`. Updates require
repeating RSA generation, signing, parser, and OpenSSH checks. Larger keys cost
more CPU time and memory. Cancel discards the result but cannot interrupt native
work already running.
