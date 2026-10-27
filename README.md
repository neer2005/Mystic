# Mystic

A native Mac game-streaming client for Moonlight-compatible hosts (Sunshine, Apollo,
Vibepollo, Rubylight), written in Swift and Metal for macOS 27 on Apple silicon.

Mystic is a macOS front end for the [Nightjar](https://github.com/RamazanKara/nightjar)
streaming engine. It exists because the Mac has no client that treats the platform
seriously: everything on macOS today is a Qt or Java port that inherits the lowest
common denominator of its other platforms.

**Status: pre-alpha.** Nothing streams yet. The protocol core and its tests are the
first pieces; see `docs/ROADMAP.md`.

## Targets

- **macOS 27** (Golden Gate) on **Apple silicon only**. Not a compatibility matrix —
  macOS 27 dropped Intel, so there is nothing else to support.
- Xcode 27 / Swift 6.4 for the app. The protocol core additionally builds on Linux
  with Swift 6.2, so protocol work does not require a Mac.

## Architecture in one paragraph

Nightjar's streaming engine is ~105k lines of Rust, and it already exposes a C ABI
through its `ffi` crate. Mystic links that engine as an `xcframework` and owns
everything the Mac can do better: a SwiftUI front end, VideoToolbox decoding,
a Metal implementation of the PyroWave wavelet decoder, presentation and frame
pacing, GameController input, and AVAudioEngine audio. The engine handles protocol,
pairing, control, RTP reordering, FEC and depacketization; Mystic handles everything
that touches the GPU or the user.

## Layout

```
Sources/MysticCore/      platform-neutral Swift: SDP parsing, latency accounting
Tests/MysticCoreTests/   runs on Linux and macOS
```

The app target and the Metal/VideoToolbox modules are added once the Xcode project
exists; they cannot build on Linux and are deliberately kept out of the core package.

## Building

Protocol core (any platform):

```sh
swift test
```

macOS app: see `docs/ARCHITECTURE.md`. The app requires Xcode 27 and the Nightjar
engine built for macOS arm64.

## Licence

GPL-3.0. Mystic derives from Nightjar (GPL-3.0) and, through it, from the Moonlight
project. The PyroWave codec itself is MIT (Hans-Kristian Arntzen) and is ported to
Metal under those terms.
