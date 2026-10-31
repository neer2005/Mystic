# Live bitrate and frame rate

Open Host Session → Stream during streaming. Full-stream launches/resumes request
Nightjar's `rlRateChange=1`; the bridge exposes controls only after the host's DESCRIBE
announces 0x553C. Hosts advertising HTTP RuntimeBitrate without that control message
receive bitrate-only controls. Missing capabilities never produce a fake success.

Bitrate is 1–150 Mbps. Frame rate is 10 fps through the original launch rate, capped
at 240 fps, with millihertz precision for values such as 59.94. Saved profiles remain
unchanged. Manual changes pause automatic bitrate for the rest of this attempt. Any
older automatic write is drained before the manual request; reconnect uses the
original immutable stream plan and restores its automatic policy.

The control bridge allows one pending request, matches the host's serial, and ignores
late or unrelated replies. A reply must arrive within five seconds; a timed-out or
failed request clears displayed confirmed values and marks the result uncertain.
The host's applied bitrate/frame rate and per-field applied, unchanged, clamped or
refused outcomes are displayed. Sending a message alone does not establish success.
HTTP fallback displays the actual bitrate returned by the host and cannot change FPS.

Confirmed frame-rate changes update decoder presentation hints on its owning queue.
Nominal integer pacing rounds fractional rates up, while source timestamps preserve
their actual timing. A decoder setup resets the hint. Disconnect/recovery invalidates
pending UI updates and clears negotiated capability/result state. These changes add
an ABI function without changing the ABI 2 struct layouts.

## Validation

Rust tests cover negotiated availability, bounds, concurrent request refusal, timeout,
serial matching and stale results. The C smoke test calls the new owned-JSON API.
Swift tests cover HTTP fallback, host clamping/read-back, unsupported FPS writes,
launch ceilings, failed requests, stale connections, automatic-policy pause and saved
profile preservation/reconnect. A hardware decoder fixture verifies frame-rate hints
change and reset correctly. Full Swift/Rust checks and the C bridge smoke test passed.

Live Big Dawg inspection on 2026-10-31 confirmed successful Desktop resume and
negotiation of both rate controls, with 100 Mbps / 120 fps launch settings. The panel
was inspected during streaming. Actual live changes, host outcomes and visible
smoothness/audio/input continuity remain a joint test: try 40 Mbps / 60 fps, inspect
host-confirmed results, then reconnect and check restoration of the original profile.
