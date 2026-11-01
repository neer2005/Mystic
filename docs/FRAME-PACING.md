# Native frame pacing

Settings → Video → Frame Pacing selects **Low Latency**, **Balanced**, **Balanced
with FPS Limit**, **Smoothest Video** or **PC Frame Times** for the next stream. Older preferences default to Low Latency. The choice is captured
with the stream's launch settings and retained through automatic reconnects.
It cannot change during an active/starting/recovering stream.

Low Latency gives each decoded image a presentation time at the renderer's
current clock, without intentional buffering. Balanced maps source PTS deltas
onto the renderer clock with one negotiated frame interval of lead: about 16.7 ms
at 60 fps or 8.3 ms at 120 fps. It preserves source cadence and tolerates modest
arrival jitter at the cost of that extra buffer. Audio playback is unchanged;
real A/V alignment still needs listening/visual validation.

The last three are in-order pacings. None lets a newer frame replace a waiting one that is still fresh: a frame is skipped only once it is over a
frame old and a newer one waits, or when the three-frame mailbox overflows.

- **Balanced with FPS Limit** follows Nightjar's `cap_slot`: each frame gets the slot one frame
  after the last, never before now and never more than one frame away, and a late frame starts the
  slots again. Source timestamps do not move the slots.
- **Smoothest Video** maps source PTS deltas onto the renderer clock like Balanced, behind two
  frame intervals of lead. This is a Mac choice: Nightjar's desktop shows each frame in turn at
  the refresh, while its PyroWave path maps host timestamps with an extra refresh of buffering.

- **PC Frame Times** ports the `schedule` half of Nightjar's `present_clock.rs`: each frame is
  shown at its timestamp on the PC plus a delay, the 97th percentile of how late the last 128 frames
  were ready, plus 0.5 ms. The delay rises at once, falls within seconds and never holds a frame over
  50 ms; the first 250 ms of PC time are shown when ready. The stream's timestamps come from RTP, so
  they are the PC's frame times. The HUD shows the latest frame's hold.

  On a screen with a refresh timeline it also uses `schedule_on_grid`: the delay covers the 75th
  percentile, each frame takes the nearest refresh it can make, and it is released a quarter refresh
  ahead. The stream view's `CADisplayLink` supplies the timeline, at the screen's top rate and only
  in this mode. A frame sharing the previous one's refresh is counted in the HUD.

All modes work on both renderers. On Metal a frame's time becomes `present(_:atTime:)`, and
the in-order modes draw from a first-in, first-out slot of three frames rather than the newest.

The native AVSampleBufferRenderSynchronizer/receiver remains the presentation
path. Source timestamps retain their independent origin; new uncompressed sample
buffers carry renderer-relative timestamps and the negotiated frame duration.
Pixel buffers and HDR attachments are retained without a CPU image copy. This
does not add Metal rendering, refresh-rate switching, VRR control or beam racing.

## Display refresh rate

Each launch tells the host the stream screen's refresh rate x100, as Nightjar's desktop
client does: CoreGraphics's mode rate (59.94 Hz on a 59.94 Hz display; the nominal maximum
where a panel reports 0). It goes in the launch request (`client_refresh_rate_x100`) and the
stream's ANNOUNCE (`clientRefreshRateX100`). A host that reads fractional rates then launches
59.94 rather than 60 when the display rounds to the stream's frame rate, so frames are not
dropped or repeated every 16 seconds; other hosts, and streams at another rate, keep the
integer rate. Not yet tried against a host that reads fractions.

## Bounds and recovery

The mailbox retains at most one pending image, or three in the in-order modes, plus one image in
a suspended drain or enqueue. Past that bound a new decoded image replaces the oldest pending one. Balanced waits
before enqueueing a sample more than one frame ahead of the renderer clock;
while waiting it can discard the held image if a newer one is pending. These
waits and suspended enqueues are cancelled/flushed on generation resets.

Low Latency drops images older than two frame intervals at the presenter.
Balanced allows up to the greater of 100 ms or three intervals for local image
age. It reanchors after long stalls, when a frame comes over two buffers early against
the timeline, or on a negotiated frame-rate change, flushing
old renderer scheduling while preserving the current displayed image. Corrupt,
negative, duplicate and out-of-order timestamps cannot commit source ordering.
One forward timestamp far ahead of the time since the last frame is dropped; repeated jumps request
keyframe/timeline recovery through the existing decoder recovery gate.

Reset/stop clear the displayed image and fence late decoder, wait, enqueue and
metrics completions. A new generation starts with fresh source/renderer anchors.
Settings changes elsewhere cannot change a recovering stream's captured mode.

