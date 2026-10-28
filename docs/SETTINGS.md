# Settings and library defaults

Open Mystic → Settings with Command–Comma. General controls the default library
view, app sort order, and latency HUD visibility. Video contains resolution, frame
rate, bitrate, codec and HDR. Audio contains the host channel layout, local volume
and mute. Network enables or disables local host discovery while the library is
open. Appearance, accessibility, and input-capture behavior follow the existing
system/application behavior; there are no duplicate system preference switches.

Stream Details edits the same saved defaults as Settings. These are shared app
preferences, not per-app or per-host overrides. Starting a stream captures video
and channel layout for that session. Those UI controls and Restore Defaults are
disabled while a session is starting, running or disconnecting. Volume and mute
apply immediately to the audio player. The HUD toggle remains available in the
stream window and in General settings. Discovery does not automatically connect.

The versioned `streamPreferences.v1` UserDefaults document contains only stream
and library defaults and the last-viewed Settings pane. Credentials remain in
Keychain and saved hosts retain their separate catalog. Invalid or future-version
settings fall back to defaults with a message in Settings. Reads are bounded to
64 KiB. Supported resolutions are 720p, 1080p, 1440p and 2160p; frame rates are 60
and 120; bitrate is clamped to 5–150 Mbps, volume to 0–1, and enum-like fields to
supported options. Non-finite volume values return to 0.8. Codec/HDR preferences
never bypass the decoder capability or host-app checks at launch.

Restore Defaults resets stream/library defaults while keeping the current Settings
pane. It does not change host entries, identity, pairings, or certificates. The
last pane survives window close and app restart. Search/filter text is transient;
view mode and sort order persist. Filtering reconciles the selected app so Start
Stream cannot launch an app hidden by the filter. Different view modes preserve
the same app selection. Command–F is scoped to the library window.

## Validation — 2026-10-27

Xcode 27 / Swift 6.4: 118 tests, 114 passed and the same four AV1 hardware skips.
New tests cover invalid preference normalization, persistence/restart, corrupt and
future documents, restore behavior, shared model bindings, discovery enable/stop
lifecycle, search/filter/sort selection, and restored stream options reaching the
host launch request. An initial command-line run under the restricted sandbox
skipped hardware probing; the full Xcode run exercised the launch tests.

Live UI checks confirmed Command–Comma, native Settings toolbar/window titles,
restoring the last pane after close and app restart, persisted list/grid choice,
native sidebar connection to Big Dawg, searching for Desktop, list/grid selection,
and Desktop launch from Stream Details. While Desktop streamed, format/channel
controls were disabled and local volume/mute remained available. The final build's
Command–F focused the search field. The app bundle builds and its ad-hoc signature
verifies. No new engine ABI or consumer-interface changes were required.
