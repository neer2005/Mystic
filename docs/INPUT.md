# Keyboard and mouse input

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
the host keyboard layout; local IME composition, clipboard synchronization, and
controller forwarding are separate work. macOS-reserved shortcuts may switch
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
Caps Lock, repeat suppression, button numbering, letterboxing, flipped coordinates,
fractional/clamped movement, coalescing, overflow, and release retry behavior.
Desktop tests cover scheduling, batch invalidation, closed-mailbox rejection, and
refusing capture without a connection/image. The C smoke test covers the additive
horizontal scroll entry point.

Live Desktop keyboard/mouse, relative capture, focus loss, and release-chord checks
are performed after building with `scripts/build-macos-app.sh`. A visible host
window is required to verify that input reached the host; a successful enqueue is
not proof of delivery.
