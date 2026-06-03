# Tips and FAQ

Common questions, useful patterns, and known compatibility issues.

## General Tips

- **Hide untracked files:**
  - `DiffviewOpen -uno`
- **Exclude certain paths:**
  - `DiffviewOpen -- :!exclude/this :!and/this`
- **Run as if git was started in a specific directory:**
  - `DiffviewOpen -C/foo/bar/baz`
- **Diff the index against a git rev:**
  - `DiffviewOpen HEAD~2 --cached`
  - Defaults to `HEAD` if no rev is given.
- **Compare against merge-base (PR-style diff):**
  - `DiffviewOpen origin/main...HEAD --merge-base`
  - Shows only changes introduced since branching.
- **Use as a merge tool from the command line:**
  - `:DiffviewOpen` automatically detects conflicts during a merge, rebase,
    cherry-pick, or revert, so it can replace `git mergetool`. Add a git alias
    for convenience:
    ```gitconfig
    # In ~/.gitconfig:
    [alias]
        diffview = "!nvim -c DiffviewOpen"
    ```
  - Then run `git diffview` after a conflicted merge or rebase. Stage
    resolved files with `-` in the file panel before quitting, or with
    `git add` afterwards.
- **Trace line evolution:**
  - Visual select lines, then `:'<,'>DiffviewFileHistory --follow`
  - Or for single line: `:.DiffviewFileHistory --follow`
- **Diff two arbitrary files (like `vimdiff`):**
  - `:DiffviewDiffFiles file1 file2`
  - This works without a VCS repository.
  - To use it as a replacement for `nvim -d`, add a shell function:
    ```bash
    dvdiff() {
      nvim -c "DiffviewDiffFiles ${1// /\\ } ${2// /\\ }"
    }
    ```
  - Then run `dvdiff file1 file2` from the command line.

## Understanding Revision Arguments

- `DiffviewOpen HEAD~5` compares HEAD~5 to working tree (all changes since)
- `DiffviewOpen HEAD~5..HEAD` compares HEAD~5 to HEAD (excludes working tree changes)
- `DiffviewOpen HEAD~5^..HEAD~5` shows changes within that single commit
- For viewing a specific commit's changes, use `DiffviewFileHistory` instead

## FAQ

- **Q: How do I get the diagonal lines in place of deleted lines in
  diff-mode?**
  - A: Change your `:h 'fillchars'`:
    - (vimscript): `set fillchars+=diff:╱`
    - (Lua): `vim.opt.fillchars:append { diff = "╱" }`
  - Note: whether or not the diagonal lines will line up nicely will depend on
    your terminal emulator. The terminal used in the screenshots is Kitty.
- **Q: How do I jump between hunks in the diff?**
  - A: Use `[c` and `]c`
  - `:h jumpto-diffs`

## Diff Display

- **Inline (unified) diff:**
  - Use the `diff1_inline` layout to display diffs in a single window, with
    deletions rendered as virtual lines above the corresponding position
    and intra-line changes highlighted with `DiffText`.
  - To make it the default view: `view.default.layout = "diff1_inline"`.
    The layout is automatically appended to `view.cycle_layouts.default`
    if missing, so `g<C-x>` cycles back to it without extra config.
  - To cycle through it alongside side-by-side layouts, list them all
    explicitly:
    ```lua
    require("diffview").setup({
      view = {
        cycle_layouts = {
          default = { "diff2_horizontal", "diff1_inline" },
        },
      },
    })
    ```
  - Navigate hunks with `]c`/`[c` (mapped to `next_inline_hunk` and
    `prev_inline_hunk`).
  - Inline is not available in the merge tool (it needs a 2-way diff).
- **Overleaf-style inline diff (strikethrough for deletions):**
  - Set `view.inline.style = "overleaf"` to render deleted characters as
    inline virtual text with strikethrough, next to the added characters
    they were replaced by. Whole-line deletions are also shown with a
    strikethrough instead of a plain delete background.
    ```lua
    require("diffview").setup({
      view = {
        default = { layout = "diff1_inline" },
        inline = { style = "overleaf" },
      },
    })
    ```
  - Customise the strikethrough via `DiffviewDiffDeleteInline` (see the
    next entry on overriding inline groups).
