# On-device SSH key generation

Status: implementation plan. This PR does not change app behavior and is independent of ProxyJump.

## Outcome

A user can create an SSH identity in the Keys tab without copying a private key
from another computer. The generated key is available to existing saved hosts
(and, when available, jump hosts). The user can copy or share its OpenSSH public
key for installation in a server's `authorized_keys`.

## Scope

Ship Ed25519 generation first, using `Curve25519.Signing.PrivateKey()` from the
existing Crypto dependency. Keep RSA, ECDSA generation, Secure Enclave identities,
SSH certificates, private-key export, and automatic installation on remote
servers out of this change. Existing imported key types remain usable.

The initial design stores an exportable software key in Keychain; it must not be
described as Secure Enclave backed. Private-key material is never placed on the
clipboard, shared, logged, or persisted in UserDefaults.

## Current code and planned changes

- `Sources/UI/KeyListView.swift`: offer Generate Key alongside Import Key. Ask for
  a name, show Ed25519 as the algorithm, and generate only after the user taps
  Create. Disable duplicate submissions while saving. After success, show a
  public-key detail view with Copy and Share actions.
- New `Sources/SSH/SSHKeyGenerator.swift`: generate Ed25519 material with Crypto;
  produce a private-key representation accepted by `SSHKeyParser` and an OpenSSH
  public line (`ssh-ed25519 <base64> <comment>`). Use SSH length-prefixed binary
  encoding rather than treating raw public-key bytes as a complete SSH blob.
  Normalize the comment to one line and exclude control characters.
- Keep the existing text-based private-key storage and authentication path. Add
  a small, tested OpenSSH Ed25519 private-key writer compatible with the existing
  parser (unsealed `openssh-key-v1`, check integers, public/private records, and
  required padding). This unencrypted representation is protected at rest by
  Keychain, not by a separate SSH-key passphrase. Do not introduce a shell tool
  or write a temporary private-key file on the device.
- `Sources/Model/KeyStore.swift`: add `generateKey(name:)`, reusing validation and
  storage through `importKey`. Publish metadata only after Keychain succeeds.
  Provide public-key derivation from the stored key for the detail view; avoid
  an independently persisted public-key copy that can become inconsistent.
- `Sources/Model/Keychain.swift`: retain the current
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` protection and access group.
  Check all writes and display recoverable failures. Do not add biometric gates
  in this change, because unattended connection and reconnect behavior needs a
  separate design for those gates.
- `project.yml`: include Foundation-safe generator code in the test target.

## User flow

1. Open Keys, choose Generate Key, enter a name, and tap Create.
2. Store the private key in Keychain and show its public-key line and SHA256
   fingerprint. Use the existing fingerprint helper for consistency.
3. Copy or share the public key. Explain that only this public key belongs in
   the server's `~/.ssh/authorized_keys`. Remote installation is performed by the
   user; this feature must not contact or modify servers by itself.
4. Select the generated key on a saved host and connect using the existing
   public-key authentication path.

The key remains on this device and is not restored from backups. The detail view
should explain that users need another way into their servers if the device is
lost. Deletion should identify affected saved hosts and use existing reference
cleanup; deleting a local key does not remove its public key from servers.

## Validation and acceptance criteria

- Generated private keys round-trip through `SSHKeyParser`; the parsed public
  key matches the generated public line and fingerprint.
- Two generations yield different identities; a signature verifies with the
  matching public key and fails with an unrelated key.
- Validate OpenSSH interoperability using disposable test keys and `ssh-keygen
  -y`, comparing public algorithm/blob fields. Fixture private material is never
  a real user identity.
- Exercise real public-key SSH authentication with a locally controlled test
  server; generation must work without network access.
- Cover blank names, Unicode names, newline/control-character sanitization,
  malformed serializer input, and exact binary padding/length boundaries.
- Inject storage failure: no phantom metadata entry or success UI appears and
  retry remains possible. Test duplicate-tap handling and deletion/reference
  cleanup.
- On a signed iPhone build, verify persistence after relaunch, assignment to a
  host, successful authentication, and that Copy/Share contains only public
  material. Inspect Keychain attributes through an app-level integration test.
- Run the existing suite and iOS device build. Existing imported keys and saved
  connections must continue decoding and authenticating unchanged.

## Delivery

Implement in its own feature PR after review of this plan. No dependency on the
ProxyJump branch is needed: both features reuse `KeyStore` references. A later
combined smoke test can use one generated key on a jump host and a different key
on its destination to verify independent identity selection.
