# Pacing baseline

The figures later changes are compared against, from the session log's `Presentation` lines.

Build `33ecd32`, 2026-11-02. TestUFO on Big Dawg's Desktop, over Wi-Fi with Keep AWDL Off While Streaming on, HEVC 10-bit HDR,
3024×1890 at 120 fps negotiated, recommended bitrate, on a 120 Hz MacBook panel. Each setup ran twice for 98 seconds, the second round in
reverse order, launched with `open`. Counters are at the 90-second reading; ranges cover the 30, 60 and 90-second readings.

| Setup | Run | Decoded | Presenter drops | Renderer drops | Shown | Shown every p50 / p95 / p99, ms | Uneven | Decoded to screen p50, ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Metal, Lowest Latency, V-Sync off | 1 | 10,593 | 74 | 1,294 | 9,208 | 8.3-8.9 / 16-17 / 19-22 | 69-76% | 8.1-8.3 |
| | 2 | 10,598 | 76 | 1,285 | 9,225 | 8.1-8.9 / 17 / 19 | 63-67% | 7.9-8.3 |
| Metal, Lowest Latency, V-Sync on | 1 | 10,543 | 99 | 0 | 10,429 | 8.3 / 8.3 / 8.3 | 0-1% | 29-31 |
| | 2 | 10,597 | 2,738 | 0 | 7,848 | 8.3 / 16.7 / 16.7 | 34% | 53 |
| Metal, Balanced | 1 | 10,595 | 2,476 | 0 | 8,106 | 8.3 / 16.7 / 16.7 | 29-31% | 49 |
| | 2 | 10,609 | 107 | 0 | 10,469 | 8.3 / 8.3 / 8.3 | 0% | 28-35 |
| Metal, Balanced with FPS Limit | 1 | 10,602 | 2,676 | 0 | 7,907 | 8.3 / 16.7 / 16.7 | 33-34% | 55-59 |
| | 2 | 10,598 | 146 | 0 | 10,427 | 8.3 / 8.3 / 8.3-16.7 | 0-2% | 36-44 |
| Metal, Smoothest Video | 1 | 10,602 | 2,692 | 0 | 7,890 | 8.3 / 16.7 / 16.7 | 33% | 52-54 |
| | 2 | 10,605 | 2,685 | 0 | 7,899 | 8.3 / 16.7 / 16.7 | 32-34% | 50-51 |
| System, Lowest Latency, V-Sync on | 1 | 10,588 | 50 | 3,893 | not reported | not reported | not reported | not reported |
| | 2 | 10,710 | 65 | 4,015 | not reported | not reported | not reported | not reported |
| System, Lowest Latency, V-Sync off | 1 | 10,709 | 63 | 3,750 | not reported | not reported | not reported | not reported |
| | 2 | 10,712 | 63 | 3,865 | not reported | not reported | not reported | not reported |

## After skipping a frame when drawables are full

Same setup, two 68-second runs each, in reversed order the second round, figures at 60 s. This replaces the Metal V-Sync rows above; the other rows are unaffected.

| Setup | Run | Decoded | Presenter drops | Renderer drops | Shown | Shown every p50 / p95 / p99, ms | Uneven | Decoded to screen p50, ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Metal, Lowest Latency, V-Sync on | 1 | 7,001 | 60 | 27 | 6,831 | 8.3 / 8.3 / 8.3 | 0% | 30 |
| | 2 | 7,058 | 71 | 38 | 6,860 | 8.3 / 8.3 / 16.7 | 1% | 28 |
| Metal, Balanced | 1 | 7,050 | 67 | 37 | 6,868 | 8.3 / 8.3 / 8.3 | 0% | 29 |
| | 2 | 7,057 | 56 | 68 | 6,844 | 8.3 / 8.3 / 16.7 | 1% | 27 |
| Metal, Smoothest Video | 1 | 7,053 | 31 | 25 | 6,911 | 8.3 / 8.3 / 8.3 | 0% | 30 |
| | 2 | 7,048 | 37 | 53 | 6,877 | 8.3 / 8.3 / 8.3 | 0% | 32 |

By eye, the user found Metal with V-Sync on smooth on TestUFO, 2026-11-02. All six stayed in the good state. Waiting for a drawable marked the bad state: about 8.5 ms median against 0.04 ms. Skipping a frame that waited over 4 ms
lets the queue drain. Six short runs are not proof it can never return. FPS Limit shares this path and was not rerun.

## Two drawables with V-Sync

Metal, Lowest Latency, V-Sync on, same setup, two 68-second runs each, alternating, figures at 60 s. Two is now the V-Sync setting, as SDL's double
buffering on Windows; SDL on Metal leaves Apple's default of three. Without V-Sync it stays three, not tested with two.

| Drawables | Run | Decoded | Renderer drops | Shown | Shown every p50 / p95 / p99, ms | Uneven | Decoded to screen p50 / p95, ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3 | 1 | 6,994 | 44 | 6,792 | 8.3 / 8.3 / 8.3 | 0% | 30.2 / 33.0 |
| | 2 | 7,049 | 18 | 6,891 | 8.3 / 8.3 / 8.3 | 0% | 26.6 / 34.5 |
| 2 | 1 | 7,051 | 395 | 6,520 | 8.3 / 8.3 / 16.7 | 4% | 26.2 / 28.0 |
| | 2 | 7,050 | 134 | 6,782 | 8.3 / 8.3 / 16.7 | 2% | 25.7 / 27.5 |

Two takes 1-4 ms off the median and about 5-7 ms off the p95, and costs more skipped frames and a little evenness. Not yet looked at by eye.

## Notes on the first table

- **Metal with V-Sync settles into one of two states for a whole run.** Good: every refresh shows a frame, about 99% shown, about 29-36 ms.
  Bad: about 25% of frames dropped before the renderer, gaps of 8.3, 8.3 and 16.7 ms, about 50-59 ms. What picks the state is not known yet, so compare
  both; a single run says little. Smoothest Video landed in the bad state both times.
- With V-Sync off, both runs agree closely, and this remains the only sub-10 ms setup, by Metal's report.
- As expected, V-Sync makes no measurable difference on System, whose timing macOS controls. It reports no shown frames or delay.
- The window was not logged, and full screen has stuck between launches before. TestUFO's own frame rate was not read; about 117 decoded frames a second
  suggests it was moving at 120. One sitting on one network, and "shown" is Metal's `presentedTime`, not a camera.
