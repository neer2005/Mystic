# Metal renderer

Status: on `main` as an experimental option, off by default: Settings → Video → Renderer. The
display layer stays the default until the open problems below have been tested.

## Why

`AVSampleBufferDisplayLayer` gives no control over the picture or when it reaches the screen.
Upscaling, PTS-driven pacing, VRR and PyroWave all need Mystic to do its own drawing.

## How it fits

`DisplayLayerPresenter` hands retimed frames to a `PresentationReceiver`. `MetalPresentationReceiver`
is a second one, so mailbox, pacing modes, resets, failure recovery, telemetry and input mapping
are the same code on both paths. The presenter's `surface` is the layer the view shows; it is
`videoRect`-sized on both, with Metal's drawable at that rect's size in pixels.

- **No copies.** VideoToolbox's IOSurfaces become Metal textures through `CVMetalTextureCache`.
- **Color.** A shader converts YCbCr to the source's nonlinear RGB using its tagged matrix and the
  pixel format's range. Transfer and primaries are not touched: they become the layer's color space.
- **HDR.** PQ and HLG use `itur_2100_PQ` and `itur_2100_HLG` with `CAEDRMetadata` and the frame's
  mastering and light-level metadata. macOS still owns tone mapping, as `HDR.md` says.
- **Timing.** A frame is presented at once, or at its timestamp when pacing holds it. The render
  queue waits for a drawable first and then draws the newest frame, off the main actor. Metal keeps its own host-time clock, because the display layer's
  synchronizer gets no samples on this path; using it caused repeated timestamp resets.
- **Fallback.** If Metal cannot start, the stream uses the display layer and the session log says so.

## Stages

1. Match the display layer behind a setting (this stage).
2. Measure against the display layer on hosts: latency, dropped frames, SDR and HDR picture.
3. PTS-driven pacing; Balanced with FPS limit and Smoothest video. Built, on both renderers, and
   not yet tried live; see `FRAME-PACING.md`.
4. MetalFX upscaling, with bilinear as the baseline.
5. Make Metal the default. VRR and phase-lock follow; PyroWave stays last.

## Measurements so far

Big Dawg Desktop, 2026-11-01: HEVC 10-bit HDR, 3024×1890 at 120 fps, windowed, Low Latency, overlay
on Debug. One sitting of mostly idle content on a remote address; a first look, not a benchmark.

| | System | Metal, 3 drawables, first 30 s | Metal, 3 drawables, next 30 s |
| --- | --- | --- | --- |
| Rendered / received fps | 118 / 118-120 | 88 / 120 | 119 / 120 |
| Renderer enqueue p50 / p95 ms | 0.07 / 0.29 | 7.64 / 9.37 | 0.77 / 8.37 |
| Decode → renderer p50 / p95 ms | 0.31 / 0.84 | 1.71 / 5.64 | 0.30 / 3.32 |
| Client submit → enqueue p50 / p95 ms | 3.59 / 5.78 | 13.28 / 16.24 | 4.85 / 14.53 |
| Round trip ms | 4-10 | 20 | 5 |

Enqueue times are not like for like: the display layer's returns before the screen is involved,
while Metal's includes waiting for a drawable. Screen latency is unmeasured on both.

### After turning AWDL off, at a fixed bitrate

The same setup a little later, at a fixed 100 Mbps, 90 seconds each, sampled every 30 seconds. Counts
are at the end of the run. `awdl0` was being turned down every 30 seconds and macOS kept bringing it
back, so these runs do not show AWDL's effect.

| | System | Metal |
| --- | --- | --- |
| Rendered fps at 30 / 60 / 90 s | 117 / 112 / 117 | 118 / 100 / 117 |
| Round trip at 30 / 60 / 90 s, ms | 3 / 26 / 4 | 4 / 14 / 3 |
| Video loss | 0% | 0% |
| Decoded / enqueued frames | 10,383 / 10,089 | 10,423 / 8,980 |
| Superseded before the renderer | 294 | 1,437 |
| Dropped by the renderer | 2,499 | not reported |
| Client submit → enqueue p50 / p95 ms | 4.23 / 7.27 | 7.46 / 16.20 |

- Round-trip spikes happen on both, so they come from the network path, not the renderer.
- No loss was seen in these runs, where one earlier run showed 5.1%. AWDL may be involved, but these
  runs cannot say: its state during them is unknown.
