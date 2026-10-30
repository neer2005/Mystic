# UI design — first-party macOS 27

The target is "this looks like Apple shipped it." That is a discipline, not a theme:
use the system's own structure, controls, materials and behaviours, and add no
custom chrome.

## Principles

1. **No custom-drawn window furniture.** Standard `NSWindow`/`WindowGroup` title bar,
   unified toolbar, standard traffic lights. No custom title bar, no rounded-corner
   overlay, no hand-rolled sidebar.
2. **System structure first.** Three-pane `NavigationSplitView`:
   **Hosts → Library → Detail**. Collapsible sidebar, `.searchable` on the content
   column, inspector for stream details.
3. **System typography and colour.** Semantic fonts (`.title2`, `.body`,
   `.callout`, `.monospacedDigit()` for numbers), semantic colours, no hard-coded
   greys. Everything must hold up in light, dark, and increased-contrast modes.
4. **Materials, not gradients.** Liquid Glass belongs on floating controls and
   overlays (the stats HUD, the disconnect pill, in-stream toasts), not on window
   backgrounds. Verify the current modifier names against the macOS 27 SDK before
   writing them — the API surface moved in 26 and may have moved again.
5. **Keyboard is the primary input.** Every action has a menu item and a shortcut.
   Full keyboard navigation in the library grid. No mouse-only affordances.
6. **Nothing modal that can be inline.** Settings use the standard `Settings` scene
   with tabs, not sheets. Pairing uses an inline PIN field, not a dialog stack.

## Window layout

```
┌────────────┬────────────────────────────────┬──────────────┐
│ Sidebar    │ Content                        │ Inspector    │
│            │                                │ (optional)   │
│ ● MacBook  │  ┌────┐ ┌────┐ ┌────┐          │ Stream       │
│   Studio   │  │game│ │game│ │game│          │ Codec   HEVC │
│            │  └────┘ └────┘ └────┘          │ 4:4:4    on  │
│ Library    │                                │ HDR      on  │
│  All       │                                │ Bitrate  80  │
│  Recent    │                                │              │
└────────────┴────────────────────────────────┴──────────────┘
```

- Sidebar sections: **Hosts** (with online/idle state), **Library**, **Recent**.
- Content: adaptive grid of app tiles with box art when the host provides it,
  otherwise a monogram tile in the system accent.
- Inspector: per-app stream overrides. Hidden by default, `⌥⌘I` to toggle.

## Screens

- **Hosts** — discovered hosts (mDNS) and manual entries; last seen, address, host
  type, firmware. Add host is an inline row, not a modal.
- **Pairing** — host shows a 4-digit PIN; the window shows a focused numeric field
  with the digits in `.monospacedDigit()`. Errors appear inline, never as an alert.
- **Library** — grid, sortable, filterable. Hover reveals a play affordance; `Space`
  previews details. Context menu mirrors the menu bar items.
- **Streaming window** — borderless full-screen by default, entering a full-screen
  space (not a fake fullscreen). Cursor hides after idle. Esc holds to disconnect,
  with a Liquid Glass progress pill. No visible HUD unless enabled.
- **Stats HUD** — floating, Liquid Glass, `⌃⌘S` to toggle. Shows the per-stage
  latency figures from `LatencyHistogram`, FPS, bitrate, decode time, and dropped
  frames. Monospaced digits so values do not jitter.
- **Settings** — standard tabs: General, Video, Audio, Input, Network, Advanced.
  Advanced contains the experimental toggles (Metal renderer, PyroWave, mic
  passthrough) each with an explicit "unstable" note.

## Menu bar

`File` (Connect, Disconnect), `Session` (Full Screen, Toggle Stats, Send Key
Combination), `View` (Sidebar, Inspector, Grid/List), `Host` (Wake, Pair, Forget).
Standard `Window`, `Help`. Every item backed by a `Commands` group.

## Feel

- Animations: system defaults only, plus a short cross-fade entering full-screen.
  Nothing bouncy.
- Sound: none. Streaming apps should be silent.
- Launch: window restored to last selection; a host is never auto-connected.
- Accessibility: full VoiceOver labels on tiles and controls, respects Reduce Motion
  and Increase Contrast, supports Dynamic Type equivalents in the library.

## App icon

Multi-layer Liquid Glass icon authored in Icon Composer: a dark base, an aurora-like
gradient sweep, and a single bright glyph. No text, no border, no shadow of its own —
the system draws the platform shadow.


## Implemented shell — 2026-10-27

The library now uses a standard three-column NavigationSplitView: native host
sidebar, searchable app library, and a grouped-form Stream Details column. Grid
and native list views share the selected app. Name/host-order sorting and an HDR
filter operate on the current host's app list. The grid uses SF Symbols when art
is unavailable; it does not fabricate covers. Arrow keys move selection in the
grid, and the native list supplies list keyboard behavior. Command–F focuses the
library's search field through a command scoped to that window. Standard sidebar
commands and the toolbar control use the system split-view behavior.

Mystic → Settings (Command–Comma) is a SwiftUI Settings scene. Its native toolbar
has General, Video, Audio, and Network panes, with the last pane restored and the
window title following the active pane. Only implemented controls are exposed.
There are no speculative experimental switches. System typography, SF Symbols,
semantic foregrounds and native form/control backgrounds handle the interface;
no custom window furniture, gradients or glass backgrounds were introduced.

These choices follow Apple's [sidebar guidance](https://developer.apple.com/design/human-interface-guidelines/sidebars),
[Settings guidance](https://developer.apple.com/design/human-interface-guidelines/settings),
and [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).
The design principle is to let standard components acquire current system styling.

Global stream settings persist in Settings. Stream Details selects global defaults,
host defaults or a custom game profile, with an inherited-value summary and a
separate host-defaults editor; see [PROFILES.md](PROFILES.md). Box-art retrieval,
a recent-app collection, and a collapsible detail inspector remain later polish. Video and host
channel layout are fixed during a stream; local volume/mute and HUD visibility
remain live. See [SETTINGS.md](SETTINGS.md) for storage and validation.

The live UI was checked in the Mac's current dark appearance. Separate light-mode,
increased-contrast, and VoiceOver acceptance remain to be performed; native
components provide the system behavior but that is not a substitute for those checks.

### Stream window fullscreen role

The stream scene explicitly uses `.windowManagerRole(.principal)`. Runtime
inspection of the broken window found collection behavior `0x20100`: auxiliary
plus fullscreen-auxiliary, with unrestricted maximum size. That role disabled the
native fullscreen command and made `toggleFullScreen` ineffective. Changing the
scene role enables the native menu and green fullscreen control without overriding
content sizing or replacing the toolbar action. Verified in the rebuilt stream
window: View → Enter Full Screen enters a native space, the menu becomes Exit Full
Screen, and the existing toolbar button exits it. This window-only verification
does not require starting or reconnecting a host stream.
