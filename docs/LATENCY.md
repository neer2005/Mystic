# Video latency HUD

Use **Latency HUD** in the stream window toolbar to show or hide the overlay.
It updates once a second and lets pointer events through to the video. Hiding it
keeps the bounded collectors active so reopening shows the current rolling window.
The app creates a fresh collector on each stream and clears the snapshot on disconnect.

Each row reports nearest-rank p50 and p95 in milliseconds over at most 600 samples
for that measurement. A dash means no valid samples are available, including host
processing when the host reports zero. Zero-duration assembly is a valid sample:
packets may already have been batched when the engine completes the frame.

| Row | Boundary |
| --- | --- |
| Host processing | Host-reported value, converted from tenths of a millisecond |
| Frame assembly | Engine first-FEC-block receive timestamp to completed-frame enqueue timestamp |
| VideoToolbox decode | Immediately before DecodeFrame to entry into a successful decoded-image callback |
| Decode → renderer | Decoded-image callback entry to renderer enqueue call, including output validation, main-actor scheduling, and sample construction |
| Renderer enqueue | Time spent awaiting the renderer's enqueue result |
| Client submit → enqueue | Entry into the decoder submit callback to successful renderer enqueue completion, including decoder worker wait and compressed-sample construction |

Decode counters include successfully validated output; enqueue counters include only
accepted images. Cancelled flushes and stale generations do not count as enqueues.
Submitted counts frames reserved for decoding, including submissions that subsequently
fail. Counter differences can include in-flight, rejected, stale or coalesced work;
they are not a packet-loss or dropped-frame percentage. Decode/enqueue FPS is the
counter increase divided by actual time between polls. A static Desktop host can
send fewer frames than the configured maximum; these rates are not refresh rates.

The engine clock and local DispatchTime clock have different origins. Only the
engine receive/completion pair is subtracted; all local stages use DispatchTime
uptime in integer microseconds. RTP-derived presentation timestamps only schedule
frames. They cannot establish one-way network transit or capture-to-display latency.
The renderer does not supply scanout timestamps here, so enqueue is explicitly not
"presented," and neither network nor glass-to-glass figures are manufactured.
Host processing and frame assembly are separate measurements; do not add row
percentiles to estimate an end-to-end percentile.

MysticCore owns the platform-neutral bounded accumulators and unit conversion.
MysticStream owns the locked collector and generation checks. Decoder invalidation
changes the generation gate without erasing the current stream's rolling history;
a new stream uses a new collector. The presenter carries each image's local timing
alongside its pixel buffer; telemetry adds no tasks per frame. Snapshot sorting and
observable UI updates run at one-second intervals on the existing media monitor.
Regressed or implausible durations over 60 seconds are omitted rather than wrapped.
The existing C ABI and consumer interfaces are unchanged.

## Validation — 2026-10-27

Xcode 27 / Swift 6.4: 103 tests, 99 passed and four AV1 hardware skips. New tests
cover exact host units, independent clock origins, missing/malformed timings,
bounded rolling percentiles, rate intervals and idle rates, stale generations,
concurrent completions, and fresh-stream reset. The existing H.264 hardware fixture
now verifies all six measurements through an actual display renderer enqueue.

Live Desktop on the paired Big Dawg host showed updating timings, counters and
rates. The toolbar toggle hid and restored the HUD without stopping video. One
observed sample showed about 1.7 ms decode p50 and 2.4 ms client-submit-to-enqueue
p50. These are observations from this session, not performance guarantees or
network/glass-to-glass latency. Local app build and ad-hoc signature verification
also pass. Visual HDR fidelity and physical controller acceptance remain separate.
