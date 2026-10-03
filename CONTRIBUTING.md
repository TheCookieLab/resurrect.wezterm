# Contributing

[Overview](README.md) · [Usage guide](docs/usage.md) · [Changelog](CHANGELOG.md)

This fork prioritizes predictable recovery on stable WezTerm. Keep fixes focused,
include a behavioral regression when appropriate, and describe what you exercised.

## Repository layout

| Path | Purpose |
|---|---|
| `plugin/init.lua` | Plugin entry point for URL loading and offline vendoring |
| `plugin/resurrect/` | Capture, layout restoration, storage and picker modules |
| `plugin/types.lua` | Lua type annotations |
| `tests/test_resurrect.py` | Python stdlib runner for the embedded-Lua fixtures |
| `tests/layout.lua` | Pane geometry, selection, spawning and session behavior |
| `tests/storage.lua` | Paths, real filesystem I/O, backups and checkpoint recovery |
| `docs/usage.md` | Installation, API contracts and integration limits |
| `.github/workflows/tests.yml` | Windows, Linux and macOS test workflow |

Runtime snapshots belong in a private directory outside this checkout. The library
creates its state subdirectories at runtime; no checked-in `state/` tree is needed.

## Run the tests

Install [WezTerm](https://wezterm.org/installation.html) and Python 3. CI uses Python
3.12 and WezTerm `20240203-110809-5046fc22`, the supported compatibility floor.
Make sure `wezterm` is on `PATH`, then run from the repository root:

```sh
wezterm --version
python3 -m unittest discover -s tests -v
```

On Windows:

```powershell
wezterm --version
py -3 -m unittest discover -s tests -v
```

No pip packages, standalone Lua interpreter, Busted installation or running terminal
session are required. Temporary configurations and state are isolated from your own
WezTerm configuration and snapshots.

### Why the tests use WezTerm

The Python runner loads each Lua fixture through `wezterm --config-file … show-keys --lua`.
This exercises the real embedded Lua runtime, JSON conversion, directory listing and
file operations. The geometry fixture supplies a deterministic mux model because
`show-keys` has no live panes; it is not a native GUI test.

A fixture must write an explicit success marker after all assertions pass. Exit status
alone is insufficient: WezTerm can fall back to its default configuration after a Lua
error. A missing WezTerm installation fails the suite rather than silently skipping it.

Replacing WezTerm with a standalone Lua runner would require substitute implementations
of host APIs and weaken the storage/integration coverage. Keep these tests on the actual
runtime; add isolated pure-Lua tests only when they provide distinct behavioral coverage.

### Continuous integration

[The test workflow](.github/workflows/tests.yml) runs on pushes, pull requests and manual
dispatches, on `ubuntu-22.04`, `windows-2022` and `macos-15` (Apple Silicon). All jobs
install the exact compatibility-floor release from the official WezTerm GitHub assets,
verify its SHA-256, then run the same unittest command used locally. The Windows
archive and macOS application bundle are extracted into the runner's temporary
directory; the Linux job installs the official Ubuntu package.

The workflow needs no secrets, display server or SSH host. GitHub actions are pinned to
commit SHAs, and the token has read-only repository access. No dedicated WezTerm setup
action is required. When updating the runtime, update the release version, all asset
checksums and these compatibility notes together; do not replace a pinned release with
an unversioned package-manager install.

## Review checklist

- Preserve non-executing restoration: never replay snapshot argv or feed saved history
  into shell input. Remote attachment must remain an explicit integration decision.
- Preserve good saves on partial writes, corrupt input and failed restores. Do not
  silently omit or duplicate panes to make a layout appear to succeed.
- Use stable WezTerm APIs, keep startup free of setup subprocesses, and avoid adding
  helper plugins or runtime dependencies without a concrete need.
- Keep capture/restore contracts and examples in the usage guide current. Record
  user-visible changes and upstream attribution in the changelog, not the README.
- Tests should prove observable behavior or failure boundaries, not source text,
  mocked forwarding calls or incidental defaults.

## Native acceptance

Changes to spawning, layout, history or lifecycle behavior also need a real GUI smoke
run in an isolated configuration/state directory. Check counts and geometry, titles,
active/zoomed panes, usable fresh prompts, history after resize, and failure recovery.
Never close the contributor's normal terminal or use live snapshots as fixtures.

The separate [terminal-profile suite](https://github.com/TheCookieLab/terminal-profile/tree/main/tests)
covers its checkpoint scheduling, startup policy and SSH placeholders. Prior native
Windows acceptance exercised multi-workspace/grid/zoom/history restoration, PowerShell
redraw, native-close/crash recovery, corrupt state, missing directories, denied writes
and real SSH/tmux reconnection. Native macOS/Linux GUI behavior remains unverified;
headless CI is not a substitute for that proof.
