# Opus audio playback

`AudioPlayer` implements the existing `AudioConsumer` lifecycle and is passed to
`StreamingEngine.start` alongside the video decoder. It uses the same launch key,
IV, and transport negotiation as the video session; Nightjar handles audio RTP,
reordering, FEC, and decryption.

## Decode and channel layout

The C bridge is now **ABI 2**. `MysticAudioSetup` includes the sample rate, Opus
stream count, coupled stream count, and eight-entry channel map. Rebuild the engine
archive and Swift app together. Old/new libraries are rejected by the ABI check.

Opus 0.4.0 wraps the libopus source bundled in opusic-sys 0.7.6. Cargo.lock pins the
versions/checksums; no Homebrew Opus dylib or runtime download is required. Building
requires CMake and Rust 1.82 or newer. License notices ship in the app resources.

Decoding runs synchronously on the serialized audio consumer queue. Borrowed
packet memory is consumed before the callback returns; no packet pointer escapes.
The decoder reuses PCM buffers and converts negotiated mono/stereo/5.1/7.1 layouts
to stereo. The supplied Opus mapping is honored, followed by speaker-mask-based
mixing in Windows channel order. Center and corresponding surrounds use 0.707
weights, rear center uses 0.5, and LFE is omitted because there is no crossover.
Surround coefficients are normalized with fixed headroom to avoid clipping.
Stereo channel gain is unchanged. This is a stereo-output milestone, not discrete
multichannel speaker output.

A missing packet (`nil`) asks libopus for concealment using the negotiated frame
length. A malformed nonempty packet is logged with rate limiting and treated as
lost. Invalid sample rates, channel maps, masks, or packet durations fail setup
instead of starting a silent stream. Setup supports the engine's 48 kHz format.

## Real-time output and controls

AVAudioEngine renders a standard noninterleaved 48 kHz stereo source through its
mixer/output converter. The system engine handles output-device rate conversion.
The render callback calls a Rust single-producer/single-consumer PCM ring reader;
it performs no allocation, lock, dispatch, decode, or logging.

The ring holds at most 8192 stereo frames. When consuming a backlog above 2880
frames (60 ms), it skips older queued frames; producer overflow drops newly decoded
output without skipping Opus state advancement. Underruns are zero-filled. Volume
and mute use an atomic ring gain with a 128-frame render-side ramp, independent of
Core Audio parameter timing and without changing the Mac's system volume.

A device configuration notification rebuilds the graph with a fresh ring, avoiding
stale audio after a route change. If output recreation fails, three one-second
retries are bounded to the current lifecycle generation. Stop/cleanup cancel those
retries and remove observers. The source block retains its ring state until the
engine releases it, so a late render cannot read freed storage.

The app provides Stereo, 5.1 → Stereo, and 7.1 → Stereo host requests, consistent in
both the HTTP launch and RTSP stream configuration. It defaults to Stereo, 80%
application volume, unmuted. Volume/mute remain available during playback; host
layout changes apply to the next session. Audio statistics show decoded/concealed
packets, rendered frames, and queued milliseconds. They indicate pipeline activity,
not proof that a listener can hear the selected physical output.

## Validation

- Synthetic independent channel tones verify Opus decoding and 5.1 routing/downmix.
- Packet-loss and malformed-packet tests cover concealment and buffer bounds.
- An offline AVAudioEngine test verifies actual source-node rendering and mute.
- Core tests verify mono/stereo passthrough, speaker routing, LFE omission, headroom,
  bad masks, insufficient storage, and non-finite samples.
- Rust tests exercise ring overflow, backlog skipping, zero-fill, gain/mute, and a
  concurrent producer/consumer ordering stress test.
- C smoke tests exercise Opus ownership, nil-packet concealment, buffer validation,
  stereo ring layout, and statistics across ABI 2.

Run `engine/scripts/test-c-abi.sh` and the Xcode `Mystic-Package` test suite. Core
Audio service access is required even for the offline engine test; a restricted
process sandbox can prevent audio component creation. Live listening and device
switch behavior require the host and the user's selected audio output.

## Live result — 2026-10-27

Desktop streamed from the paired Rubylight host with stereo audio. Mystic showed
more than 2600 decoded packets, no concealed packets at the sampled observation,
and about 40 ms of queued PCM. The user confirmed hearing host audio through the
Mac. Physical listening, automated render/mute checks, and the stereo/surround
fixture checks passed; output-device switching and live surround remain unverified.

## Microphone forwarding

Mac microphone capture and encrypted Rubylight/Apollo passthrough are now available
as a separate opt-in path. Enable Use Mac Microphone before starting a stream;
Mute Microphone is independent of playback Mute. The user confirmed the Windows
input meter responds to the Mac mic on Big Dawg. See [MICROPHONE.md](MICROPHONE.md).
