local helpers = require("diffview.tests.helpers")
local async = require("diffview.async")
local config = require("diffview.config")
local StandardView = require("diffview.scene.views.standard.standard_view").StandardView
local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local FileHistoryView =
  require("diffview.scene.views.file_history.file_history_view").FileHistoryView

local eq = helpers.eq

-- The queuing branch of `_set_file` only inspects `:is_done()` on the
-- in-flight slot, so a duck-typed stub is enough to exercise it without
-- spawning a real Future (which would leave a yielded coroutine in
-- `async._handles` for the lifetime of the test process).
local function pending_in_flight()
  return {
    is_done = function()
      return false
    end,
  }
end

-- Drain any `cb` the test body didn't consume (e.g., because an
-- assertion inside the pcall raised before reaching the corresponding
-- drain call). Without this, the wrapped `use_entry` coroutine stays
-- suspended in `async._handles` for the rest of the test process.
-- `pcall` per callback so a misbehaving cb during cleanup doesn't mask
-- the original error.
local function drain_remaining_cbs(cbs)
  while #cbs > 0 do
    pcall(table.remove(cbs, 1))
  end
end

describe("diffview.standard_view panel cursor", function()
  local orig_win_is_valid, orig_win_get_cursor, orig_win_set_cursor

  before_each(function()
    orig_win_is_valid = vim.api.nvim_win_is_valid
    orig_win_get_cursor = vim.api.nvim_win_get_cursor
    orig_win_set_cursor = vim.api.nvim_win_set_cursor
  end)

  after_each(function()
    vim.api.nvim_win_is_valid = orig_win_is_valid
    vim.api.nvim_win_get_cursor = orig_win_get_cursor
    vim.api.nvim_win_set_cursor = orig_win_set_cursor
  end)

  ---Build a minimal mock view with a panel stub.
  local function make_view(panel_open, winid)
    local view = {
      panel = {
        winid = winid or 42,
        is_open = function()
          return panel_open
        end,
      },
      panel_cursor = nil,
    }
    setmetatable(view, { __index = StandardView })
    return view
  end

  it("save_panel_cursor stores the cursor when panel is open", function()
    local view = make_view(true, 42)
    vim.api.nvim_win_is_valid = function()
      return true
    end
    vim.api.nvim_win_get_cursor = function()
      return { 5, 3 }
    end

    view:save_panel_cursor()
    eq({ 5, 3 }, view.panel_cursor)
  end)

  it("save_panel_cursor is a no-op when panel is closed", function()
    local view = make_view(false)
    vim.api.nvim_win_is_valid = function()
      return true
    end
    vim.api.nvim_win_get_cursor = function()
      error("should not be called")
    end

    view:save_panel_cursor()
    eq(nil, view.panel_cursor)
  end)

  it("save_panel_cursor is a no-op when winid is invalid", function()
    local view = make_view(true, 42)
    vim.api.nvim_win_is_valid = function()
      return false
    end
    vim.api.nvim_win_get_cursor = function()
      error("should not be called")
    end

    view:save_panel_cursor()
    eq(nil, view.panel_cursor)
  end)

  it("restore_panel_cursor sets the cursor when panel_cursor exists", function()
    local set_args
    local view = make_view(true, 42)
    view.panel_cursor = { 10, 2 }
    vim.api.nvim_win_is_valid = function()
      return true
    end
    vim.api.nvim_win_set_cursor = function(w, c)
      set_args = { w, c }
    end

    view:restore_panel_cursor()
    eq({ 42, { 10, 2 } }, set_args)
  end)

  it("restore_panel_cursor is a no-op when panel_cursor is nil", function()
    local view = make_view(true, 42)
    vim.api.nvim_win_is_valid = function()
      return true
    end
    vim.api.nvim_win_set_cursor = function()
      error("should not be called")
    end

    view:restore_panel_cursor()
  end)

  it("round-trips: save then restore preserves cursor position", function()
    local restored
    local view = make_view(true, 42)
    vim.api.nvim_win_is_valid = function()
      return true
    end
    vim.api.nvim_win_get_cursor = function()
      return { 7, 4 }
    end
    vim.api.nvim_win_set_cursor = function(_, c)
      restored = c
    end

    view:save_panel_cursor()
    view:restore_panel_cursor()
    eq({ 7, 4 }, restored)
  end)
end)

