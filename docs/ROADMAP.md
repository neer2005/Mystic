# Roadmap

Estimates assume one developer plus agent assistance, with the Nightjar engine linked
rather than rewritten.

## Phase 0 — foundations (done)

- [x] Swift package with a Linux-testable core (platform-neutral parsers and timing tests)
- [x] `StreamDescription`: SDP/`x-ss-*` capability parsing
- [x] `LatencyStats`/`SessionLatency`: per-stage histograms, nearest-rank percentiles
- [x] Architecture and UI design docs

## Phase 1 — engine linkage (1–2 weeks)

- [x] Build Nightjar as a static archive for macOS arm64
- [x] C ABI and Swift `StreamingEngine` façade, with video/audio consumer seams
- [ ] Package the engine as an `xcframework`
- [x] PIN pairing, pinned HTTPS host control, app list, launch/resume, Keychain credentials
- [x] Validate pairing and launch against a real host (Rubylight, Desktop)
- [x] Host discovery (mDNS `_nvstream._tcp`), saved endpoints, one-click reconnect and legacy-address migration (local Bonjour fixture verified; Big Dawg uses its saved non-LAN address)
- [ ] CI: core tests on Linux, engine build on macOS

## Phase 2 — first playable (6–10 weeks)

- [x] Minimal SwiftPM macOS app target: manual host, library, stream window, connect/disconnect commands
- [x] Native three-pane shell and Settings scene: search, grid/list, sort/filter, shared saved stream defaults (live Desktop launch verified)
- [x] Wire host launch credentials and RTSP session lifecycle through engine to decoder
- [x] VideoToolbox H.264/HEVC/AV1 implementation with per-profile hardware probes
- [x] Display-layer presenter and native fullscreen control
- [x] Live Desktop video, disconnect/resume, saved pairing across app restart, native fullscreen, 1080p → 720p session change
- [x] Live simulated reference-loss/IDR recovery on 4K/120 HEVC 10-bit Desktop
- [x] Bounded automatic reconnect and opt-in automatic bitrate using Nightjar shared policies (automated lifecycle/policy tests; live network validation pending)
- [ ] Controlled UDP packet loss/FEC recovery and visual HDR validation
- [ ] AV1 hardware validation on a supported Mac (current Mac reports no hardware decoder)
- [x] AVAudioEngine audio (bundled libopus), concealment, stereo/surround downmix, volume/mute
- [x] Live stereo listening confirmed on Desktop
- [ ] Output-device switch and live surround validation
- [x] Keyboard/mouse mapping, window capture/release, and bounded engine delivery
- [x] Live keyboard shortcut, pointer clicking/scrolling, relative capture, and release chord verified on Desktop
- [x] GameController input: DualSense/Xbox extended-profile mapping, bounded delivery and lifecycle (snapshot tested; physical host acceptance pending)
- [x] Latency HUD: engine frame assembly/host processing, VideoToolbox decode, and renderer enqueue timings; rolling p50/p95 and rates (live Desktop verified; network transit/scanout unavailable)

## Phase 3 — PyroWave and platform polish (2–4 months)

- [ ] Metal compute port of the PyroWave decoder (MSL), 4:4:4 support
- [ ] HDR/EDR output with correct PQ metadata and no double tone-mapping
- [ ] Metal renderer with PTS-driven frame pacing
- [x] Controller handle rumble and supported trigger-motor rumble via Core Haptics (automated checks; physical validation pending)
- [ ] DualSense PCM haptics and adaptive triggers
- [x] Opt-in Mac microphone capture, mono Opus and encrypted Apollo/Rubylight forwarding (live Windows input-meter response confirmed on Big Dawg)
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
