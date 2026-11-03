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
The decoder reuses PCM buffers and honors the negotiated Opus mapping in Windows
speaker-mask order. Stereo remains stereo. For a 5.1/7.1 stream, Mystic reads the
actual output device's configured speaker layout (preferred channel layout, or a
named engine format). A channel count alone is insufficient: unknown/discrete
interface channels do not imply surround speaker assignments.

Named tags, bitmaps and explicit channel descriptions are resolved into speaker
roles. With all required speakers available, PCM is reordered into that physical
layout without downmixing or normalizing surround levels. LFE stays independent.
Windows 7.1 orders rear before side channels; Apple's MPEG 7.1 C orders sides before
rears. These are mapped explicitly, including Windows-style bitmaps with direct
surround labels. A 5.1 stream on a configured 7.1 output leaves the unused rear
pair silent; a 5.1 rear-only speaker pair is also supported. Stereo streams do not
invent center, LFE or surround output.

Unsupported/unlabeled destinations and insufficient layouts (including a 7.1
stream on a 5.1 output) fall back to stereo. If a multichannel graph cannot start,
Mystic tries a stereo graph before spending a retry. Audio settings report the
actual selected mode and fallback reason. Output changes re-evaluate the layout
without renegotiating the host stream. Only configured six/eight-channel outputs
are eligible; larger generic interfaces, height/object audio, compressed
passthrough and virtual headphone surround are not implemented. Configure speakers
in macOS Audio MIDI Setup; Mystic never modifies those settings.

In stereo fallback, center and corresponding surrounds use 0.707
weights, rear center uses 0.5, and LFE is omitted because there is no crossover.
Surround coefficients are normalized with fixed headroom to avoid clipping.
Stereo channel gain is unchanged. LFE omission applies only to downmixing, not
discrete output.

A missing packet (`nil`) asks libopus for concealment using the negotiated frame
length. A malformed nonempty packet is logged with rate limiting and treated as
lost. Invalid sample rates, channel maps, masks, or packet durations fail setup
instead of starting a silent stream. Setup supports the engine's 48 kHz format.

## Real-time output and controls

AVAudioEngine renders a labeled noninterleaved 48 kHz stereo or multichannel source through its
mixer/output converter. The system engine handles output-device rate conversion.
The render callback calls a Rust single-producer/single-consumer PCM ring reader;
it performs no allocation, lock, dispatch, decode, or logging.

The ring holds at most 8192 frames of 1–8 channels. When consuming a backlog above 2880
frames (60 ms), it skips older queued frames; producer overflow drops newly decoded
output without skipping Opus state advancement. Volume
and mute use an atomic ring gain with a 128-frame render-side ramp, independent of
Core Audio parameter timing and without changing the Mac's system volume.

Late packets are filled rather than played as silence, by Nightjar's playout rule. A packet
that arrives on an empty queue (the first, after a route change, or after an outage) is led with
silence: Nightjar's 10 ms past one read of the output (the device's I/O buffer, read from Core
Audio, 512 frames when unknown), about 21 ms on a Mac's speakers. The render thread only reads
the ring, so the rest of the rule runs on the decode queue: a timer at the packet rate sees a
packet that is late while the ring holds less than the output's next read and fills its time
with Opus concealment. The packet whose time concealment played is skipped when it arrives, so
a late burst never adds latency; the HUD's audio line counts them as "late skipped".
Concealment stops after 100 ms of outage, and what arrives after that is new, not late.