describe("diffview.standard_view should_show_panel", function()
  local original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original_config)
  end)

  it("StandardView reads file_panel.show", function()
    local view = setmetatable({}, { __index = StandardView })

    config.get_config().file_panel.show = true
    eq(true, view:should_show_panel())

    config.get_config().file_panel.show = false
    eq(false, view:should_show_panel())
  end)

  it("FileHistoryView reads file_history_panel.show", function()
    local view = setmetatable({}, { __index = FileHistoryView })

    config.get_config().file_history_panel.show = true
    eq(true, view:should_show_panel())

    config.get_config().file_history_panel.show = false
    eq(false, view:should_show_panel())
  end)

  it("FileHistoryView is independent of file_panel.show", function()
    local view = setmetatable({}, { __index = FileHistoryView })

    config.get_config().file_panel.show = false
    config.get_config().file_history_panel.show = true
    eq(true, view:should_show_panel())

    config.get_config().file_panel.show = true
    config.get_config().file_history_panel.show = false
    eq(false, view:should_show_panel())
  end)
end)

describe("diffview.standard_view layout-swap focus", function()
  it("restores focus to the file panel when the panel was focused before the swap", function()
    local panel_focus_calls = 0
    local main_focus_calls = 0

    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      panel = {
        focus = function(_, no_open)
          panel_focus_calls = panel_focus_calls + 1
          eq(true, no_open)
        end,
      },
      cur_layout = {
        is_focused = function()
          return true
        end,
        get_main_win = function()
          return {
            focus = function()
              main_focus_calls = main_focus_calls + 1
            end,
          }
        end,
      },
    }, { __index = StandardView })

    view:restore_focus_after_layout_swap(true)

    eq(1, panel_focus_calls)
    eq(0, main_focus_calls)
  end)

  it("preserves main-window focus when the diff layout was focused before the swap", function()
    local panel_focus_calls = 0
    local main_focus_calls = 0

    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      panel = {
        focus = function()
          panel_focus_calls = panel_focus_calls + 1
        end,
      },
      cur_layout = {
        is_focused = function()
          return true
        end,
        get_main_win = function()
          return {
            focus = function()
              main_focus_calls = main_focus_calls + 1
            end,
          }
        end,
      },
    }, { __index = StandardView })

    view:restore_focus_after_layout_swap(false)

    eq(0, panel_focus_calls)
    eq(1, main_focus_calls)
  end)

  it("does nothing when neither the panel nor the layout was focused before the swap", function()
    local panel_focus_calls = 0
    local main_focus_calls = 0

    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      panel = {
        focus = function()
          panel_focus_calls = panel_focus_calls + 1
        end,
      },
      cur_layout = {
        is_focused = function()
          return false
        end,
        get_main_win = function()
          return {
            focus = function()
              main_focus_calls = main_focus_calls + 1
            end,
          }
        end,
      },
    }, { __index = StandardView })

    view:restore_focus_after_layout_swap(false)

    eq(0, panel_focus_calls)
    eq(0, main_focus_calls)
  end)
end)

