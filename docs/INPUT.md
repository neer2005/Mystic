# Keyboard, mouse, and controller input

The stream window forwards local AppKit events through `StreamSession`'s existing
engine queue. It does not install a global event tap or request Accessibility /
Input Monitoring access. Only the focused streaming view controls the host.

## Controls

- Click the video, or choose **Control Desktop**, to enable keyboard and absolute
  pointer input. The first activation click is consumed so it cannot click an
  unexpected host control.
- Choose **Capture Mouse** for relative mouse movement. The pointer moves to the
  video center, is hidden, and is temporarily disconnected from local cursor
  positioning. This is intended for games.
- **Control–Option–Shift–Escape** releases input. **Release Input** does the same.
  Relative capture restores the cursor's previous position.
- Changing the active app, focusing another window/control, closing the stream,
  disconnecting, or quitting releases capture and held keys/buttons.
- After a release, input stays released until explicitly activated again.

Control Desktop leaves the local pointer visible. Absolute positions use the
actual aspect-fit video rectangle, derived from decoded presentation dimensions
including clean aperture and pixel aspect ratio. Letterbox clicks are ignored;
drags are clamped at image edges. The protocol receives normalized coordinates in
a fixed 32767×32767 space, independent of Retina scale or stream resolution.

Physical keys map to Windows virtual keys, including the engine's 0x8000 wire
marker and extended-key modifier. Shift, Control, Option, and Command map to their
left/right Windows Shift, Ctrl, Alt, and Windows keys. Use **Control**, rather than
Command, for Windows shortcuts such as copy/paste. Local auto-repeat is suppressed;
the host handles held-key repeat. Caps Lock generates a complete press/release on
state changes. Ordinary Escape is forwarded; only the release chord stays local.

Letters, digits, punctuation, F1–F20, navigation, keypad, and ISO/JIS positions have
physical mappings. Fn/media keys and unknown positions are not sent. Text follows
the host keyboard layout; local IME composition remains separate work. Clipboard text transfer and opt-in
sync are described in [CLIPBOARD.md](CLIPBOARD.md). macOS-reserved shortcuts may switch
apps; that transition releases host input instead of trapping the user.

Mouse buttons map explicitly: Mac left/right/middle become host 1/3/2; buttons 4
and 5 become host back/forward. Both scroll axes preserve fractional deltas; precise
trackpad deltas are converted to high-resolution wheel units. Cocoa horizontal
scroll has its sign reversed to match wheel-right. The horizontal wheel C function
is an additive ABI 2 entry point; existing structure layouts are unchanged.

## Ownership and bounded delivery

AppKit state stays on the main actor. An immutable event is offered to a mailbox
with one scheduled engine-queue drain and at most 256 pending events. Consecutive
positions/motion/wheel events coalesce without crossing a key or button boundary.
A release clears pending work and invalidates a batch already taken by the worker.
An overflow becomes a release marker and returns capture to the Mac.

The worker tracks only down events the engine accepted. Release emits key-ups for
ordinary keys first, then modifiers, then held mouse buttons. Failed releases are
retained for retry. Transport failure stops the stream and runs engine cleanup
rather than leaving an unresponsive captured window. No keystroke content is logged.

## Checks

Core tests cover physical key rows and wire flags, two-sided/synthetic modifiers,
including shortcuts that carry modifier flags without separate modifier events,
Caps Lock, repeat suppression, button numbering, letterboxing, flipped coordinates,
fractional/clamped movement, coalescing, overflow, and release retry behavior.
Desktop tests cover scheduling, batch invalidation, closed-mailbox rejection,
refusing capture without a connection/image, and enabling/restoring window mouse-move
delivery. Key events without a window identifier are accepted only while the stream
window is key and its video view is first responder. The C smoke test covers the additive
horizontal scroll entry point.

Live Desktop keyboard/mouse, relative capture, focus loss, and release-chord checks
are performed after building with `scripts/build-macos-app.sh`. A visible host
window is required to verify that input reached the host; a successful enqueue is
not proof of delivery.

## Live result — 2026-10-27

