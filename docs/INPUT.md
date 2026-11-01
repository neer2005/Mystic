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

Control Desktop leaves the local pointer visible. With Settings → General → Local Cursor
(on by default, as Nightjar) and a host that sends cursor shapes (control messages
0x5540/0x5541; the serverinfo's `CursorShapeVersion` and the stream's DESCRIBE must both offer
them), the host leaves its cursor out of the video and Mystic draws the host's cursor as the
Mac pointer over the video, so it moves without video delay. Shapes are on only in desktop
control, as Nightjar's `stream/cursor.rs`: released input and Capture Mouse turn them off and
the host draws its cursor into the video again. Images keep the host display's scale (a
64-pixel cursor from a 200% display is 32 points, drawn from every pixel on Retina), the 32
most recently used are cached, a hide waits 150 ms for a show that cancels it (Windows hides
the cursor while changing it), and an id the host never sent or a malformed shape draws the
Mac arrow with one line in the session log. Not yet tried against a live host.

Absolute positions use the
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

## Keyboard layout and host text fields

Keys go as positions, so what they type depends on the PC's layout. Hosts that take a layout
report (serverinfo `KeyboardLayoutVersion`, and 0x553E offered on DESCRIBE) are told this Mac's
layout when the stream starts and whenever the user switches input sources
(`kTISNotifySelectedKeyboardInputSourceChanged`), as Nightjar's desktop client reports its
Windows or XKB layout. Mac layouts with a Windows counterpart that types the same by position
go as that Windows layout (German as `00000407`, Swiss French as `0000100C`, Dvorak as
`00010409`); others go as their first BCP-47 language, which the PC maps to its default
layout. A layout is sent only when it changed; a refusal is logged and retried on the next
change. Where Mac and Windows layouts of one language place a symbol differently (`@` on a
German Mac is Option–L, on Windows AltGr–Q), the PC's layout wins.

Hosts that send text field notices (`TextInputVersion`, 0x553B) are asked for raises and
lowers only, never the surrounding text. Nightjar uses them to open an on-screen keyboard,
which a Mac does not have; Mystic uses them for text that arrives without a key. The video
view is a text input client, so the emoji picker, the Character Viewer and dictation insert
into it, and that text goes to the host as UTF-8 (in order with keys, through the input
mailbox) while the host reports a focused field. A host that sends no notices takes the text
at any time. Keys never pass through the Mac's text system, so typed keys are never echoed as
text, and IME composition stays separate work. Not yet tried against a live host.

## Saved key shortcuts

Settings → Keyboard keeps up to 32 named chords of up to eight keys, such as `WIN + TAB` or
`CTRL + ALT + DELETE`, and Stream → Send Shortcut (also a hidden stream toolbar item) presses
one on the host: modifiers first, then the rest, released in reverse, with the extended flag
Mystic's own keys carry. This reaches shortcuts macOS keeps for itself. The file is Nightjar's
and Android's (`{"version":1,"data":[{"id","name","keys"}]}` with Android key names, aliases
such as `KEYCODE_META_LEFT` and `VK_LCONTROL` accepted), so Export and Import move shortcuts
between Mystic, Nightjar and Moonlight on Android; an import replaces every shortcut and an
invalid file changes nothing. Files are bounded to 64 KiB; saved in `keyShortcuts.v1`.

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

Development app builds use a persistent certificate; see [SIGNING.md](SIGNING.md).
The first signed build may need new approval for existing Keychain items. The
connection UI identifies that stage separately from host networking. No
trust/pinning checks are bypassed.

## Controllers

Control Desktop or Capture Mouse also enables GameController forwarding. Pair a
DualSense or Xbox controller in macOS first. Up to 16 extended-profile controllers
are forwarded, as Nightjar; the engine folds them to four for hosts that take no more
(GameStream). Each has positional A/B/X/Y face buttons (Cross/Circle/Square/Triangle on
PlayStation), d-pad, shoulders, stick clicks, Menu/Options, analog triggers, and both
sticks. Sticks use a radial dead zone (12% unless changed in Settings → Controls) rescaled to full travel; triggers use 0–255.
Where the controller has them, Guide/Home, the touchpad click (DualSense, DualShock 4),
Share and paddles 1–4 (Xbox) are forwarded too; Guide and Share stop opening the Mac's
own overlays while the stream has input. Touchpad contacts and DualSense adaptive
resistance effects are not forwarded.