- **Customise inline char-level highlights:**
  - In the `diff1_inline` layout, changed characters use these groups:
    the unified style highlights them with `DiffviewDiffTextInline`,
    while the "overleaf" style uses `DiffviewDiffAddInline` for added
    chars and `DiffviewDiffDeleteInline` for the strikethrough
    deletions. Their backgrounds derive by default from `DiffText`,
    `DiffviewDiffAdd`, and `DiffviewDiffDelete` respectively. The
    unified group tracks `DiffText` (as the built-in side-by-side diff
    does), so changes stay visible against the paired-row
    `DiffviewDiffChange` backdrop even when your colourscheme gives
    `DiffAdd` and `DiffChange` similar tints (e.g. tokyonight); it falls
    back to `DiffAdd` for schemes that leave `DiffText` unset.
  - These groups are re-derived on every colourscheme change, so set
    overrides from a `ColorScheme` autocmd rather than once at startup
    (a plain `:hi` is overwritten on the next change). Register the
    autocmd *after* `require("diffview").setup({...})` so it runs
    after diffview's own rebuild and has the final say:
    ```lua
    require("diffview").setup({...})
    vim.api.nvim_create_autocmd("ColorScheme", {
      callback = function()
        vim.api.nvim_set_hl(0, "DiffviewDiffTextInline", { bg = "#3a4a3a" })
        vim.api.nvim_set_hl(0, "DiffviewDiffAddInline", { bg = "#2e4326" })
        vim.api.nvim_set_hl(0, "DiffviewDiffDeleteInline", {
          bg = "#552020",
          fg = "#ff8080",
          strikethrough = true,
        })
      end,
    })
    ```
  - `DiffviewDiffTextInline` does not track later overrides to
    `DiffText`: its bg is derived only at `setup()` and on each
    `ColorScheme`, and Neovim emits no event for a standalone
    `DiffText` change. Override `DiffviewDiffTextInline` directly
    instead.
- **Better diff display (changes shown as add+delete instead of modification):**
  - Set Neovim's `diffopt` to use a better algorithm:
    - `vim.opt.diffopt:append { "algorithm:histogram" }`
  - Alternatives: `algorithm:patience` or `algorithm:minimal`
  - This affects how Neovim's built-in diff mode displays changes.
