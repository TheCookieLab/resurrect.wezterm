# resurrect.wezterm

Maintained fork of [MLFlexer/resurrect.wezterm](https://github.com/MLFlexer/resurrect.wezterm),
which is archived. Saves and restores WezTerm workspaces, windows, tabs, split layouts,
selection, zoom, titles, working directories and bounded local terminal history.

This fork restores **fresh shells, not running programs**. It never executes saved argv
or sends historical output as shell input. Remote domains do not reconnect automatically.
The [terminal-profile integration](https://github.com/TheCookieLab/terminal-profile)
adds startup restore, debounced checkpoints, a recovery picker and SSH placeholders that
reconnect to the existing remote tmux session only after Enter.

Compatibility floor: WezTerm `20240203-110809-5046fc22`. No helper plugin, nightly API,
standalone Lua runtime or configuration-time subprocess/network fetch is required by the loader.

## Loading

The normal WezTerm plugin loader works:

```lua
local wezterm = require 'wezterm'
local resurrect = wezterm.plugin.require 'https://github.com/TheCookieLab/resurrect.wezterm'
```

For reproducible offline configuration, copy a committed `plugin/` tree and `LICENSE`
into `vendor/resurrect/` beside your config, add the config directory to `package.path`,
and use `require 'vendor.resurrect.plugin'`. terminal-profile uses this approach and
records the exact fork revision in its README. Loading does not create a state directory.
No plugin updates or development-helper dependencies run during configuration evaluation.

## Full-session API

Configure an absolute state directory before saving. **The library does not secure its
permissions for you.** Create a private directory first (mode 0700 on POSIX, protected
current-user DACL on Windows). Keep it outside your checkout and plugin cache.

```lua
-- Called after your application's private-directory setup:
local manager = resurrect.state_manager
assert(manager.change_state_save_dir('/absolute/private/wezterm-state'))
manager.set_max_nlines(3500)

-- Called by a runtime action, not during configuration evaluation:
local snapshot, capture_error = resurrect.session_state.capture()
if not snapshot then
  wezterm.log_error(capture_error)
  return
end
local path, warning_or_error = manager.save_session(snapshot)
if not path then
  wezterm.log_error(warning_or_error)
elseif warning_or_error then
  wezterm.log_warn(warning_or_error)
end
```

- `session_state.capture(opts?) -> state | nil, error`: every mux window, grouped by
  workspace; includes active workspace/window, ordered tabs, cell sizes and pane trees.
  Rejects empty or inconsistent captures rather than replacing a good save.
- `state_manager.save_session(state) -> path | nil, warning_or_error`: validated,
  immutable `session/snapshot-<20-digit-generation>.json`; retains the newest three
  valid generations only after successful publication. Corrupt generations are preserved.
- `state_manager.load_session(path?) -> state | nil, warning_or_error, info`: newest
  valid generation by default, falling back past corrupt files. Inspect the warning
  even when a state was returned. A missing initial session is a normal fresh start.
- `state_manager.list_sessions() -> records, warning_or_error`: newest valid generations
  with immutable-path `id`, `generation`, `saved_at`, `windows`, `tabs`, `panes` and decoded `state`.
- `session_state.restore(state, opts?) -> windows | nil, error, partial_windows`:
  validates before spawning; creates new windows without closing existing ones or
  mutating the decoded state. `opts.workspace_names` maps saved workspace names to
  new names for additive recovery. The caller handles partial failures and startup policy.

## Capture and restore options

`get_tab_state(tab, opts?)`, `get_window_state(window, opts?)`,
`get_workspace_state(opts?)` and `session_state.capture(opts?)` accept:

- `capture_process = true` to retain available process metadata for library consumers;
  default false. Missing process info/name is valid. Metadata is never replayed.
- `on_pane_capture(pane, leaf)` to attach serializable metadata. Returning false skips
  cwd, text and process capture, useful for SSH identities and private panes.
- `pane_tree.save_non_local_domains = true` is an opt-in module flag for non-local
  history capture. Default false. It does **not** authorize history injection there.

Restore options include:

- `spawn_pane(leaf, opts) -> SpawnCommand, optional_notice` to supply a trusted current
  spawn policy. Called for every initial pane, tab and split. Do not execute snapshot argv.
- `on_pane_restore(leaf)` receives a callback-local leaf copy with its live `pane`.
  `tab_state.default_on_pane_restore` inserts sanitized local history with explicit
  previous-session markers. Never inject this text through `send_text`.
- `on_warning(message)` receives one summarized set of nonfatal restore problems.
- Workspace restores support `spawn_in_workspace`, `workspace_name` and `window`.
  Only the reused window is moved; unrelated workspaces are never renamed or merged.

Default spawning uses fresh native-local or configured WSL shells. Other domains
(SSH, SSHMUX, Unix, TLS, missing WSL) become labelled local shells with a disconnected
notice. A missing local cwd falls back to the default directory with a warning; WSL
paths are not rewritten into Windows paths. Full-screen programs are not restarted.

History insertion must occur after the new shell has initialized. terminal-profile
queues delivery, rearms it after resize/reload, and blocks saving/recovery until it
finishes. History is moved above the redrawable fresh-shell viewport so PowerShell
redraw/resize does not erase it. Saved controls are stripped; fixed VT bookkeeping
preserves the live screen and cursor. History is plain text, not a terminal/application
state dump, and does not preserve colors or unsaved buffers. Built-in injection is
local-only, including when non-local capture is explicitly enabled.

Pane trees use a binary slicing representation: leaves have `kind='pane'`; splits
have `kind='split'`, `direction='Right'|'Bottom'`, `first`, `second`, `first_extent`
and `second_extent`. Integer-cell reconstruction accounts for the divider cell and
subtree minimum sizes. Aligned grids, T-shaped and nested layouts restore every pane
exactly once. Overlaps, holes, duplicate panes, ambiguous active selections and
undersized reused tabs fail explicitly instead of silently duplicating/dropping panes.
Use `pane_tree.first_leaf`, `leaves`, `map` and `fold`; map/fold visit leaves only.

## Named workspace, window and tab saves

The smaller state APIs remain available:

```lua
local manager = resurrect.state_manager
local snapshot, err = resurrect.workspace_state.get_workspace_state()
if snapshot then
  local ok, save_error = manager.save_state(snapshot, 'work')
  if not ok then wezterm.log_error(save_error) end
else
  wezterm.log_error(err)
end

-- Bind these returned actions in config.keys:
local save_window = resurrect.window_state.save_window_action()
local save_tab = resurrect.tab_state.save_tab_action()
```

`load_state(name, 'workspace'|'window'|'tab')` loads a named save and falls back to its
previous-good `.bak`. `fuzzy_loader.fuzzy_load(window, pane, callback, opts?)` supplies
literal relative IDs; `state_manager.parse_state_id(id)` returns type and decoded
name. Pass only listed IDs to `delete_state(id)`, not absolute paths.

Names are encoded as reversible UTF-8 hex with an `s-` prefix: separators, reserved
Windows names, case distinctions and trailing punctuation do not collide. Existing
upstream `+`-encoded filenames and the old pane-tree schema are not migration aliases;
use a new state directory. No directory creation via cmd.exe/VBS or recursive shell
listing remains. Named saves check writes, flush, close, validation and publication;
invalid destinations are quarantined without destroying a good backup.

Optional named-state encryption remains available through `state_manager.set_encryption`
and the existing age/rage/GPG implementation. It needs those external tools and is not
enabled by this fork or terminal-profile. **Full-session snapshots reject encryption**
with an explicit error if requested; they never silently write plaintext in that case.
The existing encryption command implementation has not been redesigned in this fork.

## Lifecycle limits

Stable WezTerm has no Lua shutdown/window-close callback. A configuration must use
runtime checkpoints for native close, OS shutdown and crashes, and a save-then-quit
action when an exact final flush is required. Do not save an empty teardown layout.
`gui-startup` does not run for `connect`/`--attach`; attach workflows need their own
`gui-attached`/mux-server policy. Never automatically restore onto an attached live mux.
Config reload is not a cold startup and must not trigger another restore.

One persistent GUI process should own each state directory. This storage is not a
multi-process lock service. Exact desktop pixel positions, local process survival,
command replay and unsaved application buffers are outside the contract.

## Review of all 11 open upstream pull requests

Reviewed against archived upstream `65cbbbf6d2c76f3e36af7610a356fc190fcb6147`.
Changes were reconciled into one implementation, not merged blindly. Credit belongs
to the original contributors below for the adapted fixes and design inputs.

| PR / contributor | Reviewed head | Decision in this fork/integration |
|---|---|---|
| [146](https://github.com/MLFlexer/resurrect.wezterm/pull/146) — @FelixIsaac | `24d8cdd1197b371f72462cb3845d3c7382f0cf54` | Adapted opt-in non-local text capture; retained local-only history injection and no `send_text` fallback. |
| [145](https://github.com/MLFlexer/resurrect.wezterm/pull/145) — @midgramr | `b7241bac48e5bde537a6570612b9af3d26f60747` | Adapted nil-safe process capture; rejected unquoted process execution and all automatic argv replay. |
| [138](https://github.com/MLFlexer/resurrect.wezterm/pull/138) — @fireboy1919 | `ba1dbb279f8bef1608b70a22675f527efddb535f` | Documented startup versus attach semantics; rejected the racing marker/status restore recipe. |
| [137](https://github.com/MLFlexer/resurrect.wezterm/pull/137) — @fireboy1919 | `1755c366b5d6c3a40ea20e35eab5d419b03f9180` | Adapted structural autosave in terminal-profile using supported `update-status`, process-wide signatures and debounce; no nonexistent focus event/count-only observer. |
| [136](https://github.com/MLFlexer/resurrect.wezterm/pull/136) — @SingingTree | `d7a3e8237046c2fdaa911ab33508e4b2f83c5604` | Adapted path joins and useful behavioral cases; replaced shell/probe mkdir with checked, quiet runtime creation. |
| [134](https://github.com/MLFlexer/resurrect.wezterm/pull/134) — @lowjoel | `eca8ed3d20c3c18da9fa486ddac292a470d2f4f0` | Subsumed by the reconciled path implementation; rejected colliding `+` substitutions. |
| [130](https://github.com/MLFlexer/resurrect.wezterm/pull/130) — @vike2000 | `d28536dc91e2622c9d1d34b85d55b679b37252e2` | Kept the no-console-flash goal; rejected code that probes but fails to create missing directories and mishandles absolute/UNC roots. This is a directory fix, not a split fix. |
| [128](https://github.com/MLFlexer/resurrect.wezterm/pull/128) — @andreystepanov | `a24d52a0ea8b767521c06d8f4baf0f48f6f61a6e` | Not adopted: Nix executable/argument rewriting serves command replay, which this fork deliberately does not perform, and can discard adjacent editor arguments. |
| [127](https://github.com/MLFlexer/resurrect.wezterm/pull/127) — @tdragon | `ec666510dcf3d954ecca0595c6614213715ec599` | Replaced overlapping right/bottom lists with exact binary slicing; rejected a nil guard that hides duplicate panes. |
| [123](https://github.com/MLFlexer/resurrect.wezterm/pull/123) — @userux | `a16048137a24ba170426c49eeea6b485ec2599ee` | Fixed both save actions to import `resurrect.state_manager`, including the leftover broken root import. No compatibility alias. |
| [118](https://github.com/MLFlexer/resurrect.wezterm/pull/118) — @fvalenza | `9a51cf56b1ae9de0bed6bec4d984ac19067b5e69` | Adapted target-workspace spawning and moving only the reused window; never rename the user's entire active workspace. |

Additional improvements: full-session capture, private profile storage, checked temp
publication, three-generation recovery, preserved corruption evidence, additive recovery,
non-executing restoration and offline vendoring. Original upstream code remains MIT;
see [LICENSE](LICENSE).

## Verification

With Python 3 and WezTerm installed:

```sh
python3 -m unittest discover -s tests
# Windows: py -3 -m unittest discover -s tests
```

Tests execute fixtures in WezTerm's embedded Lua with real JSON/filesystem operations
and require an explicit success artifact; WezTerm silently falling back to default
configuration is not a pass. Geometry fixtures use deterministic mux models. The
terminal-profile suite covers lifecycle transitions, recovery and SSH placeholders.

Native Windows acceptance additionally exercised multi-workspace/grid/zoom/history
restoration, PowerShell redraw, native close and crash checkpoints, corruption fallback,
missing directories, denied writes and real SSH/tmux reconnection. Native macOS/Linux
GUI behavior has not been verified; fixtures are not a substitute for those checks.
