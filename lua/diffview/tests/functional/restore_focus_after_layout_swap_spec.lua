local async = require("diffview.async")
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")

local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local Diff1Raw = require("diffview.scene.layouts.diff_1_raw").Diff1Raw
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local EventEmitter = require("diffview.events").EventEmitter
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local Layout = require("diffview.scene.layout").Layout
local RevType = require("diffview.vcs.rev").RevType

local await, pawait = async.await, async.pawait
local eq = helpers.eq
local run = helpers.run
local cleanup_repo = helpers.cleanup_repo
local close_view = helpers.close_view

-- Build a repo with two entries that land on different layout classes under
-- `view.one_sided_layout = "raw"`:
--   * `existing.txt` (modified, status M) keeps the default Diff2Hor.
--   * `newfile.txt`  (untracked, status ?) is substituted to Diff1Raw.
-- Stepping between them via `view:set_file` therefore exercises the swap
-- branch in `StandardView.use_entry`.
local function make_repo()
  local repo = helpers.init_repo()

  local existing = repo .. "/existing.txt"
  local f = assert(io.open(existing, "w"))
  f:write("line one\n")
  f:close()
  run({ "git", "add", "existing.txt" }, repo)
  run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" }, repo)

  f = assert(io.open(existing, "a"))
  f:write("line two\n")
  f:close()

  local newfile = repo .. "/newfile.txt"
  f = assert(io.open(newfile, "w"))
  f:write("new file content\n")
  f:close()

  return repo
end

