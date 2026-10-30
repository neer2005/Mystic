# mystic-ffi

C ABI over Nightjar's `nightjar-core` streaming engine, so the Swift app never has to
implement a Rust trait.

## Nightjar revision

Pinned to Nightjar 4.0.1, `461e403b0a1fde4a1e447f73c65c505ab61e84ea`
(synced 2026-10-30). `nightjar-core`, `rubylight-protocol`,
and `nightjar-policy` must use the same revision; commit the updated `Cargo.lock`
with all three pins.

This brings in upstream engine fixes, including HEVC prefix-SEI preservation,
FEC loss reporting for hosts that negotiate it, session-start failure reporting,
and encrypted microphone setup diagnostics. New Nightjar application features
still require their own Mystic integration.

Mystic retains ABI 2: Opus stereo, 5.1 and 7.1. The bridge copies the first eight
entries from Nightjar's expanded 12-entry mapping only for supported layouts and
rejects 7.1.4 or passthrough setups before invoking Swift. Passthrough negotiation
stays disabled. No C struct layout or Swift binding changes are required.

## What it does

`nightjar-core` exposes Rust traits — `VideoDecoder`, `AudioRenderer`, `Listener` — and a
blocking `Session::start`. This crate turns those into C function pointers and keeps every
Rust type behind an opaque handle.

ABI v1 covers:

- handle lifecycle (`mystic_session_new` / `mystic_session_free`)
- `mystic_session_start` (blocking) and `mystic_session_interrupt`
- `mystic_session_stop`
- video callbacks: setup, start, submit, stop, cleanup
- audio callbacks: init, start, play, stop, cleanup
- listener callbacks: stage events, connection started/terminated, log
- input injection: relative and absolute mouse, buttons, keyboard, wheel and high-resolution
  scroll, plus IDR requests
- `mystic_struct_sizes` so C and Swift can prove the layout matches what Rust compiled

**Not in v1** (deliberate, next iterations):

- controllers, touch and pen (`send_controller`, `send_touch`, `send_pen`)
- statistics (`Session::stats`) and host control messages
- per-buffer frame descriptors (`mystic_frame_buffers` returns `MYSTIC_ERR_UNIMPLEMENTED`)
- Rubylight `0x55xx` control messages (`Session::send`)

## Threading contract

- `mystic_session_start` **blocks** until streaming or a stage fails: call it off the main
  thread.
- Video, audio and log callbacks run on session-owned threads and may overlap; the `user`
  pointer must be safe for concurrent use.
- `mystic_session_interrupt` is safe from any thread while `start` blocks.
- `mystic_session_free` must not race with a running callback.

## Build

```sh
cd engine
cargo test                                   # 5 ABI tests
cargo build --release                        # target/release/libmystic_ffi.a (~52 MB)
cc -std=c11 -Iinclude tests/c_abi_smoke.c target/release/libmystic_ffi.a \
   -lpthread -ldl -lm -o /tmp/c_abi_smoke && /tmp/c_abi_smoke
```

On macOS the link line drops `-ldl` and needs the usual system frameworks:

```sh
cc -std=c11 -Iinclude tests/c_abi_smoke.c target/release/libmystic_ffi.a \
   -lpthread -lm -framework Security -framework CoreFoundation -o /tmp/c_abi_smoke
```

### If cargo cannot fetch the engine

With a global `git@github.com:` URL rewrite, libgit2 tries SSH and fails without an agent:

```sh
export CARGO_NET_GIT_FETCH_WITH_CLI=true
```

The engine is pinned to one revision in `Cargo.toml`; bump it deliberately and re-run the
ABI test.

## Verified

```
rust tests     6 passed
C ABI smoke    PASS  (all six struct layouts match; input refused before start;
                     start reaches RtspHandshake and reports "Connection refused"
                     against a dead address)
```

Layouts as compiled on aarch64 Linux (byte-identical on Apple silicon, verified):

`video_setup=36 audio_setup=12 frame=64 frame_buffer=24 stream_config=92 callbacks=120`.

## ABI rules

- Bump `MYSTIC_ABI_VERSION` on any signature or struct change; the Swift side refuses a
  mismatch.
- Never reorder or resize a struct in place — add fields at the end of a new version.
- `panic = "abort"`: nothing unwinds across the boundary.

## Audio (ABI 2)

The audio setup callback now carries the negotiated Opus stream count, coupling,
sample rate, and channel mapping. Build the archive and Swift wrapper together.
The engine statically links bundled libopus through the pinned `opus`/`opusic-sys`
crates. CMake and Rust 1.82+ are required; no system libopus install is needed.
The PCM ring reader is allocation/lock free and is called by the AVAudioEngine
source node. See `docs/AUDIO.md` from the repository root for lifecycle details.


ABI 2 also has additive microphone availability/sending functions and bounded
capture-ring/mono-Opus encoder functions. Start/stop, conversion, encoding and sends
are serialized by the Swift session worker. The audio IO producer only writes the
ring's atomic sample storage. Microphone packets use Nightjar's encrypted transport;
the front end does not construct encryption or silently send unencrypted audio.

## Network policies (additive ABI 2)

`MysticRecovery` wraps Nightjar's shared recovery budget. Session bitrate calls
wrap its adaptive controller and read real receiver counters plus frame timing.
Call these on their owning actor/worker; no policy call is a real-time audio
callback. No existing C layouts change. Swift serializes samples and applied
rates on the session worker, and performs host HTTP requests separately. See
`docs/NETWORK.md` from the repository root for defaults, behavior and limits.

## Controller feedback (additive ABI 2)

`mystic_session_controller_arrival_with_feedback` reports only implemented analog,
handle-rumble and trigger-rumble capabilities, with a caller-supplied slot epoch.
The old arrival entry point remains compatible and advertises analog triggers only.
Nightjar listener rumble events feed a fixed mailbox of eight latest states; the
poll API returns owned motor values and the arrival epoch. New arrivals clear a
slot's pending feedback, and Swift rejects old epochs after release/slot reuse.
The existing callback/configuration struct layouts are unchanged. No PCM haptics,
controller audio, LEDs or DualSense adaptive trigger resistance is advertised.

## Clipboard text (additive ABI 2)

Host JSON operations `clipboardRead` and `clipboardWrite` use Nightjar's pinned
HTTPS text endpoint and independently enforce current read/set permissions.
`mystic_session_clipboard_step` bridges the shared `ClipboardSync` rules through
bounded JSON, with a foreground baseline and at most one pending incoming text.
It never holds the clipboard mutex while sending control messages. The old ABI
layouts stay unchanged. Swift owns the pasteboard and discards stale results.
See `docs/CLIPBOARD.md` for behavior and validation.
