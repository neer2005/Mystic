# Launching from a frontend, a script or a link

Game frontends (ES-DE, Pegasus, Playnite, LaunchBox), scripts and shortcuts can start a
stream without going through the library, as with Nightjar's desktop command line.

## Command line

```
Mystic.app/Contents/MacOS/MysticApp --host <name|id|address> [--app <name|id>] [--quit-on-exit]
Mystic.app/Contents/MacOS/MysticApp --version
```

- `--host` names a saved, paired PC: its host ID, its address (`10.0.0.2` or
  `10.0.0.2:47989`), or its name, ignoring case. A name two saved PCs share is refused.
- `--app` names an app by its ID or name, ignoring case. Without it, the PC's library opens.
- `--quit-on-exit` quits Mystic when that stream ends, so the frontend gets its window back.
- `--name value` and `--name=value` both work. macOS's own `-NS…` arguments are ignored.

Exit codes follow Nightjar's: 0 after a stream ran (or `--version` and `--help`), 1 when the
PC or app cannot be found or the stream never starts, and 64 for a wrong command line. If
another game is running on the PC, the usual confirmation asks before closing it. A start
that fails prints its reason to standard error.

## Links

`mystic://stream?host=<name|id>&app=<name|id>&quit-on-exit=1` does the same from a browser,
a Shortcuts action or `open`. Any web page can open such a link, so Mystic always asks
"Start <app> on <PC>?" first and connects only when you choose Start. A failure is shown in
the library window.

## Making one

In a library, right-click a game and choose **Copy Launch Link** or **Copy Command Line**.
Both use the PC's host ID and the app's ID, so they keep working after a rename. The copied
command line is quoted for the shell.

## Verification

Tests cover both spellings of each option, usage errors, skipped macOS arguments, links in
both directions, shell quoting, PC and app matching by ID, address and unique name, the launch
through to a stream, quitting with 0 after it ends and 1 when it never starts, and a link that
waits for confirmation. The built app prints its version and usage and exits with 64 for an
unknown option. Launching from a real frontend has not been tried yet.
