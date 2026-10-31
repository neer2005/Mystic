# Human Interface Guidelines review checklist

Review and improve Mystic’s alignment with Apple’s [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines).

Work on a `codex/` feature branch. Run relevant checks, commit the completed work, and merge into `main`, following `AGENTS.md`.

## Tasks

- [ ] **Fix the resolution picker layout.** Keep the selected resolution concise; put display name and aspect ratio in secondary text. Ensure the picker indicator remains visible.
- [x] **Complete menu-bar commands.** Expose relevant library and streaming actions, including refresh, favourites, and input capture. Use context-sensitive availability and appropriate shortcuts.
- [ ] **Unify library keyboard navigation.** Give Home and host libraries consistent arrow-key selection, visible focus, scrolling to selection, and Return-to-play behavior.
- [ ] **Improve accessibility.** Expose favourite, availability, and running states on game cards. Test VoiceOver labels, focus order, status feedback, and Full Keyboard Access.
- [ ] **Clarify the quit action.** Name the actual running game in the button and confirmation, especially when it differs from the selected game.
- [ ] **Simplify the game inspector.** Reduce repeated information and artwork height. Present a compact video summary with expandable details so common controls are easier to reach.
- [ ] **Standardize artwork presentation.** Make card backgrounds and fitting behavior consistent across different artwork proportions.
- [ ] **Associate search with the library.** Make its placement and scope clear rather than appearing tied to the inspector.
- [ ] **Consolidate sidebar connection information.** Reduce repeated host names and group pairing status and connection actions clearly.
- [ ] **Review context menus.** Hide unavailable contextual actions where appropriate under Apple’s guidance.
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

## Review scope

The library and General/Video Settings were visually inspected on October 31, 2026. Streaming, full-screen behavior, and VoiceOver remain unverified. Treat visual suggestions as findings to validate, and preserve working behavior.
