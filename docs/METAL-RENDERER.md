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

### Where decoded-to-screen time goes

Big Dawg Desktop, 2026-11-01: Low Latency, 3024×1890 at 120 fps negotiated, about 20 fps of mostly idle content,
fixed 100 Mbps, on a 120 Hz panel. One run each, read at 60 s. Medians in ms, and the session log has these per stream.

| Run | Decoded to screen | To enqueue | For drawable | Encode | GPU | GPU done to shown |
| --- | --- | --- | --- | --- | --- | --- |
| Window, HDR | 22.2 | 0.1 | 0.1 | 0.1 | 0.8 | 20.8 |
| Window, SDR | 22.2 | 0.1 | 0.1 | 0.2 | 0.8 | 20.6 |
| Window, HDR, `displaySyncEnabled` off | 12.0 | 0.1 | 0.1 | 0.2 | 0.7 | 10.5 |
| Full screen, HDR | 14.3 | 0.1 | 0.1 | 0.1 | 1.2 | 12.2 |
| Full screen, SDR | 23.7 | 0.1 | 0.1 | 0.3 | 1.2 | 21.4 |
| Full screen, HDR, `displaySyncEnabled` off | 7.6 | 0.1 | 0.1 | 0.2 | 1.4 | 5.5 |

- **Mystic's own stages take under 2 ms.** Almost all the rest is after the GPU finishes, in the system's path to the panel.
- Turning `displaySyncEnabled` off about halved it in both window and full screen, with more renderer drops
  (18 against 3, and 93 against 36). It is not a setting yet: tearing has not been looked at.
- "Shown" is Metal's `presentedTime`, and whether it means the same with sync off is unconfirmed; a camera would settle it.
- That full screen beat a window with HDR but not with SDR is unexplained. The window state was not logged here, and later
  runs meant to be windowed logged full screen, so treat the window and full screen labels in this table as unconfirmed.
- One idle run each, with no game load. The display layer cannot report this, so it is not compared.

### Display sync on a game

Low Latency on Metal now turns `displaySyncEnabled` off. DRAGON BALL: Sparking! ZERO's title screen, HDR, 120 fps
negotiated, fixed 100 Mbps, 2026-11-01: four 100-second runs of each, read at 30, 60 and 90 s. All eight logged full screen,
including the ones meant to be windowed, for a reason not yet known, so a window is not covered on a game.

| | Decoded to screen p50, ms | p95, ms | Renderer drops at 90 s | Uneven |
| --- | --- | --- | --- | --- |
| Sync off | 5.6-6.8 | 7-18 | 389-651 | 15-72% |
| Sync on | 22-26 | 26-50 | 424-653 | 36-54% |

- About 16 ms less by Metal's own report, with no more drops. Whether it all reaches the panel needs a camera.
- **Tearing has not been looked at,** and this is a title screen with little motion.
- With sync off, shown intervals stop falling on the 8.3 ms steps of the panel, and evenness is no better.
- Stretches with gaps near 100 ms appear with sync on and off, so sync does not cause them. Their cause is not known.

### TestUFO, the standard moving test

TestUFO on Big Dawg's Desktop, Low Latency, HDR, 3024×1890 at 120 fps negotiated, recommended bitrate, 2026-11-01: two 98-second
runs of each, one after the other, figures at 90 s. Window state not logged. By eye, the user found Metal with sync off much more jittery than System.

| | Decoded | Enqueued | Dropped by renderer | Shown | Shown every p50 / p95 / p99, ms | Decoded to screen p50, ms |
| --- | --- | --- | --- | --- | --- | --- |
| Metal, sync off | 10,501-10,558 | 10,413-10,457 | 2,145-2,204 | 8,199-8,299 | 8.4 / 17 / 19 | 7.7-8.0 |
| Metal, sync on | 10,528-10,572 | 10,441-10,488 | 3,827-4,121 | 6,310-6,639 | 8.3 / 17 / 17-75 | 43 |
| System | 10,540-10,667 | 10,423-10,560 | 2,773-4,928 | not reported | not reported | not reported |

- **About 117 fps reached the decoder, and nearly all reached the renderer.** The frames go missing at presentation, not on the network.
- **With sync on, shown gaps sit on the panel's 8.3 and 16.7 ms steps; with sync off they do not.** This fits the
  jitter seen with sync off, but sync on has not been watched yet, and the drop counts of Metal and System may not mean the same thing.
- **Sync on cost about 35 ms here,** against 16 ms on the 60 fps title screen, with "GPU done to shown" at a steady 40 ms. It is
  not frames queuing in Mystic; see below.

### Drawing the newest frame at each refresh, tried and not kept

A `CAMetalDisplayLink` at frame latency 1 drew the newest frame as each refresh came up. Same TestUFO setup, 2026-11-01, medians at the
last reading. It is on the local branch `codex/metal-newest-at-refresh`, not on `main`, because it adds delay.

| | Decoded to screen, ms | GPU done to shown, ms | Shown (reading) | Uneven |
| --- | --- | --- | --- | --- |
| Sync off, as on `main` | 7.3-8.8 | 6.5-7.7 | 5,950 at 60 s; 7,282-8,065 at 90 s | 36-64% |
| New mode, 3 drawables | 33-45 | 29-41 | 5,116 at 60 s; 7,107-8,224 at 90 s | 12-34% |
| New mode, 2 drawables | 46-48 | 40-41 | 4,828-6,294 at 60 s | 5-34% |
| New mode, one present in flight | 44 | 41 | 1,114 at 60 s | 11% |

- The new mode is much more even, as the shown gaps stay on the panel's steps, but costs about 25-40 ms.
- **The delay is not frames queuing in Mystic:** with one present in flight, about 20 shown a second, "GPU done to shown" was still 41 ms.
- Full screen did not remove it. Window state turned out to stick: a run that did not ask for full screen logged it, so
  the earlier TestUFO and refresh runs may have been in full screen too. Why the title screen's sync-on runs were about 21 ms is not known.

## Open problems before Metal can be the default

- **Automatic bitrate** still needs comparing, since these runs used a fixed one.
- **Longer and busier runs:** every run so far was 90 seconds of idle desktop or a title screen.
- **A true 120 fps game** has not been measured; this one ran at 60.
- **Not tried live:** SDR, HLG, Video Size other than Fit, moving between screens, a real game.
- Screen latency needs a camera or timestamp measurement before any claim that Metal matches.
- 4:2:0 chroma is sampled bilinearly without accounting for chroma siting.
