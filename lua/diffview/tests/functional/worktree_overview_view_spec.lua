local async = require("diffview.async")
local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
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
        -- not the full `/tmp/.../repo` form. The negative assertion on
        -- the shared parent pins the stripping behavior, since the
        -- positive basename checks would still pass against unstripped
        -- rendering (each basename is a substring of its full path).
        local repo_name = vim.fs.basename(repo)
        local linked_name = vim.fs.basename(linked)
        local shared_parent = vim.fs.dirname(repo)
        assert.is_truthy(joined:find(repo_name, 1, true))
        assert.is_truthy(joined:find(linked_name, 1, true))
        assert.is_truthy(joined:find("feature/x", 1, true))
        assert.is_nil(joined:find(shared_parent, 1, true))

        -- The linked worktree was branched off `make_repo`'s single commit
        -- with no further commits, so its ahead count should be zero.
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
      -- Snapshot the config before the pcall body so a failed assertion
      -- inside doesn't leak `include_bare = true` into later specs.
      local original = require("diffview.config")._config.worktree_overview
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
        require("diffview.config")._config.worktree_overview =
          vim.tbl_extend("force", original, { include_bare = true })

        view:render()
        joined = table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
        assert.is_truthy(joined:find("(bare)", 1, true))
        assert.equals(2, #view._visible_entries)
      end)

      require("diffview.config")._config.worktree_overview = original
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

        -- The committed `added.txt` must surface in the DiffView's file
        -- list under the `<base>...HEAD` range (populated into `working`
        -- for revision diffs). `ready` flips before `update_files` fills
        -- the panel, so wait on both.
        assert.is_true(
          vim.wait(5000, function()
            return opened.ready and #opened.files.working > 0
          end),
          "DiffView never surfaced the committed `added.txt`"
        )
        local found_added
        for _, f in ipairs(opened.files.working) do
          if f.path == "added.txt" then
            found_added = f
            break
          end
        end
        assert.is_not_nil(found_added)

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

  it(
    "renders status-unknown markers on a clean batch when the status probe errored",
    test_utils.async_test(function()
      -- Regression: when every visible row is clean except one whose
      -- `git status` probe exited non-zero, `compute_widths` would see
      -- no positive dirty count anywhere and leave `any_dirty` false, so
      -- `trio_w` collapses to zero and `push_stats_cells` returns before
      -- reaching the `status_unknown` branch. The affected row then
      -- looked clean in the UI despite us knowing the probe failed.
      local repo = test_utils.make_repo()

      local view
      local ok, err = pcall(function()
        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()

        -- Synthesize two rows: one truly clean, one whose status probe
        -- errored. Both have zero dirty counts, so without the fix the
        -- widths dict never reserves trio space and the dim markers for
        -- the errored row are suppressed. Use the real entry at [1] as
        -- the clean baseline and craft a second one that mirrors it.
        local real = view.entries[1]
        local errored = {
          path = real.path .. "-errored",
          is_bare = false,
          is_detached = false,
          is_locked = false,
          is_prunable = false,
          head_commit = real.head_commit,
          branch = real.branch,
          ref = real.ref,
          stats = {
            base = real.stats and real.stats.base or nil,
            ahead = 0,
            behind = 0,
            changed_files = 0,
            insertions = 0,
            deletions = 0,
            staged = 0,
            unstaged = 0,
            untracked = 0,
            errors = { "status" },
          },
        }
        -- Zero out the real entry's dirty counts too so the batch has no
        -- positive dirty count anywhere; this is the trigger shape.
        if real.stats then
          real.stats.staged = 0
          real.stats.unstaged = 0
          real.stats.untracked = 0
          real.stats.errors = real.stats.errors or {}
        end
        view.entries = { real, errored }

        view:render()
        local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
        assert.equals(2, #lines)
        -- `render` strips the shared parent directory, so lines carry
        -- basenames rather than full paths. The errored basename ends in
        -- `-errored`, which is unique; check it first so the clean row
        -- picks up only the leftover.
        local real_name = vim.fs.basename(real.path)
        local errored_name = vim.fs.basename(errored.path)
        local clean_line, errored_line
        for _, line in ipairs(lines) do
          if line:find(errored_name, 1, true) then
            errored_line = line
          elseif line:find(real_name, 1, true) then
            clean_line = line
          end
        end
        assert.is_truthy(clean_line)
        assert.is_truthy(errored_line)

        -- Semantic check: each dirty-trio cell renders as `<marker><suffix>`,
        -- and the suffix letters `s`/`u`/`?` live only on this trio -- so
        -- a hit on each proves the `status_unknown` branch fired. Plain
        -- find keeps the `?` from being treated as a pattern.
        assert.is_truthy(errored_line:find("─s", 1, true))
        assert.is_truthy(errored_line:find("─u", 1, true))
        assert.is_truthy(errored_line:find("─?", 1, true))

        -- Fixture-independent check: anything the two rows share (nil
        -- base, probe errors on branch/diff) adds the same number of
        -- dashes to both lines, so the delta isolates the trio's own
        -- contribution. The errored row should carry exactly three
        -- more dashes than the clean row.
        local _, clean_dashes = clean_line:gsub("─", "")
        local _, errored_dashes = errored_line:gsub("─", "")
        assert.equals(3, errored_dashes - clean_dashes)
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
    "paint_placeholder renders both the static and animated forms",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local view
      local ok, err = pcall(function()
        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()

        -- Static form (no arguments): `init_layout` paints this before
        -- `refresh` starts, so a human watching the open sees it first.
        view:paint_placeholder()
        local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
        assert.equals(1, #lines)
        assert.equals("Scanning worktrees...", lines[1])

        -- Animated form: the first frame plus the elapsed-time suffix.
        view:paint_placeholder(0, 2500)
        lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
        assert.equals(1, #lines)
        assert.is_truthy(lines[1]:find("Scanning worktrees...", 1, true))
        assert.is_truthy(lines[1]:find("2.5s", 1, true))
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
    "shows the Scanning placeholder before refresh completes and clears it after",
    test_utils.async_test(function()
      -- Covers the full placeholder lifecycle: `init_layout` paints the
      -- static frame, `_start_spinner` arms the timer, `refresh` runs, and
      -- the final `render` replaces the placeholder with the worktree rows.
      -- A buffer-contents check at the moment `refresh` is entered catches
      -- a regression where the placeholder is never painted (or painted
      -- after refresh, so the user never sees it).
      local repo = test_utils.make_repo()

      local view
      local during_refresh = {}
      local ok, err = pcall(function()
        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        -- Snapshot buffer state the moment `refresh` starts; `post_open`
        -- has already painted the placeholder and armed the spinner by
        -- this point.
        local original_refresh = view.refresh
        view.refresh = function(self)
          during_refresh.lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
          during_refresh.spinner_timer = self._spinner_timer
          during_refresh.spinner_start = self._spinner_start
          return original_refresh(self)
        end
        view:open()

        -- Mid-refresh: buffer shows the placeholder and the spinner is
        -- live.
        assert.is_truthy(during_refresh.lines[1]:find("Scanning worktrees...", 1, true))
        assert.is_not_nil(during_refresh.spinner_timer)
        assert.is_not_nil(during_refresh.spinner_start)

        -- Post-refresh: the final overview replaces the placeholder and
        -- the spinner has been stopped.
        local final_lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
        assert.is_falsy((final_lines[1] or ""):find("Scanning worktrees...", 1, true))
        assert.is_nil(view._spinner_timer)
        assert.is_nil(view._spinner_start)
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
    "post_open stops the spinner on both the success and error paths",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()

      -- Success path: after a normal open, the timer must be stopped and
      -- the hrtime anchor cleared so a later refresh starts clean.
      local view
      local ok, err = pcall(function()
        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()
        assert.is_nil(view._spinner_timer)
        assert.is_nil(view._spinner_start)
      end)

      test_utils.close_view(view)

      if not ok then
        test_utils.cleanup_repo(repo)
        async.await(async.scheduler())
        error(err)
      end

      -- Error path: swap `refresh` for one that throws, and verify that
      -- `post_open`'s pcall still runs `_stop_spinner` before re-raising.
      local errored_view
      local err_ok, err_err = pcall(function()
        errored_view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        errored_view.refresh = function()
          error("synthetic refresh failure")
        end
        local open_ok, open_err = pcall(function()
          errored_view:open()
        end)
        assert.is_false(open_ok)
        assert.is_truthy(tostring(open_err):find("synthetic refresh failure", 1, true))
        assert.is_nil(errored_view._spinner_timer)
        assert.is_nil(errored_view._spinner_start)
      end)

      test_utils.close_view(errored_view)
      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not err_ok then
        error(err_err)
      end
    end)
  )

  it(
    "enter_selected drops the base rev when the worktree HEAD IS the base",
    test_utils.async_test(function()
      -- Selecting the main worktree (whose HEAD is the resolved base)
      -- used to produce `base...HEAD` -> empty range AND hid staged /
      -- unstaged work behind the empty revision view. The fix drops the
      -- rev arg in that case so the DiffView falls through to a working-
      -- tree-vs-HEAD view, which still surfaces an uncommitted change.
      local repo = test_utils.make_repo()

      local overview
      local opened
      local ok, err = pcall(function()
        -- Stage an uncommitted change so the fallback has something to
        -- display; a passing test still asserts on the view's shape, but
        -- a dirty worktree makes the regression concrete.
        local f = assert(io.open(repo .. "/dirty.txt", "w"))
        f:write("dirty\n")
        f:close()
        run({ "git", "add", "dirty.txt" }, repo)

        overview = WorktreeOverviewView({ adapter = make_adapter(repo) })
        overview:open()

        -- The repo has exactly one worktree row; select it.
        assert.equals(1, #overview.entries)
        vim.api.nvim_win_set_cursor(overview.winid, { 1, 0 })
        overview:enter_selected()

        opened = require("diffview.lib").get_current_view()
        assert.is_not_nil(opened)
        -- The overview and DiffView share `adapter.ctx.toplevel` and both
        -- have a nil `rev_arg`, so pin that a *different* view opened and
        -- that it's actually a DiffView before trusting the rev-arg shape.
        assert.not_equals(overview, opened)
        assert.is_true(opened:instanceof(DiffView))
        assert.equals(repo, opened.adapter.ctx.toplevel)
        -- `rev_arg` on a working-tree-vs-HEAD DiffView is nil / empty;
        -- a `base...` form would set it to that string.
        local rev_arg = opened.rev_arg
        assert.is_true(rev_arg == nil or rev_arg == "")
        -- The staged `dirty.txt` must surface in the DiffView's staged
        -- bucket; this is what the fix exists to make visible. `ready`
        -- flips before `update_files` populates the panel, so wait on
        -- both.
        assert.is_true(
          vim.wait(5000, function()
            return opened.ready and #opened.files.staged > 0
          end),
          "DiffView never surfaced the staged fixture"
        )
        local found
        for _, f in ipairs(opened.files.staged) do
          if f.path == "dirty.txt" then
            found = f
            break
          end
        end
        assert.is_not_nil(found)
      end)

      test_utils.close_view(opened)
      test_utils.close_view(overview)
      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "enter_selected warns and still opens when no base can be resolved",
    test_utils.async_test(function()
      -- With `make_repo` renamed off `main`/`master` and no remotes, the
      -- resolver returns nil. The DiffView used to open silently with the
      -- working-tree-vs-HEAD fallback, which hides committed changes on
      -- the branch; we now emit a visible warning so the user knows what
      -- they are (not) looking at.
      local repo = test_utils.make_repo()

      local overview
      local opened
      local warned
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
          warned = msg
        end
      end

      local ok, err = pcall(function()
        run({ "git", "branch", "-m", "feature/only" }, repo)

        overview = WorktreeOverviewView({ adapter = make_adapter(repo) })
        overview:open()

        vim.api.nvim_win_set_cursor(overview.winid, { 1, 0 })
        overview:enter_selected()

        assert.is_string(warned)
        assert.is_truthy(warned:find("No comparison base", 1, true))
        opened = require("diffview.lib").get_current_view()
        assert.is_not_nil(opened)
        -- Without this the test could pass with no DiffView opened: the
        -- current tabpage is still the overview's, so `get_current_view`
        -- would hand back `overview` itself.
        assert.not_equals(overview, opened)
        assert.is_true(opened:instanceof(DiffView))
      end)

      vim.notify = original_notify
      test_utils.close_view(opened)
      test_utils.close_view(overview)
      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )
end)