## Measurements on a game

Big Dawg over the remote route, DRAGON BALL: Sparking! ZERO's title screen (about 56 fps shown), Metal,
HEVC 10-bit HDR, 3024×1890 at 120 fps negotiated, fixed 100 Mbps, on a 120 Hz panel, 2026-11-01. One sitting of
100-second runs, each read at 30, 60 and 90 s; figures cover the last 512 frames at each reading, and counters are totals at 90 s.

| Pacing | Decoded to screen p50, ms | Shown every p95 / p99, ms | Uneven | Late | Shared | Renderer drops |
| --- | --- | --- | --- | --- | --- | --- |
| Low Latency | 21 | 25 / 25-33 | 32-53% | 13 | 0 | 205 |
| Balanced | 32 (one reading) | 100 / 150 | 23% | 117 | 0 | 1 |
| PC Frame Times, no grid, first | 22 | 25 / 25 | 33-36% | 325 | 0 | 79 |
| PC Frame Times, no grid, second | 30-57 | 25-58 / 58-83 | 40-47% | 376 | 0 | 94 |
| PC Frame Times, grid, first | 23-41 | 25-67 / 67-92 | 44-52% | 1,148 | 146 | 104 |
| PC Frame Times, grid, second | 21-22 | 25 / 33 | 31-53% | 1,137 | 188 | 135 |

- **Motion was not more even than Low Latency.** Frames alternated 16.7 and 25 ms on every pacing,
  so about a third to a half of them miss the even two-refresh step. Why is not yet known; a quarter
  refresh, 2 ms at 120 Hz, may be too short a lead for macOS.
- **The grid may cost less delay,** with a median near 22 ms in four of six readings against 22-57 ms without, but
  the spread between runs of the same pacing is as large as the difference. Neither is settled.
- Decoded to screen uses the renderer's `presentedTime`, so it stops at the system's report, not the panel.
- **Balanced reset the video timeline 12 times in 100 s** with "Presentation timestamp discontinuity" and lost 1,214
  frames, and did so once on Desktop. A spike anchored its timeline on late frames, so on-time frames
  looked over 100 ms in the future and were treated as corrupt; smaller shifts made each frame wait until
  the next replaced it. Such frames now realign the timeline; the fix has automated checks, not a new run.
- This is one title screen in one sitting, with no AWDL record for these runs and no camera.

## HUD measurements

The latency HUD now shows:

- Active pacing mode.
- Presenter image queue depth (0–2, or 0–4 in the in-order modes) and its high-water mark.
- Late-to-presenter frames, including late images dropped by policy.
- Presenter drops, with superseded, late and timestamp/order breakdowns.
- Timeline resynchronizations.
- On Metal, how far apart frames were shown and the share that were uneven, from `presentedTime`.
- With PC Frame Times, the latest frame's hold and the refreshes shared with an earlier frame.
- Renderer-reported dropped/corrupted frames, or an em dash when unavailable.

Presenter queue depth does not measure AVFoundation's internal queues. Presenter
counters count Mystic decisions; renderer counters come from AVFoundation and
are shown separately. They must not be added as if they measured disjoint events.
The Decode → renderer timing includes any pacing wait; Renderer enqueue measures
acceptance/backpressure, not physical scanout. Network transit and glass-to-glass
latency remain unavailable.

Renderer metrics are queried asynchronously on their own monitor, so a delayed
metrics query cannot block audio statistics, controller feedback or bitrate
adaptation. Availability/counter behavior follows the platform, including flushes.
See Apple's [receiver enqueue API](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/receiver/enqueue(_:))
and [dropped-frame metric](https://developer.apple.com/documentation/avfoundation/avvideoperformancemetrics/numberofdroppedframes).

## Verification

Pure policy tests cover 60/120 fps, jittered cadence, bounded early scheduling,
late images, duplicate/corrupt PTS, timestamp arithmetic, rate changes and stall
reanchoring. Controlled receiver tests cover native sample PTS/duration, queue
coalescing, suspended-enqueue cancellation, wait cancellation, generation fences
and rate-change flushing. Telemetry tests reject stale counters/metrics. Settings
and reconnect tests cover migration, persistence and the captured mode.

Low Latency and Balanced also run through the real hardware-decoder/display-layer fixture test,
including renderer metrics and clearing on stop. The in-order modes have automated checks of the
policy, mailbox and Metal slot; only PC Frame Times has been seen on a stream. These checks do not establish
smoothness on a visible panel, sustained gaming latency or HDR fidelity. See
[PLAYTEST.md](PLAYTEST.md) for live checks.