- System's rendered figure counts frames accepted, not shown: its renderer dropped about a quarter
  of them. Metal has no such counter, so **neither path's true shown rate is known yet**, and
  System's 117 and Metal's 117 are not the same measurement.

### Newest frame on a free drawable, with shown frames counted

The render queue now takes a drawable first and draws whichever frame is newest, and Metal reports
frames replaced, timed out or never presented as renderer drops. Same setup, fixed 100 Mbps, 90
seconds each, one after the other, with `awdl0`'s status logged every 5 seconds.

| | System | Metal |
| --- | --- | --- |
| "Rendered" fps at 30 / 60 / 90 s | 113 / 119 / 119 | 119 / 120 / 119 |
| Round trip at 30 / 60 / 90 s, ms | 19 / 3 / 3 | 6 / 5 / 5 |
| Decoded / enqueued frames | 10,472 / 10,335 | 10,493 / 10,368 |
| Superseded before the renderer | 137 | 125 |
| Dropped by the renderer | 2,766 | 670 |
| Accepted and not dropped | 7,569 (72%) | 9,698 (92%) |
| Renderer enqueue p50 / p95 ms | 0.08 / 0.31 | 0.03 / 0.06 |
| Client submit → enqueue p50 / p95 ms | 3.77 / 5.91 | 3.45 / 5.21 |

- The enqueue times are now like for like: neither includes waiting for the screen.
- The drop counts are **not known to mean the same thing**: System's comes from AVFoundation's
  `numberOfDroppedFrames`, Metal's from `presentedTime` and frames replaced in the slot. 92% against
  72% is promising, not proof. A camera or per-frame display timing still has to confirm it.
- A display refreshing at or near 120 Hz cannot show every 119.6 fps frame in step, so some drops
  are expected on both.
- **AWDL lines up with the one spike.** A loop ran `ifconfig awdl0 down` every 30 seconds, and macOS
  brought the interface back between runs of it. System's 19 ms ±23 sample fell inside the only long
  active stretch logged (14:25:25-14:25:56); samples with it down read 3-6 ms. One coincidence, so
  suggestive only, and it means these two runs did not see equal network conditions.
- System's drops kept growing after that stretch (681, 1,942, 2,766 at 30, 60 and 90 s), so AWDL does
  not explain the gap in drops. Metal's were 330, 440 and 670.

### A real game at 60 fps

Dragon Ball: Sparking! Zero on its title screen, about 60 fps and 19 Mbps, HDR, fixed 100 Mbps, same
stream settings, one after the other. Figures are the change over 90 seconds of a running stream,
which leaves out the transition into the game.

| | System | Metal |
| --- | --- | --- |
| Decoded / enqueued | 5,414 / 5,398 | 5,473 / 5,441 |
| Superseded before the renderer | 16 | 33 |
| Dropped by the renderer | 322 (6.0%) | 204 (3.7%) |
| Client submit → enqueue p50 / p95 ms (end of run) | 5.53 / 8.95 | 5.21 / 8.52 |
| Renderer enqueue p50 / p95 ms (end of run) | 0.04 / 0.08 | 0.02 / 0.03 |
| Timeline resets | 0 | 0 |

- At a game's own 60 fps the renderers are close; the large gap at 120 fps does not carry over.
- Same caveat on the drop counts. A title screen is also not a battle: motion is gentle.
- **AWDL lined up with every spike here.** With `awdl0`'s status logged every 5 seconds, readings taken
  while it was active showed 11-29 ms round trips on both renderers, including the only loss seen
  (14.5%, on System); the two taken while it was down showed 3 ms. Reading times are approximate, to
  within several seconds, and this is eight readings in one sitting.
- Quit and Start, and resuming a running game, also worked here.

## Open problems before Metal can be the default

- **Automatic bitrate** still needs comparing, since these runs used a fixed one.
- **Longer and busier runs:** every run so far was 90 seconds of idle desktop or a title screen.
- **A true 120 fps game** has not been measured; this one ran at 60.
- **Not tried live:** SDR, HLG, Video Size other than Fit, moving between screens, a real game.
- Screen latency needs a camera or timestamp measurement before any claim that Metal matches.
- 4:2:0 chroma is sampled bilinearly without accounting for chroma siting.
