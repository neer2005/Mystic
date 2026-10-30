# HDR and EDR output

Enable HDR in Settings → Video before starting a stream. The host app must
advertise HDR and the Mac must pass the selected codec's 10-bit hardware probe.
The preference requests HDR from the host; it does not relabel SDR video as HDR.

## Native presentation

VideoToolbox decodes into the negotiated IOSurface-backed 10-bit YCbCr format.
PQ/HLG transfer, color primaries, YCbCr matrix and range remain source-defined.
HDR-active callbacks with missing transfer/primaries/matrix tags request video
recovery rather than guessing a color space. Static mastering-display and
content-light metadata are carried when supplied; they are optional, including
for HLG. The presenter constructs its sample description from the tagged image,
preserving these attachments when retiming for either pacing mode.

For actual PQ/HLG images on an EDR-capable destination, the sample-buffer layer
sets `preferredDynamicRange = .high`. SDR, detached/idle presentation and known
SDR destinations use `.standard`. `toneMapMode` remains `.automatic`: macOS owns
output mapping to the screen. Mystic performs no additional pixel conversion,
manual brightness scaling, custom tone map or SDR metadata substitution.

The owning view reads **its window's screen**, rather than the main screen. Window
screen changes and AppKit screen-parameter notifications refresh the destination,
including changes in available headroom. Potential headroom greater than 1
establishes EDR capability. Current headroom can be 1 while an HDR-capable screen
is idle, and is not used to disable the HDR request. Moving between SDR and HDR
screens updates output policy without restarting or renegotiating the host stream.
An unavailable headroom reading is reported as unknown; macOS remains responsible
for safely mapping the output. No HDR request is made while detached.

The latency HUD reports source transfer/primaries, optional static metadata,
destination name, current/potential headroom and requested output mode. These are
tags and API readings, **not measured screen luminance or proof of HDR fidelity**.
It deliberately says “HDR output requested” rather than claiming measured HDR.

## Verification

Automated tests exercise PQ/HLG and SDR transitions, potential versus current
headroom, SDR destination mapping, invalid readings, required color attachments,
native HEVC 10-bit decode/enqueue and metadata propagation, generation reset,
stale-frame rejection, and window notification/attachment/replacement lifecycle.
The existing profile tests also cover HEVC 10-bit 4:4:4 metadata propagation.
The synthetic native test injects display readings; it does not require or prove
physical HDR output. AV1 hardware verification remains pending on a supported Mac.

Use the HDR section in [PLAYTEST.md](PLAYTEST.md) for visual acceptance. HDR/EDR
output is implemented; highlight detail, brightness and color correctness remain
pending real-host/display validation.

## Platform references

- [Apple: CALayer preferredDynamicRange](https://developer.apple.com/documentation/quartzcore/calayer/preferreddynamicrange)
- [Apple: current EDR headroom](https://developer.apple.com/documentation/appkit/nsscreen/maximumextendeddynamicrangecolorcomponentvalue)
- [Apple: potential EDR headroom](https://developer.apple.com/documentation/appkit/nsscreen/maximumpotentialextendeddynamicrangecolorcomponentvalue)

The Xcode 27 `CALayer.h` contract also documents `.high` for focused media,
`.standard` for SDR, the per-layer scope of the setting, and automatic tone mapping.
