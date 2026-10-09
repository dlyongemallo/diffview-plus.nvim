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
        -- `render` strips the shared parent directory from every path, so
        -- what shows up on each row is the basename (`repo`, `repo-wt`),
        -- not the full `/tmp/.../repo` form.
        local repo_name = vim.fs.basename(repo)
        local linked_name = vim.fs.basename(linked)
        assert.is_truthy(joined:find(repo_name, 1, true))
        assert.is_truthy(joined:find(linked_name, 1, true))
        assert.is_truthy(joined:find("feature/x", 1, true))

        -- The linked worktree was branched off `make_repo`'s single commit
        -- with no further commits, so it should have zero stats and no
        -- stats segment at all in its row.
        local linked_entry
        for _, e in ipairs(view.entries) do
          if e.path == linked then
            linked_entry = e
            break
          end
        end
        assert.is_not_nil(linked_entry)
        assert.equals(0, linked_entry.stats.ahead)
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

        local lhs = { ["R"] = false, ["<CR>"] = false }
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(view.bufnr, "n")) do
          -- `nvim_buf_get_keymap` may return `<CR>` normalised to the
          -- literal "\r" in either `m.lhs` or `m.lhsraw` depending on the
          -- Neovim version; compare every spelling so this test does not
          -- depend on which form nvim is in the mood for.
          if m.lhs == "R" or m.lhsraw == "R" then
            lhs["R"] = true
          end
          if m.lhs == "<CR>" or m.lhs == "\r" or m.lhsraw == "\r" then
            lhs["<CR>"] = true
          end
        end
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
    "hides bare worktrees unless include_bare is enabled",
    test_utils.async_test(function()
      -- Driving `include_bare` with a real bare repo would mean switching
      -- the whole repo to `--bare`, which `make_repo` is not set up for.
      -- Inject a synthetic bare entry alongside a real one and re-render,
      -- which exercises the exact filter path.
      local repo = test_utils.make_repo()

      local view
      local ok, err = pcall(function()
        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()

        view.entries = {
          view.entries[1],
          {
            path = repo .. "-fake-bare",
            is_bare = true,
            is_detached = false,
            is_locked = false,
            is_prunable = false,
          },
        }

        -- Default config: bare entries are filtered out of the visible list.
        view:render()
        local joined = table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
        assert.is_falsy(joined:find("(bare)", 1, true))
        assert.equals(1, #view._visible_entries)

        -- Flip the config and re-render; the bare row is now visible.
        local original = require("diffview.config")._config.worktree_overview
        require("diffview.config")._config.worktree_overview =
          vim.tbl_extend("force", original, { include_bare = true })

        view:render()
        joined = table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
        assert.is_truthy(joined:find("(bare)", 1, true))
        assert.equals(2, #view._visible_entries)

        require("diffview.config")._config.worktree_overview = original
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

        -- Overview should have picked up the extra commit as `ahead = 1`
        -- against the resolved default base.
        local linked_entry
        for _, e in ipairs(overview.entries) do
          if e.path == linked then
            linked_entry = e
            break
          end
        end
        assert.is_not_nil(linked_entry)
        assert.equals(1, linked_entry.stats.ahead)
        assert.equals(1, linked_entry.stats.changed_files)
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