- **VSCode-style character-level highlighting:**
  - [diffchar.vim](https://github.com/rickhowe/diffchar.vim) enhances diff
    mode with precise character and word-level highlighting. It automatically
    activates in diff mode, adding a second layer of highlights on top of
    Neovim's built-in line-level `DiffChange` backgrounds. This gives
    VSCode-style dual-layer highlighting: light backgrounds for changed lines
    plus fine-grained highlights for the exact characters that differ.
  - diffchar.vim works with diffview out of the box. Install the plugin and
    open a diff -- no additional configuration is needed. Note that
    diffchar.vim only applies to diff-mode layouts (`diff2_*`, `diff3_*`,
    `diff4_*`); the `diff1_inline` layout renders inline changes via
    extmarks rather than Neovim's diff mode, so diffchar.vim has no effect
    there -- see *Customise inline char-level highlights* above for
    `diff1_inline`'s built-in mechanism. You may want to enable visual
    indicators next to deleted characters to get VSCode-style
    character-level diffs, or disable diffchar's default keymaps
    (`<leader>g`, `<leader>p`) if they conflict with your mappings:
    ```lua
    {
      'rickhowe/diffchar.vim',
      config = function()
        -- Use bold/underline on adjacent chars instead of virtual blank columns.
        vim.g.DiffDelPosVisible = 1

        -- Disable diffchar default keymaps.
        -- See: https://github.com/rickhowe/diffchar.vim/issues/21
        vim.cmd([[
          nmap <leader>g <Nop>
          nmap <leader>p <Nop>
        ]])
      end,
    }
    ```
  - diffchar supports multiple diff granularities via `g:DiffUnit`: `'Char'`
    (character-level), `'Word1'` (words separated by non-word characters),
    `'Word2'` (whitespace-delimited words), and custom delimiter patterns. It
    also offers multi-colour matching via `g:DiffColors` to visually correlate
    corresponding changed units across windows.

## LSP and Formatting in Diff Buffers

- LSP clients are automatically detached from non-working-tree diff buffers
  (those with `diffview://` URIs). This prevents errors from LSP servers that
  do not support the custom URI scheme, and avoids incorrect LSP features on
  historical content.
- Auto-formatting is disabled on these buffers (`vim.b.autoformat = false`).
- Inlay hints are automatically disabled for non-working-tree buffers to
  prevent position mismatch errors.
- Diagnostics and other LSP features only appear for the working tree (LOCAL)
  side of diffs. To see them, compare against the working tree:
  `DiffviewOpen main` (not `main..HEAD`).

## Neogit Integration

- Configure [Neogit](https://github.com/NeogitOrg/neogit) with
  `integrations = { diffview = true }` for seamless integration.

## Keymap Configuration

The keymaps config is structured as a table with sub-tables for various
different contexts where mappings can be declared. In these sub-tables
key-value pairs are treated as the `{lhs}` and `{rhs}` of a normal mode
mapping. The implementation uses `vim.keymap.set()` (which implies `noremap`),
and all mappings use `silent`. In most contexts, `nowait` is also set. The
`{rhs}` can be either a vim command in the form of a string, or a lua
function:

```lua
  view = {
    -- Vim command:
    ["a"] = "<Cmd>echom 'foo'<CR>",
    -- Lua function:
    ["b"] = function() print("bar") end,
  }
```

For more control (i.e. mappings for other modes), you can also define index
values as list-like tables containing the arguments for `vim.keymap.set()`.
This way you can also change all the `:map-arguments` with the only exception
being the `buffer` field, as this will be overridden with the target buffer
number:

```lua
view = {
  -- Normal and visual mode mapping to vim command:
  { { "n", "v" }, "<leader>a", "<Cmd>echom 'foo'<CR>", { silent = true } },
  -- Visual mode mapping to lua function:
  { "v", "<leader>b", function() print("bar") end, { nowait = true } },
}
```

To disable any single mapping without disabling them all, set its `{rhs}` to
`false`:

```lua
  view = {
    -- Disable the default normal mode mapping for `<tab>`:
    ["<tab>"] = false,
    -- Disable the default visual mode mapping for `gf`:
    { "x", "gf", false },
  }
```

Most of the mapped file panel actions also work from the view if they are added
to the view maps (and vice versa). The exception is for actions that only
really make sense specifically in the file panel, such as `next_entry`,
`prev_entry`. Actions such as `toggle_stage_entry` and `restore_entry` work
just fine from the view. When invoked from the view, these will target the file
currently open in the view rather than the file under the cursor in the file
panel.

**For more details on how to set mappings for other modes, actions, and more
see:**
- `:h diffview-config-keymaps`
- `:h diffview-actions`

### Customizing Default Keymaps

The default keymaps (`<leader>e`, `<leader>b`, `<leader>c*`) may conflict
with your configuration. Override them in your setup:

```lua
local actions = require("diffview.actions")
require("diffview").setup({
  keymaps = {
    view = {
      -- Use localleader instead to avoid conflicts
      { "n", "<localleader>e", actions.focus_files },
      { "n", "<localleader>b", actions.toggle_files },
      -- Or disable specific mappings
      { "n", "<leader>e", false },
    },
  },
})
```

## Platform Notes

- **MSYS2/Cygwin on Windows:**
  - If you use MSYS2 or Cygwin git with native Windows Neovim, path conversion
    is handled automatically via `cygpath`. Ensure `cygpath` is on your `PATH`.
    Alternatively, install [Git for Windows](https://gitforwindows.org/) which
    uses native Windows paths and avoids the issue entirely.

## Known Compatibility Issues

Some plugins may conflict with diffview's window layout or keymaps. Here are
known issues and workarounds:

- **lens.vim (automatic window resizing):**
  - [camspiers/lens.vim](https://github.com/camspiers/lens.vim) automatically
    resizes windows based on focus, which interferes with diffview's layout.
  - **Workaround:** Configure lens.vim to exclude diffview filetypes:
    ```lua
    -- In your lens.vim or lens.nvim config:
    vim.g['lens#disabled_filetypes'] = {
      'DiffviewFiles', 'DiffviewFileHistory', 'DiffviewFileHistoryPanel'
    }
    ```

- **[which-key.nvim](https://github.com/folke/which-key.nvim) shows
  `diffview_ignore` entries:**
  - In a diffview buffer, which-key lists several `z*` fold commands with
    the description `diffview_ignore`. Filter them out in your setup:
    ```lua
    require("which-key").setup({
      filter = function(mapping)
        return mapping.desc ~= "diffview_ignore"
      end,
    })
    ```

- **Scrollbind misalignment with context or winbar plugins:**
  - Plugins that add lines at the top of windows (code context, breadcrumbs)
    cause the diff panes to fall out of visual sync.

  - **[nvim-treesitter-context](https://github.com/nvim-treesitter/nvim-treesitter-context):**
    Two steps are needed. First, configure treesitter-context to disable
    itself for diffview buffers using the `on_attach` callback:
    ```lua
    require("treesitter-context").setup({
      on_attach = function(buf)
        return not vim.b[buf].ts_context_disable
      end,
    })
    ```
    Then add diffview hooks to force treesitter-context to re-evaluate
    `on_attach` at the right times. This is necessary because
    treesitter-context only evaluates `on_attach` once per buffer (on
    `BufReadPost`), so working-tree files that were loaded before diffview
    opened would otherwise keep context enabled:
    ```lua
    require("diffview").setup({
      hooks = {
        diff_buf_win_enter = function(bufnr, winid, ctx)
          -- Re-trigger treesitter-context's on_attach evaluation.
          -- The group name is an internal detail of nvim-treesitter-context
          -- and may differ across versions; verify it matches your install
          -- or omit it to fire all BufReadPost handlers.
          pcall(vim.api.nvim_exec_autocmds, "BufReadPost", {
            buffer = bufnr,
            group = "treesitter_context_update",
          })
        end,
        view_closed = function()
          local ok, tsc = pcall(require, "treesitter-context")
          if ok and tsc.enabled() then
            tsc.enable()
          end
        end,
      },
    })
    ```

  - **[barbecue.nvim](https://github.com/utilyre/barbecue.nvim)** and other
    winbar plugins: Unlike treesitter-context, barbecue resets the winbar
    on every `CursorMoved` and `BufWinEnter`, so clearing it per-window is
    not sufficient. Instead, toggle barbecue's visibility using
    `view_enter`/`view_leave` hooks (these fire when switching to and from
    the diffview tab):
    ```lua
    require("diffview").setup({
      hooks = {
        view_enter = function()
          pcall(function() require("barbecue.ui").toggle(false) end)
        end,
        view_leave = function()
          pcall(function() require("barbecue.ui").toggle(true) end)
        end,
      },
    })
    ```

- **[vim-markdown](https://github.com/preservim/vim-markdown) (preservim/vim-markdown):**
  - vim-markdown's `after/ftplugin/markdown.vim` sets `foldmethod=expr` with a
    markdown section foldexpr. In diff buffers this would collapse markdown
    sections and hide diff content. Diffview suppresses the synthetic `FileType`
    event that would otherwise let that ftplugin run on diffview buffers, so
    `foldmethod=diff` is preserved and vim-markdown's folds are not applied.
  - If you still see section folds in diff buffers (e.g. because another
    plugin re-fires `FileType` on the buffer), raise the initial fold level:
    ```lua
    require("diffview").setup({
      view = { foldlevel = 99 },
    })
    ```
  - To raise the fold level only for markdown diff buffers (leaving the
    default of 0 in place for other filetypes), use the `diff_buf_win_enter`
    hook instead:
    ```lua
    require("diffview").setup({
      hooks = {
        diff_buf_win_enter = function(bufnr, winid)
          if vim.bo[bufnr].filetype == "markdown" then
            vim.wo[winid].foldlevel = 99
          end
        end,
      },
    })
    ```

- **Plugins that act on the current window/buffer (fzf-lua, blame.nvim, etc.):**
  - Panel windows are pinned to their buffer via `winfixbuf`, so plugins
    that try to load a different buffer into the current window
    (e.g., [fzf-lua](https://github.com/ibhagwan/fzf-lua)) will fail when
    invoked from the panel.
  - Plugins that run a job against the current buffer's name (e.g.,
    [blame.nvim](https://github.com/FabijanZulj/blame.nvim)) will fail
    because the panel buffer is `nofile`.
  - **Workaround:** wrap the offending keymaps with a helper that, when
    invoked from a diffview panel, first focuses the diff's main window.
    This both avoids the `winfixbuf` error and makes the picked file
    open in the right place:
    ```lua
    local function in_diff_window(fn)
      return function()
        if vim.wo.winfixbuf then
          local ok, lib = pcall(require, "diffview.lib")
          if ok then
            local view = lib.get_current_view()
            if view and view.cur_layout then
              local main = view.cur_layout:get_main_win()
              if main and main.id and vim.api.nvim_win_is_valid(main.id) then
                vim.api.nvim_set_current_win(main.id)
              end
            end
          end
        end
        fn()
      end
    end

    vim.keymap.set("n", "<a-f>",
      in_diff_window(function() require("fzf-lua").files() end))
    vim.keymap.set("n", "<a-b>",
      in_diff_window(function() vim.cmd("BlameToggle") end))
    ```
  - If you would rather not use the wrapper,
    [stickybuf.nvim](https://github.com/stevearc/stickybuf.nvim) will
    bounce the buffer to a non-panel window (so files at least open
    somewhere, though not necessarily the diff's main window).

<!-- vim: set tw=80 -->
