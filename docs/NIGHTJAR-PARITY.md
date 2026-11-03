# Nightjar parity

Mystic targets Nightjar's user-facing features, adapted to macOS rather than copied
pixel for pixel. PyroWave is the last implementation milestone. A shared engine is
not sufficient: each feature needs native UI, lifecycle handling and validation.

Baseline: local Nightjar 4.3.1, revision `f25e40b6`, especially
`docs/CLIENT-PARITY.md`, `docs/features.md` and `protocol/desktop/src/session_page.rs`.
Rows naming a `protocol/desktop/src` module come from comparing that client's code with
Mystic's, not only its documentation.
This checklist is a feature-area inventory, not a numerical completion estimate.
“Implemented” does not imply physical or live-host validation. Platform limitations
must be investigated and documented before a feature is marked inapplicable.

| Area | Mystic status | Remaining work / evidence |
| --- | --- | --- |
| Discovery, manual host, PIN pairing, saved hosts | Implemented | Desktop pairing/restart verified on Big Dawg; broader host coverage pending |
| Wake-on-LAN | Implemented | Nightjar's plan (every interface's broadcast, IPv6 `ff02::1`, its port set, three bursts) and wait (resend every 8 s, 90 s limit); see HOME.md. Real wake of a sleeping PC pending |
| Pairing links and one-time PINs | Implemented, live validation pending | Nightjar's `rubylight://pair` link, typed or pasted, and a host's PIN and passphrase; see HOSTS.md. Refusals and a host's error seen on Big Dawg; a successful pairing not yet tried. QR scanning has no Mac flow, as on Nightjar's desktop |
| PC's error reason | Implemented | When the PC ends a stream on an error, Nightjar 4.3.1's wording plus "The PC reported: …" from its next serverinfo, waiting at most 5 s. Not triggered on a real host yet |
| Client identification | Implemented | Requests carry `Nightjar/4.3.1+mystic.<version>`: the engine release, marked as Mystic |
| Native library, artwork, store/title search | Implemented for connected host | Big Dawg browsing/search/refresh verified |
| Combined Home, favourites, recent games | Implemented | Multi-PC merge/routing tests and Big Dawg live Home verified; store filter present, separate store shelves pending |
| Offline library/cache | Implemented | Versioned metadata and bounded artwork cache; persistence/invalidation tests; real offline-host validation pending |
| Launch/resume and per-game video profiles | Implemented | Desktop live verification; extend profiles beyond video |
| Native session status, resume, disconnect/end/close | Implemented | Live status checks and action validation described in SESSION.md |
| Classic quit and quit-and-start-another | Implemented | Real quit verified on Big Dawg (2026-11-01, after fixing the dialog's dismissal cancelling it); real switch from Desktop to a game verified the same day; see GAME-SWITCHING.md |
| Quick resume / quit on leave | Implemented, live validation pending | Nightjar's policy: quick resume global and off by default; quit on leave per game, only on a leave the player chose; see SESSION.md |
| Remote Monitor, input-only, co-op | Pending | Explicit roles and permissions |
| Network profiles, launch shortcuts/CLI | Implemented, live validation pending | Nightjar's command line and `mystic://stream` links (LAUNCHING.md); settings profiles by hand or by network, told by the route rather than the Wi-Fi name (no Location permission); see PROFILES.md |
| Resolution, frame rate and bitrate choices | Implemented | Native, Display, Recommended, custom sizes and rates, up to 2000 Mbps; 0.5 Mbps not offered; see SETTINGS.md |
| Video size, play audio on the PC, automatic quality minimums | Implemented, partial live validation | Fit and Native Pixels seen live; see SETTINGS.md |
| Mouse speed and buttons; controller on/off, Nintendo layout, motion, vibration, dead zone | Implemented, physical validation pending | Nightjar's Controls settings the Mac can apply; automated checks only |
| Host details and web UI | Implemented | Nightjar's `host_page.rs`: software, permissions and the web UI link (Stream → Host Details, the library toolbar, and the pairing view). Details and URL checked on Big Dawg; see HOSTS.md |
| PIN lock, languages | Pending | |
| Window position memory | Implemented by macOS | AppKit saves each window's frame by scene (`NSWindow Frame stream`, `… library`) and reopens it on the same display, position and size, constrained to the screens present; Nightjar's `window_place.rs` does this by hand |
| Controller menu navigation | Pending | Nightjar (`console.rs`, `nav_repeat.rs`) drives every screen from a controller |
| H.264/HEVC decoding | Implemented | Big Dawg HEVC verified |
| AV1 hardware decode | Implemented, hardware validation pending | Current Mac reports unsupported hardware |
| HDR10 and SDR transitions | Implemented | PQ/BT.2020 HUD and visual MacBook checks passed with user. Display luminance goes to the host as Nightjar's estimate from EDR headroom (DisplayCaps for Rubylight, the launch query for others; see HDR.md). Live host check pending |
| HLG, HDR10+, Dolby Vision, 10-bit SDR | Partial / pending | HLG metadata path exists; format-specific fidelity and capability work remain. 10-bit SDR implemented (Settings → 10-bit Color), offered through Nightjar's `color::offer` from the Mac's verified decoders; negotiated on Big Dawg, banding not yet judged by eye, see BASELINE.md |
| True 4:4:4 | Implemented, live validation pending | Settings → Prefer YUV 4:4:4, offered through Nightjar's `color::offer`. This Mac's decoder passes for H.264 and HEVC; Big Dawg reports it encodes none, so no 4:4:4 stream has run |
| Full chroma (packed 4:4:4) | Pending | Needs a Metal unpacking step and the host option; measure its delay first |
| Metal renderer | Experimental, off by default | Live HDR on Big Dawg, and Low Latency without the refresh wait about 16 ms faster by its own report. Tearing and screen latency not checked; see METAL-RENDERER.md |
| Upscaling | Pending | Choose Mac-native rendering path |
| Native pacing, HUD | Implemented, partial parity, live validation pending | Nightjar's `stream::present` ported 1:1: its four pacings, V-Sync setting and host-time scheduling, the last unreachable without a display check. Not yet measured live; see FRAME-PACING.md. Phase-lock reports on Metal with V-Sync, no measured gain yet. Clock sync measures PC to screen on Metal; see BASELINE.md. VRR and its display check remain; beam racing needs PyroWave |
| Performance overlay modes and host telemetry | Implemented, live validation pending | Nightjar's Compact, Statistics and Debug with the shared health mark and hardware poll; see LATENCY.md |
| Fractional refresh rate | Implemented, live validation pending | The screen's exact rate goes in `client_refresh_rate_x100` at launch and in the ANNOUNCE, as Nightjar's desktop client sends it; see FRAME-PACING.md |
| Virtual display controls, display arrangement, PC render resolution and scaling | Implemented, partial live validation | Per host and game, each row following what the host reports. Extend confirmed in Big Dawg's log on launch and resume; other choices not yet tried; see SETTINGS.md |
| Recovery, automatic bitrate | Implemented | Big Dawg reconnect passed; congestion testing pending. Startup stage allowlist matches Nightjar. A network back on an address the stream cannot continue over reconnects at once (NETWORK.md); a real network drop not yet tested |
| Automatic bitrate on Foundation Sunshine hosts | Implemented, live validation pending | Nightjar's `host_abr.rs`: the host's controller on at stream start, a report every three seconds, off at the end over its own connection; see NETWORK.md |
| Automatic quality (resolution/FPS) | Implemented, live validation pending | Nightjar's ladder over Reconfigure, per profile; see NETWORK.md |
| Link test before the first bitrate | Pending | Off by default in Nightjar (`http::probe_start_kbps`, `launch::estimated_kbps`) |
| Live manual bitrate/FPS | Implemented | Big Dawg negotiation/UI verified; live Apply pending; see LIVE-RATES.md |
| FEC controls | Implemented | Settings → Network; launch and ANNOUNCE requests; engine loss reports. Effect on a lossy link not yet measured; see NETWORK.md |
| Ride out drops and link reports | Implemented | Drop tolerance and Wi-Fi/link-speed hints; Big Dawg launch told "wireless" over Wi-Fi. A real network drop not yet tested; see NETWORK.md |
| VPN route packet size | Implemented | Tunnel/PPP interfaces or an MTU under 1500 stream as remote with 1024-byte packets, as Nightjar; see NETWORK.md. Not yet tried over a real VPN |
| Keep AWDL off while streaming (not in Nightjar) | Implemented | Privileged helper, opt-in, after AWDL Control; on Big Dawg over Wi-Fi it removed gaps near 100 ms; see NETWORK.md |
| Client roaming | Implemented, live validation pending | Network watcher, roaming and metered-network settings (on and off by default, as Nightjar); see NETWORK.md |
| Stream health report and bitrate trial | Implemented | Nightjar's StreamHealth/BitrateTrial via the engine; HUD network figures. Big Dawg report verified; the trial is tested with fakes only (no lossy link yet); see STREAM-HEALTH.md |
| Remote access check | Implemented, live validation pending | Android's and Nightjar's check (`host_page.rs`): five pinned probes, then the host's route; the PC's context menu |
| Statistics CSV | Implemented | Nightjar's Save statistics columns, per second, last hour; Stream → Save Statistics… |
| Per-frame timing CSV | Implemented | Nightjar's `timing_csv.rs` and its columns, joined with host records; `NIGHTJAR_TIMING_CSV` names a file or folder, as on Nightjar's desktop. Checked on Big Dawg |
| Bandwidth test | Pending | Nightjar's `network_test.rs` (Rubylight and Foundation probes) |
| Input latency test | Implemented | Stream menu → Measure Input Latency, Nightjar's Android `LatencyProbe` (its desktop has none). Input is released first so the host's pointer is in the video. Not yet measured: Big Dawg (host 7.1.431) sends about 20 frames a second on a still desktop, so the screen never counts as still and the test reports it couldn't measure |
| Stereo playback, mute, output changes | Implemented | User verified on Big Dawg. Late packets are filled with Opus concealment and skipped on arrival, Nightjar's playout rule run on the decode side; see AUDIO.md |
| Audio clock drift trim | Implemented | Nightjar 4.3.1's `playout.rs` rule, simulated at 35 and 300 ppm; see AUDIO.md. No trim seen live yet |
| 5.1/7.1 discrete PCM | Implemented, physical validation pending | Speaker identity and downmix checks |
| 7.1.4/passthrough | Pending | Mac output capability investigation |
| Microphone | Implemented | Nightjar 4.3.1's encoder settings: 64 kb/s speech with in-band FEC for 10% loss. Host input-meter response verified previously, before this change |
| Microphone echo cancellation | Deferred (2026-10-31) | macOS voice processing removes only what plays through the same audio engine as the microphone; Mystic plays and records on separate engines. Doing it means playing the stream through the microphone's engine while it is on, which likely limits surround to stereo and applies voice processing to game sound. If taken up: Nightjar's Automatic (off with headphones), On and Off |
| Keyboard/mouse and fullscreen | Implemented | User verified on Big Dawg. Nightjar 4.3.1's 0.5 ms relative motion floor merges a 4 or 8 kHz mouse |
| Display stays awake while streaming | Implemented | `DisplayWake` holds an idle-display-sleep activity for the stream, as SDL keeps Nightjar's screen saver off |
| Keyboard layout report | Implemented, live validation pending | Nightjar's `text_field.rs`: the Mac's layout at start and on every switch (0x553E), as the matching Windows layout or the BCP-47 language; see INPUT.md |
| Host text fields | Implemented for Mac, live validation pending | Nightjar opens an on-screen keyboard on a raise (0x553B); a Mac has none, so a focused field takes emoji picker, Character Viewer and dictation text as UTF-8. IME composition pending |
| Saved key chords, import/export | Implemented, live validation pending | Nightjar's `shortcuts.rs` and Android's file format; Settings → Keyboard and Stream → Send Shortcut; see INPUT.md |
| Host cursor shapes | Implemented, live validation pending | Nightjar's `stream/cursor.rs`: Local Cursor in desktop control, 32-image cache, 150 ms hide debounce; see INPUT.md |
| Controller input/rumble | Implemented, physical validation pending | Controller unavailable during joint playtest. 16 controllers, as Nightjar |
| Controller mapping, motion, touchpad, LEDs/battery | Partial, physical validation pending | Typed arrivals, Guide/touchpad click/Share/paddles, motion, battery and light done (see INPUT.md); motion axes unverified. Touchpad contacts pending: GameController has no reliable finger-down state. Per-model remapping pending |
| Host night mode and headphone surround | Implemented | Host Controls → Stream, Nightjar's `menu_extras.rs`, for this stream only. Night mode read, changed and restored on Big Dawg; the sound itself not judged by ear |
| Controller as mouse | Pending | Nightjar stream menu (`controller_mouse.rs`) |
| DualSense adaptive triggers / PCM haptics | Pending | Mac device/API support investigation |
| Touch/pen and local cursor | Pending applicability audit | Native Mac input devices and host support; Nightjar sends raw touchpad contacts to the PC (`touchpad.rs`) |
| Clipboard text | Implemented, live validation deferred | Manual and opt-in foreground sync |
| Clipboard images | Implemented, live validation pending | Stream menu, as PNG both ways, only when the host offers it through its native API; a TIFF copy also goes on the Mac clipboard |
| Files | Implemented, live validation pending | Library header → PC menu → Files on a host with the native API: Nightjar's page and shared transfer list, with drag and drop. Closing cancels what has not finished. Big Dawg answers that it takes no files and offers none, so no file has moved on a real host |
| Shared folders | Implemented, live validation pending | Library header → PC menu → Shared Folders: Nightjar's browser, one transfer at a time, downloads into a folder you choose, uploads with a write grant, with drag and drop. Closing cancels the transfer. Big Dawg answers that it shares no folders, so nothing has been browsed or moved on a real host |
| USB | Parked | Big Dawg does not offer it, so it could not be tested. Nightjar's engine and libusb would carry most of it; on macOS, devices held by a system driver need root or the `com.apple.vm.device-access` entitlement |
| Session graphics / Radeon controls | Implemented | Big Dawg GPU/settings and permission gating verified; live writes/restore pending Host control permission; see GRAPHICS.md |
| Accessibility and system appearance | Partial | SwiftUI/accessibility labels present; systematic audit pending |
| Release packaging, CI, notarization | Implemented, first run pending | Tag-driven GitHub Actions release with disk image, checksum and notarization; see RELEASING.md. Needs Developer ID secrets |
| Update check | Implemented | Nightjar's `update_check.rs` against Mystic's GitHub releases, once per launch; offers nothing until a release is published; see SETTINGS.md |
| Redacted session log | Implemented | Nightjar's `logfile.rs` rules: this run and the last, 4 MiB cap, each line redacted by `report::redact`; Help → Show Session Log in Finder |
| Crash records | Implemented by macOS | macOS writes crash reports (Console → Crash Reports); Nightjar's `crash_dump.rs` exists for Windows minidumps. A problem report that bundles them is pending |
| Published latency measurements | Pending | Timestamp and glass-to-glass method |
| PyroWave | Last | Metal decode, calibration, bandwidth and pacing integration |

Next sequence: validate session actions/live stream controls, finish remaining host/library management,
sharing, input/audio/diagnostics and remaining video integration, release hardening,
then PyroWave. Validate each feature as suitable hardware becomes available.
