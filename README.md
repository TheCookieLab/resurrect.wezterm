# resurrect.wezterm

**Pick up your terminal layout where you left off.**

Save and restore [WezTerm](https://wezterm.org/) workspaces, windows, tabs and splits—
with your titles, folders, active panes, zoom and local scrollback intact.

This maintained fork of [MLFlexer/resurrect.wezterm](https://github.com/MLFlexer/resurrect.wezterm)
focuses on predictable recovery:

- **Restore your workspace, not yesterday's commands.** Fresh shells; no saved-program
  execution or automatic remote connections.
- **Recover from a bad save.** Validated snapshots, three checkpoint generations and
  fallback to a previous good state.
- **Keep your configuration self-contained.** No helper plugins; supports both WezTerm's
  plugin loader and a vendored, offline installation.

## Get started

Requires WezTerm **20240203-110809-5046fc22** or newer.

```lua
local resurrect = require('wezterm').plugin.require(
  'https://github.com/TheCookieLab/resurrect.wezterm'
)
```

Follow the **[usage guide](docs/usage.md)** to choose a private storage directory and
wire up save/restore actions. This is a Lua library, not an automatic startup service.
For ready-made checkpoints, startup recovery and on-demand SSH reconnection, see
[terminal-profile](https://github.com/TheCookieLab/terminal-profile).

History snapshots contain plaintext terminal output. Running processes and unsaved
application buffers are not preserved; native shutdown recovery needs periodic checkpoints.

[Usage guide](docs/usage.md) · [Contributing & tests](CONTRIBUTING.md) ·
[Changelog](CHANGELOG.md) · [MIT license](LICENSE)
