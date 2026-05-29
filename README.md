# diffview+

> **Note:** This is an **actively maintained fork** of [sindrets/diffview.nvim](https://github.com/sindrets/diffview.nvim) with bug fixes and improvements applied. See [`doc/diffview_changelog.txt`](doc/diffview_changelog.txt) (`:h diffview.changelog`) for breaking changes and notable additions.

## Introduction

Single tabpage interface for easily cycling through diffs for all modified files
for any git rev. Review all changed files, resolve merge conflicts, and browse
file history from a unified view.

![preview](https://user-images.githubusercontent.com/2786478/131269942-e34100dd-cbb9-48fe-af31-6e518ce06e9e.png)

## Requirements

- Neovim ≥ 0.10.0 (with LuaJIT)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) or [mini.icons](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-icons.md) (optional) for file icons

Supported VCS (at least one required):

- **Git** ≥ 2.31.0
- **Mercurial** ≥ 5.4.0
- **Sapling** (any version; detected automatically via the Mercurial adapter)
- **Jujutsu** ≥ 0.38.0
- **Perforce** ≥ 2019.1 with the `p4` CLI (experimental)

## Installation

```lua
-- Lazy
{
    "dlyongemallo/diffview-plus.nvim",
    version = "*",
    -- optional: lazy-load on command
    -- cmd = {
    --     "DiffviewOpen",
    --     "DiffviewToggle",
    --     "DiffviewFileHistory",
    --     "DiffviewDiffFiles",
    --     "DiffviewLog",
    -- },
}
```

```vim
" Plug
Plug 'dlyongemallo/diffview-plus.nvim'
```

## Quick Start

```vim
:DiffviewOpen              " Diff working tree against index
:DiffviewFileHistory %     " History for the current file
:DiffviewFileHistory       " History for the whole repo
:DiffviewDiffFiles a b     " Diff two arbitrary files
:DiffviewClose             " Close the current diffview
```

Press `g?` in any diffview buffer to see all available keymaps.

See [USAGE.md](USAGE.md) for detailed guides on PR review, stash inspection,
and committing workflows.

## Features

- **Diff View** — Browse all changed files in a single tabpage. Stage
  individual hunks by editing index buffers directly.
  ![preview](https://user-images.githubusercontent.com/2786478/131269942-e34100dd-cbb9-48fe-af31-6e518ce06e9e.png)

- **File History** — List all commits affecting a file, directory, or line
  range. Filter by author, message, date range, and more.
  ![file history](https://user-images.githubusercontent.com/2786478/188331057-f9ec9a0d-8cda-4ff8-ac98-febcc7aa4010.png)

- **Merge Tool** — 3-way and 4-way diff layouts for resolving conflicts,
  with mappings for choosing OURS/THEIRS/BASE versions.
  ![merge tool](https://user-images.githubusercontent.com/2786478/188286293-13bbf0ab-3595-425d-ba4a-12f514c17eb6.png)

- **Staging** — Stage and unstage individual files or all changes from the
  file panel (`-` / `s` / `S` / `U`). You can stage individual hunks by
  editing any buffer that represents the index (after running `:DiffviewOpen`
  with no `[rev]` the entries under "Changes" will have the index buffer
  on the left side, and the entries under "Staged changes" will have it on the
  right side). Once you write to an index buffer the index will be updated.
  (Note: Staging is a Git concept. These actions are no-ops on Jujutsu.)

- **Unified Inline Diff** — `diff1_inline` layout renders adds/deletes
  in a single window via extmark overlays, with tree-sitter highlights
  preserved on both added and deleted lines. Configurable via
  `view.inline.style` (`"unified"` / `"overleaf"`).

- **Multi-file Selection** — Select multiple files in the file panel
  (`w` to toggle, `C` to clear) for batch stage / unstage / restore.
  Selections persist across Neovim restarts.

- **Pin Local in File History** — Run `:DiffviewFileHistory --pin-local`
  to keep the working tree on one side while cycling commits on the
  other (Git only).

## Commands

| Command | Description |
|---|---|
| `:DiffviewOpen [rev] [options] [ -- {paths...}]` | Open a diff view |
| `:DiffviewFileHistory [paths] [options]` | Browse file/commit history |
| `:DiffviewDiffFiles {file1} {file2}` | Diff two arbitrary files |
| `:DiffviewMergeFiles {output} [{base}] {left} {right}` | 3-way / 4-way merge editor (no VCS required) |
| `:DiffviewDiffDirs {left} {right} [{output}]` | Compare two on-disk directories (no VCS required) |
| `:DiffviewClose` | Close the current diffview. You can also use `:tabclose`. |
| `:DiffviewToggleFiles` | Toggle the file panel |
| `:DiffviewFocusFiles` | Bring focus to the file panel |
| `:DiffviewRefresh[!]` | Update stats and entries in the file list (with `!`, also force-reload stage diff buffers) |

Examples:

```vim
:DiffviewOpen                      " Working tree changes
:DiffviewOpen HEAD~2               " Changes since HEAD~2
:DiffviewOpen origin/main...HEAD   " Symmetric diff (PR-style)
:DiffviewOpen -- lua/diffview      " Limit to specific paths
:DiffviewFileHistory %             " Current file history
:'<,'>DiffviewFileHistory          " History for selected lines
```

#### VCS Adapter Notes

- **Jujutsu** supports `:DiffviewOpen`, `:DiffviewFileHistory`, and works as
  jj's external merge tool (`:DiffviewMergeFiles`) and diff editor
  (`:DiffviewDiffDirs`); see `:h :DiffviewMergeFiles` and
  `:h :DiffviewDiffDirs` for `~/.config/jj/config.toml` wiring. The options
  `--cached`, `--staged`, `--imply-local`, the `--pin-local` flag, and
  line-range history (`:'<,'>DiffviewFileHistory`) are not supported;
  staging actions are no-ops (jj has no staging index). In colocated
  repos, set `preferred_adapter = "jj"` to use the Jujutsu adapter.
- **Sapling** is detected automatically through the Mercurial adapter. Use
  `hg_cmd` to configure the executable (e.g. `hg_cmd = { "sl" }`).
- **Perforce** support is experimental. Requires the `p4` CLI ≥ 2019.1
  and the environment variables `P4PORT`, `P4USER`, `P4CLIENT`.

For full command documentation, see `:h diffview-commands`.

> [!IMPORTANT]
> ### Familiarize Yourself With `:h diff-mode`
>
> This plugin builds on nvim's built-in diff mode. Make sure you're familiar
> with jumping between hunks (`:h jumpto-diffs`) and applying diff changes
> (`:h copy-diffs`).

## Configuration

A minimal configuration showing commonly customised options:

```lua
require("diffview").setup({
  enhanced_diff_hl = true,
  use_icons = true,
  view = {
    default = { layout = "diff2_horizontal" },
    merge_tool = { layout = "diff3_horizontal" },
  },
  file_panel = {
    listing_style = "tree",
    win_config = { position = "left", width = 35 }, -- Use "auto" to fit content
  },
  hooks = {},   -- See :h diffview-config-hooks
  keymaps = {}, -- See :h diffview-config-keymaps
})
```

For the full list of options with defaults, see
[`doc/diffview_defaults.txt`](doc/diffview_defaults.txt) or run
`:h diffview.defaults` in Neovim.

See [RECIPES.md](RECIPES.md) for ready-to-use configuration snippets covering
PR review, merge conflicts, file history, and more.

## Companion Plugins

- **[diffchar.vim](https://github.com/rickhowe/diffchar.vim)** — VSCode-style
  character/word-level diff highlighting. Works out of the box.
- **[Telescope](https://github.com/nvim-telescope/telescope.nvim)** — Select
  branches or commits interactively. See [RECIPES.md](RECIPES.md) for setup.
- **[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)** — When
  installed and `watch_index` is enabled (the default), the file panel
  refreshes instantly after staging or unstaging hunks via gitsigns.
- **[Neogit](https://github.com/NeogitOrg/neogit)** — Git porcelain with
  built-in diffview integration (`integrations = { diffview = true }`).

See [TIPS.md](TIPS.md) for setup details and known compatibility issues.

## Tips and FAQ

See [TIPS.md](TIPS.md) for common usage patterns, revision argument
guide, LSP diagnostics in diffs, platform notes, and plugin compatibility.

## Further Reading

| Resource | Description |
|---|---|
| [USAGE.md](USAGE.md) | PR review, stash inspection, committing guides |
| [RECIPES.md](RECIPES.md) | Configuration snippets and recommended keymaps |
| [TIPS.md](TIPS.md) | Tips, FAQ, and known compatibility issues |
| `:h diffview` | Full plugin documentation |
| `:h diffview.defaults` | Complete default configuration |


<!-- vim: set tw=80 -->
