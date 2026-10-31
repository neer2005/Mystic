# Native host session controls

Session and Graphics is available from the library and stream toolbars and from
Stream → Session and Graphics… (⌘I). While open, it reads
Rubylight's native session state every two seconds and displays game, owner, state,
and host-provided action permissions. Unsupported hosts receive an explanation;
ordinary local Disconnect remains available. Resume uses the existing launch/resume
flow and the running game's saved video profile.

Disconnect Host Session leaves the game running and suspends the session. End Host
Session ends it and restores temporary host settings while leaving the game running.
Close Game on Host closes the game and may lose unsaved progress. Host writes require
an explicit UI confirmation; unavailable actions show permission/busy explanations.

Requests use the paired, certificate-pinned Nightjar HostClient. Before a write, the
bridge rereads the session, verifies its app and owner still match the displayed
session, and checks that the exact action is allowed. The host remains authoritative
if another client races that check. Only disconnect, end and close_game are accepted
by the bridge. Unknown actions never become host commands.

During an intentional exit, termination callbacks do not start automatic reconnect.
The connection is cleaned up after the host answers. A failed write retains a usable
stream when possible and displays an error; if the stream terminated while waiting,
it stops without reconnecting. Disconnect/host changes invalidate late results.
Polling only runs while the panel is open, never while an action is pending.

## Validation

Automated checks cover permission defaults, unknown actions, changed app/owner,
write failures, intentional-exit recovery suppression and late-read cleanup.
Live Big Dawg checks on 2026-10-31 confirmed idle and streaming state, Desktop's
name, this-device ownership, allowed Disconnect/End actions and disabled Close Game
with the Host control explanation. Confirmed Disconnect Host Session returned Mystic
to disconnected state, left Desktop running and did not automatically reconnect.
Desktop resumed through the existing library flow. End Session and Close Game remain
separate live checks; Close Game requires a host permission change and user-led
validation because it can discard unsaved progress.

The Graphics tab now provides Radeon controls; see GRAPHICS.md for behavior and
validation. Classic-host Quit Game and quit-and-start-another are available in the library;
see GAME-SWITCHING.md. The Stream tab now provides live FPS/manual bitrate controls; see LIVE-RATES.md. See NIGHTJAR-PARITY.md for the complete inventory.
