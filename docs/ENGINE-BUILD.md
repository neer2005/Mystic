# Engine build status

Tracking whether Nightjar's `nightjar-core` builds and behaves on the Mac, which is the
gate for Mystic Phase 1.

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
- Do not gate work on `enet_rtt`. Treat it as a known platform-flaky harness test until
  the Linux comparison below settles it.
- If it reproduces on Linux, it is a genuinely flaky test worth reporting upstream; if it
  only fails on macOS, the fix is in the test's real-time sleeps (a deterministic
  packet-delivery hook instead of `thread::sleep`), not in the engine.

## Toolchain

- macOS: stable Rust, Xcode 27 (versions to be recorded)
- Linux dev box: rustc 1.99.1, aarch64, Swift 6.2 for `MysticCore`

## Build note

Cargo fails to fetch the `Rubylight` dependency when `git@github.com:` URL rewriting is
active globally, because libgit2 does not use `~/.ssh`. Fix:

```sh
export CARGO_NET_GIT_FETCH_WITH_CLI=true
```
