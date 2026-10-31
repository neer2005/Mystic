# Quit and switch games

From the library, Start Stream reads fresh host state. If another app is running,
Mystic shows Quit and Start with the current app, host and target names and a warning
about unsaved progress. Quit Running Game offers the same confirmation without a
target. Cancel sends no quit or launch request. Disconnect the local stream before
switching games in the library; the existing session controls remain available while
streaming.

The selected target and its resolved video profile are captured before confirmation.
Codec/HDR validation and microphone permission checks occur before a quit can be
confirmed. A selection/settings change cannot replace the confirmed target or its
stream plan. Host/connection changes invalidate pending confirmations.

Quitting uses Nightjar's classic pinned HTTPS cancel path, available without the
additional Host control grant required by native Close Game. Explicit host Launch
permission is respected; legacy hosts without permission fields defer to the host's
cancel response. Before cancelling, the bridge rereads the running numeric ID and
UUID and refuses a changed/missing app. On native hosts it also refuses another or
unknown session owner. The host remains authoritative if ownership races the check;
its declined/599 responses are shown as errors.

After the host accepts quit, both the bridge and model verify idle host state before
launching a replacement. The launch bridge retains its independent refusal to replace
an unrelated running app. A failed, declined or uncertain quit never launches the
target and refreshes host state when possible. Ordinary launch/resume is unchanged
when the host is idle or already running the target. Quit alone refreshes the library.

## Validation

Automated checks cover cancellation, confirmation invalidation across connections,
changed IDs/UUIDs, permissions, standalone quit, immutable target/profile selection,
invalid target settings before quit, and refusal without a replacement launch. The
full Swift suite and Rust tests passed; targeted checks passed after final changes.

Live Big Dawg checks on 2026-10-31 confirmed both standalone Quit Game and Quit and
Start 007 First Light correctly named Desktop as the current app, presented the
unsaved-progress warning, and cancelled without closing it. Real quit and replacement
launch remain a joint live check: first ensure all host work is saved, then confirm
an intended switch and check video, audio, input and target profile settings.
