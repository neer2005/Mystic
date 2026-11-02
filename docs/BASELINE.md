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

- **Metal with V-Sync settles into one of two states for a whole run.** Good: every refresh shows a frame, about 99% shown, about 29-36 ms.
  Bad: about 25% of frames dropped before the renderer, gaps of 8.3, 8.3 and 16.7 ms, about 50-59 ms. What picks the state is not known yet, so compare
  both; a single run says little. Smoothest Video landed in the bad state both times.
- With V-Sync off, both runs agree closely, and this remains the only sub-10 ms setup, by Metal's report.
- As expected, V-Sync makes no measurable difference on System, whose timing macOS controls. It reports no shown frames or delay.
- The window was not logged, and full screen has stuck between launches before. TestUFO's own frame rate was not read; about 117 decoded frames a second
  suggests it was moving at 120. One sitting on one network, and "shown" is Metal's `presentedTime`, not a camera.
