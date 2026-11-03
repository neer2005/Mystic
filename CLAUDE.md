# Maintaining Mystic

Mystic has two developers: its owner and Claude. These are the working rules.

- **Latency first.** Measure any change to video, audio or input for added delay before it
  merges; a change that adds delay doesn't ship, however much smoother it looks.
- **Branches.** Work on a short-lived branch, run the checks, then merge into `main` with
  `--no-ff`. Push `main` when a piece of work is done. Tag only when the owner asks for a
  release.
- **Checks.** `bash engine/scripts/test-c-abi.sh`, `swift test`, and
  `bash scripts/build-macos-app.sh` must pass, with no compiler or clippy warnings.
- **Live tests** use the owner's PC, Big Dawg, with testufo.com open in its Desktop app. Leave
  their settings as found: `defaults export com.mystic.streaming` before, `import` after. Ask
  before closing a Mystic window that isn't yours.
- **Nightjar parity.** Mystic follows Nightjar's behaviour unless the Mac needs otherwise. When
  moving the engine pin, rebuild, run the tests and compare a TestUFO run before and after.
- **Docs.** Keep the README current. Explain the non-obvious in code comments next to it,
  not in separate documents.
