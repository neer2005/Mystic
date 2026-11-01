# Human Interface Guidelines review checklist

Review and improve Mystic’s alignment with Apple’s [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines).

Work on a `codex/` feature branch. Run relevant checks, commit the completed work, and merge into `main`, following `AGENTS.md`.

## Tasks

- [x] **Fix the resolution picker layout.** Keep the selected resolution concise; put display name and aspect ratio in secondary text. Ensure the picker indicator remains visible.
- [x] **Complete menu-bar commands.** Expose relevant library and streaming actions, including refresh, favourites, and input capture. Use context-sensitive availability and appropriate shortcuts.
- [x] **Unify library keyboard navigation.** Give Home and host libraries consistent arrow-key selection, visible focus, scrolling to selection, and Return-to-play behavior.
- [ ] **Improve accessibility.** Expose favourite, availability, and running states on game cards. Test VoiceOver labels, focus order, status feedback, and Full Keyboard Access.
- [x] **Clarify the quit action.** Name the actual running game in the button and confirmation, especially when it differs from the selected game.
- [x] **Simplify the game inspector.** Reduce repeated information and artwork height. Present a compact video summary with expandable details so common controls are easier to reach.
- [x] **Standardize artwork presentation.** Make card backgrounds and fitting behavior consistent across different artwork proportions.
- [x] **Associate search with the library.** Make its placement and scope clear rather than appearing tied to the inspector.
- [x] **Consolidate sidebar connection information.** Reduce repeated host names and group pairing status and connection actions clearly.
- [x] **Review context menus.** Hide unavailable contextual actions where appropriate under Apple’s guidance.
- [ ] **Inspect the streaming interface visually.** Check toolbar crowding, overflow, input-release discoverability, and full-screen behavior.
- [ ] **Validate layout and appearance.** Check compact windows, long titles and values, expanded settings, light/dark appearance, and increased accessibility contrast.

## Acceptance criteria

- Common library actions work with keyboard-only navigation.
- Controls and values remain readable without clipping or obscured indicators.
- Destructive actions clearly identify their target.
- VoiceOver exposes meaningful labels and states.
- Provide before/after screenshots and a short validation report; identify anything that could not be tested.

## Progress

- 2026-10-31: Menu-bar commands and the stream toolbar were reworked (see the
  implemented menus in `UI-DESIGN.md`). Checked in the running app against Big Dawg's
  Desktop session: menu availability on Home, host library and stream; ⌘1/⌘2, ⌘R, ⌘I,
  ⌥⌘L, ⌃⌘M and the ⌃⌥⇧⎋ release; Customize Toolbar; disconnect. Not yet checked:
  full-screen toolbar behaviour, Mute Microphone with the microphone enabled, Retry
  Audio with an unavailable output, VoiceOver for the new items. The streaming-interface
  item below stays open for those.
- 2026-10-31: Home and the host library share `GameGrid` (see `UI-DESIGN.md`). Checked in
  the app: arrow keys on Home (which previously had none) and the host grid,
  scrolling to the selection, accent/grey selection with and without focus, click,
  double-click and Return playing a game, context-menu Play, and Return in the search
  field still only searching. Accessibility Inspector confirms each card's label and
  value (for example "007 First Light", "Steam, on Big Dawg, Online"). Accessibility
  Inspector did not list the cards' custom actions, so the same commands are also in
  each card's context menu.
- 2026-10-31: Checked by the user with VoiceOver: cards read their title, state and
  selection, and the Actions menu (VO-⌘-Space) offers Play and Favourites on Home and
  Start/Resume Stream in a host library. Focus order across the window and Full
  Keyboard Access remain to be checked, so the accessibility item stays open.
- 2026-10-31: Library window pass. Each change was checked in the running app against
  Big Dawg:
  - *Resolution picker*: shows only the size (for example 3024 × 1890) with its
    indicator; the purpose and aspect ratio are caption text beneath it.
  - *Quit*: the button names the running game ("Quit Desktop…") even when another game is
    selected, and the standard confirmation dialog asks "Quit Desktop on Big Dawg?" with a
    destructive "Quit Desktop" button. For a switch it reads "Quit and Start …". Checked
    by opening and cancelling only; no game was quit.
  - *Details panel*: a 72-point cover beside the title and store/HDR line, Start and Quit
    below it, and the video settings as a one-line summary with a Details disclosure.
  - *Artwork*: art in the 2:3 card shape fills it; other shapes (square store art, 3:4
    covers) are fitted over a blurred fill of themselves, in grids and details alike.
  - *Search*: centred in the toolbar above the library and scoped by its prompt
    ("Search Big Dawg", "Search Home").
  - *Sidebar*: the separate host section is gone. The connected host's row shows its state
    ("Connected", "Pairing required", "Streaming") and a Finder-style eject button.
    Pairing moved to the library pane, with the PIN shown inline; the connecting state
    there has a Cancel button.
  - *Context menus*: list only what can be done now — Start or Resume, Quit for the
    running game, Disconnect or Connect and Remove for a host.
  - *Keyboard*: choosing a host in the sidebar left SwiftUI unable to focus the grid, so
    arrow keys stopped working (this affected the previous release too). The grid now
    takes keys through an AppKit first responder; arrows and Return work after sidebar
    use on Home and the host library.
  - *Layout and appearance*: checked at the minimum window size (the video summary
    wraps, nothing clips), with long titles, and in light appearance via
    `-NSRequiresAquaSystemAppearance YES`.

  Not tested: the inline pairing view (no unpaired host was available), Increase
  Contrast (a system setting), Tab order and Full Keyboard Access, and the stream window.
- 2026-10-31: Full screen. View → Enter Full Screen was missing whenever the stream window
  was in front, and the Grid/List toggles removed it everywhere. Mystic now owns the
  item and follows the focused window (see `UI-DESIGN.md`). Checked in the app: one item
  on Home and the host library, present while streaming, Enter from the menu, the title
  changing to Exit Full Screen, ⌃⌘F out, and Disconnect from full screen closing the
  stream window and its Space. Not tested: a stream ending with an error while in full
  screen, which should leave full screen and keep the window.

## Review scope

The library and General/Video Settings were visually inspected on October 31, 2026. Streaming, full-screen behavior, and VoiceOver remain unverified. Treat visual suggestions as findings to validate, and preserve working behavior.
