# Metal renderer

Status: in progress on the `codex/metal-renderer` branch. Off by default: Settings → Video →
Renderer. The display layer stays the default until the two have been compared on real hosts.

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
- **Timing.** A frame is presented at once, or at its timestamp when pacing holds it. `nextDrawable`
  runs off the main actor. Metal keeps its own host-time clock, because the display layer's
  synchronizer gets no samples on this path; using it caused repeated timestamp resets.
- **Fallback.** If Metal cannot start, the stream uses the display layer and the session log says so.

## Stages

1. Match the display layer behind a setting (this stage).
2. Measure against the display layer on hosts: latency, dropped frames, SDR and HDR picture.
3. PTS-driven pacing; Balanced with FPS limit and Smoothest video.
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

## Open problems before Metal can be the default

- **Throughput is not yet steady.** Runs move between about 88 and 119 fps, and round trip moves with
  them. The cause is unknown. Two drawables stayed near 88 fps in the one-minute run measured.
- **Automatic bitrate fell further on Metal** (48-64 Mbps with no menu open, against 100 on System),
  which needs a repeat with bitrate fixed. It fell on System too (64 Mbps) once a menu was open.
- **Not tried live:** SDR, HLG, Video Size other than Fit, moving between screens, a real game.
- Screen latency needs a camera or timestamp measurement before any claim that Metal matches.
- Renderer-reported drop counters do not apply, and drawable timeouts are not counted, so a frame
  missed that way is invisible in the overlay.
- 4:2:0 chroma is sampled bilinearly without accounting for chroma siting.
