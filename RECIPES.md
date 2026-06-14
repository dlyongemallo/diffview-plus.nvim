# Recipes

Here are some practical snippets and keymaps for common diffview workflows.
Each recipe shows only the relevant options. Combine them as needed.

## Recommended Keymaps

These keymaps are commonly used patterns for working with diffview:

```lua
-- Toggle diffview open/close
vim.keymap.set('n', '<leader>dv', '<cmd>DiffviewToggle<cr>', { desc = 'Toggle Diffview' })

-- Diff working directory
vim.keymap.set('n', '<leader>do', '<cmd>DiffviewOpen<cr>', { desc = 'Diffview open' })
vim.keymap.set('n', '<leader>dc', '<cmd>DiffviewClose<cr>', { desc = 'Diffview close' })

-- File history
vim.keymap.set('n', '<leader>dh', '<cmd>DiffviewFileHistory %<cr>', { desc = 'File history (current file)' })
vim.keymap.set('n', '<leader>dH', '<cmd>DiffviewFileHistory<cr>', { desc = 'File history (repo)' })

-- Visual mode: history for selection
vim.keymap.set('v', '<leader>dh', "<Esc><cmd>'<,'>DiffviewFileHistory --follow<CR>", { desc = 'Range history' })

-- Single line history
vim.keymap.set('n', '<leader>dl', '<cmd>.DiffviewFileHistory --follow<CR>', { desc = 'Line history' })

-- Diff against main/master branch (useful before merging)
vim.keymap.set('n', '<leader>dm', function()
  -- Try main first, fall back to master
  local result = vim.fn.systemlist({ 'git', 'rev-parse', '--verify', 'main' })
  local ok = vim.v.shell_error == 0 and result[1] ~= nil and result[1] ~= ''
  local branch = ok and 'main' or 'master'
  vim.cmd('DiffviewOpen ' .. branch)
end, { desc = 'Diff against main/master' })
```

## Restoring Files

If the right side of the diff is showing the local state of a file, you can
restore the file to the state from the left side of the diff (key binding `X`
from the file panel by default). The current state of the file is stored in the
git object database, and a command is echoed that shows how to undo the change.

## Hooks

The `hooks` table allows you to define callbacks for various events emitted
from Diffview. The available hooks are documented in detail in
`:h diffview-config-hooks`. The hook events are also available as User
autocommands. See `:h diffview-user-autocmds` for more details.

Examples:

```lua
hooks = {
  diff_buf_read = function(bufnr)
    -- Change local options in diff buffers
    vim.opt_local.wrap = false
    vim.opt_local.list = false
    vim.opt_local.colorcolumn = { 80 }
  end,
  view_opened = function(view)
    print(
      ("A new %s was opened on tab page %d!")
      :format(view.class:name(), vim.api.nvim_tabpage_get_number(view.tabpage))
    )
  end,
}
```

## Configuration Recipes

<details>
<summary><b>Minimal / Clean</b></summary>

Strip away visual noise and auto-clean resources on close.

```lua
require("diffview").setup({
  show_help_hints = false,
  hide_merge_artifacts = true,
  clean_up_buffers = true,
  auto_close_on_empty = true,
})
```

</details>

<details>
<summary><b>PR Review</b></summary>

Optimised for reviewing pull requests against a base branch. `--imply-local`
makes the right-side buffer editable so you can fix things as you review.

```lua
require("diffview").setup({
  default_args = {
    DiffviewOpen = { "--imply-local" },
  },
  file_panel = {
    show_branch_name = true,
    always_show_sections = true,
  },
})
```

Open with a symmetric range to see only the changes introduced by the branch:

```
:DiffviewOpen origin/main...HEAD
```

</details>

<details>
<summary><b>PR Review Progress Tracking</b></summary>

Use file selections (`<Space>` key) to track which files you've reviewed.
Selected files show a `■` indicator; directories show `■` when all
files are selected or `▣` when some are.

To persist your progress across Neovim restarts, enable
`persist_selections`:

```lua
require("diffview").setup({
  persist_selections = { enabled = true },
})
```

The `DiffviewSelectionChanged` User autocmd fires whenever selections
change, allowing external plugins to react:

```lua
-- Example: log selection changes (replace with your own integration).
vim.api.nvim_create_autocmd("User", {
  pattern = "DiffviewSelectionChanged",
  callback = function()
    local sel = require("diffview.api").selections
    local paths = sel.get_paths()
    vim.notify(
      #paths > 0
        and ("Reviewed: " .. table.concat(paths, ", "))
        or "No files marked as reviewed"
    )
  end,
})
```

The public selections API (see `:h diffview-selections-api`) provides
stable functions for programmatic access:

```lua
local sel = require("diffview.api").selections

sel.get()                 -- { { path = "...", kind = "working" }, ... }
sel.get_paths()           -- { "src/a.lua", "src/b.lua" }
sel.is_selected("a.lua")  -- true / false
sel.select({ "a.lua" })   -- additive
sel.deselect({ "a.lua" })
sel.set({ "a.lua" })      -- replace entire selection
sel.clear()
sel.any()                 -- true if anything is selected
sel.count()               -- number of selected files
```

