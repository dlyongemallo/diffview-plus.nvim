local config = require("diffview.config")
local test_utils = require("diffview.tests.helpers")
local EventEmitter = require("diffview.events").EventEmitter

local CDiffView = require("diffview.api.views.diff.diff_view").CDiffView
local Rev = require("diffview.api.views.diff.diff_view").Rev
local RevType = require("diffview.api.views.diff.diff_view").RevType

local eq = test_utils.eq
local run = test_utils.run
local make_repo = test_utils.make_repo
local cleanup_repo = test_utils.cleanup_repo
local close_view = test_utils.close_view

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function make_files()
  return { working = {}, staged = {}, conflicting = {} }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("diffview.scene.views.diff.DiffView", function()
  local orig_emitter, original_config

  before_each(function()
    orig_emitter = DiffviewGlobal.emitter
    DiffviewGlobal.emitter = EventEmitter()
    original_config = vim.deepcopy(config.get_config())
    -- Disable icons so render does not require nvim-web-devicons.
    config.get_config().use_icons = false
  end)

  after_each(function()
    DiffviewGlobal.emitter = orig_emitter
    config.setup(original_config)
  end)

  describe("update_files", function()
    -- Regression: cached/staged views (right = STAGE) used to skip the
    -- HEAD-tracking refresh, so committing while such a view stayed open
    -- left `self.left` pinned to the stale HEAD and the file diff was
    -- computed against the wrong base.
    it(
      "refreshes left when track_head is set and HEAD moves, even when right is STAGE",
      test_utils.async_test(function()
        local repo = make_repo()
        local view

        local ok, err = pcall(function()
          local initial_head = run({ "git", "rev-parse", "HEAD" }, repo)

          view = CDiffView({
            git_root = repo,
            -- Mirror what `parse_revs(nil, {cached=true})` produces for Git:
            -- left = head_rev() with track_head=true, right = STAGE 0.
            left = Rev(RevType.COMMIT, initial_head, true),
            right = Rev(RevType.STAGE, 0),
            files = make_files(),
            update_files = function()
              return make_files()
            end,
            get_file_data = function()
              return {}
            end,
          })

          view:open()
          vim.wait(2000, function()
            return view.initialized
          end, 10)
          eq(initial_head, view.left.commit)

          -- Advance HEAD by committing a new file outside the view.
          local f = assert(io.open(repo .. "/foo.txt", "w"))
          f:write("foo\n")
          f:close()
          run({ "git", "add", "foo.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "foo" }, repo)
          local new_head = run({ "git", "rev-parse", "HEAD" }, repo)
          assert.are_not.equal(initial_head, new_head)

          -- Trigger a refresh; the track_head block in update_files must
          -- pick up the new HEAD.
          view:update_files()
          vim.wait(2000, function()
            return view.left.commit == new_head
          end, 10)

          eq(new_head, view.left.commit)
        end)

        close_view(view)
        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )

    -- Regression: the wrapped impl signature were changed from
    -- (self, callback) to (self, opts, callback). Legacy callers using
    -- update_files(callback) would otherwise dereference opts.force on a
    -- function and crash; the wrapper normalizes the args.
    it(
      "accepts the legacy update_files(callback) signature",
      test_utils.async_test(function()
        local repo = make_repo()
        local view

        local ok, err = pcall(function()
          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo), true),
            right = Rev(RevType.STAGE, 0),
            files = make_files(),
            update_files = function()
              return make_files()
            end,
            get_file_data = function()
              return {}
            end,
          })

          view:open()
          vim.wait(2000, function()
            return view.initialized
          end, 10)

          local cb_called = false
          view:update_files(function()
            cb_called = true
          end)
          vim.wait(2000, function()
            return cb_called
          end, 10)

          assert.is_true(cb_called)
        end)

        close_view(view)
        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )
  end)

  -- actions.refresh_files({ force = true }) re-creates the entry for files
  -- whose layout includes a STAGE-rev side, so unsaved edits in the virtual
  -- stage buffer are dropped. Entries without a STAGE side (LOCAL/COMMIT
  -- only) are left untouched, and force is a no-op without the flag. This
  -- block exercises the decision in isolation, mirroring the pattern in
  -- nil_guards_spec.lua.
  describe("force-refresh stage buffers (1ad47af)", function()
    ---Decision lifted from DiffView:update_files: should the entry be
    ---force-replaced because it includes a STAGE-rev side?
    ---@param old_file table
    ---@param opts { force?: boolean }?
    local function should_force_replace(old_file, opts)
      opts = opts or {}
      if not opts.force then
        return false
      end
      for _, f in ipairs(old_file.layout:files()) do
        if f.rev.type == RevType.STAGE then
          return true
        end
      end
      return false
    end

    ---@param rev_types table
    local function mock_entry(rev_types)
      local files = {}
      for _, t in ipairs(rev_types) do
        files[#files + 1] = { rev = { type = t } }
      end
      return {
        layout = {
          files = function()
            return files
          end,
        },
      }
    end

    it("force=true triggers replacement when a STAGE-rev side is present", function()
      local entry = mock_entry({ RevType.LOCAL, RevType.STAGE })
      eq(true, should_force_replace(entry, { force = true }))
    end)

    it("force=true is a no-op when no STAGE-rev side is present", function()
      local entry = mock_entry({ RevType.LOCAL, RevType.COMMIT })
      eq(false, should_force_replace(entry, { force = true }))
    end)

    it("force=false leaves STAGE entries alone", function()
      local entry = mock_entry({ RevType.STAGE })
      eq(false, should_force_replace(entry, { force = false }))
    end)

    it("opts=nil defaults to no replacement (default R behaviour)", function()
      local entry = mock_entry({ RevType.STAGE })
      eq(false, should_force_replace(entry, nil))
    end)
  end)

  -- Regression: EventEmitter calls listeners as `callback(event, ...)`, so
  -- the `refresh_files` listener must accept the leading event arg before
  -- `opts`; otherwise `actions.refresh_files({ force = true })` silently
  -- drops the opts table on the floor.
  describe("refresh_files listener event-arg shape", function()
    it("forwards opts (not the Event object) to view:update_files", function()
      local listeners_factory = require("diffview.scene.views.diff.listeners")

      local captured_opts
      local view_stub = {
        update_files = function(_self, opts)
          captured_opts = opts
        end,
        panel = {},
        adapter = {},
      }

      local listeners = listeners_factory(view_stub)
      local emitter = require("diffview.events").EventEmitter()
      emitter:on("refresh_files", listeners.refresh_files)

      emitter:emit("refresh_files", { force = true })

      assert.is_table(captured_opts)
      eq(true, captured_opts.force)
    end)

    it("passes nil opts through cleanly when none are emitted", function()
      local listeners_factory = require("diffview.scene.views.diff.listeners")

      local update_called = false
      local captured_opts = "untouched"
      local view_stub = {
        update_files = function(_self, opts)
          update_called = true
          captured_opts = opts
        end,
        panel = {},
        adapter = {},
      }

      local listeners = listeners_factory(view_stub)
      local emitter = require("diffview.events").EventEmitter()
      emitter:on("refresh_files", listeners.refresh_files)

      emitter:emit("refresh_files")

      assert.is_true(update_called)
      eq(nil, captured_opts)
    end)
  end)

  -- 87f40c8 wired :DiffviewRefresh!. Symmetric data-loss fix on the close
  -- path: with no bang, DiffView:close aborts when stage buffers are
  -- modified (mirrors :bd / :q); :DiffviewClose! passes force=true.
  describe("close on modified stage buffers", function()
    local DiffView = require("diffview.scene.views.diff.diff_view").DiffView

    local function modified_stage_paths(view)
      return DiffView._modified_stage_paths(view)
    end

    -- Scratch buffers silently reset `modified=false`; use a plain
    -- unlisted buffer so the modification flag actually sticks.
    local function mock_stage_buf(modified)
      local bufnr = vim.api.nvim_create_buf(false, false)
      if modified then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "dirty" })
      end
      return bufnr
    end

    local function mock_view(layout_files_per_entry)
      local entries = {}
      for _, layout_files in ipairs(layout_files_per_entry) do
        entries[#entries + 1] = {
          path = layout_files.path,
          layout = {
            files = function()
              return layout_files.files
            end,
          },
        }
      end
      return {
        files = {
          iter = function()
            local i = 0
            return function()
              i = i + 1
              if entries[i] then
                return i, entries[i]
              end
            end
          end,
        },
      }
    end

    it("flags entries whose STAGE-rev sub-buffer is modified", function()
      local stage_buf = mock_stage_buf(true)
      local view = mock_view({
        {
          path = "foo.txt",
          files = { { rev = { type = RevType.STAGE }, bufnr = stage_buf } },
        },
      })
      eq({ "foo.txt" }, modified_stage_paths(view))
      vim.api.nvim_buf_delete(stage_buf, { force = true })
    end)

    it("ignores STAGE entries whose buffer is unmodified", function()
      local stage_buf = mock_stage_buf(false)
      local view = mock_view({
        {
          path = "foo.txt",
          files = { { rev = { type = RevType.STAGE }, bufnr = stage_buf } },
        },
      })
      eq({}, modified_stage_paths(view))
      vim.api.nvim_buf_delete(stage_buf, { force = true })
    end)

    it("ignores modified LOCAL buffers (those are caller-managed)", function()
      local local_buf = mock_stage_buf(true)
      local view = mock_view({
        {
          path = "foo.txt",
          files = { { rev = { type = RevType.LOCAL }, bufnr = local_buf } },
        },
      })
      eq({}, modified_stage_paths(view))
      vim.api.nvim_buf_delete(local_buf, { force = true })
    end)

    it("collects each affected entry only once", function()
      local b1 = mock_stage_buf(true)
      local b2 = mock_stage_buf(true)
      local view = mock_view({
        {
          path = "a.txt",
          files = {
            { rev = { type = RevType.STAGE }, bufnr = b1 },
            { rev = { type = RevType.STAGE }, bufnr = b2 },
          },
        },
      })
      eq({ "a.txt" }, modified_stage_paths(view))
      vim.api.nvim_buf_delete(b1, { force = true })
      vim.api.nvim_buf_delete(b2, { force = true })
    end)

    -- The follow-up commit threads `force = false` through every
    -- user-triggered close path (keymap close action, auto-close-on-empty,
    -- :DiffviewToggle, goto_file_edit_close). Verify the gate fires for
    -- those callers via the public method.
    -- Wire the mock view to DiffView so `view:close(...)` resolves the
    -- real method (and the helper) via __index.
    local function as_diffview(view)
      return setmetatable(view, { __index = DiffView })
    end

    it("close({ force = false }) aborts and returns false on dirty STAGE", function()
      local stage_buf = mock_stage_buf(true)
      local view = as_diffview(mock_view({
        {
          path = "foo.txt",
          files = { { rev = { type = RevType.STAGE }, bufnr = stage_buf } },
        },
      }))
      view.closing = {
        check = function()
          return false
        end,
      }

      eq(false, view:close({ force = false }))
      vim.api.nvim_buf_delete(stage_buf, { force = true })
    end)

    it("close({ force = true }) bypasses the gate", function()
      -- Stub everything close() touches past the gate so we can confirm
      -- the gate doesn't trip under force.
      local stage_buf = mock_stage_buf(true)
      local view = as_diffview(mock_view({
        {
          path = "foo.txt",
          files = { { rev = { type = RevType.STAGE }, bufnr = stage_buf } },
        },
      }))
      local closing_sent = false
      view.closing = {
        check = function()
          return closing_sent
        end,
        send = function()
          closing_sent = true
        end,
      }

      -- close() proceeds past the gate; we don't care about the rest of
      -- the teardown for this test, only that the gate didn't return false.
      pcall(view.close, view, { force = true })
      assert.is_true(closing_sent)
      vim.api.nvim_buf_delete(stage_buf, { force = true })
    end)
  end)

  -- Companion to the close-gate fix: when `auto_close_on_empty` fires while a
  -- stage buffer is dirty, the deferred close used to be lost. The
  -- buf_write_post listener now picks it up after the user saves, so the
  -- view actually closes instead of stranding the user in an empty view.
  describe("auto_close_on_empty deferred-retry", function()
    local lib = require("diffview.lib")
    local listeners_factory = require("diffview.scene.views.diff.listeners")

    ---Mock view exposing only what the listeners under test touch. The first
    ---update_files call empties `working` to simulate the post-stage refresh;
    ---subsequent calls preserve whatever the test has set. `_modified_stage_paths`
    ---is keyed off `close_returns_ref` to mirror the real coupling between the
    ---dirty-stage gate and `close({ force = false })`'s return value.
    local function make_stub_view(close_returns_ref)
      local stub
      local update_count = 0
      stub = {
        files = {
          working = { { path = "foo.txt" } },
          conflicting = {},
        },
        panel = {
          highlight_cur_file = function() end,
        },
        adapter = {
          add_files = function()
            return true
          end,
          has_local = function()
            return true
          end,
        },
        left = {},
        right = {},
        tabpage = vim.api.nvim_get_current_tabpage(),
        emitter = { emit = function() end },
        close_calls = 0,
        update_files = function(_self, _opts, callback)
          update_count = update_count + 1
          if update_count == 1 then
            stub.files.working = {}
          end
          if callback then
            callback()
          end
        end,
        close = function()
          stub.close_calls = stub.close_calls + 1
          return close_returns_ref.value
        end,
        _modified_stage_paths = function()
          return close_returns_ref.value and {} or { "stage.txt" }
        end,
      }
      return stub
    end

    it("defers when close aborts; retries on the next buf_write_post", function()
      local original_dispose = lib.dispose_view
      local original_config = vim.deepcopy(config.get_config())
      config.setup({ auto_close_on_empty = true })

      local close_returns = { value = false }
      local view_stub = make_stub_view(close_returns)
      local dispose_calls = 0
      lib.dispose_view = function()
        dispose_calls = dispose_calls + 1
      end

      local listeners = listeners_factory(view_stub)

      -- 1st pass: stage_all triggers maybe_auto_close. close returns false
      -- (dirty stage), so the close attempt counts but no dispose happens.
      listeners.stage_all()
      eq(1, view_stub.close_calls)
      eq(0, dispose_calls)

      -- 2nd pass: simulate the user saving the dirty stage buffer.
      -- buf_write_post should pick up the deferred close and retry.
      close_returns.value = true
      listeners.buf_write_post()
      eq(2, view_stub.close_calls)
      eq(1, dispose_calls)

      -- 3rd pass: the flag is consumed; subsequent saves don't retry.
      listeners.buf_write_post()
      eq(2, view_stub.close_calls)
      eq(1, dispose_calls)

      lib.dispose_view = original_dispose
      config.setup(original_config)
    end)

    -- Regression for the BufWritePost retry: the autocmd fires globally
    -- (any buffer, any tab) without buffer context, so saving an unrelated
    -- buffer used to re-run the close gate and re-show the warning while
    -- the stage buffer was still dirty. The retry is now silent: it only
    -- attempts the close when the gate would actually pass.
    it("does not re-attempt close while stage buffers are still dirty", function()
      local original_dispose = lib.dispose_view
      local original_config = vim.deepcopy(config.get_config())
      config.setup({ auto_close_on_empty = true })

      local close_returns = { value = false }
      local view_stub = make_stub_view(close_returns)
      local dispose_calls = 0
      lib.dispose_view = function()
        dispose_calls = dispose_calls + 1
      end

      local listeners = listeners_factory(view_stub)

      -- Defer once (dirty stage; close returns false).
      listeners.stage_all()
      eq(1, view_stub.close_calls)

      -- Saving an unrelated buffer fires buf_write_post while the stage
      -- buffer is still dirty: the retry should stay silent (no extra
      -- close call, no extra warning).
      listeners.buf_write_post()
      eq(1, view_stub.close_calls)
      eq(0, dispose_calls)

      -- Once the stage buffer is saved, the gate would pass and the retry
      -- runs the close.
      close_returns.value = true
      listeners.buf_write_post()
      eq(2, view_stub.close_calls)
      eq(1, dispose_calls)

      lib.dispose_view = original_dispose
      config.setup(original_config)
    end)

    it("clears the pending flag if working/conflicting become non-empty", function()
      local original_dispose = lib.dispose_view
      local original_config = vim.deepcopy(config.get_config())
      config.setup({ auto_close_on_empty = true })

      local close_returns = { value = false }
      local view_stub = make_stub_view(close_returns)
      local dispose_calls = 0
      lib.dispose_view = function()
        dispose_calls = dispose_calls + 1
      end

      local listeners = listeners_factory(view_stub)

      -- Defer once.
      listeners.stage_all()
      eq(1, view_stub.close_calls)

      -- Re-introduce a working file (e.g. user edited a tracked file). The
      -- next buf_write_post should not attempt another close.
      view_stub.files.working = { { path = "bar.txt" } }
      listeners.buf_write_post()
      eq(1, view_stub.close_calls)
      eq(0, dispose_calls)

      lib.dispose_view = original_dispose
      config.setup(original_config)
    end)

    -- Regression: `buf_write_post` previously kicked off `view:update_files`
    -- and evaluated `maybe_auto_close` in parallel. Because `update_files` is
    -- debounced/async, a save that reintroduced working entries via the
    -- refresh would still see the empty pre-refresh state and close the view
    -- before the file list repopulated. The retry now runs as the
    -- `update_files` callback so it always sees the post-refresh state.
    it("re-evaluates the gate after the post-write refresh", function()
      local original_dispose = lib.dispose_view
      local original_config = vim.deepcopy(config.get_config())
      config.setup({ auto_close_on_empty = true })

      local close_returns = { value = false }
      local view_stub = make_stub_view(close_returns)
      local dispose_calls = 0
      lib.dispose_view = function()
        dispose_calls = dispose_calls + 1
      end

      local listeners = listeners_factory(view_stub)

      -- Defer once: the dirty stage gate trips, auto_close_pending is set.
      listeners.stage_all()
      eq(1, view_stub.close_calls)

      -- Stage buffer is now saved (close would pass the gate), but the next
      -- refresh introduces a fresh working entry. The retry must see the
      -- post-refresh `working`; if it ran before update_files, it would
      -- close even though the view is no longer empty.
      close_returns.value = true
      view_stub.update_files = function(_self, _opts, callback)
        view_stub.files.working = { { path = "fresh.txt" } }
        if callback then
          callback()
        end
      end

      listeners.buf_write_post()
      eq(1, view_stub.close_calls)
      eq(0, dispose_calls)

      lib.dispose_view = original_dispose
      config.setup(original_config)
    end)
  end)

  -- `_set_file` rapid-navigation coalescing is exercised against
  -- `StandardView` (the shared owner of the worker) in
  -- `standard_view_spec.lua`; DiffView inherits the behavior unchanged.
end)
