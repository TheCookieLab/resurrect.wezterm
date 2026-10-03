# Changelog

Notable changes to this maintained fork. Dates use YYYY-MM-DD.

## Unreleased

### Documentation and development

- Replace the implementation-heavy README with a short project overview; move API,
  storage and lifecycle guidance to [the usage guide](docs/usage.md).
- Preserve the eleven-PR upstream review and contributor credits in this changelog.
- Add [contributor guidance](CONTRIBUTING.md) and headless test CI on Windows, Linux
  and macOS (Apple Silicon) using checksum-pinned official WezTerm releases. Keep the
  actual embedded Lua runtime rather than replacing its JSON and filesystem behavior
  with mocks.
- Remove obsolete in-checkout state placeholders and ignore runtime data and Python caches.

## 2026-10-03 — Maintained fork

### Added

- Full-session capture and restore across workspaces, windows, ordered tabs and panes.
- Immutable, validated session checkpoints with three valid generations, corruption
  fallback and additive recovery primitives.
- Offline vendoring without a development-helper plugin or configuration-time setup.

### Changed

- Restore fresh shells and bounded plain history, never saved argv or automatic remote
  connections. Remote domains restore disconnected; SSH reconnection policy belongs
  to the integrating configuration.
- Reconstruct split layouts with integer-cell binary slicing, preserving active and
  zoomed selections without duplicating panes.
- Use reversible state names, checked temporary-file publication and previous-good
  backups for named saves. Preserve corrupt files for recovery.

### Fixed

- Nil process metadata, Windows/UNC path handling, directory-creation console flashes,
  broken named save-action imports and incorrect workspace targeting.

### Compatibility

- WezTerm `20240203-110809-5046fc22` is the compatibility floor.
- Use a new, private state directory: upstream pane trees and lossy `+`-encoded names
  are not supported aliases. Full-session encryption is explicitly rejected rather
  than silently producing plaintext.
- The separate [terminal-profile integration](https://github.com/TheCookieLab/terminal-profile)
  adds private-root permissions, checkpoint scheduling, startup recovery and SSH
  placeholders. These policies are not enabled merely by loading this library.

### Upstream pull request review

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