-- Rapid navigation (e.g., mashing `<Tab>` faster than the async HEAD~ git
-- fetch can complete) used to spawn overlapping `_set_file` coroutines
-- that shared the same windows. The second's `Layout.use_entry`
-- overwrote `win.file`, and the first's `open_file` then ran
-- `set_win_buf` against an empty buffer whose content was still loading,
-- placing an empty left-side buffer in the diff window so `]c` in
-- `jump_to_first_change` found no changes and stranded the cursor at
-- line 1. The fix coalesces concurrent calls: only the newest pending
-- file is kept, and the in-flight worker picks it up on completion;
-- queued callers receive the same in-flight Future so `await(set_file)`
-- (e.g. from conflict resolution) does not resume until the view has
-- actually switched files.
describe("diffview.standard_view _set_file serialization", function()
  it("queues pending file when a previous _set_file is in-flight", function()
    local in_flight = pending_in_flight()

    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      _set_file_in_flight = in_flight,
      _set_file_pending = nil,
    }, { __index = StandardView })

    -- The queued branch only touches the pending slot and returns the
    -- existing worker, so we can stub out everything else.
    StandardView._set_file(view, "file_B")

    eq("file_B", view._set_file_pending)
    -- The queued path does not modify the in-flight slot; the real
    -- worker is responsible for clearing it on exit.
    assert.are.equal(in_flight, view._set_file_in_flight)
  end)

  it("returns the existing in-flight Future for queued callers", function()
    local in_flight = pending_in_flight()

    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      _set_file_in_flight = in_flight,
      _set_file_pending = nil,
    }, { __index = StandardView })

    -- Non-awaited rapid navigation should not spawn a new wrapper task
    -- per call; each queued call returns the same in-flight Future so
    -- awaited callers join the existing worker.
    local first = StandardView._set_file(view, "file_B")
    local second = StandardView._set_file(view, "file_C")
    assert.are.equal(in_flight, first)
    assert.are.equal(in_flight, second)
  end)

  it("keeps only the newest pending file across multiple queued calls", function()
    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      _set_file_in_flight = pending_in_flight(),
      _set_file_pending = nil,
    }, { __index = StandardView })

    StandardView._set_file(view, "file_B")
    StandardView._set_file(view, "file_C")
    StandardView._set_file(view, "file_D")

    -- Latest-wins: intermediate navigations are dropped so the user
    -- doesn't sit through brief openings of files they tabbed past.
    eq("file_D", view._set_file_pending)
  end)

  it("starts a new worker when the previous one is already done", function()
    local opened = {}
    local cbs = {}
    local saved_vim_cmd = vim.cmd
    vim.cmd = function() end

    -- An already-settled future shouldn't block fresh work. The check
    -- `:is_done()` lets `_set_file` recover from a crashed previous
    -- worker (slot wasn't cleared) by starting a new one.
    local done_future = async.void(function() end)()

    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      panel = { render = function() end, redraw = function() end },
      cur_layout = { detach_files = function() end },
      emitter = { emit = function() end },
      cur_entry = { opened = true },
      nulled = false,
      _set_file_in_flight = done_future,
      _set_file_pending = nil,
      use_entry = async.wrap(function(_, target, cb)
        table.insert(opened, target)
        table.insert(cbs, cb)
      end, 3),
    }, { __index = StandardView })

    local ok, err = pcall(function()
      StandardView._set_file(view, "file_A")
      -- The recovery branch must have replaced the stale done future
      -- with a fresh worker. Check before draining since draining clears
      -- the slot back to nil.
      assert.is_not.equal(done_future, view._set_file_in_flight)
      -- Drain the worker so its coroutine doesn't linger in
      -- `async._handles` for the rest of the test process.
      table.remove(cbs, 1)()
    end)

    drain_remaining_cbs(cbs)
    vim.cmd = saved_vim_cmd
    assert.is_true(ok, err)

    eq({ "file_A" }, opened)
    eq(nil, view._set_file_in_flight)
  end)

  it("does not queue when no _set_file is in-flight", function()
    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      _set_file_in_flight = nil,
      _set_file_pending = nil,
    }, { __index = StandardView })

    -- Without an in-flight worker `_set_file` must proceed past the
    -- queuing branch and start a worker. We don't care about the
    -- failure mode here -- only that it tried (panel is nil, so the
    -- worker errors on its first method call). The pending slot must
    -- end up clean: the worker clears `pending` at the top of each
    -- iteration, so a subsequent call doesn't replay file_X.
    pcall(function()
      StandardView._set_file(view, "file_X")
    end)

    eq(nil, view._set_file_pending)
  end)

  -- The core contract for awaited callers (e.g. conflict resolution's
  -- `await(view:set_file(item))`): the returned Future must not resolve
  -- until the requested file has actually been opened. With the worker
  -- stubbed to stall on each `use_entry`, we sequence two overlapping
  -- calls and assert both stay pending until the worker drains, then
  -- resolve in lockstep.
  it("await(_set_file) resumes only after the latest pending file is opened", function()
    local opened = {}
    local cbs = {}

    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      panel = { render = function() end, redraw = function() end },
      cur_layout = { detach_files = function() end },
      emitter = { emit = function() end },
      cur_entry = { opened = true },
      nulled = false,
      -- Controllable use_entry: record the target and stash its
      -- callback so the test resumes the worker on demand.
      use_entry = async.wrap(function(_, target, cb)
        table.insert(opened, target)
        table.insert(cbs, cb)
      end, 3),
    }, { __index = StandardView })

    local saved_vim_cmd = vim.cmd
    vim.cmd = function() end

    local ok, err = pcall(function()
      -- First caller starts the worker; it stalls inside use_entry for file_A.
      local call_a = StandardView._set_file(view, "file_A")
      eq({ "file_A" }, opened)
      assert.is_false(call_a:is_done())

      -- Second caller queues file_B and receives the in-flight worker.
      local call_b = StandardView._set_file(view, "file_B")
      assert.are.equal(call_a, call_b)
      eq({ "file_A" }, opened)
      assert.is_false(call_a:is_done())

      -- Resume the worker through file_A. It picks up the queued
      -- file_B and stalls again. The caller must still be pending.
      table.remove(cbs, 1)()
      eq({ "file_A", "file_B" }, opened)
      assert.is_false(call_a:is_done())

      -- Resume the worker through file_B. The loop drains, the worker
      -- exits, and the shared Future resolves.
      table.remove(cbs, 1)()
      assert.is_true(call_a:is_done())
      eq(nil, view._set_file_in_flight)
      eq(nil, view._set_file_pending)
    end)

    drain_remaining_cbs(cbs)
    vim.cmd = saved_vim_cmd
    if not ok then
      error(err)
    end
  end)
