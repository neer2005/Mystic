# Combined Home library

Home is Mystic's default library view. It refreshes saved, locally pinned PCs over
separate paired HTTPS connections and merges installed native games by their host's
stable game_id. Each installation retains its own host identity, app UUID/ID and
endpoint. Classic entries without a native game_id remain per-PC, so two Desktops
or unrelated apps with the same numeric ID are never silently combined. Multiple
saved addresses for the same known host share one Home library.

Game cards show artwork, stores and PC names. Search covers titles, stores and PCs;
a store filter and All Games, Favourites and Recently Played collections are available.
Favourites belong to the combined game; recent play is recorded per installation only
after the engine reports connected, not when a launch is merely requested.

Play on a PC opens a fresh pinned connection, verifies host identity and that the
chosen UUID/ID is still in its current library, selects that game's existing profile,
and uses the normal launch/resume/confirmed-switch path. It never copies credentials
between addresses or changes another PC's profile. Disconnect the active local stream
before choosing another host or game. The host-specific browser remains in the sidebar.

## Persistence and offline state

Versioned Home metadata, favourites and recent history are saved locally in UserDefaults
without certificates, private keys or launch secrets. Cached libraries remain visible
when a PC is unreachable or requires pairing. Not checked, Checking, Online,
Unreachable and Pairing required are distinct; an old cached library is never proof
that a PC is online. The last saved date is shown. A failed native-library read retains
the previous native cache rather than deleting it because a partial fallback arrived.

The cache is limited to 32 PCs, 1,000 apps per PC, 5,000 apps total and 8 MiB metadata.
Decoded metadata validates host associations and endpoints. Encoded artwork uses hashed
installation/version keys in the app's Caches/HomeArt folder, at most 4 MiB per image,
32 images in memory and 64 MiB on disk. Native cover versions invalidate old artwork;
classic covers are refreshed by a daily cache key. Artwork URLs supplied by hosts are
never navigated. Removing a saved host removes its Home entries/history and orphaned
favourites; a shared favourite remains while another saved PC has that game. Unreferenced
disk covers are disposable and age out through the bounded cache.

## Wake-on-LAN

While reachable, a PC's serverinfo MAC and, when supported, native wake adapter/broadcast
addresses are remembered. Wake sends bounded standard magic packets on UDP port 9 to
local broadcast, reported IPv4 subnet broadcasts and the saved host's resolved IPv4
address. Zero, malformed and multicast MACs are rejected. No host permissions or power
settings are changed. The result says packets were sent, not that the PC woke; Refresh
Home performs the paired reachability check. Firmware/adapter wake configuration and
network routing must support it. A remote VPN may not carry broadcasts. Automatic wake
retry/polling, manual MAC editing and additional directed-wake strategies remain polish.

## Validation

Automated checks cover multi-PC merging, separate classic entries, aliases, favourites
and recent-history persistence, offline cache retention, cover invalidation, restart
reachability, removal, pinned-only refresh and per-host profile routing. Connected-stream
tests cover recent-play recording. Rust validates magic-packet construction and invalid
MACs; the C smoke test verifies owned error handling without emitting a wake packet.
Full Swift/Rust checks and the C bridge smoke test passed.

Live Big Dawg checks on 2026-10-31 confirmed Home loads 28 games with cover art, store
and PC labels, Online status and remembered wake availability; Steam search returned
14 games. Play on Big Dawg resumed Desktop successfully, and Recently Played contained
Desktop after disconnect and a full app restart. Command-F focused Home search.
The app layout was inspected visually. Real multi-PC hosts,
a real offline PC and waking a sleeping machine remain hardware/network validation;
automated tests cover their library/routing behavior. Favourites and restart caching
are covered by persistent-storage tests.