On the paired Rubylight host's Desktop, the user confirmed that physical Control+F
opened the Windows browser's Find box. The user also confirmed pointer clicking,
scrolling, relative Capture Mouse, and Control–Option–Shift–Escape returning
control to the Mac. These checks used the existing Desktop stream.

Development rebuilds are ad-hoc signed; macOS may ask again before allowing the
rebuilt app to read its existing Keychain identity. The connection UI identifies
that stage separately from host networking. No trust/pinning checks are bypassed.

## Controllers

Control Desktop or Capture Mouse also enables GameController forwarding. Pair a
DualSense or Xbox controller in macOS first. Up to four extended-profile controllers
are forwarded with positional A/B/X/Y face buttons (Cross/Circle/Square/Triangle on
PlayStation), d-pad, shoulders, stick clicks, Menu/Options, analog triggers, and both
sticks. Sticks use a radial 12% dead zone rescaled to full travel; triggers use 0–255.
Guide/Home, touchpad, paddles, motion and DualSense adaptive resistance effects are
not forwarded. Controller arrivals use the generic extended-gamepad type and
advertise analog triggers plus only the feedback motors macOS exposes.

Host-driven handle rumble now uses GameController-created Core Haptics engines.
Low/high amplitudes target the left/right handles separately when available;
otherwise their maximum drives the controller's default haptic locality. Trigger
rumble is advertised only when both trigger motor engines can be created. Trigger
rumble is vibration, not DualSense adaptive trigger resistance. System-disabled
or unavailable haptics leave controller input working without a feedback claim.

Feedback uses a fixed eight-state Rust mailbox (four slots, two motor kinds),
coalescing to the latest amplitude, including zero stops. A serialized worker poll
and an awaited main-actor loop bound delivery. Capture epochs are echoed through
controller arrivals and polled feedback; old polls and old slot bindings are
rejected after release/reactivation or unplug/replacement. The existing ABI 2
callback and configuration layouts remain unchanged.

Release, focus loss, unplug, disconnect, reconnect recovery and teardown stop the
controller's players and engines. A motor error disables feedback for that
controller, updates its advertised capabilities and records a diagnostic while
leaving input active. Engine resets invalidate cached players without replaying
old effects. PCM haptics, controller audio, LEDs and adaptive triggers remain
separate work.

Connected devices contribute a four-bit gamepad mask to host launch/resume. During
capture, connect/disconnect notifications update the active mask and reuse free
slots without moving surviving controllers. Unplug sends a neutral state. Focus
loss, the release shortcut, disconnect, and quit disable handlers and neutralize
controller slots accepted by the engine. Reactivation takes fresh snapshots, so
held controls reflect the current physical state. Unsent events share the same
256-event mailbox and epoch invalidation as keyboard/mouse. Stick-only changes can
coalesce; button and trigger transitions remain ordered.

Snapshot-controller tests exercise the actual GameController profile mapping,
including d-pad directions/diagonals, signed stick extremes, trigger conversion,
four-device capacity, slot reuse, disconnect/reconnect, queued callback rejection,
and overflow shutdown. Core tests cover invalid analog values, coalescing boundaries,
and neutral-state release retries. The C smoke test covers controller entry points
and slot/mask rejection. Xcode validation: 98 tests, 94 passed, four AV1 hardware
skips. Rust: 11 passed; C ABI smoke: PASS.

**Live controller acceptance is pending:** no physical controller was available on
2026-10-27. With one connected, stream Desktop, activate Control Desktop, open the
host's game-controller properties, and check each button, both sticks, and both
triggers. Then check unplug/reconnect and release/focus loss while a control is held.
These simulated tests do not establish Bluetooth/USB behavior or host recognition.


## Controller feedback validation — 2026-10-30

Tests cover per-controller capabilities, handle/trigger routing, explicit zero
stops, absent motors, release/reactivation, slot replacement, stale feedback,
feedback failure without input failure, bounded/coalesced Rust storage and the
Listener → C polling path. Core Haptics validates real continuous-controller
patterns without requiring a physical controller. The C smoke test checks the
new feedback layout, bounded output storage and capability rejection.

Physical rumble strength, USB/Bluetooth behavior and game-specific feedback still
need a real controller and host. See [PLAYTEST.md](PLAYTEST.md) for the live checklist.
