# Stream health

**Stream → Why Did My Stream Stutter?…** (⌃⌘H, or the Stream Health toolbar item from
Customize Toolbar) explains stutter from measurements the stream already collects. It
runs Nightjar's own stream doctor, `nightjar_policy::health::StreamHealth` and
`BitrateTrial`, the code behind Android's and the desktop client's report, so findings
match Nightjar's for the same evidence.

## What feeds it

Once a second, while streaming, the media monitor gives the engine one stats tick:

| Input | Source |
| --- | --- |
| Frame loss | Engine: frames completed and dropped since the last tick |
| Round trip, poor connection, held input | Engine: `Session::stats()` |
| Jitter, late frames, received frame rate | Engine: each frame's RTP time and arrival, on the frame path |
| Decode | Mystic: VideoToolbox decode median from the rolling telemetry |
| Host processing p95 | Mystic: the frame header's host processing time |
| Display wait p95 | Mystic: decoded to renderer |
| Released and shown rates | Mystic: decoded and enqueued frames per second |
| Thermal level | macOS `ProcessInfo.thermalState` (fair 1, serious 2, critical 3) |

Mystic's timings come from its rolling 600-frame telemetry rather than Nightjar's
two-second window, so they react more slowly to a short spike. Nothing is recorded to
disk or sent anywhere; Copy Report puts only the displayed text on the clipboard.

## The report

It covers the last 30 seconds of samples, and network stalls of the last 20 minutes for
the rhythm check. Findings are network, decode, host, presentation, temperature, bursts
and repeating stalls; each has Nightjar's advice, worded for a Mac. The largest observed
values follow. With fewer than three recent samples it says there is not enough video to
assess; with no findings it says so, without claiming every stage is healthy.

The Latency HUD shows the same network figures: round trip and its variance, jitter,
frame loss and the received frame rate, plus a poor-connection or held-input note.

## The bitrate trial

When network findings repeat and the host changes its bitrate during a stream, the report
offers **Try a Lower Bitrate**: 20 % below the encoder's live bitrate (read from the
host's server info, never the saved setting), at least 500 kbps, for this session only.
**Undo Bitrate Trial** returns to the bitrate before it. Automatic bitrate, a manual rate
change or a reconnect replaces the trial, and no trial is offered while automatic bitrate
runs or another host action is in flight.

## Not yet

- The report shown after a stream that ended with findings (Nightjar's desktop does this).
- Wi-Fi facts (band, signal, link rate). macOS gives them through CoreWLAN, which needs
  location permission for some fields.
- Stall start times are kept per connection; a reconnect starts the 20-minute history over.