This is useful for integrating with external review tools. For example,
to save and restore selections across a diffview reopen:

```lua
local sel = require("diffview.api").selections
local saved = sel.get_paths()
-- ... close and reopen diffview ...
sel.set(saved)
```

You can also replace the revision range in-place with `set_revs`
(see `:h diffview-set-revs-api`), which avoids the close/reopen
entirely:

```lua
local api = require("diffview.api")
api.set_revs("new_base_sha..HEAD")
```

Combining both APIs enables a seamless rebase workflow for tools like
[gitlab.nvim](https://github.com/harrisoncramer/gitlab.nvim):

```lua
local api = require("diffview.api")
local sel = api.selections

-- Save reviewed files before rebase.
local reviewed = sel.get_paths()

-- ... perform server-side rebase, obtain new_base_sha ...

-- Update the diff range in-place (no screen reshuffling).
api.set_revs(new_base_sha .. ".." .. source_branch)

-- Restore reviewed-file marks.
sel.set(reviewed)
```

</details>

<details>
<summary><b>Better Diffs</b></summary>

Enable enhanced highlighting and use the histogram diff algorithm for more
readable diffs. Pair with
[diffchar.vim](https://github.com/rickhowe/diffchar.vim) for character-level
precision (see [Companion Plugins](README.md#companion-plugins) for setup
details).

```lua
require("diffview").setup({
  enhanced_diff_hl = true,
  diffopt = { algorithm = "histogram" },
})
```

</details>

<details>
<summary><b>File History Power User</b></summary>

Show both numeric and bar stats, use relative dates, and reorder commit info
for a denser history view.

```lua
require("diffview").setup({
  file_history_panel = {
    stat_style = "both",
    date_format = "relative",
    commit_format = { "hash", "subject", "author", "date", "ref", "reflog", "status", "files", "stats" },
  },
  view = {
    file_history = {
      layout = "diff2_vertical",
    },
  },
})
```

</details>

<details>
<summary><b>Merge Conflict Resolution</b></summary>

Use a 4-way diff layout showing BASE, OURS, THEIRS, and the merge result.
Winbar labels help identify each pane. Diagnostics are disabled to reduce
noise during conflict resolution.

```lua
require("diffview").setup({
  view = {
    merge_tool = {
      layout = "diff4_mixed",
      disable_diagnostics = true,
      winbar_info = true,
    },
    cycle_layouts = {
      merge_tool = { "diff4_mixed", "diff3_mixed", "diff3_horizontal", "diff1_plain" },
    },
  },
})
```

</details>

<details>
<summary><b>Telescope Integration</b></summary>

Use [Telescope](https://github.com/nvim-telescope/telescope.nvim) to select
branches or commits for diffview:

```lua
-- Diff against a branch selected via Telescope
vim.keymap.set('n', '<leader>db', function()
  require('telescope.builtin').git_branches({
    attach_mappings = function(_, map)
      map('i', '<CR>', function(prompt_bufnr)
        local selection = require('telescope.actions.state').get_selected_entry()
        require('telescope.actions').close(prompt_bufnr)
        vim.cmd('DiffviewOpen ' .. selection.value)
      end)
      return true
    end,
  })
end, { desc = 'Diffview branch' })

-- File history for a commit selected via Telescope
vim.keymap.set('n', '<leader>dC', function()
  require('telescope.builtin').git_commits({
    attach_mappings = function(_, map)
      map('i', '<CR>', function(prompt_bufnr)
        local selection = require('telescope.actions.state').get_selected_entry()
        require('telescope.actions').close(prompt_bufnr)
        vim.cmd('DiffviewOpen ' .. selection.value .. '^!')
      end)
      return true
    end,
  })
end, { desc = 'Diffview commit' })
```

</details>

<details>
<summary><b>Commit Graph</b></summary>

To browse a commit graph and open its commits in diffview, you have two
options. [Neogit](https://github.com/NeogitOrg/neogit) renders a graph
natively (`graph_style = "unicode"` or `"kitty"`) and opens diffs through
its diffview integration. Alternatively,
[gitgraph.nvim](https://github.com/isakbm/gitgraph.nvim) is a lightweight,
graph-only alternative.

gitgraph draws the graph and exposes `on_select_commit` /
`on_select_range_commit` hooks. Wire them to `:DiffviewOpen` so that pressing
`<CR>` on a commit or a visual selection opens it in diffview's layouts.

```lua
require("gitgraph").setup({
  hooks = {
    -- <CR> on a commit: show that commit's own changes.
    on_select_commit = function(commit)
      vim.cmd("DiffviewOpen " .. commit.hash .. "^!")
    end,
    -- <CR> over a visual range: diff the whole selected range.
    on_select_range_commit = function(from, to)
      vim.cmd("DiffviewOpen " .. from.hash .. "~1.." .. to.hash)
    end,
  },
})

vim.keymap.set("n", "<leader>dg", function()
  require("gitgraph").draw({}, { all = true, max_count = 5000 })
end, { desc = "Commit graph" })
```

gitgraph can render the graph with plain box-drawing characters or with Kitty
terminal branch glyphs via its `symbols` table; see its README for details.

</details>

<!-- vim: set tw=80 -->
