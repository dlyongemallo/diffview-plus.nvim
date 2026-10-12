local async = require("diffview.async")
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local WorktreeOverviewView =
  require("diffview.scene.views.worktree_overview.worktree_overview_view").WorktreeOverviewView
local test_utils = require("diffview.tests.helpers")

local run = test_utils.run

local function make_adapter(repo)
  return GitAdapter({
    toplevel = repo,
    cpath = repo,
    path_args = {},
  })
end

describe("diffview.scene.views.worktree_overview WorktreeOverviewView", function()
  it(
    "opens a tabpage and renders one line per worktree",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local linked = repo .. "-wt"

      local view
      local ok, err = pcall(function()
        run({ "git", "worktree", "add", "-b", "feature/x", linked }, repo)

        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()

        assert.is_true(vim.api.nvim_tabpage_is_valid(view.tabpage))
        assert.is_true(view.ready)
        assert.equals(2, #view.entries)

        local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
        assert.equals(2, #lines)

        local joined = table.concat(lines, "\n")
        assert.is_truthy(joined:find(repo, 1, true))
        assert.is_truthy(joined:find(linked, 1, true))
        assert.is_truthy(joined:find("feature/x", 1, true))
      end)

      test_utils.close_view(view)
      pcall(run, { "git", "worktree", "remove", "--force", linked }, repo)
      test_utils.cleanup_repo(repo)
      pcall(vim.fn.delete, linked, "rf")
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "installs keymaps from config.keymaps.worktree_overview on the buffer",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local view
      local ok, err = pcall(function()
        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()

        local lhs = { ["q"] = false, ["R"] = false, ["<CR>"] = false }
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(view.bufnr, "n")) do
          -- `nvim_buf_get_keymap` may return `<CR>` normalised to the
          -- literal "\r" in either `m.lhs` or `m.lhsraw` depending on the
          -- Neovim version; compare every spelling so this test does not
          -- depend on which form nvim is in the mood for.
          if m.lhs == "q" or m.lhsraw == "q" then
            lhs["q"] = true
          end
          if m.lhs == "R" or m.lhsraw == "R" then
            lhs["R"] = true
          end
          if m.lhs == "<CR>" or m.lhs == "\r" or m.lhsraw == "\r" then
            lhs["<CR>"] = true
          end
        end
        assert.is_true(lhs["q"])
        assert.is_true(lhs["R"])
        assert.is_true(lhs["<CR>"])
      end)

      test_utils.close_view(view)
      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "enter_selected opens a DiffView scoped to the chosen worktree",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local linked = repo .. "-wt"

      local overview
      local opened
      local ok, err = pcall(function()
        run({ "git", "worktree", "add", "-b", "feature/x", linked }, repo)
        -- A real divergent commit on the linked worktree so the resolved
        -- `<base>...HEAD` range has something to diff.
        local f = assert(io.open(linked .. "/added.txt", "w"))
        f:write("added\n")
        f:close()
        test_utils.commit(linked, "add file on feature/x")

        overview = WorktreeOverviewView({ adapter = make_adapter(repo) })
        overview:open()

        -- Position the cursor on the row for the linked worktree.
        local target_lnum
        for i, e in ipairs(overview.entries) do
          if e.path == linked then
            target_lnum = i
            break
          end
        end
        assert.is_not_nil(target_lnum)
        vim.api.nvim_win_set_cursor(overview.winid, { target_lnum, 0 })

        local overview_tab = overview.tabpage
        overview:enter_selected()

        local cur_tab = vim.api.nvim_get_current_tabpage()
        assert.is_not.equals(overview_tab, cur_tab)

        opened = require("diffview.lib").get_current_view()
        assert.is_not_nil(opened)
        -- The newly opened view is a DiffView attached to the linked
        -- worktree's toplevel, not the overview's hub repo.
        assert.equals(linked, opened.adapter.ctx.toplevel)
        -- The view is scoped via `<base>...` so the hub branch's commits
        -- drop out. The hub branch (`main` or `master` depending on the
        -- host git's `init.defaultBranch`) is the only candidate
        -- `resolve_default_base` can find in this fixture (no `origin/*`).
        local base = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo)
        assert.equals(base .. "...", opened.rev_arg)
      end)

      test_utils.close_view(opened)
      test_utils.close_view(overview)
      pcall(run, { "git", "worktree", "remove", "--force", linked }, repo)
      test_utils.cleanup_repo(repo)
      pcall(vim.fn.delete, linked, "rf")
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )
end)