The first version had no lead and concealed below 10 ms. A Mac's output reads 512 frames at a
time, so the ring sat below that mark most of the time, and any 5 ms packet arriving a little
late was replaced by concealment and then thrown away: with 3 ms of Wi-Fi jitter, about 12
packets a second (6 %), which sounded choppy. With the lead, ordinary jitter conceals nothing;
only a stall longer than the cushion (Wi-Fi's 30-60 ms ones) still does, as it must.

Playback follows the Mac's default audio output. Core Audio listeners observe
default-output/device-list changes and the current device's alive, nominal-rate,
output-stream-configuration and preferred-speaker-layout changes. The engine's configuration notification
provides a second signal. This does not change the Mac's selected output, system
volume, or microphone device. Native output metadata reports the engine's actual
device and format, rather than assuming the default did not change during setup.

Route notifications stop the old graph immediately and coalesce for 150 ms before
creating a fresh graph/ring. Queued old audio is discarded. Output creation gets
one attempt plus three one-second retries (each with stereo fallback if needed). After that, the status is unavailable,
while device monitoring remains active. A later device event or **Retry Audio**
starts a fresh bounded attempt sequence. Retry Audio appears in the stream toolbar
and Audio settings when playback is unavailable, and Stream → Retry Audio Output is
enabled then. Recovery is confined to audio;
the host stream and video session are not restarted.

Setup validates the negotiated Opus format without opening the audio device.
Output starts with the consumer's start callback. A missing/unavailable device at
start therefore does not abort an otherwise valid stream. During an output outage
Opus decoding and concealment continue, but decoded PCM is discarded, preserving
decoder state without accumulating old sound. Volume/mute are retained across
rebuilds. A new ring's render-side gain is initialized before the audio thread
starts, so mute is effective from its first sample.

Stop/cleanup cancel pending rebuilds/retries and remove device/engine listeners.
Lifetime and output revisions reject late callbacks from older sessions and
retired engines. The source block retains its ring state until the engine releases
it, so a late render cannot read freed storage. If device monitoring cannot be
registered, engine notifications and manual retry remain available; a diagnostic
explains the monitoring failure.

The app provides Stereo, 5.1, and 7.1 host requests, consistent in
both the HTTP launch and RTSP stream configuration. It defaults to Stereo, 80%
application volume, unmuted. Volume/mute remain available during playback; host
layout changes apply to the next session. Audio statistics show output state,
device name/rate, discrete/downmix mode and fallback reason, decoded/concealed packets, rendered frames, queued milliseconds,
successful output restarts and PCM discarded during output changes. Render/drop/
underrun counters accumulate across output rebuilds and reset at the next setup.
The queued count refers only to the current ring. They indicate pipeline activity,
not proof that a listener can hear the selected physical output.

## Validation

- Synthetic independent channel tones verify Opus decoding and 5.1 routing/downmix.
- Dedicated 7.1 Opus tones verify LFE and separation of all side/rear speakers;
  core tests cover arbitrary output order, 5.1 on 7.1 and conservative fallback.
- Native offline six/eight-channel graphs verify each plane, including nonstandard
  speaker order, 44.1/48/96 kHz conversion, mute and stereo-only source isolation.
- Controlled route transitions verify 7.1 → headphones → 7.1 without decoder reset,
  with gain retention and stale callbacks from failed surround graphs rejected.
- Packet-loss and malformed-packet tests cover concealment and buffer bounds.
- An offline AVAudioEngine test verifies actual source-node rendering and mute.
- Native offline graphs verify 48 kHz stream conversion to 16, 44.1 and 96 kHz
  outputs, and silence from the first sample of a newly muted output.
- Native Core Audio listener registration/refresh/cleanup is exercised without
  changing the selected physical device.
- Controlled output tests use real Opus packets and PCM rings to check notification
  coalescing, stale-audio discard, cumulative statistics, gain retention, exhausted
  retry budgets, later device/manual recovery, continuing decoder state during an
  outage, and old-session/engine callback rejection. They do not simulate physical
  Bluetooth or HDMI driver behavior.
- Core tests verify mono/stereo passthrough, speaker routing, LFE omission, headroom,
  bad masks, insufficient storage, and non-finite samples.
- Rust tests exercise ring overflow, backlog skipping, zero-fill, gain/mute, and a
  concurrent producer/consumer ordering stress test for stereo and eight channels.
- C smoke tests exercise Opus ownership, nil-packet concealment, buffer validation,
  stereo/multichannel ring layout, and statistics across ABI 2. The multichannel
  constructor/planar reader are additive symbols; existing signatures and struct
  layouts remain unchanged. Rebuild the static archive with the app.

Run `engine/scripts/test-c-abi.sh` and the Xcode `Mystic-Package` test suite. Core
Audio service access is required even for the offline engine test; a restricted
process sandbox can prevent audio component creation. Live listening and device
switch behavior require the host and the user's selected audio output.

Platform contracts: [Apple engine configuration notifications](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange)
and [Core Audio property listeners](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)).
Speaker references: [Apple MPEG 5.1 order](https://developer.apple.com/documentation/coreaudiotypes/kaudiochannellayouttag_mpeg_5_1_a)
and [preferred device channel layouts](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertypreferredchannellayout).

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

## Sound on the PC

Session and Graphics → Stream shows the host's **Night Mode** and **Headphone Surround** when it offers them to this device. They are read when the panel opens and change this stream only; nothing is saved. A setting the host applies later says so, such as Headphone Surround's "Applies next stream".
