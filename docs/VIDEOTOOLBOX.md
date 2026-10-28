# VideoToolbox integration

`MysticStream` is a macOS-only Swift package product. `MysticCore` and `MysticKit`
remain free of Apple frameworks, and the Linux package graph excludes the stream
library and its tests. The engine ABI and consumer protocols are unchanged.

## Connecting the module

Initialize the presentation surface and probe capabilities on the main actor:

```swift
import MysticKit
import MysticStream

let capabilities = await VideoCapabilities.probe()
let presenter = DisplayLayerPresenter(onFailure: { message in print(message) })
let decoder = VideoToolboxDecoder(
    capabilities: capabilities,
    presenter: presenter,
    log: { message in print(message) }
)
var configuration = StreamConfiguration()
configuration.supportedVideoFormats = capabilities.supportedFormats
```

Attach `presenter.layer` to an AppKit view and manage its bounds on the main actor.
Retain the presenter and decoder for the stream's lifetime. Pass `decoder` as
`video` to `StreamingEngine.start` from a background execution context;
engine startup blocks. This module does not own a window, discovery, pairing,
audio, or the host's launch/quit lifecycle.

Probe once during subsystem initialization. An empty supported mask means the
caller must surface the exclusion reasons and decline to start video streaming.
PyroWave formats always have explicit exclusion reasons until the Metal backend
exists. Unknown formats and packed-chroma layouts fail setup.

## Capability and fidelity contract

The format bits match the pinned Nightjar revision `f449b5d`. The probe requires
hardware session creation, verifies hardware selection, decodes a synthetic
fixture, checks dimensions, IOSurface, exact pixel format and PTS, checks color
transfer metadata, and enqueues the result in a display layer. H.264, HEVC, AV1,
8/10-bit and 4:2:0/4:4:4 variants are evaluated separately. Ten-bit probes use PQ.
The report records why each rejected variant was excluded.

Probes establish profile support at 64×64, not maximum stream throughput or display
HDR luminance. Actual stream configuration is validated again when its first
keyframe creates a decompression session. There is no software fallback, chroma
reduction, or forced SDR conversion. HDR-active frames require 10-bit negotiation
and PQ/HLG transfer metadata. Correct visual HDR output still requires a suitable
window/display and visual validation; an offscreen readiness check cannot prove it.

CoreMedia consumes encoded NAL parameter sets with emulation-prevention bytes
intact. SPS inspection removes those bytes only in a temporary parser copy to
validate chroma and bit depth. AV1 has a separate bounded OBU/sequence-header
parser and av1C builder; it never passes through Annex B conversion. AV1 unspecified
color values stay unspecified, and unsupported explicit colorimetry fails clearly.

HEVC/H.264 static HDR SEI and AV1 HDR metadata are carried across dependent frames.
AV1 mastering metadata is converted from AV1 fixed-point units and RGB order to
Core Video's HEVC layout and units. The resulting pixel-buffer attachments flow
into the uncompressed presentation sample. VideoToolbox supplies the stream's
VUI color attachments; no SDR tags are substituted for missing HDR tags.

## Ownership, timing, and recovery

The consumer copies borrowed compressed data before returning to the engine.
CoreMedia owns each submitted block buffer. Decoded images retain IOSurface-backed
pixel buffers, with no CPU pixel copy in the presentation path.

Consumer operations serialize on a private queue. At most three decode operations
are in flight. Queue overflow, invalid configuration, and reference loss request
an IDR. Asynchronous decoder/display failures immediately request a keyframe and latch
recovery before the next submission. See [RECOVERY.md](RECOVERY.md). Recovery discards dependent frames until a usable keyframe arrives.
New parameter sets rebuild the session; keyframe dimension changes are accepted.

PTS conversion uses integer microseconds relative to the first frame of a session.
The presenter anchors a render synchronizer to the first accepted image and uses
the macOS 27 receiver API for backpressure. A mailbox coalesces waiting images to
the newest frame; stale images and timestamps outside a 100 ms scheduling window
are dropped. It retains at most one waiting image plus an enqueue in progress.

Stop/cleanup invalidate session generations, cancel pending presentation work,
and clear the displayed image. Old callbacks cannot contaminate a new generation.
The raw-output initializer supports testing or an alternative presenter: callbacks
run on decoder threads, must return promptly, and must not synchronously invoke
the decoder's lifecycle methods. Alternative presenters must honor generation
resets and forward presentation failures to `presentationFailed`.

## Verification

Run `swift test` on macOS with the engine static archive built (see ENGINE-BUILD.md).
Hardware decoding needs access to VideoToolbox services; a process sandbox can
make session creation fail with OSStatus -12911 even when hardware exists. The
engine connection-failure test additionally needs loopback networking.

The suite checks parser bounds, exact timestamps, parameter-byte preservation,
HDR metadata conversion, recovery, bounded work, and stale generation rejection.
Hardware tests decode each supported fixture, test dependent frames and changed
parameter sets, and exercise actual display/clear behavior. Unsupported hardware
profiles produce explicit XCTest skips; AV1 syntax/configuration checks run even
when the Mac lacks an AV1 hardware decoder.

Live-host callback ordering, sustained throughput, and visual HDR fidelity remain
separate validation steps requiring a host and a visible presentation window.
