# Stream recovery and automatic bitrate

## Automatic reconnect

Settings → Network → Reconnect Interrupted Streams is on by default, including
when loading older saved settings. It only restores a stream that previously
received decoded video; failed first launches, clean exits, protected-content
errors, pairing/certificate failures, permission errors and decoder errors remain
manual.

Mystic uses Nightjar 4.0.1's shared `Backoff` and termination classification. The
retry delays are 1, 2, 4, 8 and 12 seconds, with at most five attempts within a
one-minute recovery window. A connection must last 30 seconds to renew that
budget. Briefly reconnecting does not reset it, even if a later attempt receives
no picture. Known transport failures during a recovery start can retry; other
startup failures stop recovery.

Recovery releases input, stops microphone capture and the old media session, and
recreates a pinned host connection to the original endpoint. It verifies the
host identity and that the original app is still running, then resumes with the
original resolution, codec, HDR, audio and controller settings and fresh launch
keys. A recovery request cannot launch an app that has stopped or replace another
app. Callback generations fence old sessions and HTTP responses. Disconnect,
closing the stream window and quitting cancel pending recovery.

This restores sessions after transient termination.

## Network changes and client roaming

As Nightjar's desktop client, every stream runs a network watcher: it checks the address
this Mac uses toward the host once a second and on every macOS path change. Its events:

- **Lost.** No route toward the host. The session log says so and the status reads
  "Network lost". The stream rides it out for as long as Ride Out Network Drops allows.
- **Changed.** A new address toward the host, or one back after a loss. Each change
  goes to the engine, which roams onto the new network when the host advertises client
  roaming and Settings → Network → Keep Streams When the Network Changes is on (the
  default, as Nightjar). Metered networks (an iPhone hotspot, cellular, or Low Data Mode)
  need Also onto Metered Networks.
- **Back on an address the stream cannot continue over** (it did not roam): Mystic
  reconnects at once instead of waiting for the connection to time out, using Nightjar's
  shared rule. Not when automatic reconnect is off, before the first picture, on a
  metered network without permission, or when a drop tolerance above 10 seconds holds
  the connection. The attempt starts without its delay but still counts toward the
  reconnect budget.

Without a route when the stream starts, the watcher does not run and the engine's roaming
stays off unless metered networks are allowed, as in Nightjar.

## VPN routes

The route lookup also reads the interface toward the host. A tunnel or PPP interface (utun,
which carries WireGuard, Tailscale and the system VPNs; ipsec, ppp, tun, tap; ZeroTier's
feth and zt) or an MTU under 1500 makes it a VPN route, Moonlight's rule as Nightjar applies
it. Such a stream goes as remote with 1024-byte video packets: a tunnel's smaller MTU
(WireGuard's 1420, Tailscale's 1280) would fragment every 1392-byte packet. Before this, a
VPN to a private address, such as Tailscale's IPv6 `fd7a:` range, streamed as local.
Other routes leave the choice to the engine, which streams public addresses as remote.

## Network drops, error correction and link hints

Settings → Network holds three of Nightjar's stream network settings. Each applies to
the next stream and is locked during one.

- **Ride Out Network Drops** (Off, 20, 30 or 60 seconds) is the engine's network grace
  period. Off keeps Nightjar's 3-second grace, below the control connection's own
  10-second timeout, so it adds no tolerance. While the network is silent the engine
  holds input and, when the host answers, sends the current key, button and controller
  state rather than replaying the silence. The host has its own timeout (Sunshine's
  `ping_timeout`); a longer wait only helps if the host waits as long. When tolerance
  runs out, Reconnect Interrupted Streams still applies.
