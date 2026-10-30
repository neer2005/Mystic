# Clipboard text sharing

The stream toolbar's Clipboard menu provides **Send Text to Host** and **Copy Host
Text to Mac**. These are explicit actions; simply connecting or starting a stream
does not read or send clipboard contents. Host read and write permissions are
checked separately. Unsupported/denied directions are disabled, and the bridge
checks fresh pinned-HTTPS host permissions again before each manual request.

Manual transfers use Nightjar's text clipboard API over the paired host's pinned
HTTPS connection. Plain UTF-8 text up to 1 MiB is accepted; NUL characters are
refused. Files, image fallback strings and concealed/transient/generated clipboard
items are not sent as text. Copy Host Text to Mac may replace the current item
because it is an explicit action, but only if the active window and Mac clipboard
are unchanged when the response arrives. Failures are shown in the Clipboard menu.

## Automatic text sync

Enable **Settings → General → Sync Clipboard Text** before starting a stream.
It defaults off, including with older saved settings, and is locked during a
session. The launch/resume requests the host's clipboard-sync extension; the
engine uses it only if the RTSP handshake announces control message 0x5508. Hosts
without that extension can still use manual clipboard transfer when permitted.

The Mac pasteboard is polled only while the stream window is active. Existing
text at stream start stays local, as does text copied while another window/app is
active: returning to the stream establishes a fresh baseline without sending it.
New nonempty foreground copies are shared using Nightjar's existing token/echo
rules, including line-ending normalization. Empty copies do not clear the other
side automatically.

Sync is text only, up to 65,490 UTF-8 payload bytes per copy. Larger plain-text
copies can use the manual command up to 1 MiB. Files, images, protected clipboard
items and newer local copies are preserved instead of being overwritten by
incoming sync. Our own host-to-Mac writes do not become local edits on the next
poll. A newly observed local edit takes precedence over older queued host text.

Focus notifications invalidate in-flight writes; returning to the stream
baselines again. Disconnect and automatic recovery stop the old coordinator, and
a resumed session starts a new one. Late responses cannot change the clipboard
after teardown. The engine holds one latest incoming text copy rather than an
unbounded queue, and no clipboard contents are logged. A sync error stops sync
with an explanation while leaving the stream and manual commands available.

## Validation

Automated checks use fake transports and isolated, private NSPasteboards, never
the user's general clipboard. They cover Unicode, byte/NUL limits, directional
permissions, initial/background baselines, off-by-default migration, echo
suppression, foreground changes, newer local copies, non-text protection,
unsupported hosts, and responses arriving after stop. Rust tests exercise the
shared clipboard rules, and C smoke tests exercise owned error responses.

Live clipboard interoperability with the paired host remains pending. Image
clipboard, file transfers and shared folders are separate work.