end)

-- The detach step is the only piece the subclasses customise; the rest
-- of the open sequence lives on `StandardView`. Verify each subclass
-- still hits the correct layout method so a future refactor can't
-- silently swap variants.
describe("diffview.standard_view _detach_files_for_next", function()
  ---Drive the worker once, capturing which layout method gets invoked.
  ---@param view table # Stubbed view with __index set to the class under test.
  ---@param target string # Sentinel passed as the next-file argument.
  ---@return table opened # The list of files passed to `use_entry`.
  local function drive_worker_once(view, target)
    local opened = {}
    local cbs = {}
    view.panel = { render = function() end, redraw = function() end }
    view.emitter = { emit = function() end }
    view.cur_entry = { opened = true }
    view.nulled = false
    view._set_file_in_flight = nil
    view._set_file_pending = nil
    view.use_entry = async.wrap(function(_, t, cb)
      table.insert(opened, t)
      table.insert(cbs, cb)
    end, 3)

    local saved_vim_cmd = vim.cmd
    vim.cmd = function() end
    local ok, err = pcall(function()
      StandardView._set_file(view, target)
      -- Let the worker open the requested file so we can inspect the
      -- captured layout method calls, then resolve to drain the loop.
      table.remove(cbs, 1)()
    end)
    drain_remaining_cbs(cbs)
    vim.cmd = saved_vim_cmd
    if not ok then
      error(err)
    end
    return opened
  end

  it("DiffView calls cur_layout:detach_files() (default)", function()
    local detach_calls = {}
    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      cur_layout = {
        detach_files = function(_self)
          table.insert(detach_calls, { method = "detach_files" })
        end,
        detach_files_for_swap = function(_self, file)
          table.insert(detach_calls, { method = "detach_files_for_swap", file = file })
        end,
      },
    }, { __index = DiffView })

    local opened = drive_worker_once(view, "file_A")

    eq({ "file_A" }, opened)
    eq({ { method = "detach_files" } }, detach_calls)
  end)

  it("FileHistoryView calls cur_layout:detach_files_for_swap(next_file)", function()
    local detach_calls = {}
    ---@diagnostic disable-next-line: missing-fields
    local view = setmetatable({
      cur_layout = {
        detach_files = function(_self)
          table.insert(detach_calls, { method = "detach_files" })
        end,
        detach_files_for_swap = function(_self, file)
          table.insert(detach_calls, { method = "detach_files_for_swap", file = file })
        end,
      },
    }, { __index = FileHistoryView })

    local opened = drive_worker_once(view, "file_A")

    eq({ "file_A" }, opened)
    -- The swap variant must receive the upcoming entry so pinned
    -- layouts can keep the (b) window bound when the path matches.
    eq({ { method = "detach_files_for_swap", file = "file_A" } }, detach_calls)
  end)
end)
