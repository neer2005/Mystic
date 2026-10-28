# Host discovery and saved hosts

The library sidebar offers Saved Hosts, Nearby Hosts, and Manual Host.
Click a saved or nearby entry to connect. Successful server-info requests save
unpaired hosts; paired hosts are saved after the pinned app-list request succeeds.
A successful connection updates the display name and moves that endpoint to the
front of the list. The most recent saved endpoint fills the manual form on launch.
Nothing automatically connects to a host or launches an app.

Saved entries contain only a label, normalized address/port, host ID metadata,
and last-connected date. The versioned `savedHosts.v1` UserDefaults document holds
at most 32 entries. The old last-address/port preference is migrated once when no
catalog exists. Removing every entry persists an empty catalog, so migration does
not bring removed entries back. Removing an entry does not unpair it or delete its
Keychain certificate; the remove button explains this. Corrupt or unsupported
catalog data produces a message while manual connections remain available.

Identity and certificates remain in Keychain. Pin lookup uses the same lowercase
`address:port` key as before. Display name and host UUID do not merge endpoints or
transfer certificates. Different addresses/ports remain distinct even if they lead
to the same PC. A new address without a local certificate offers PIN pairing,
even if its HTTP server-info says the host recognizes Mystic's client identity.
Existing pinned endpoints continue to use HTTPS without an HTTP fallback.

## Bonjour

The pinned Nightjar desktop implementation browses `_nvstream._tcp.local.` and
uses the advertised SRV port. Mystic uses Foundation's NetService browser on the
main run loop with a five-second resolution timeout. The service's resolved DNS
hostname (without its terminal root dot) and advertised port become the endpoint;
using a stable `.local` hostname avoids rebinding a saved address on DHCP changes.
Advertisements are only address suggestions. Browsing never reads credentials,
probes HTTP, or changes a saved entry. User selection starts normal host control.
The app declares `_nvstream._tcp` in NSBonjourServices and retains its Local Network
usage description.

Browsing is idempotent and begins with the library view. Closing that view stops
it; Refresh Discovery cancels current resolutions and starts a fresh generation.
Departing services leave Nearby Hosts but do not remove saved entries. At most 64
services are retained/resolved; duplicate resolved endpoints produce one row.
Late browser/resolver callbacks cannot repopulate a stopped/restarted browser.
A browsing error points to Local Network access in System Settings and keeps the
manual form available.

mDNS normally stays on the local multicast network. A host reachable by a VPN or
other routed address may never appear under Nearby Hosts. Save its manual address
instead. The sidebar does not infer "online" from a saved record or "paired" from
an untrusted advertisement.

## Validation — 2026-10-27

Xcode 27 / Swift 6.4: 111 tests, 107 passed and four AV1 hardware skips. Tests cover
endpoint validation, advertised-port/hostname mapping, bounded persistence and
round trips, exact-endpoint updates, migration/removal across restart, corrupt
preferences, saved-endpoint pin reuse, discovery sorting/deduplication/bounds,
service removal and stale generation callbacks. Rust: 12 passed, including the
new-address/local-pin pairing case; C ABI smoke: PASS.

The actual app discovered a temporary local `_nvstream._tcp` advertisement as
"Mystic Discovery Fixture", showing its resolved `.local` hostname and port.
Stopping the advertisement removed its row. The fixture and diagnostic browse
process were stopped afterward. No Big Dawg advertisement was observed on this
LAN; its existing saved address remains usable. Discovery across a real host's
multicast network and Local Network denial/recovery are separate environmental
acceptance checks.

After an app restart, the migrated saved address was still listed. Clicking it
reconnected to Big Dawg using the existing endpoint pin, loaded the paired app
library, and replaced the address-only saved label with "Big Dawg". The final
app build and ad-hoc signature verification pass.
