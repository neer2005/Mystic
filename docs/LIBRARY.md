# Native game library

Paired hosts advertising Nightjar's NativeApi capability are queried for Rubylight's
native v1 library. Games show titles, store names, cover art and running status in
Mystic's native grid/list and detail pane. Search matches game titles and stores.
Refresh Library rereads the host's apps and library while no stream is active.

Classic app entries retain their launch UUID and HDR capability when enriched by
native metadata, so existing game profiles remain attached. Installed native games
missing from the classic list are included by app ID; their HDR support remains
unadvertised until the classic list confirms it. Apps such as Desktop remain available.
Explicitly uninstalled native entries do not add launchable games.

Hosts without the native API retain their classic app list. A failed native library
request leaves that list usable and shows a notice with the failure. Covers use
Nightjar's bounded box-art request over the same pinned HTTPS/client-certificate
connection. Host-provided artwork URLs are never navigated. Covers load on demand,
with a maximum of 64 encoded images in memory; absent art uses a placeholder.
Disconnect, host changes and refresh invalidate stale cover results.

This document describes the connected-host browser. Combined Home, favourites,
recent play and offline caching now live alongside it; see HOME.md. Additional game
metadata and separate store shelves remain future work.

## Live validation

1. Connect to Big Dawg. Check titles, store labels and covers against its library.
2. Search by title and store; switch grid/list and select a game to see its details.
3. Confirm the running game offers Resume Stream; launch/resume through the normal
   flow. Existing host/game video settings should still apply.
4. Disconnect, refresh and reconnect. Check selection and game profile persistence.
5. Connect to a host without NativeApi: classic apps and streaming must still work.

Automated checks cover native metadata merging, launch identity retention,
uninstalled/duplicate entries, store search, refresh, profile preservation,
failed-library fallback and disconnect cleanup. Live Big Dawg validation on 2026-10-31 confirmed 28 apps, cover art and store
labels, a Steam search returning 14 games, selection retained after refresh, and
Desktop resume through the new button. The resumed stream reported decoded video
and retained its saved resolution, HEVC/HDR, pacing and bitrate settings. Launching
a different game and testing a real non-native host remain manual checks.
