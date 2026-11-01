# Nightjar parity

Mystic targets Nightjar's user-facing features, adapted to macOS rather than copied
pixel for pixel. PyroWave is the last implementation milestone. A shared engine is
not sufficient: each feature needs native UI, lifecycle handling and validation.

Baseline: local Nightjar 4.0.1, revision `461e403b`, especially
`docs/CLIENT-PARITY.md`, `docs/features.md` and `protocol/desktop/src/session_page.rs`.
Rows naming a `protocol/desktop/src` module come from comparing that client's code with
Mystic's, not only its documentation.
This checklist is a feature-area inventory, not a numerical completion estimate.
“Implemented” does not imply physical or live-host validation. Platform limitations
must be investigated and documented before a feature is marked inapplicable.

| Area | Mystic status | Remaining work / evidence |
| --- | --- | --- |
| Discovery, manual host, PIN pairing, saved hosts | Implemented | Desktop pairing/restart verified on Big Dawg; broader host coverage pending |
| Wake-on-LAN | Implemented, basic | Remembered physical MAC/subnet addresses; packet tests passed; real wake and automatic retry/polling pending. Nightjar (`wol.rs`) sends on every network interface, including IPv6; Mystic sends only to remembered broadcast addresses |
| QR/one-time pairing | Pending | Mac pairing-link flow |
| Client identification | Pending | Nightjar calls `http::set_app_version` so requests carry `Nightjar/<version>`; Mystic never sets it, so hosts see plain `Nightjar` with no version |
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
| Window position memory | Pending | Nightjar (`window_place.rs`) reopens on the same display, position and size |
| Controller menu navigation | Pending | Nightjar (`console.rs`, `nav_repeat.rs`) drives every screen from a controller |
| H.264/HEVC decoding | Implemented | Big Dawg HEVC verified |
| AV1 hardware decode | Implemented, hardware validation pending | Current Mac reports unsupported hardware |
| HDR10 and SDR transitions | Implemented, partial parity | PQ/BT.2020 HUD and visual MacBook checks passed with user. Display luminance is never sent: Nightjar sends `DisplayCaps` to Rubylight hosts and `display_luminance` at launch to others (`sdl.rs`), so the host currently tone-maps for a generic display |
| HLG, HDR10+, Dolby Vision, 10-bit SDR | Partial / pending | HLG metadata path exists; format-specific fidelity and capability work remain. Launch never sets `ten_bit_sdr`; Nightjar first checks the decoder with fixtures (`color_probe.rs`) |
| Full-chroma/true 4:4:4 | Pending | Codec/presentation integration and supported-hardware checks, with a decoder check as above |
| Upscaling | Pending | Choose Mac-native rendering path |
| Native pacing, HUD | Implemented, partial parity | Low Latency/Balanced; Balanced with FPS limit, Smoothest video, PTS Metal renderer, VRR/phase-lock remain |
| Performance overlay modes and host telemetry | Pending | Nightjar (`overlay.rs`) has Compact, Statistics and Debug, with the host's CPU/GPU load, temperatures, power and clocks |
| Fractional refresh / virtual display controls | Pending | Native settings and host capability negotiation. Launch sends neither `launch_refresh_rate_x100` nor `client_refresh_rate_x100`, so 59.94 Hz launches as 60 |
| Recovery, automatic bitrate | Implemented, partial parity | Big Dawg reconnect passed; congestion testing pending. Startup stage allowlist matches Nightjar. No route watcher: Nightjar (`stream/mod.rs` `roam_watch`) reconnects as soon as a lost route returns and waits while none exists |
| Automatic bitrate on Foundation Sunshine hosts | Pending | Nightjar (`host_abr.rs`) turns on the host's own controller and reports the network every three seconds; Mystic's automatic bitrate needs Rubylight |
| Automatic quality (resolution/FPS) | Pending | Nightjar (`quality.rs`) uses `nightjar_policy::quality`'s bounded ladder; Mystic changes bitrate only |
| Link test before the first bitrate | Pending | Off by default in Nightjar (`http::probe_start_kbps`, `launch::estimated_kbps`) |
| Live manual bitrate/FPS | Implemented | Big Dawg negotiation/UI verified; live Apply pending; see LIVE-RATES.md |
| FEC controls | Implemented | Settings → Network; launch and ANNOUNCE requests; engine loss reports. Effect on a lossy link not yet measured; see NETWORK.md |
| Ride out drops and link reports | Implemented | Drop tolerance and Wi-Fi/link-speed hints; Big Dawg launch told "wireless" over Wi-Fi. A real network drop not yet tested; see NETWORK.md |
| VPN route packet size | Pending | Nightjar (`location_for_route`) streams a VPN route as remote with 1024-byte packets; Mystic always sends 1392 and leaves location to the engine, so a VPN to a private address fragments |
| Client roaming | Pending | Engine support exists; needs route-change monitoring and settings |
| Stream health report and bitrate trial | Implemented | Nightjar's StreamHealth/BitrateTrial via the engine; HUD network figures. Big Dawg report verified; the trial is tested with fakes only (no lossy link yet); see STREAM-HEALTH.md |
| Connection test, benchmark, CSV timings, input latency test | Pending | Native diagnostics and export; Nightjar desktop has the timing CSV (`timing_csv.rs`) and Remote access check (`network_test.rs`) |
| Stereo playback, mute, output changes | Implemented | User verified on Big Dawg. Device underruns play silence; Nightjar (`playout.rs`) fills them with Opus concealment and skips packets whose time has passed |
| 5.1/7.1 discrete PCM | Implemented, physical validation pending | Speaker identity and downmix checks |
| 7.1.4/passthrough | Pending | Mac output capability investigation |
| Microphone | Implemented | Live host input-meter response verified previously |
| Microphone echo cancellation | Pending | Mac voice-processing integration |
| Keyboard/mouse and fullscreen | Implemented | User verified on Big Dawg |
| Keyboard follows text fields, layout report | Pending | Nightjar (`text_field.rs`) handles host text-field notices (0x553B) and reports the keyboard layout (0x553E); Mystic sends US key positions only |
| Saved key chords, import/export | Pending | Nightjar (`shortcuts.rs`) shares Android's file format; Mystic has only its release chord |
| Host cursor shapes | Pending | Nightjar (`stream/cursor.rs`) shows the host's cursor, with a hide debounce |
| Controller input/rumble | Implemented, partial parity | Controller unavailable during joint playtest. At most four controllers (Nightjar: 16) |
| Controller mapping, motion, touchpad, LEDs/battery | Partial / pending | Arrival announces only analog triggers, rumble and trigger rumble; Nightjar (`gamepad.rs`) also announces touchpad, dual touchpad, accelerometer, gyro, battery and RGB LED |
| Controller as mouse, host night mode/headphone surround | Pending | Nightjar stream menu (`controller_mouse.rs`, `menu_extras.rs`; Rubylight `/audio`) |
| DualSense adaptive triggers / PCM haptics | Pending | Mac device/API support investigation |
| Touch/pen and local cursor | Pending applicability audit | Native Mac input devices and host support; Nightjar sends raw touchpad contacts to the PC (`touchpad.rs`) |
| Clipboard text | Implemented, live validation deferred | Manual and opt-in foreground sync |
| Clipboard images, files, shared folders, USB | Pending | Capability/permission-aware native flows |
| Session graphics / Radeon controls | Implemented | Big Dawg GPU/settings and permission gating verified; live writes/restore pending Host control permission; see GRAPHICS.md |
| Accessibility and system appearance | Partial | SwiftUI/accessibility labels present; systematic audit pending |
| Release packaging, CI, notarization, updates | Pending | Signed local app exists; distribution and release checks remain; Nightjar checks for updates once per launch (`update_check.rs`) |
| Redacted reports / crash records | Pending | Privacy-safe diagnostics and export; Nightjar desktop writes redacted logs (`logfile.rs`, `report::redact`) and crash dumps (`crash_dump.rs`) |
| Published latency measurements | Pending | Timestamp and glass-to-glass method |
| PyroWave | Last | Metal decode, calibration, bandwidth and pacing integration |

Next sequence: validate session actions/live stream controls, finish remaining host/library management,
sharing, input/audio/diagnostics and remaining video integration, release hardening,
then PyroWave. Validate each feature as suitable hardware becomes available.
