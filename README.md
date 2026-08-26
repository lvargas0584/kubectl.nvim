# kubectl.nvim

A single-screen Kubernetes dashboard for Neovim, in the spirit of lazygit.

Instead of a picker you open, filter and close for every operation, you keep a
**curated watchlist** of the handful of deployments you actually work with, and
act on the focused row: restart it, change its image or version, scale it, or
stream its logs — each behind a confirmation, none of it needing a mouse.

```
┌─ WATCHLIST ────────────────────────────────┬─ pagos-api ─────────────────┐
│ NS    DEPLOYMENT      VAR     VERSION      │ 12:04:31 INFO started       │
│ qa    pagos-api       jvm     dev_1.4.2    │ 12:04:32 INFO listening     │
│ qa    catalogo        native  1.2.0     ⚠  │ ...                         │
│ dev   pagos-api       jvm     feature_R... ├─ catalogo ──────────────────┤
│                                            │ 12:04:02 ERROR pull failed  │
│ ctx: cluster-dev  ns: qa  15s  ?=ayuda     │ ...                         │
└────────────────────────────────────────────┴─────────────────────────────┘
```

## Features

- **Curated watchlist** — add only the deployments you care about; it persists
  across sessions, per kube context.
- **Version at a glance** — the image is split into its variant (`jvm`/`native`)
  and its tag (`dev_1.4.2`, `feature_RPLAT-32456`), so you read the deployed
  version without parsing an 80-character image reference.
- **Failures surface themselves** — `ImagePullBackOff`, `CrashLoopBackOff` and
  degraded replica counts are highlighted on the row, with the reason inline.
- **Several live log panes at once** — split the log area and watch two services
  side by side. Search with plain `/`, filter server-side with `grep`.
- **Every mutation confirms first**, defaulting to *No*, so a stray `<CR>` never
  restarts anything.
- **Namespaces coexist** — watch `qa` and `dev` deployments on the same screen
  instead of switching context to see each.
- **Fully async** — every `kubectl` call runs through `vim.system`; the editor
  never blocks.

## Requirements

- Neovim 0.10+ (uses `vim.system`)
- `kubectl` on `PATH`, configured against a cluster
- tmux (optional, only for the `T` escape hatch)

Telescope is no longer required. If you have a `vim.ui.select` handler installed
(Telescope, fzf-lua, snacks…), the "add deployment" and "pick namespace" prompts
use it automatically.

## Installation

### lazy.nvim

```lua
{
  'levargas0584/kubectl.nvim',
  cmd = 'Kubectl',
  config = function()
    require('kubectl').setup()
  end,
}
```

### packer.nvim

```lua
use {
  'levargas0584/kubectl.nvim',
  config = function()
    require('kubectl').setup()
  end,
}
```

## Usage

```vim
:Kubectl
```

Toggles the dashboard. An empty watchlist tells you to press `a`.

Or bind it:

```lua
vim.keymap.set('n', '<leader>k', '<cmd>Kubectl<cr>', { desc = 'Kubernetes' })
```

### Keymaps — watchlist

The focused row is the implicit subject of every action.

| Key     | Action                                     | Confirms |
| ------- | ------------------------------------------ | -------- |
| `<CR>`  | Stream logs in the active pane             |          |
| `o`     | Stream logs in a **new** pane              |          |
| `<Tab>` | Jump to the log area                       |          |
| `a`     | Add a deployment to the watchlist          |          |
| `d`     | Remove it from the watchlist               | yes      |
| `R`     | `rollout restart`                          | yes      |
| `i`     | Edit the full image reference              | yes      |
| `v`     | Edit **only** the version tag              | yes      |
| `s`     | Scale to N                                 | yes      |
| `0`     | Scale to 0                                 | yes      |
| `n`     | Change the default namespace               |          |
| `e`     | Deployment events (deployment errors)      |          |
| `K`     | `describe` — full image, conditions        |          |
| `T`     | Open logs in a tmux pane instead           |          |
| `r`     | Refresh now                                |          |
| `?`     | Help                                       |          |
| `q`     | Close                                      |          |

### Keymaps — log panes

| Key       | Action                                            |
| --------- | ------------------------------------------------- |
| `/` `n` `N` | Neovim's own search — nothing plugin-specific   |
| `g`       | Filter the stream: `kubectl logs -f \| grep WORD` |
| `t`       | Change `--tail N`                                 |
| `f`       | Toggle follow (auto-scroll)                       |
| `x`       | Close this pane and kill its stream               |
| `<C-c>`   | Stop the stream, keep the pane                    |
| `<Tab>`   | Back to the watchlist                             |

The row-independent actions — `a`, `n`, `r`, `?` — are mapped in the log panes
too, so you can add a deployment or refresh without hopping back to the
watchlist first.

### Changing a version

Two keys, depending on how much changes:

- `v` — you are moving `dev_1.4.2` → `feature_RPLAT-32456`. The prompt is
  prefilled with just the tag; the repository is preserved.
- `i` — you are switching `app_jvm:dev_1.4.2` → `app_native:1.2.0`. The prompt is
  prefilled with the whole reference, so you edit both halves at once.

Both show a before/after diff in the confirmation.

## Configuration

All options are optional; these are the defaults:

```lua
require('kubectl').setup({
  layout = 'tab',            -- 'tab' opens its own tabpage, 'split' sits beside
                             -- the buffer you are in
  watchlist_width = 'auto',  -- 'auto' fits the columns; or give a number
  auto_refresh = 15,         -- seconds; 0 disables the refresh timer
  log_tail = 200,            -- initial --tail for a new log pane
  log_max_lines = 10000,     -- per-pane scrollback cap
  log_follow = true,         -- start panes in follow mode
  confirm_actions = true,    -- set false to skip every confirmation prompt
  tmux_split_cmd = "tmux split-window -h '%s; read'",  -- only used by `T`
})
```

The watchlist is stored at `stdpath('data')/kubectl-nvim/watchlist.json`.

## Development

```bash
nvim -l tests/run.lua
```

Covers the pure logic (age formatting, image parsing, row building, column
widths, watchlist persistence), the log stream's chunk reassembly, and the
window layout in both `tab` and `split` modes. No cluster required.

Help file: `doc/kubectl.txt`. After editing it, run `:helptags doc`.

## License

MIT. See `LICENSE`.

## Issues

Bug reports and feature requests: [GitHub Issues](https://github.com/levargas0584/kubectl.nvim/issues).
Include your Neovim version, OS, and steps to reproduce.
