# Stream recovery and automatic bitrate

## Automatic reconnect

Settings → Network → Reconnect Interrupted Streams is on by default, including
when loading older saved settings. It only restores a stream that previously
received decoded video; failed first launches, clean exits, protected-content
errors, pairing/certificate failures, permission errors and decoder errors remain
manual.

Mystic uses Nightjar 4.0.1's shared `Backoff` and termination classification. The
retry delays are 1, 2, 4, 8 and 12 seconds, with at most five attempts within a
one-minute recovery window. A connection must last 30 seconds to renew that
budget. Briefly reconnecting does not reset it, even if a later attempt receives
no picture. Known transport failures during a recovery start can retry; other
startup failures stop recovery.

Recovery releases input, stops microphone capture and the old media session, and
recreates a pinned host connection to the original endpoint. It verifies the
host identity and that the original app is still running, then resumes with the
original resolution, codec, HDR, audio and controller settings and fresh launch
keys. A recovery request cannot launch an app that has stopped or replace another
app. Callback generations fence old sessions and HTTP responses. Disconnect,
closing the stream window and quitting cancel pending recovery.

This restores sessions after transient termination. Route-change monitoring,
proactive network-return probes, configurable drop tolerance and roaming controls
are not integrated yet.

## Automatic bitrate

Settings → Video → Automatic Bitrate is off by default. Enable it before starting
a stream; the selected bitrate becomes the ceiling. The stream toolbar shows the
current applied bitrate or why adaptation is unavailable/stopped. The preference
and reconnect switch apply to the next stream and are locked during a session.

Hosts must advertise Nightjar's RuntimeBitrate capability. A host without it keeps
the fixed stream bitrate. Once decoded video starts, Mystic requests the selected
ceiling and initializes Nightjar's shared `AdaptiveBitrateController` from the
host's actual applied rate. A lower host cap is retained.

The policy receives once-a-second post-FEC frame loss, frame-arrival jitter and
VideoToolbox decode timing. Its codec/size/frame-rate-dependent floor, sustained
pressure rules and recovery ramp are shared with Nightjar. Only one request is
in flight; host responses update policy state. Unknown/stale measurements are not
reported as healthy. A failed or invalid bitrate response stops adaptation and
leaves playback running, with a visible explanation.

This changes bitrate only. Automatic resolution/FPS changes, Foundation Sunshine's
host-side ABR controller, thermal inputs and network queue-delay measurements
remain separate work. Requests use the existing pinned HTTPS host connection.

## Validation

Automated lifecycle tests cover recovery cancellation, retry exhaustion across
successive sessions, old callbacks, unchanged launch options, changed host/app,
transport versus permanent failures, startup transport versus decoder failures,
opt-out, deadline expiry, host capability gating and bitrate-request failure.
Rust tests cover classification/budget, frame timing, congestion cuts, recovery
and host caps. C smoke tests exercise the additive policy interface. Saved
settings tests cover migration and persistence.

Live packet-loss/reconnect and adaptive-bitrate behavior still need validation
against a streaming host. Automated tests do not establish visual quality or
reconnect latency on a real network.
