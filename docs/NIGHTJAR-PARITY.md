# Nightjar parity

Mystic targets Nightjar's user-facing features, adapted to macOS rather than copied
pixel for pixel. PyroWave is the last implementation milestone. A shared engine is
not sufficient: each feature needs native UI, lifecycle handling and validation.

Baseline: local Nightjar 4.0.1, revision `461e403b`, especially
`docs/CLIENT-PARITY.md`, `docs/features.md` and `protocol/desktop/src/session_page.rs`.
This checklist is a feature-area inventory, not a numerical completion estimate.
“Implemented” does not imply physical or live-host validation. Platform limitations
must be investigated and documented before a feature is marked inapplicable.

| Area | Mystic status | Remaining work / evidence |
| --- | --- | --- |
| Discovery, manual host, PIN pairing, saved hosts | Implemented | Desktop pairing/restart verified on Big Dawg; broader host coverage pending |
| Wake-on-LAN | Implemented, basic | Remembered physical MAC/subnet addresses; packet tests passed; real wake and automatic retry/polling pending |
| QR/one-time pairing | Pending | Mac pairing-link flow |
| Native library, artwork, store/title search | Implemented for connected host | Big Dawg browsing/search/refresh verified |
| Combined Home, favourites, recent games | Implemented | Multi-PC merge/routing tests and Big Dawg live Home verified; store filter present, separate store shelves pending |
| Offline library/cache | Implemented | Versioned metadata and bounded artwork cache; persistence/invalidation tests; real offline-host validation pending |
| Launch/resume and per-game video profiles | Implemented | Desktop live verification; extend profiles beyond video |
| Native session status, resume, disconnect/end/close | Implemented | Live status checks and action validation described in SESSION.md |
| Classic quit and quit-and-start-another | Implemented | Big Dawg confirmations/cancellation verified; real quit/switch validation pending; see GAME-SWITCHING.md |
| Quick resume / quit on leave | Pending | Per-game opt-in policy |
| Remote Monitor, input-only, co-op | Pending | Explicit roles and permissions |
| Network profiles, launch shortcuts/CLI | Pending | Native Mac entry points |
| Host details/web UI, PIN lock, languages | Partial / pending | Host sidebar exists; full controls and localization pending |
| H.264/HEVC decoding | Implemented | Big Dawg HEVC verified |
| AV1 hardware decode | Implemented, hardware validation pending | Current Mac reports unsupported hardware |
| HDR10 and SDR transitions | Implemented | PQ/BT.2020 HUD and visual MacBook checks passed with user |
| HLG, HDR10+, Dolby Vision, 10-bit SDR | Partial / pending | HLG metadata path exists; format-specific fidelity and capability work remain |
| Full-chroma/true 4:4:4 | Pending | Codec/presentation integration and supported-hardware checks |
| Upscaling | Pending | Choose Mac-native rendering path |
| Native pacing, HUD | Implemented, partial parity | Low Latency/Balanced; other modes, PTS Metal renderer, VRR/phase-lock remain |
| Fractional refresh / virtual display controls | Pending | Native settings and host capability negotiation |
| Recovery, automatic bitrate | Implemented | Big Dawg reconnect passed; congestion testing pending |
| Live manual bitrate/FPS | Implemented | Big Dawg negotiation/UI verified; live Apply pending; see LIVE-RATES.md |
| FEC controls | Pending | Native settings and feedback |
| Ride out drops, roaming and link reports | Pending integration audit | Shared engine support does not establish app parity |
| Connection test, health report, benchmark, CSV timings | Pending | Native diagnostics and export |
| Stereo playback, mute, output changes | Implemented | User verified on Big Dawg |
| 5.1/7.1 discrete PCM | Implemented, physical validation pending | Speaker identity and downmix checks |
| 7.1.4/passthrough | Pending | Mac output capability investigation |
| Microphone | Implemented | Live host input-meter response verified previously |
| Microphone echo cancellation | Pending | Mac voice-processing integration |
| Keyboard/mouse and fullscreen | Implemented | User verified on Big Dawg |
| Controller input/rumble | Implemented, physical validation pending | Controller unavailable during joint playtest |
| Controller mapping, motion, touchpad, LEDs/battery | Partial / pending | Broader Nightjar controller feature coverage |
| DualSense adaptive triggers / PCM haptics | Pending | Mac device/API support investigation |
| Touch/pen and local cursor | Pending applicability audit | Native Mac input devices and host support |
| Clipboard text | Implemented, live validation deferred | Manual and opt-in foreground sync |
| Clipboard images, files, shared folders, USB | Pending | Capability/permission-aware native flows |
| Session graphics / Radeon controls | Implemented | Big Dawg GPU/settings and permission gating verified; live writes/restore pending Host control permission; see GRAPHICS.md |
| Accessibility and system appearance | Partial | SwiftUI/accessibility labels present; systematic audit pending |
| Release packaging, CI, notarization, updates | Pending | Signed local app exists; distribution and release checks remain |
| Redacted reports / crash records | Pending | Privacy-safe diagnostics and export |
| Published latency measurements | Pending | Timestamp and glass-to-glass method |
| PyroWave | Last | Metal decode, calibration, bandwidth and pacing integration |

Next sequence: validate session actions/live stream controls, finish remaining host/library management,
sharing, input/audio/diagnostics and remaining video integration, release hardening,
then PyroWave. Validate each feature as suitable hardware becomes available.