describe("StandardView.use_entry layout-swap focus (integration)", function()
  local orig_emitter, original_config

  before_each(function()
    orig_emitter = DiffviewGlobal.emitter
    DiffviewGlobal.emitter = EventEmitter()
    original_config = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    DiffviewGlobal.emitter = orig_emitter
    config.setup(original_config)
  end)

  -- The fix in StandardView.use_entry captures `panel:is_focused()` *before*
  -- the layout swap and restores panel focus *after* it. Without that
  -- capture, the destroy/create dance in the swap branch lands focus on the
  -- new layout's main window, even though the caller passed `focus = false`.
  -- This test reproduces that scenario by navigating between a modified file
  -- (Diff2Hor) and an untracked file (Diff1Raw).
  it(
    "preserves panel focus when navigating Diff2Hor -> Diff1Raw",
    helpers.async_test(function()
      config.setup({
        use_icons = false,
        view = {
          default = { layout = "diff2_horizontal", focus_diff = false },
          one_sided_layout = "raw",
        },
      })

      local repo = make_repo()
      local view

      local ok, err = pcall(function()
        local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
        view = DiffView({
          adapter = adapter,
          rev_arg = nil,
          path_args = {},
          left = GitRev(RevType.STAGE, 0),
          right = GitRev(RevType.LOCAL),
          options = { show_untracked = true },
        })
        assert.is_true(view:is_valid())

        view:open()
        local loaded = vim.wait(3000, function()
          return view.initialized
        end, 10)
        assert.is_true(loaded, "view did not finish loading within 3s")

        -- Drain the initial set_file kicked off by update_files so the
        -- subsequent navigations start from a settled view state.
        if view._set_file_in_flight then
          await(view._set_file_in_flight)
        end

        local modified_entry, raw_entry
        for _, f in view.files:iter() do
          if f.path == "existing.txt" then
            modified_entry = f
          elseif f.path == "newfile.txt" then
            raw_entry = f
          end
        end
        assert.is_not_nil(modified_entry, "expected a FileEntry for existing.txt")
        assert.is_not_nil(raw_entry, "expected a FileEntry for newfile.txt")

        -- Confirm the substitution: navigating between these two entries
        -- crosses the layout-class boundary that triggers the swap branch.
        eq(Diff2Hor, modified_entry.layout.class)
        eq(Diff1Raw, raw_entry.layout.class)

        -- Setup: ensure the active entry is the Diff2Hor one and that
        -- panel focus is what the user would have under focus_diff=false.
        await(view:set_file(modified_entry, false, false))
        eq(modified_entry, view.cur_entry)
        view.panel:focus(true)
        assert.is_true(
          view.panel:is_focused(),
          "test precondition: panel should be focused before the swap"
        )

        -- Trigger the swap: load the Diff1Raw entry with focus=false. This
        -- is the same code path `<tab>` reaches via `select_next_entry`
        -- -> `view:next_file(true)` -> `_set_file`, but invoking
        -- `set_file` directly keeps the navigation deterministic regardless
        -- of file ordering in the panel.
        await(view:set_file(raw_entry, false, false))
        eq(raw_entry, view.cur_entry)
        eq(Diff1Raw, view.cur_layout.class)

        assert.is_true(
          view.panel:is_focused(),
          "panel focus was lost across the Diff2Hor -> Diff1Raw layout swap"
        )
      end)

      close_view(view)
      cleanup_repo(repo)
      if not ok then
        error(err)
      end
    end)
  )

  -- The atomic-swap invariant: `self.cur_layout` always exposes a
  -- valid layout to observers throughout the swap — the outgoing one
  -- until `create` resolves, then the fully-created new one while
  -- the old windows are torn down. A concurrent `ensure_layout` (the
  -- debounced `update_files_impl` firing mid-swap, or any autocmd
  -- that window teardown fires synchronously) therefore never sees a
  -- half-built layout and cannot trip `Layout:recover`.
  it(
    "keeps cur_layout on a valid layout throughout the swap",
    helpers.async_test(function()
      config.setup({
        use_icons = false,
        view = {
          default = { layout = "diff2_horizontal", focus_diff = false },
          one_sided_layout = "raw",
        },
      })

      local repo = make_repo()
      local view

      local ok, err = pcall(function()
        local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
        view = DiffView({
          adapter = adapter,
          rev_arg = nil,
          path_args = {},
          left = GitRev(RevType.STAGE, 0),
          right = GitRev(RevType.LOCAL),
          options = { show_untracked = true },
        })
        assert.is_true(view:is_valid())

        view:open()
        local loaded = vim.wait(3000, function()
          return view.initialized
        end, 10)
        assert.is_true(loaded, "view did not finish loading within 3s")

        if view._set_file_in_flight then
          await(view._set_file_in_flight)
        end

        local modified_entry, raw_entry
        for _, f in view.files:iter() do
          if f.path == "existing.txt" then
            modified_entry = f
          elseif f.path == "newfile.txt" then
            raw_entry = f
          end
        end

        -- Land on the Diff2Hor entry as the swap's outgoing layout.
        await(view:set_file(modified_entry, false, false))
        eq(Diff2Hor, view.cur_layout.class)

        -- Spy on the invariant. Sample `self.cur_layout:is_valid()` on
        -- every `Layout:destroy` entry that fires during the swap: at
        -- each of those points the view must still expose a valid
        -- layout to any observer (concurrent `ensure_layout`, autocmds
        -- that window teardown fires synchronously, etc.). The specific
        -- identity of that layout — outgoing vs. freshly-created —
        -- doesn't matter to the invariant; only its validity does.
        local snapshots = {}
        local orig_destroy = Layout.destroy
        Layout.destroy = function(layout_self)
          snapshots[#snapshots + 1] = view.cur_layout and view.cur_layout:is_valid()
          orig_destroy(layout_self)
        end

        local swap_ok, swap_err = pawait(view.set_file, view, raw_entry, false, false)
        Layout.destroy = orig_destroy
        assert(swap_ok, swap_err)

        eq(Diff1Raw, view.cur_layout.class)

        -- At least one destroy fires during the swap (the outgoing
        -- Diff2Hor). Every snapshot taken while the swap was in
        -- flight must show a valid `cur_layout`.
        assert.is_true(#snapshots > 0, "expected at least one Layout:destroy call during the swap")
        for i, valid in ipairs(snapshots) do
          assert.is_true(valid, "cur_layout was invalid at destroy call #" .. i)
        end
      end)

      close_view(view)
      cleanup_repo(repo)
      if not ok then
        error(err)
      end
    end)
  )
end)
