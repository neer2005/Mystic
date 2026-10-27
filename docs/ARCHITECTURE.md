# Architecture

## Why a hybrid, not a rewrite

Nightjar's `protocol/` workspace is 104,902 lines of Rust:

| crate | lines | role |
| --- | --- | --- |
| `desktop` | 41,462 | Windows/Linux UI — **discarded** for Mystic |
| `client` | 34,352 | streaming client: decode, present, audio, input |
| `core` | 8,388 | protocol engine |
| `vendor` | 9,141 | vendored dependencies |
| `android` | 3,711 | Android glue — discarded |
| `policy` | 3,199 | bitrate/pacing policy |
| `difftest` | 2,118 | differential testing harness |
| `cli` | 2,086 | command-line front end |
| `ffi` | 445 | **C ABI — the integration point** |

A Swift rewrite of that is a year of work for no user-visible gain. A Swift rewrite of
`core` alone is plausible later; a rewrite of the whole thing is not.

So: keep the engine, replace the platform layer. The split follows where Apple-specific
work pays off.

## Layer diagram

```
┌──────────────────────────────────────────────────────────┐
│ MysticApp (SwiftUI)                                      │
│   host list · library · settings · stats overlay         │
├──────────────────────────────────────────────────────────┤
│ MysticStream (Swift)                                     │
│   session lifecycle · VideoToolbox · Metal · audio · in  │
├──────────────────────────────────────────────────────────┤
│ NightjarEngine (Rust, GPL-3.0, via ffi → xcframework)    │
│   RTSP · control stream · crypto · RTP · FEC · depacket  │
└──────────────────────────────────────────────────────────┘
```

Rules:

- The engine never owns a window, a decoder, or a device. It owns bytes and state.
- Swift never parses protocol bytes; if it needs a field, the FFI grows an accessor.
- Anything with a GPU or UI handle lives in Swift.

## MysticCore

Platform-neutral, Foundation-only, builds on Linux. This is where logic that benefits
from a fast test loop lives.

- `StreamDescription` — parser for the host's RTSP `DESCRIBE` answer: media sections,
  payload mappings, `fmtp` parameters, `x-ss-*` capability extensions. Negotiation
  decisions read off this.
- `LatencyStats` / `SessionLatency` — per-stage latency histograms (network,
  depacketize, decode, present, glass-to-glass) with nearest-rank percentiles and a
  frame-to-frame jitter metric. Fixed-size ring buffers: the streaming path must not
  allocate per frame.

## Capture and present path

- **VideoToolbox** for H.264, HEVC and AV1 (hardware AV1 on M3 and later), decoding
  into IOSurface-backed `CVPixelBuffer`s so the frame never leaves the GPU.
- **Presentation** via `AVSampleBufferDisplayLayer` first, with a Metal path behind a
  flag. The Metal path exists for control over pacing and for 4:4:4/HDR composition;
  it is only enabled if measurement shows the layer is the bottleneck.
- **PyroWave** is decoded with Metal compute shaders (MSL). Upstream decodes it with
  Vulkan, which does not exist on macOS. This is the largest single piece of new
  engineering in the project and the main reason Mystic can beat other Mac clients on
  quality-per-bit rather than only on latency.

## Latency accounting

Every stage records its own duration, so a regression is attributable:

1. host encode timestamp (from the engine) →
2. local receive (network)
3. RTP reassembly (depacketize)
4. decoder in → out (decode)
5. present → visible (present)

Reported as p50/p95/p99 per stage, plus a glass-to-glass figure validated against a
high-speed camera capture. Numbers are published with their method; latency claims
without a method are worthless.

## Open decisions

- Whether the Rust engine is linked statically (simpler, one binary) or as a dylib
  inside the app bundle (easier to update independently). Static is the default.
- Whether the Metal renderer replaces `AVSampleBufferDisplayLayer` for all codecs or
  only for PyroWave and 4:4:4 streams.
- Whether `core` is eventually ported to Swift. Deferred until the app ships.
