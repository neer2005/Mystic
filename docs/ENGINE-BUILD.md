# Engine build status

Tracking whether Nightjar's `nightjar-core` builds and behaves on the Mac, which is the
gate for Mystic Phase 1.

## Nightjar 4.0.1 sync (2026-10-30)

Mystic now pins Nightjar `461e403b0a1fde4a1e447f73c65c505ab61e84ea`, matching
the local Nightjar checkout. Its expanded Opus mapping is adapted to Mystic's
existing eight-channel ABI; unsupported audio layouts/codecs fail before Swift
callbacks. Automatic reconnect and opt-in bitrate adaptation now use the pinned
Nightjar shared policies; see `NETWORK.md` for behavior and limits. Controller
feedback now crosses a bounded polling bridge to native Core Haptics; see
`INPUT.md` and `PLAYTEST.md`. Manual clipboard text sharing and opt-in foreground
sync are covered in `CLIPBOARD.md`. Native Low Latency/Balanced presentation
and its diagnostic counters are covered in `FRAME-PACING.md`. Display-aware native
HDR/EDR requests and color metadata diagnostics are covered in `HDR.md`. Saved host
and game video profiles and their launch/recovery snapshot are covered in `PROFILES.md`. See
`engine/README.md` for scope and revision-update rules.

Verified on macOS arm64 with Xcode 27:

- `bash engine/scripts/test-c-abi.sh`: 25 Rust tests passed, release archive built,
  C smoke test passed with all six struct layouts matching.
- `swift test --disable-sandbox`: 186 tests passed; four AV1 hardware tests skipped
  because this Mac has no hardware AV1 decoder.
- `bash scripts/build-macos-app.sh`: local `.build/Mystic.app` rebuilt with persistent
  Apple Development signing and strict signature verification; see `SIGNING.md`.

Live streaming against a host has not been revalidated for this revision.
The earlier engine investigation below records the original baseline.

## Verified: macOS 27, Apple silicon (2026-10-27)

```
cd ~/src/nightjar/protocol
cargo test -p nightjar-core --locked
```

The engine **compiles and runs on macOS arm64**. Results:

| test binary | result |
| --- | --- |
| (main lib tests, 14 tests) | **14 passed** |
| `control_messages_contract` | **1 passed** |
| `enet_rtt` | **1 failed** — `the_smoothed_round_trip_time_converges_down_to_the_samples` |

Failure message:

```
a steady 2 ms link leaves the variance at 2ms, expected 1 ms or less
client/tests/enet_rtt.rs:94
```

## Why this is not an engine defect

The test drives ENet with a **synthetic clock** (`Rc<Cell<u64>>`), so the sample stream
should be 40 samples of 40 ms followed by 120 samples of 2 ms. Replaying the exact
smoothing from `protocol/vendor/rusty_enet/src/c/protocol.rs` (lines ~1242-1300) over
that sequence:

| variant | settled mean | settled variance | assertion |
| --- | --- | --- | --- |
| patched (round-up division) | 2 ms | 0 ms | passes |
| upstream (truncating) | 9 ms | 7 ms | fails |

So the patched smoothing converges exactly as the patch intends. The macOS run must have
fed it a different sample stream, which points at the test harness rather than the
algorithm: `enet_rtt.rs` reads the RTT through real `thread::sleep` calls used to let
loopback datagrams land, so the interleaving of `service()` passes depends on the
platform scheduler. The smoothing absorbs frequent small excursions (replaying a +1 ms
excursion on every third exchange still settles to variance 0), so only a recurring
alternating jitter keeps variance above 1 — scheduling, not arithmetic.

The failure is also variance-only: the mean settled within the 3 ms bound. A systematic
arithmetic error would move both.

## Consequence for Mystic

- **The engine builds on macOS.** That was the Phase 1 question, and the answer is yes.
- Do not gate work on `enet_rtt`. Treat it as a known platform-flaky harness test.
- If it reproduces on Linux, it is a genuinely flaky test worth reporting upstream; if it
  only fails on macOS, the fix is in the test's real-time sleeps (a deterministic
  packet-delivery hook instead of `thread::sleep`), not in the engine.

## Resolved: the Linux comparison (2026-10-27)

The identical test on Linux (rustc 1.99.1, aarch64, same `--locked` lockfile):

```
running 1 test
test the_smoothed_round_trip_time_converges_down_to_the_samples ... ok
test result: ok. 1 passed; 0 failed; finished in 0.50s
```

(`nightjar-core` builds clean on Linux in 1m 09s from cold.)

So: **the test passes on Linux and fails on macOS.** Combined with the replay above, the
conclusion is that the engine's smoothing arithmetic is correct on both platforms and the
failure comes from `enet_rtt.rs`'s real-time `thread::sleep` calls, which produce a
different `service()` interleaving on macOS. It is a harness bug, not an engine or porting
bug.

Nothing to fix before building Mystic. Worth reporting upstream as a test-only issue with
the Linux/macOS split and the replay table as evidence — the fix is to drive packet
delivery deterministically instead of sleeping.

## Side benefit

Because `nightjar-core` compiles on Linux, the `mystic-ffi` shim can be built and
unit-tested on the Linux box against the real engine. Only the macOS link of the resulting
static library needs the Mac.

## Toolchain

- macOS: stable Rust, Xcode 27 (versions to be recorded)
- Linux dev box: rustc 1.99.1, aarch64, Swift 6.2 for `MysticCore`

## Build note

Cargo fails to fetch the `Rubylight` dependency when `git@github.com:` URL rewriting is
active globally, because libgit2 does not use `~/.ssh`. Fix:

```sh
export CARGO_NET_GIT_FETCH_WITH_CLI=true
```
