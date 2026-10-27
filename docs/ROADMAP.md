# Roadmap

Estimates assume one developer plus agent assistance, with the Nightjar engine linked
rather than rewritten.

## Phase 0 — foundations (done)

- [x] Swift package with a Linux-testable core (`swift test`, 16 tests)
- [x] `StreamDescription`: SDP/`x-ss-*` capability parsing
- [x] `LatencyStats`/`SessionLatency`: per-stage histograms, nearest-rank percentiles
- [x] Architecture and UI design docs

## Phase 1 — engine linkage (1–2 weeks)

- [ ] Build Nightjar `protocol/` as a static archive for macOS arm64
- [ ] Wrap `ffi` in an `xcframework`; Swift `NightjarEngine` façade over the C ABI
- [ ] Host discovery (mDNS) and pairing against a real host
- [ ] CI: core tests on Linux, engine build on macOS

## Phase 2 — first playable (6–10 weeks)

- [ ] Xcode app target, three-pane SwiftUI shell, Settings scene, menu bar commands
- [ ] RTSP session lifecycle: DESCRIBE → SETUP → ANNOUNCE → PLAY via the engine
- [ ] VideoToolbox decode (H.264, HEVC, AV1) into IOSurface-backed buffers
- [ ] `AVSampleBufferDisplayLayer` presentation in a full-screen space
- [ ] AVAudioEngine audio (Opus via libopus), multichannel downmix
- [ ] GameController input: keyboard, mouse, DualSense/Xbox
- [ ] Latency HUD wired to the engine's timestamps

## Phase 3 — PyroWave and platform polish (2–4 months)

- [ ] Metal compute port of the PyroWave decoder (MSL), 4:4:4 support
- [ ] HDR/EDR output with correct PQ metadata and no double tone-mapping
- [ ] Metal renderer with PTS-driven frame pacing
- [ ] DualSense haptics and adaptive triggers
- [ ] Microphone passthrough (Apollo/Rubylight mono Opus over UDP)
- [ ] Native library browsing against Rubylight's API

## Phase 4 — hardening and release

- [ ] Published latency measurements with method (host timestamp → present, plus
      240 fps camera glass-to-glass)
- [ ] Notarised `.dmg` and a Homebrew cask
- [ ] Crash reporting that does not leak session contents
- [ ] GPL-3.0 source publication per release

## Explicit non-goals

- Intel Macs (macOS 27 dropped them)
- iOS, iPadOS, tvOS, visionOS — one platform, done properly
- Windows or Linux builds
- Reimplementing the Nightjar engine in Swift before the app exists
