local async = require("diffview.async")
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")

local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local Diff1Raw = require("diffview.scene.layouts.diff_1_raw").Diff1Raw
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local EventEmitter = require("diffview.events").EventEmitter
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local Window = require("diffview.scene.window").Window

local await = async.await
local eq = helpers.eq
local run = helpers.run
local cleanup_repo = helpers.cleanup_repo
local close_view = helpers.close_view

-- Same fixture shape as `restore_focus_after_layout_swap_spec`: two files
-- that resolve to different layout classes under
-- `view.one_sided_layout = "raw"` so that navigation between them exercises
-- the layout-class swap branch in `StandardView.use_entry`.
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

---Set up a fresh DiffView against `repo` and wait for its initial load.
---@param repo string
---@return DiffView, FileEntry, FileEntry # view, modified_entry (Diff2Hor), raw_entry (Diff1Raw)
local function open_view_and_wait(repo)
  local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
  local view = DiffView({
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
  assert.is_not_nil(modified_entry, "expected a FileEntry for existing.txt")
  assert.is_not_nil(raw_entry, "expected a FileEntry for newfile.txt")
  eq(Diff2Hor, modified_entry.layout.class)
  eq(Diff1Raw, raw_entry.layout.class)

  return view, modified_entry, raw_entry
end

describe("StandardView layout-swap cancellation (integration)", function()
  local orig_emitter, original_config, orig_load_file

  before_each(function()
    orig_emitter = DiffviewGlobal.emitter
    DiffviewGlobal.emitter = EventEmitter()
    original_config = vim.deepcopy(config.get_config())
    orig_load_file = Window.load_file
  end)

  after_each(function()
    Window.load_file = orig_load_file
    DiffviewGlobal.emitter = orig_emitter
    config.setup(original_config)
  end)

  ---Install a `Window.load_file` shim that yields via `async.scheduler`
  ---before delegating to the real implementation. The extra scheduler
  ---tick is the deterministic seam a mid-swap injection (close signal or
  ---`:tabnew`) needs: the drain coroutine parks in load_file, control
  ---returns to the test, we mutate view/tab state, and the drain resumes
  ---to find `swap_cancelled` true.
  local function install_load_file_seam()
    local orig = orig_load_file
    Window.load_file = async.wrap(function(self, callback)
      await(async.scheduler())
      local ok = await(orig(self))
      callback(ok)
    end)
  end

  -- Cancellation via `self.closing:send()` must:
  --   * Drop the staged layout from `self.layouts` (so the next swap
  --     re-clones from `entry.layout` rather than reusing the partial
  --     one).
  --   * Not publish `new_layout` to `self.cur_layout`.
  --   * Skip the `file_open_post` emit (listeners assume a live view).
  it(
    "aborts a mid-yield layout swap when the view starts closing",
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
        local modified_entry, raw_entry
        view, modified_entry, raw_entry = open_view_and_wait(repo)

        await(view:set_file(modified_entry, false, false))
        eq(modified_entry, view.cur_entry)
        eq(Diff2Hor, view.cur_layout.class)

        local file_open_post_calls = 0
        view.emitter:on("file_open_post", function()
          file_open_post_calls = file_open_post_calls + 1
        end)

        install_load_file_seam()

        -- Fire `closing:send()` on a scheduler tick so it lands while
        -- the drain is parked in the load_file seam. `vim.schedule`
        -- runs its callback on the next event-loop pump, which happens
        -- while we're awaiting the swap Future below.
        vim.schedule(function()
          view.closing:send()
        end)

        await(view:_set_file(raw_entry))

        -- The staged Diff1Raw layout must have been torn down and its
        -- cache slot cleared so a follow-up swap will re-stage rather
        -- than reuse the partial state left by the cancelled attempt.
        eq(nil, view.layouts[Diff1Raw])

        -- The published layout was never replaced, and `cur_entry`
        -- follows it: leaving `cur_entry` advanced would put the
        -- outgoing layout under a selection for the incoming entry.
        eq(Diff2Hor, view.cur_layout.class)
        eq(modified_entry, view.cur_entry)

        -- The post-swap emit is skipped so listeners don't run against
        -- a closing view.
        eq(0, file_open_post_calls)
      end)

      close_view(view)
      cleanup_repo(repo)
      if not ok then
        error(err)
      end
    end)
  )

  -- Cancellation via `self.tabpage ~= nvim_get_current_tabpage()` must:
  --   * Also drop the staged cache entry and skip the publish.
  --   * Leave the diff view usable once the user returns to the diff
  --     tabpage (a subsequent `set_file` completes normally).
  --   * Skip the `wincmd =` that would otherwise run in the intruding
  --     tabpage.
  it(
    "aborts a mid-yield layout swap when the user switches tabpages",
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
      local other_tab

      local ok, err = pcall(function()
        local modified_entry, raw_entry
        view, modified_entry, raw_entry = open_view_and_wait(repo)

        await(view:set_file(modified_entry, false, false))
        eq(modified_entry, view.cur_entry)
        eq(Diff2Hor, view.cur_layout.class)

        local file_open_post_calls = 0
        view.emitter:on("file_open_post", function()
          file_open_post_calls = file_open_post_calls + 1
        end)

        install_load_file_seam()

        -- Schedule the tab switch to fire while the drain is parked in
        -- the load_file seam.
        vim.schedule(function()
          vim.cmd("tabnew")
          other_tab = vim.api.nvim_get_current_tabpage()
        end)

        await(view:_set_file(raw_entry))

        assert.is_not_nil(other_tab, "tabnew should have run before the swap resolved")
        assert.is_true(
          vim.api.nvim_tabpage_is_valid(other_tab),
          "intruding tabpage should still exist"
        )

        -- The intruding tabpage keeps exactly the one window `tabnew`
        -- opened it with: no stray `pivot_producer` split, no `wincmd =`
        -- reflow.
        eq(1, #vim.api.nvim_tabpage_list_wins(other_tab))

        -- Same cache/publish invariants as the close case, plus
        -- `cur_entry` matches `cur_layout`.
        eq(nil, view.layouts[Diff1Raw])
        eq(Diff2Hor, view.cur_layout.class)
        eq(modified_entry, view.cur_entry)
        eq(0, file_open_post_calls)

        -- Returning to the diff tabpage and swapping again completes
        -- normally: the view is not permanently wedged by the
        -- cancellation.
        vim.api.nvim_set_current_tabpage(view.tabpage)
        Window.load_file = orig_load_file
        await(view:set_file(raw_entry, false, false))
        eq(raw_entry, view.cur_entry)
        eq(Diff1Raw, view.cur_layout.class)
      end)

      if other_tab and vim.api.nvim_tabpage_is_valid(other_tab) then
        pcall(vim.api.nvim_command, "tabclose " .. vim.api.nvim_tabpage_get_number(other_tab))
      end
      close_view(view)
      cleanup_repo(repo)
      if not ok then
        error(err)
      end
    end)
  )
end)
