# Session graphics controls

Open Host Session in either toolbar, then choose Graphics. Mystic reads Rubylight's
native Radeon API over the same paired, certificate-pinned Nightjar connection.
It displays each GPU, driver, toggle, integer range/step, choice and current value.
Settings unknown by name are rendered by their host-reported type. Unsupported,
read-only, external-setup and temporarily unavailable states show an explanation.
A host without the endpoint receives an unavailable notice rather than empty controls.

Changes require Host control and this device's owned streaming/suspended session.
Before each write the bridge rereads session ownership/app identity and panel revision,
then validates the GPU, setting, state, type, range/step or allowed choice. Changed
snapshots are refused; the host remains authoritative if another writer races the
check. Each request changes one setting. Unknown kinds remain read-only.

The UI displays values returned by the host, not optimistic local values. On a write
failure Mystic rereads the panel, since the driver may have applied part of a request.
The error remains visible while polling refreshes actual state. Failed reads disable
editing. Writes are serialized with host exit actions. Late results from a disconnected
or replaced connection are discarded.

Polling runs only while Graphics is visible, every two seconds, and pauses during
writes. Restore My Graphics Changes confirms before restoring the changes made by
this device; it also checks the original connection and panel revision. Per-setting
restore notes show original values. End Session restores temporary host changes;
Disconnect retains them for resume, following the host's policy.

Automated checks cover permissions, unknown states/types, numeric bounds/steps,
choices, stale revisions, host read-back after failure and connection isolation.
Live Big Dawg verification on 2026-10-31 confirmed RX 9070 XT / driver 26.10.1,
reported toggles, choices, numeric limits/steps, unsupported and read-only rows, and
the Host control permission notice with disabled editing. Layout was inspected in
the running app. Real writes and restoration remain pending: grant this device
Host control on Big Dawg, start a stream, change a reversible setting, compare the
host's read-back, then use Restore My Graphics Changes and verify original values.
No host permissions or live driver settings were changed during this implementation.

This is the Radeon host-settings panel, not a Mac GPU tuner. Other host vendors,
live bitrate/FPS controls, co-op and further session features remain tracked in
NIGHTJAR-PARITY.md.
