# Mac microphone passthrough

Host audio playback and Mac microphone forwarding are separate paths. Before this
module, Mystic implemented playback only; enabling host audio could not transmit
the Mac's mic.

In Audio settings or Stream Details, enable **Use Mac Microphone** before starting
Desktop. Allow macOS microphone access. The stream toolbar reports whether the
host negotiated the encrypted microphone stream and shows sent-packet counts.
**Mute Microphone** controls outbound capture independently of playback Mute.
The host application must use its virtual microphone input for this audio; a local
physical host microphone is a different device. If permission is denied, enable
Mystic in System Settings → Privacy & Security → Microphone, or disable passthrough.

Capture starts only after encrypted mic negotiation succeeds. Nightjar owns the
mono Opus UDP format, AES encryption, sequence numbers and host address/port. No
unencrypted fallback is provided. If unsupported, the video stream remains usable
and microphone status explains the missing negotiation. Capture errors stop only
the mic. Disconnect/quit stop capture before releasing the streaming session.
Nothing is recorded to a file or logged as raw PCM/encoded packet contents.

## Pipeline and ownership

The default macOS input feeds an AVAudioSinkNode at the hardware's sample rate.
The sink copies borrowed float PCM's first input channel to a preallocated atomic
SPSC ring; it performs no encoding, networking, dispatch, allocation or locking.
The ring holds at most 65,536 mono samples, and the consumer skips backlog beyond
100 ms. A mute epoch tags samples so overlapping producer work cannot revive a
previous mute epoch's PCM. Read/encode/control/free calls belong to the session
worker; the producer must stop before its ring can be freed.

A 10 ms worker timer processes at most four native-rate 20 ms blocks per tick.
AVAudioConverter resamples to 48 kHz mono. Partial output accumulates into exactly
960 samples per Opus packet (20 ms, VoIP application, 32 kbps). Encoding and UDP
send execute directly on that same serial worker; there is no growing queue of
per-packet tasks. Mute discards captured samples and resets conversion and codec
state before resume. Input configuration changes rebuild the capture pipeline;
a failure is reported instead of silently continuing with stale PCM. No output
loopback or local sidetone is connected.

The new C entry points are additive to ABI 2. The existing microphone negotiation
flag and consumer protocols are unchanged. The app declares NSMicrophoneUsageDescription.
The preference is off by default, and its absence in older settings documents
preserves all existing stream defaults.

## Validation

Xcode 27 / Swift 6.4: 122 tests, 118 passed, four AV1 hardware skips. Tests feed
synthetic tones at 44.1, 48 and 96 kHz through the actual conversion and Opus path,
decode the resulting mono packets, and verify nonzero audio, 960-sample output,
and no retained output after mute/resume. Other tests cover permission denial
preventing host launch, older preference compatibility, repeated stop without
opening a mic, and session sends before start. Rust: 13 tests passed; C ABI smoke
passed, including microphone availability and invalid payload handling.

Live Desktop on Big Dawg negotiated encrypted microphone forwarding. The real Mac
input started, and the toolbar reported increasing encrypted packet counts. Separate
mic mute/resume worked while host playback remained enabled. Physical voice/input
meter acceptance on Windows is recorded below when confirmed. Packet counts alone
do not prove the host's selected input device receives usable voice.

The user confirmed that speaking into the Mac microphone moved the Windows input
meter on Big Dawg. This establishes live capture, encoding, encrypted transport,
and host input reception. Tests did not establish a particular game's voice-chat
routing or audio quality under packet loss.
