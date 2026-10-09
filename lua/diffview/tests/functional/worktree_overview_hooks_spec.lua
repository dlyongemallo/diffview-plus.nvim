local async = require("diffview.async")
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local overview = require("diffview.scene.views.worktree_overview.worktree_overview_view")
local test_utils = require("diffview.tests.helpers")

local WorktreeOverviewView = overview.WorktreeOverviewView
local run = test_utils.run

local function make_adapter(repo)
  return GitAdapter({
    toplevel = repo,
    cpath = repo,
    path_args = {},
  })
end

---Collect `evt_name` emissions on the global emitter until the test ends.
---@param evt_name string
---@return function unregister
---@return table events # Appended to on each emit.
local function capture(evt_name)
  local events = {}
  local cb = function(_, ...)
    table.insert(events, { ... })
  end
  DiffviewGlobal.emitter:on(evt_name, cb)
  return function()
    DiffviewGlobal.emitter:off(cb, evt_name)
  end, events
end

describe("diffview.scene.views.worktree_overview hooks", function()
  it(
    "calls registered status providers and renders their output",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local linked = repo .. "-wt"

      local view
      local calls = {}
      local provider = function(e)
        calls[#calls + 1] = e.path
        if e.path == linked then
          return "working"
        end
        return nil
      end

      local ok, err = pcall(function()
        run({ "git", "worktree", "add", "-b", "feature/x", linked }, repo)

        overview.register_status_provider(provider)

        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()

        -- `refresh` defers provider calls to a `vim.schedule` so a slow
        -- provider cannot freeze the UI between the stats batch and the
        -- first paint. Pump the main loop to let that callback fire
        -- before asserting what the provider saw and what rendered.
        async.await(async.schedule_now())

        -- Provider was called at least once per worktree during the render.
        local seen = {}
        for _, p in ipairs(calls) do
          seen[p] = true
        end
        assert.is_true(seen[repo])
        assert.is_true(seen[linked])

        -- The returned "working" string shows up in the linked worktree's
        -- row. `render` strips the common parent dir, so match by basename.
        local linked_name = vim.fs.basename(linked)
        local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
        local found
        for _, line in ipairs(lines) do
          if line:find(linked_name, 1, true) and line:find("working", 1, true) then
            found = line
            break
          end
        end
        assert.is_not_nil(found)
      end)

      overview.clear_status_providers()
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
    "emits opened, refreshed, and entered on the global emitter",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local linked = repo .. "-wt"

      local view, opened_view, diff_view
      local off_open, open_events = capture("worktree_overview_opened")
      local off_refresh, refresh_events = capture("worktree_overview_refreshed")
      local off_enter, enter_events = capture("worktree_overview_entered")

      local ok, err = pcall(function()
        run({ "git", "worktree", "add", "-b", "feature/x", linked }, repo)

        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()
        opened_view = view

        -- `_opened` fires once at post_open, `_refreshed` fires every refresh;
        -- post_open does one refresh, so each has exactly one event.
        assert.equals(1, #open_events)
        assert.equals(view, open_events[1][1])

        assert.equals(1, #refresh_events)
        assert.equals(view, refresh_events[1][1])
        local entries = refresh_events[1][2]
        assert.equals(2, #entries)

        -- Call it again to confirm `_refreshed` fires on every refresh.
        view:refresh()
        assert.equals(2, #refresh_events)

        -- Enter the linked worktree and check the `entered` payload.
        local lnum
        for i, e in ipairs(view.entries) do
          if e.path == linked then
            lnum = i
            break
          end
        end
        assert.is_not_nil(lnum)
        vim.api.nvim_win_set_cursor(view.winid, { lnum, 0 })
        view:enter_selected()

        assert.equals(1, #enter_events)
        assert.equals(view, enter_events[1][1])
        assert.equals(linked, enter_events[1][2].path)

        diff_view = require("diffview.lib").get_current_view()
      end)

      off_open()
      off_refresh()
      off_enter()
      test_utils.close_view(diff_view)
      test_utils.close_view(opened_view)
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
    "`refresh_worktree_overview_status` rebuilds the status column without re-querying git",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()

      local view
      local provider_output = "first"
      local provider_calls = 0
      local provider = function()
        provider_calls = provider_calls + 1
        return provider_output
      end

      local ok, err = pcall(function()
        overview.register_status_provider(provider)
        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()
        async.await(async.schedule_now())

        local initial_calls = provider_calls
        -- The source of truth that `refresh_status` must NOT re-query:
        -- stub the adapter's worktree_list to blow up if called again.
        view.adapter.worktree_list = function()
          error("worktree_list must not be called by refresh_status")
        end

        -- Flip the provider's output and request a status-only refresh.
        provider_output = "second"
        DiffviewGlobal.emitter:emit("refresh_worktree_overview_status")
        async.await(async.schedule_now())

        -- Provider ran again, worktree_list did not, buffer shows new value.
        assert.is_true(provider_calls > initial_calls)
        local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
        local any_new
        for _, line in ipairs(lines) do
          if line:find("second", 1, true) then
            any_new = true
            break
          end
        end
        assert.is_true(any_new)
      end)

      overview.clear_status_providers()
      test_utils.close_view(view)
      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "unsubscribes from `refresh_worktree_overview_status` when the view closes",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()

      local view
      local provider_calls = 0
      local provider = function()
        provider_calls = provider_calls + 1
        return "x"
      end

      local ok, err = pcall(function()
        overview.register_status_provider(provider)
        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        view:open()
        async.await(async.schedule_now())

        local calls_before_close = provider_calls
        test_utils.close_view(view)
        view = nil

        -- With no view listening, firing the event should not reach the
        -- provider at all. Any invocation here would indicate the view's
        -- `close` failed to detach the global-emitter subscription.
        DiffviewGlobal.emitter:emit("refresh_worktree_overview_status")
        async.await(async.schedule_now())
        assert.equals(calls_before_close, provider_calls)
      end)

      overview.clear_status_providers()
      if view then
        test_utils.close_view(view)
      end
      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "swallows errors raised by a status provider",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()

      local view
      local provider = function()
        error("provider blew up")
      end

      local ok, err = pcall(function()
        overview.register_status_provider(provider)

        view = WorktreeOverviewView({ adapter = make_adapter(repo) })
        -- A throwing provider must not propagate out of :open().
        view:open()

        -- Buffer rendered without the provider's status, but still rendered.
        local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
        assert.equals(1, #lines)
      end)

      overview.clear_status_providers()
      test_utils.close_view(view)
      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )
end)
