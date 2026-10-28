# First live video

Mystic now has a runnable SwiftUI macOS app. Nightjar owns HTTP pairing, pinned
HTTPS, app listing, launch/resume, and the RTSP/stream transport. Swift owns the
Keychain, connection UI, decoder, and streaming window.

## Build and run

Requirements: Apple silicon, macOS 27, Xcode 27 / Swift 6.4, and Rust. From the
repository root:

```sh
scripts/build-macos-app.sh
open .build/Mystic.app
```

The script builds the pinned engine archive, builds the `MysticApp` SwiftPM
executable, copies its decoder probe resources into a development `.app`, and
signs it ad hoc. `scripts/build-macos-app.sh release` builds an optimized app.
This is a local development bundle, not a notarized distribution build.

The package can also be opened in Xcode. Build the `MysticApp` scheme to debug the
executable, or use `Mystic-Package` to run the package test suite.

## Host flow

1. Select a saved or nearby host in the sidebar, or expand Add Host to enter its address and HTTP port (normally 47989).
2. If unpaired, choose Pair with Host. Mystic displays a random four-digit PIN;
   enter that PIN in the host's Sunshine/Apollo/Rubylight pairing page. The host
   does not display a PIN for you to type into Mystic.
3. Grant Mystic's device entry the host permissions needed to list/view/launch
   applications. Rubylight reports a clear permission error if launching is denied.
   Mystic does not change these permissions automatically.
4. Select Desktop for initial validation. Start at 1080p60, 20 Mbps, Automatic
   codec, HDR off in Stream Details. Choose Start Stream. Shared defaults are also
   available in Mystic → Settings (Command–Comma).
5. The stream opens in a separate native window. Full Screen toggles a native
   fullscreen space. Disconnect stops the local stream and leaves the host app
   running; reconnecting and selecting the same app uses Nightjar's resume path.

Saved host names, endpoints, host IDs and last-connected dates are stored in preferences. The client identity and
host certificate pins are stored in the login Keychain. Pinned HTTPS never falls
back to unverified HTTP after certificate or authentication failure. Launch key
and IV bytes stay in memory and are passed unchanged into the engine. Engine
protocol logs are excluded from the UI because they can contain credentials.

## Current limits

Opus audio playback is connected; see AUDIO.md for controls and stereo/surround
downmix behavior. Keyboard/mouse control is available in the stream window (see INPUT.md); extended-profile controller input is implemented with physical acceptance pending. Codec/HDR options are restricted by the decoder probe results;
PyroWave is unadvertised. Some host app catalog control tiles are intentionally
excluded so a click cannot terminate a host session. A different running app is
not replaced automatically. No host quit/cancel endpoint is called on disconnect.

Credentials are pinned to the entered address and port. A host certificate change
fails closed; this milestone does not yet provide a credential reset UI. Reusing
the same paired client after a host-side revocation may need local Keychain cleanup
and re-pairing. Discovery and multi-host management remain roadmap items.

## Validation recorded on 2026-10-27

Against a Rubylight 3.0.0-rc.3 host, using Desktop:

- User completed pairing and enabled the host's Launch applications permission.
- The app listed the host catalog over pinned HTTPS.
- The first launch correctly surfaced the host's 401 permission refusal.
- After permission was enabled, Desktop video was visibly presented at 1080p60.
- Disconnect stopped the local stream without quitting Desktop.
- Reconnect reused the saved pairing, and Desktop resumed with a 720p60 request;
  the visible host desktop resized accordingly.
- Restarting Mystic preserved pairing; Desktop resumed again without entering a PIN.
- The final build’s fullscreen button entered a native fullscreen space while video remained visible.
- The subsequent audio build played Desktop sound through the Mac; the user confirmed listening successfully.
- The input build forwarded Control+F to the host browser; the user confirmed mouse clicking/scrolling, relative capture, and release to the Mac.

These are live startup/reconnect observations, not sustained performance results.
Codec profile/color metadata checks, keyframe recovery state, queue bounds, and
parameter-set changes also have local fixture/unit coverage. Live packet-loss/IDR
recovery, sustained throughput, precise latency, HDR display fidelity, and AV1 on
hardware that supports it still need validation.

Run `engine/scripts/test-c-abi.sh` for Rust + C ownership/layout checks and `swift
test` for Swift tests. Both need loopback networking; decoder tests also need
access to VideoToolbox hardware services. Host-flow state tests use mocks and do
not contact or alter a real host or the user's Keychain.