- **Error Correction** (Host's Setting, Automatic, 10, 20, 30 or 50 %) is sent at launch
  to Rubylight hosts that offer client error correction, and in the ANNOUNCE to
  Sunshine-based hosts that accept it; other hosts keep their own. The engine reports
  video loss to the host once a second, which Automatic follows.
- **Tell the Host When on Wi-Fi** and **Tell the Host the Wired Link Speed** are on by
  default. Before each launch, including reconnects, Mystic asks the Network framework
  which interface reaches the host. Wi-Fi or cellular is wireless; Ethernet is wired,
  with the port's negotiated speed. A tunnel such as Tailscale defers to the Mac's
  internet connection, as in Nightjar's desktop client. Only a Rubylight host is told
  the route is wireless; any host may receive a wired link speed. The session log
  records the route and what the host was told.

The bridge carries these as ABI 3 fields of `MysticStreamConfig` (`network_grace_ms`,
`video_fec`, `link_mbps`) plus launch request fields (`fec`, `clientWireless`).

## Automatic bitrate

Settings → Video → Automatic Bitrate is off by default. Enable it before starting
a stream; the selected bitrate becomes the ceiling. The stream toolbar shows the
current applied bitrate or why adaptation is unavailable/stopped. The preference
and reconnect switch apply to the next stream and are locked during a session.

Hosts must advertise Nightjar's RuntimeBitrate capability. A host without it keeps
the fixed stream bitrate. Once decoded video starts, Mystic requests the selected
ceiling and initializes Nightjar's shared `AdaptiveBitrateController` from the
host's actual applied rate. A lower host cap is retained.

The policy receives once-a-second post-FEC frame loss, frame-arrival jitter and
VideoToolbox decode timing. Its codec/size/frame-rate-dependent floor, sustained
pressure rules and recovery ramp are shared with Nightjar. Only one request is
in flight; host responses update policy state. Unknown/stale measurements are not
reported as healthy. A failed or invalid bitrate response stops adaptation and
leaves playback running, with a visible explanation.

This changes bitrate only; resolution and frame rate are automatic quality's, below.
Requests use the existing pinned HTTPS host connection.

### Host-run automatic bitrate (Foundation Sunshine)

A host without live bitrate may run the controller itself, as Foundation Sunshine does
(`/api/abr`). With Automatic Bitrate on, Mystic asks `/api/abr/capabilities` at stream start
and, when the host has one, turns it on balanced, from 0 up to the selected bitrate. Every
three seconds it reports the window's frame loss, round trip, decode rate and dropped frames
(`/api/abr/feedback`), one report at a time, and shows the bitrate the host chose; Nightjar's
desktop `host_abr.rs` and Moonlight V+ PC do the same. Other hosts answer 404 and keep the
fixed bitrate. These requests use their own connection to the host, so the request that turns
the controller off at disconnect, reconnect or a manual bitrate change still reaches the host
after the stream's connection is cancelled; a start that finishes after its stream ended turns
the controller off itself, and a start waits for an earlier stop. While the host owns the
bitrate the stream health report offers no trial. Not yet tried against a Foundation host.
Thermal inputs and network queue-delay measurements remain separate work.

## Automatic quality

Settings → Video → Automatic Quality (per host or game, like the other video settings) runs
Nightjar's bounded resolution/frame-rate ladder: Favor Smooth Motion gives up resolution
first, Favor Sharp Detail frame rate first, and Favor Battery Life caps the stream lower. It
never goes below 720 lines or 30 fps (Nightjar's defaults), steps at most every 15 seconds,
and climbs back after 30 healthy seconds.

- It needs a host that takes the Reconfigure message (Rubylight). Otherwise the stream panel
  says so and nothing changes.
- It starts once video decodes, ticks with the stream doctor once a second, and holds while
  Mystic is not the active app.
- Automatic bitrate answers network trouble first: the ladder moves for network pressure
  only once bitrate has no room left. A slow decoder moves it directly.
- Each request must show up as a decoded picture of that size within 5 seconds, or
  automatic quality stops. A frame-rate-only step is confirmed at once.
- A manual frame-rate change in the stream panel stops it until the next reconnect.
- The stream panel shows its state, and the session log records each request.

## Validation

Automated lifecycle tests cover recovery cancellation, retry exhaustion across
successive sessions, old callbacks, unchanged launch options, changed host/app,
transport versus permanent failures, startup transport versus decoder failures,
opt-out, deadline expiry, host capability gating and bitrate-request failure.
Rust tests cover classification/budget, frame timing, congestion cuts, recovery
and host caps. C smoke tests exercise the additive policy interface. Saved
settings tests cover migration and persistence.

Live packet-loss/reconnect and adaptive-bitrate behavior still need validation
against a streaming host. Automated tests do not establish visual quality or
reconnect latency on a real network.
