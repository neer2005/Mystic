# Mystic

A native macOS client for streaming games from your PC, built on the Rust engine of
[Nightjar](https://github.com/RamazanKara/nightjar). It works with Sunshine-compatible hosts and
uses the extras Rubylight hosts offer: live bitrate and size changes, host controls, file transfer,
shared folders and more.

Low latency comes first: a change that adds delay doesn't ship.

## Requirements

- macOS 27 and Xcode 27
- Rust, with CMake for the bundled Opus

## Build and run

```sh
bash scripts/build-macos-app.sh
open .build/Mystic.app
```

The script builds the engine, then the app, and signs it. It uses the Apple Development
certificate in your keychain; with several, pick one with
`git config --local mystic.signingIdentity <SHA-1>`, or set `MYSTIC_SIGNING_IDENTITY=-` for an
ad-hoc build. Pass `release` for an optimised build.

## Test

```sh
bash engine/scripts/test-c-abi.sh   # the engine, and its C interface from C
swift test                          # the app
```

## Layout

| Path | What it is |
| --- | --- |
| `engine/` | `mystic-ffi`: a C interface over Nightjar's engine, pinned in `engine/Cargo.toml` |
| `Sources/MysticKit` | Swift wrappers over that interface |
| `Sources/MysticCore` | Platform-free logic: pacing, settings, input |
| `Sources/MysticStream` | Video decode and presentation, audio, microphone |
| `Sources/MysticDesktop` | The app's windows, settings and state |
| `Sources/MysticAWDLHelper` | The privileged helper that holds AWDL down during Wi-Fi streams |
| `scripts/` | Build, packaging and icon scripts |

## Releasing

Pushing a tag such as `v0.2.0` runs `.github/workflows/release.yml`, which tests, builds, packs
`Mystic-<version>.dmg` with a checksum and publishes a GitHub release. A tag with a suffix, such as
`v0.2.0-beta.1`, is a pre-release, which the in-app update check doesn't offer.

A public release needs these repository secrets; without them the workflow signs ad-hoc and leaves
a draft for testing:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | A Developer ID Application certificate and key exported as `.p12`, base64-encoded |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The export password |
| `NOTARY_APPLE_ID` | The Apple ID that notarizes |
| `NOTARY_APP_PASSWORD` | An app-specific password for it |
| `NOTARY_TEAM_ID` | The Apple Developer team ID |

## License

GPL-3.0; see `LICENSE`. Third-party notices are in `third_party/`.
