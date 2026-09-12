# gterm

An iOS terminal app that renders with [ghostty](../ghostty)'s `libghostty`
engine (GPU/Metal, full xterm/VT emulation) and connects over **SSH**.

> 📲 **Get the app:** [Download on the App Store](https://apps.apple.com/us/app/gterm-ghostty-ssh/id6774837597) (iOS 17+).
> Or sideload with [**AltStore** or **SideStore**](https://madeye.github.io/gterm/altstore/) — both read the same source URL `https://madeye.github.io/gterm/altstore.json`.

iOS can't `fork`/`exec` a local shell, so gterm drives the terminal from an SSH
connection via a custom **passthru IO backend** added to libghostty. See
[PLAN.md](PLAN.md) for the full architecture.

## Status

- ✅ libghostty `passthru` IO backend ([madeye/ghostty](https://github.com/madeye/ghostty))
- ✅ iOS app; ghostty terminal surface renders on device/simulator
- ✅ Lean Swift layer over libghostty (app, surface view, input)
- ✅ SSH transport (swift-nio-ssh): password auth, PTY shell, window-change
- ✅ Custom on-screen keyboard (esc/ctrl/alt/tab/arrows/symbols, sticky mods)
- ✅ Saved connections (Keychain passwords) + trust-on-first-use host keys
- ✅ ProxyJump-style routing through saved jump hosts, including chained jumps
- ✅ Public-key auth: generate Ed25519/RSA keys and import Ed25519/ECDSA/RSA
  keys in the Keys tab. Keys stay in device-only Keychain storage. Each host can
  select one or more keys to try.
- ⏳ Encrypted (passphrase) keys, richer settings (font/theme)

## Generate an SSH key

Open **Keys → + → Generate Key** to create an Ed25519 or RSA key on your device.
For RSA, enter 2048–32768 bits in multiples of 128. The default is
3072. Custom sizes including 8192 and larger are accepted. Larger keys take
longer to generate. The screen stays responsive while generation runs.
Copy or share its public key, add it to your server's `authorized_keys`, then
select the key on a saved host. The private key stays in device-only Keychain
storage. Keep another way to access your servers if the device is lost.

If a connection needs credentials, tap **Select SSH Key** in its prompt to
choose a saved key. Tapping **Connect** remembers that choice for the host.

See [on-device key generation](docs/on-device-key-generation-plan.md) for storage
and test details.

## Connecting through a jump host

1. Save a connection for your reachable jump server (for example, `bastion.example.com`
   on port `2222`), including its username and selected key or password.
2. Save the destination using its hostname as seen from the jump server (for
   example, `private.internal`), its SSH port, and its own username/credentials.
3. In the destination's **ProxyJump → Jump Host** setting, select the saved jump
   server. Connect to the destination from Hosts.

Each hop authenticates separately and asks you to verify its host key. Missing
passwords are requested together before connecting. A jump host can itself use
another saved jump host; loops and deleted jump-host references are rejected.
The jump server must permit SSH TCP forwarding to the next host. Destination
port forwards operate through the final SSH connection.

This provides ProxyJump-style transport. It does not import OpenSSH config files,
execute `ProxyCommand`, or forward an SSH agent. Import the keys needed for each
host into the app's Keys tab, or use passwords; private keys stay on the phone.

## Building

Requirements: macOS, Xcode 26+, and the patched Homebrew zig:

```sh
brew install zig@0.15        # keg-only; the build script uses it by full path
brew install xcodegen
```

0. Get the terminal engine. gterm uses a fork of ghostty that adds a
   `passthru` IO backend (so the terminal can be driven by SSH instead of a
   local shell). It's bundled as a git submodule — check it out with:

   ```sh
   git submodule update --init ghostty
   ```

   (If you cloned without `--recurse-submodules`, the command above fetches it.
   To use a separate checkout instead, pass `GHOSTTY_DIR=/path/to/ghostty` to
   the build script below.)

1. Build the terminal engine (cross-compiles `GhosttyKit.xcframework` with
   macOS + iOS + iOS-simulator slices, and applies the required iOS patch to
   libghostty's event loop):

   ```sh
   ./scripts/build-ghostty-xcframework.sh
   ```

2. Generate the Xcode project and build:

   ```sh
   xcodegen generate
   xcodebuild -project gterm.xcodeproj -scheme gterm \
     -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
     CODE_SIGNING_ALLOWED=NO build
   ```

   Or open `gterm.xcodeproj` in Xcode and run.

`gterm.xcodeproj`, `Info.plist`, and `GhosttyKit.xcframework` are generated and
git-ignored.

## Testing SSH startup

Run the Herdr auto-attach regressions on macOS (no SSH credentials or running
Herdr server required):

```sh
xcodegen generate
xcodebuild -project gterm.xcodeproj -scheme gtermSSHTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

These tests exercise the PTY handler's request/reply flow and execute its
startup command with isolated shell profiles and a fixture `herdr` executable.
They cover PATH initialization, request failures, nonzero exit status, clean
detach, and terminal input/output. Channel tests also run in the iOS
`gtermTests` scheme; testing attachment to a real remote Herdr session still
requires a simulator or device smoke test.

## Releasing for AltStore

`scripts/build-altstore-ipa.sh` produces an **unsigned** `.ipa` suitable for
sideloading via AltStore / SideStore (which sign with the user's own Apple ID
at install time):

```sh
./scripts/build-altstore-ipa.sh
# -> build/altstore/gterm-<version>-<build>.ipa  (+ .size, .sha256)
```

Then:

1. Create a GitHub Release tagged `v<version>-<build>` and attach the `.ipa`.
2. Update `docs/altstore.json` — paste the new `version`, `buildVersion`,
   `downloadURL`, `size`, and `sha256` into the leading `versions` entry
   (or prepend a new one to keep history).
3. Commit & push so GitHub Pages serves the refreshed manifest at
   `https://madeye.github.io/gterm/altstore.json`.

The AltStore landing page lives at `docs/altstore/index.html`.

## License

gterm is released under the [MIT License](LICENSE) © 2026 Max Lv.

Bundled / dependency components keep their own licenses: the
[ghostty](https://github.com/madeye/ghostty) engine is MIT; swift-nio-ssh,
swift-crypto, and swift-nio are Apache-2.0; the OpenAI and SwiftAnthropic SDKs
are MIT.

## Post-quantum key exchange

SSH connections prefer `mlkem768x25519-sha256` when the server supports it.
Servers without that algorithm use the existing classical exchanges. This hybrid
exchange combines ML-KEM-768 with X25519, as defined in
[RFC 10042](https://www.rfc-editor.org/rfc/rfc10042.html). It protects session key
establishment. Host and user authentication keep their existing key types.

The pinned [SSH engine fork](https://github.com/rcarback/swift-nio-ssh/tree/gterm/dev)
uses Swift Crypto's portable ML-KEM code so the app keeps its iOS 17 minimum.
Swift Crypto is pinned to a revision of the 4.5.2-based RSA fork because the
adapter uses an internal C API.
Dependency updates require adapter review and repeat interoperability testing.

The engine tests cover malformed inputs, hybrid-secret encoding, rekeying,
classical fallback, and OpenSSH interoperability. The app's
`PostQuantumKeyExchangeTests` verifies hybrid negotiation and authentication
through the resolved dependency.
