# Native frame pacing

Settings → Video → Frame Pacing selects **Low Latency** or **Balanced** for the
next stream. Older preferences default to Low Latency. The choice is captured
with the stream's launch settings and retained through automatic reconnects.
It cannot change during an active/starting/recovering stream.

Low Latency gives each decoded image a presentation time at the renderer's
current clock, without intentional buffering. Balanced maps source PTS deltas
onto the renderer clock with one negotiated frame interval of lead: about 16.7 ms
at 60 fps or 8.3 ms at 120 fps. It preserves source cadence and tolerates modest
arrival jitter at the cost of that extra buffer. Audio playback is unchanged;
real A/V alignment still needs listening/visual validation.

The native AVSampleBufferRenderSynchronizer/receiver remains the presentation
path. Source timestamps retain their independent origin; new uncompressed sample
buffers carry renderer-relative timestamps and the negotiated frame duration.
Pixel buffers and HDR attachments are retained without a CPU image copy. This
does not add Metal rendering, refresh-rate switching, VRR control or beam racing.

## Bounds and recovery

The mailbox retains at most one pending image plus one image in a suspended drain
or enqueue. New decoded images replace an older pending image. Balanced waits
before enqueueing a sample more than one frame ahead of the renderer clock;
while waiting it can discard the held image if a newer one is pending. These
waits and suspended enqueues are cancelled/flushed on generation resets.

Low Latency drops images older than two frame intervals at the presenter.
Balanced allows up to the greater of 100 ms or three intervals for local image
age. It reanchors after long stalls or a negotiated frame-rate change, flushing
old renderer scheduling while preserving the current displayed image. Corrupt,
negative, duplicate and out-of-order timestamps cannot commit source ordering.
One implausible forward timestamp is dropped; repeated forward jumps request
keyframe/timeline recovery through the existing decoder recovery gate.

Reset/stop clear the displayed image and fence late decoder, wait, enqueue and
metrics completions. A new generation starts with fresh source/renderer anchors.
Settings changes elsewhere cannot change a recovering stream's captured mode.

## HUD measurements

The latency HUD now shows:

- Active pacing mode.
- Presenter image queue depth (0–2) and its high-water mark.
- Late-to-presenter frames, including late images dropped by policy.
- Presenter drops, with superseded, late and timestamp/order breakdowns.
- Timeline resynchronizations.
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

Both modes also run through the real hardware-decoder/display-layer fixture test,
including renderer metrics and clearing on stop. These checks do not establish
smoothness on a visible panel, sustained gaming latency or HDR fidelity. See
[PLAYTEST.md](PLAYTEST.md) for live checks.
