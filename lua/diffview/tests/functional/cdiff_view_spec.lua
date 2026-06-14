local api = vim.api
local async = require("diffview.async")
local config = require("diffview.config")
local test_utils = require("diffview.tests.helpers")
local EventEmitter = require("diffview.events").EventEmitter

local CDiffView = require("diffview.api.views.diff.diff_view").CDiffView
local Rev = require("diffview.api.views.diff.diff_view").Rev
local RevType = require("diffview.api.views.diff.diff_view").RevType

local eq = test_utils.eq
local make_repo = test_utils.make_repo
local cleanup_repo = test_utils.cleanup_repo
local close_view = test_utils.close_view

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a minimal file list for CDiffView.
local function make_files(working, staged)
  return {
    working = working or {},
    staged = staged or {},
    conflicting = {},
  }
end

local function make_file_data(path, status)
  return {
    path = path,
    status = status or "M",
    left_null = false,
    right_null = false,
  }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("diffview.api.CDiffView", function()
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

  -- -----------------------------------------------------------------------
  -- API module exports
  -- -----------------------------------------------------------------------

  describe("API module exports", function()
    it("exports Rev", function()
      assert.is_not_nil(Rev)
      -- Should be callable as a constructor.
      local rev = Rev(RevType.LOCAL)
      eq(RevType.LOCAL, rev.type)
    end)

    it("exports RevType with expected values", function()
      assert.is_not_nil(RevType)
      assert.is_not_nil(RevType.LOCAL)
      assert.is_not_nil(RevType.COMMIT)
      assert.is_not_nil(RevType.STAGE)
      assert.is_not_nil(RevType.CUSTOM)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- Construction
  -- -----------------------------------------------------------------------

  describe("construction", function()
    it(
      "creates a valid view with pre-populated files",
      test_utils.async_test(function()
        local repo = make_repo()
        local ok, err = pcall(function()
          local view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files({ make_file_data("init.txt") }),
            update_files = function()
              return make_files()
            end,
            get_file_data = function()
              return {}
            end,
          })

          assert.is_true(view:is_valid())
          eq(1, view.files:len())
        end)

        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )

    it(
      "defaults malformed revs to STAGE",
      test_utils.async_test(function()
        local repo = make_repo()
        local ok, err = pcall(function()
          local view = CDiffView({
            git_root = repo,
            files = make_files(),
            update_files = function()
              return make_files()
            end,
            get_file_data = function()
              return {}
            end,
          })

          assert.is_true(view:is_valid())
          eq(RevType.STAGE, view.left.type)
          eq(RevType.STAGE, view.right.type)
        end)

        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )
  end)

  -- -----------------------------------------------------------------------
  -- Loading state (regression for #93)
  -- -----------------------------------------------------------------------

  describe("loading state", function()
    it(
      "clears is_loading after open when files are pre-populated",
      test_utils.async_test(function()
        local repo = make_repo()
        local view

        local ok, err = pcall(function()
          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files({ make_file_data("init.txt") }),
            update_files = function()
              return make_files({ make_file_data("init.txt") })
            end,
            get_file_data = function()
              return {}
            end,
          })

          -- Before open, is_loading should be true (set in DiffView:init).
          assert.is_true(view.is_loading)
          assert.is_true(view.panel.is_loading)

          view:open()

          -- post_open uses vim.schedule; pump the event loop to flush it.
          vim.wait(1000, function()
            return not view.is_loading
          end, 10)

          eq(false, view.is_loading)
          eq(false, view.panel.is_loading)
        end)

        close_view(view)
        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )

    it(
      "sets initialized to true after open with pre-populated files",
      test_utils.async_test(function()
        local repo = make_repo()
        local view

        local ok, err = pcall(function()
          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files({ make_file_data("init.txt") }),
            update_files = function()
              return make_files({ make_file_data("init.txt") })
            end,
            get_file_data = function()
              return {}
            end,
          })

          view:open()
          -- The files_updated event (which sets initialized) fires from the
          -- vim.schedule callback in post_open.
          vim.wait(1000, function()
            return view.initialized
          end, 10)

          eq(true, view.initialized)
        end)

        close_view(view)
        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )
  end)

  -- -----------------------------------------------------------------------
  -- Panel rendering with file_panel.show = false (#93)
  -- -----------------------------------------------------------------------

  describe("panel rendering with file_panel.show = false", function()
    it(
      "renders file list (not loading message) when panel is toggled open",
      test_utils.async_test(function()
        local repo = make_repo()
        local view

        local ok, err = pcall(function()
          config.get_config().file_panel.show = false

          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files({ make_file_data("init.txt") }),
            update_files = function()
              return make_files({ make_file_data("init.txt") })
            end,
            get_file_data = function()
              return {}
            end,
          })

          view:open()
          vim.wait(1000, function()
            return not view.is_loading
          end, 10)

          -- Panel should not be open yet.
          assert.falsy(view.panel:is_open())

          -- Toggle the panel open (simulates :DiffviewToggleFiles).
          view.panel:toggle(true)
          assert.is_true(view.panel:is_open())

          -- Read the rendered panel buffer.
          local lines = api.nvim_buf_get_lines(view.panel.bufid, 0, -1, false)
          local joined = table.concat(lines, "\n")

          assert.falsy(
            joined:find("Fetching changes"),
            "panel should not show loading message after open with pre-populated files"
          )
          assert.truthy(joined:find("Changes"), "panel should show the Changes section header")
        end)

        close_view(view)
        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )

    it(
      "places the cursor on the active file when the panel is toggled open (#161)",
      test_utils.async_test(function()
        local repo = make_repo()
        local view

        local ok, err = pcall(function()
          config.get_config().file_panel.show = false

          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files({
              make_file_data("a.txt"),
              make_file_data("b.txt"),
              make_file_data("c.txt"),
            }),
            update_files = function()
              return make_files({
                make_file_data("a.txt"),
                make_file_data("b.txt"),
                make_file_data("c.txt"),
              })
            end,
            get_file_data = function()
              return {}
            end,
          })

          view:open()
          local loaded = vim.wait(1000, function()
            return not view.is_loading
          end, 10)
          assert.is_true(loaded, "view did not finish loading within 1s")

          -- Pick a non-first file as the active entry; the bug is that the
          -- cursor lands on line 1 instead of on this file's row.
          local target_file
          for _, f in view.files:iter() do
            if f.path == "b.txt" then
              target_file = f
              break
            end
          end
          assert.is_not_nil(target_file)
          view.panel:set_cur_file(target_file)

          assert.falsy(view.panel:is_open())

          -- Toggle the panel open (simulates :DiffviewToggleFiles).
          view.panel:toggle(true)
          assert.is_true(view.panel:is_open())

          -- The cursor should land on the active file rather than the top of
          -- the buffer.
          local item = view.panel:get_item_at_cursor()
          assert.equals(target_file, item)
        end)

        close_view(view)
        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )
  end)

  -- -----------------------------------------------------------------------
  -- Auto-registration
  -- -----------------------------------------------------------------------

  describe("auto-registration", function()
    it(
      "registers view in lib.views on open",
      test_utils.async_test(function()
        local repo = make_repo()
        local view
        local lib = require("diffview.lib")

        local ok, err = pcall(function()
          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files(),
            update_files = function()
              return make_files()
            end,
            get_file_data = function()
              return {}
            end,
          })

          -- Not registered before open.
          assert.is_false(vim.tbl_contains(lib.views, view))

          view:open()

          -- Registered after open.
          assert.is_true(vim.tbl_contains(lib.views, view))
        end)

        close_view(view)
        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )

    it(
      "does not double-register when add_view is called before open",
      test_utils.async_test(function()
        local repo = make_repo()
        local view
        local lib = require("diffview.lib")

        local ok, err = pcall(function()
          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files(),
            update_files = function()
              return make_files()
            end,
            get_file_data = function()
              return {}
            end,
          })

          -- Simulate old-style manual registration before open.
          lib.add_view(view)
          local count_before = 0
          for _, v in ipairs(lib.views) do
            if v == view then
              count_before = count_before + 1
            end
          end
          eq(1, count_before)

          view:open()

          -- Should still only appear once.
          local count_after = 0
          for _, v in ipairs(lib.views) do
            if v == view then
              count_after = count_after + 1
            end
          end
          eq(1, count_after)
        end)

        close_view(view)
        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )
  end)

  -- -----------------------------------------------------------------------
  -- get_updated_files
  -- -----------------------------------------------------------------------

  describe("get_updated_files", function()
    it(
      "calls fetch_files and returns entries",
      test_utils.async_test(function()
        local repo = make_repo()
        local view
        local fetch_called = false

        local ok, err = pcall(function()
          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files(),
            update_files = function()
              fetch_called = true
              return make_files({ make_file_data("new.txt", "A") })
            end,
            get_file_data = function()
              return {}
            end,
          })

          local file_err, entries = async.await(view:get_updated_files())
          assert.is_nil(file_err)
          assert.is_true(fetch_called)
          assert.is_table(entries)
          assert.is_table(entries.working)
          eq(1, #entries.working)
        end)

        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )

    it(
      "handles fetch_files returning malformed data",
      test_utils.async_test(function()
        local repo = make_repo()
        local view

        local ok, err = pcall(function()
          view = CDiffView({
            git_root = repo,
            left = Rev(RevType.STAGE),
            right = Rev(RevType.LOCAL),
            files = make_files(),
            update_files = function()
              return "not a table"
            end,
            get_file_data = function()
              return {}
            end,
          })

          local file_err, entries = async.await(view:get_updated_files())
          assert.is_not_nil(file_err)
          assert.is_nil(entries)
        end)

        cleanup_repo(repo)
        if not ok then
          error(err)
        end
      end)
    )
  end)
end)