Arrivals name the controller type (Xbox, PlayStation, Nintendo or unknown), so the
host can emulate a matching pad, and list exactly the buttons the controller has.
They advertise analog triggers, the feedback motors macOS exposes, and the motion
sensors, battery and light the controller reports. The touchpad is not advertised:
GameController gives no reliable finger-down state, so no contacts could be sent.

- **Motion.** The host asks for each sensor and its rate; GCMotion runs only while
  asked and reports at most at that rate. The accelerometer is sent in m/s² with
  gravity as an upward reaction (CoreMotion's sign flipped, as Android reports it),
  the gyroscope in degrees per second. Axes are GameController's; whether they match
  the host's pad axes is unverified until a physical playtest.
- **Battery.** Sent after the arrival and whenever the level or charging state
  changes (checked every 5 seconds).
- **Light.** The host's colour sets the controller's light.

Hosts that take no motion or battery reports refuse them; that is not an input
failure, and the stream carries on.

Host-driven handle rumble now uses GameController-created Core Haptics engines.
Low/high amplitudes target the left/right handles separately when available;
otherwise their maximum drives the controller's default haptic locality. Trigger
rumble is advertised only when both trigger motor engines can be created. Trigger
rumble is vibration, not DualSense adaptive trigger resistance. System-disabled
or unavailable haptics leave controller input working without a feedback claim.

Feedback uses a fixed Rust mailbox of 80 states (16 slots; handle and trigger
motors, light, and the two sensor rates), coalescing to the latest value, including
zero stops. A serialized worker poll
and an awaited main-actor loop bound delivery. Capture epochs are echoed through
controller arrivals and polled feedback; old polls and old slot bindings are
rejected after release/reactivation or unplug/replacement. ABI 4 adds typed arrivals,
motion and battery entry points; the callback and configuration layouts are unchanged.

Release, focus loss, unplug, disconnect, reconnect recovery and teardown stop the
controller's players and engines. A motor error disables feedback for that
controller, updates its advertised capabilities and records a diagnostic while
leaving input active. Engine resets invalidate cached players without replaying
old effects. PCM haptics, controller audio and adaptive triggers remain separate work.

Connected devices contribute a 16-bit gamepad mask to host launch/resume. During
capture, connect/disconnect notifications update the active mask and reuse free
slots without moving surviving controllers. Unplug sends a neutral state. Focus
loss, the release shortcut, disconnect, and quit disable handlers and neutralize
controller slots accepted by the engine. Reactivation takes fresh snapshots, so
held controls reflect the current physical state. Unsent events share the same
256-event mailbox and epoch invalidation as keyboard/mouse. Stick-only changes can
coalesce; button and trigger transitions remain ordered. Each sensor and battery keeps
one queued reading, replaced by newer ones but never moved ahead of an arrival that
reassigned its slot.

Snapshot-controller tests exercise the actual GameController profile mapping,
including d-pad directions/diagonals, signed stick extremes, trigger conversion,
four-device capacity, slot reuse, disconnect/reconnect, queued callback rejection,
and overflow shutdown. Core tests cover invalid analog values, coalescing boundaries,
and neutral-state release retries. The C smoke test covers controller entry points
and slot/mask rejection. Xcode validation: 98 tests, 94 passed, four AV1 hardware
skips. Rust: 11 passed; C ABI smoke: PASS.

Since 2026-10-31, tests also cover 16-slot capacity, typed arrivals with Apple's
virtual pad (which reports an accelerometer), battery after arrival, light and sensor
rates routed only to controllers that have them, readings from a released or replaced
controller dropped, sensor/battery coalescing, and the engine's slot, button,
capability, type, motion and battery checks.

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
