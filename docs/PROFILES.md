# Host and game video settings

Settings → Video edits global defaults. In the library, select a host and game,
then choose one of the Video settings sources in Stream Details:

| Choice | Behavior |
| --- | --- |
| Use host defaults | Follows the host's custom settings, or global defaults if none exist. This is the initial choice for every game. |
| Use global defaults | Follows Settings → Video directly, bypassing any host override. |
| Custom game settings | Saves a video setup for this game on this host. Starts as a copy of the currently effective settings. |

Use **Edit Host Defaults…** to configure the host. Turn off **Use global defaults**
to begin with a copy of global video settings, then edit it. Turning the toggle
back on removes the host override. Games following host defaults immediately
inherit that change; custom game settings and explicit global choices stay intact.

Profiles include resolution, frame rate, bitrate ceiling, automatic bitrate,
codec, HDR and frame pacing. A custom profile is a complete snapshot of those
video choices, not a collection of individual inherited fields. Later global or
host edits do not change a custom game snapshot. The inherited summaries are
read-only; edit global settings in Settings or host settings in the host editor.
Switching a custom game back to host/global settings removes its custom snapshot.

Audio layout, local volume/mute, microphone, clipboard sharing, recovery and library
preferences stay global. Restore Global Defaults preserves all host/game profiles.
To reset a game, choose Use host defaults; to reset a host, enable Use global
defaults in its editor. These actions do not change pairings or host permissions.

## Identity and storage

Profiles use the paired host's unique ID, with its endpoint as a fallback only
when the host supplies no ID. Games use their UUID, falling back to the numeric
app ID when UUID is unavailable. Valid UUID strings are canonicalized for case.
Names are never used as identity. Renaming an app or changing its numeric ID
keeps its settings when the UUID stays the same. A host with the same unique ID
at another paired address uses the same profiles; a different host at an old
address gets separate settings. Endpoint fallback profiles cannot follow address
changes, and app-ID fallback profiles cannot follow ID changes.

The separate versioned `streamProfiles.v1` UserDefaults document contains only
identifiers and video preferences. There are no keys, certificates, permissions,
or launch tokens in it. Missing profiles preserve the existing global defaults.
Malformed, future-version or oversized profile documents fall back to globals
with a visible message, without resetting the global settings document.
Reads are bounded to 1 MiB; writes allow 32 custom host profiles and 256 game
choices across hosts. At capacity, existing entries can still be edited/reset;
new entries are refused with a message rather than evicting another profile.
Removing a saved host from the sidebar keeps its profiles, just as it keeps the
pairing; reconnecting that host restores access to them.

## Launch and recovery

The selected game's effective video settings are resolved once at Start Stream.
Host launch geometry/HDR and engine geometry, codec mask, colorspace and bitrate
all come from the same snapshot. Hardware decoder checks and host-app HDR checks
still apply; a profile cannot bypass them. UI profile edits are locked while
starting/streaming/reconnecting/disconnecting. Host editors capture their target
identity, so a stale editor cannot write to another selected host.

Automatic reconnect retains the original launch/media settings and pacing mode,
even if another settings writer changes global defaults or stored profiles during
the session. Changes take effect with the next manually started stream.

## Verification

Automated checks cover inheritance, explicit global bypass, snapshot isolation,
validation, persistence, corruption, capacity/reset behavior, stable IDs and
fallbacks, different-host isolation, launch/HDR validation and reconnect keeping
the original media configuration. User flows are in [PLAYTEST.md](PLAYTEST.md).
