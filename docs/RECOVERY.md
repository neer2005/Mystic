# Video reference recovery

VideoToolbox or display errors now request a host keyframe immediately, rather
than waiting for another compressed frame to arrive. A locked gate bounds these
asynchronous requests to one pending operation on the engine worker. Stop closes
the gate before interrupting the engine. Synchronous `.needIDR` still passes
through the C callback and Nightjar's decoder-refresh path unchanged.

A failed generation stays failed after its error is consumed. Later callbacks
cannot re-enable output or reserve new decode slots. Failure advances the
presenter's generation fence immediately, so a callback that races with the
failure cannot put an old image back in the presentation mailbox. Older reset
notifications cannot roll that fence backward. Stop/setup invalidate generations
and reject late callbacks and request work.

Recoveries retain the stream's last validated parameter sets and static HDR
metadata, allowing a usable IDR that omits repeated headers to rebuild the hardware
session. Setup/cleanup clear that cache, and a new configuration must still match
the negotiated codec/profile. An access unit containing incomplete H.264/HEVC
parameter sets is rejected instead of combining it with a stale description.
Dependent frames remain rejected until a usable keyframe is accepted.

## Automated checks

Xcode 27 / Swift 6.4: 125 tests, 121 passed, four AV1 hardware skips. Tests cover
hardware decode after simulated reference loss, headerless IDR recovery with cached
configuration, configuration clearing on new setup, malformed/partial parameter
sets, immediate recovery notification without another submit, duplicate/stopped
notification rejection, persistent failure fencing, monotonic presenter resets,
and bounded/closed engine request scheduling. Existing format-change and async
recovery fixture tests remain in place. No engine ABI changes were needed.

## Live test scope

Debug builds expose **Test Video Recovery** in the stream toolbar. This drops one complete
compressed frame at the decoder boundary and returns `.needIDR` to the actual
engine. It exercises decoder refresh, the live host keyframe response, hardware
decode and presentation without changing system networking. It is excluded from
release builds and does not change saved stream settings.

This is reference-loss injection after packet reassembly. It does **not** test UDP
packet loss, FEC repair limits, packet reordering, network outages, or reconnection.
Those require a controlled transport-loss harness and remain separate acceptance
checks. A decoded-keyframe log alone is not proof of screen recovery; verify the
video and progressing renderer-enqueue counters as well.


## Live result — 2026-10-27

On Big Dawg's Desktop with the user's existing 3840×2160, 120 fps, HDR configuration,
the stream negotiated HEVC 10-bit. The development action generated the log:

```text
Video keyframe decoded: hevc10, generation 2
simulated lost compressed frame
Video keyframe decoded: hevc10, generation 4
```

The Windows Desktop image remained visible afterward. HUD enqueue counters advanced
from 282 before the test to 497 and later 1,232, with a positive enqueue rate.
Host playback and encrypted microphone packet counters continued advancing.
No disconnect/reconnect was used to recover. This verifies the real engine refresh
path and host keyframe response for an injected lost compressed frame; it does not
establish recovery time, physical HDR fidelity, or transport/FEC behavior.

The debug app build and code signature verified. An optimized release build also
passed; the release executable does not contain the recovery-test action strings.
The initial restricted release invocation could not run Apple's dSYM generation;
the same build completed outside the process sandbox.
