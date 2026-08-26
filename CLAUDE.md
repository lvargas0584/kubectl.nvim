# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

kubectl.nvim is a Neovim plugin providing a single-screen, lazygit-style
Kubernetes dashboard: a curated watchlist of deployments with contextual actions
(restart, scale, image/version change, logs, events) on the focused row. There is
no build step or package manager — this is a plain Lua plugin loaded via Neovim's
runtimepath. It has no plugin dependencies; Telescope was removed in the
dashboard rewrite.

## Development

```bash
nvim -l tests/run.lua
```

That is the whole test suite: plain `assert`s, no framework, no cluster needed.
It covers the pure logic in `format.lua`, watchlist persistence (against a
tempfile via the assignable `watchlist.path`), the log stream's chunk
reassembly (using a local `sh` command in place of `kubectl`), and the window
layout in both `tab` and `split` modes.

To exercise it against a real cluster, load the plugin in Neovim (e.g. a local
`lazy.nvim` dev path) and run `:lua require('kubectl').setup()` then `:Kubectl`.

`doc/kubectl.txt` is Vim helpfile documentation; regenerate `doc/tags` with
`:helptags doc` after editing it.

## Architecture

Module load order and dependency direction (higher depends on lower):

```
init.lua (setup, :Kubectl, VimLeavePre cleanup)
  └── ui/dashboard.lua (layout, watchlist window, render, all keymaps)
        ├── ui/logs.lua (log panes, streaming)
        ├── actions.lua (mutations + confirm)
        ├── watchlist.lua (curated set, persisted to disk)
        ├── format.lua (pure rendering logic — no vim API)
        ├── k8s_client.lua (all kubectl shell-outs, async)
        ├── state.lua (context/namespace, job and timer registry)
        └── config.lua (user options merged with defaults)
```

- **`k8s_client.lua`** is the only module that shells out to `kubectl`, and
  everything in it is **async** via `vim.system`. Callbacks receive
  `(result, err)` and are always scheduled on the main loop. Raw kubectl errors
  are pattern-matched in `run` into friendlier text ("connection refused" →
  "Cannot connect to the Kubernetes cluster"). New kubectl operations must
  follow the same callback convention — nothing here may block the editor,
  because the dashboard refreshes on a timer.
  - `M.snapshot(ns, cb)` fires `get deployments` and `get pods` in parallel and
    joins them. Both are needed: images and replica counts live on the
    deployment, while AGE, restart counts and failure reasons only exist on the
    pods.
- **`format.lua`** is deliberately **free of any `vim` reference** so
  `tests/run.lua` can require it standalone. It owns `age()` (a manual UTC epoch
  calculator, because `os.date`/`os.time` are timezone-dependent and this must
  match kubectl's AGE column), `parse_image()` (the last colon is only a tag
  separator when it follows the last slash — otherwise it is a registry port),
  `build_row()`, and the adaptive column widths. Anything pure belongs here.
- **`ui/dashboard.lua`** owns the single window that matters. Rendering is two
  passes: resolve every watchlist entry against its namespace snapshot, then
  size the columns to the resolved rows. `M.rows` maps buffer line number → row
  table; every keymap reads the focused line through `M.current_row()`.
  `place_cursor()` guarantees the cursor never rests on line 1 (the header) —
  parked there, every contextual action silently no-ops.
  `M.global_keymaps` holds the row-independent actions (`a`, `n`, `r`, `?`);
  `ui/logs.lua` maps the same table into every pane so the dashboard stays
  reachable from the log area.
- **`ui/logs.lua`** manages the log area to the right. Panes are *normal Neovim
  windows*, not floats — that is what makes `/` search, `<C-w>` navigation,
  resize and multiple simultaneous panes free. A pane's buffer has
  `bufhidden = "wipe"` and a `BufWipeout` hook that kills its stream, so closing
  a window is the only cleanup path needed. `toggle_zoom()` stores a
  `winrestcmd()` snapshot; while it is set, `dashboard.apply_width()` returns
  early so the refresh timer cannot snap a zoomed pane back mid-read. `kubectl` delivers chunks rather
  than lines, so `reader()` holds the trailing partial line back until its
  newline arrives.
- **`actions.lua`** holds every mutation. All of them go through `M.confirm()`,
  which uses `vim.fn.confirm` defaulting to **No**, and all of them target
  `deployment/<name>` — never a pod. Each reports its outcome and refreshes.
- **`watchlist.lua`** persists `{context, namespace, name}` entries to
  `stdpath('data')/kubectl-nvim/watchlist.json`. `M.path` is assignable and
  `M.reload()` drops the memoized copy — that is the test seam.
- **`state.lua`** holds the active context/namespace plus registries of running
  `vim.system` handles and the refresh timer, so `M.cleanup()` can stop
  everything on `VimLeavePre`.

Config (`config.lua`) is a flat table merged via `vim.tbl_deep_extend("force", ...)`;
every consumer reads through `config.get()` rather than caching it, since
`setup()` can be called with user overrides at any time.

All user-facing text (notifications, prompts, confirmations, the help float,
winbars) is in English. `doc/kubectl.txt` is still written in Spanish.
