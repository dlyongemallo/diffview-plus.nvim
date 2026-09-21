local Diff = require("diffview.diff").Diff
local EditToken = require("diffview.diff").EditToken
local Layout = require("diffview.scene.layout").Layout
local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

-- Tests for nil guard fixes:
-- - 47b9d9e: help_panel apply_cmd nil comp.context
-- - e144466: layout sync_scroll nil target
-- - 3b4d355: diff_view update_files nil entries in edit script

describe("nil guards", function()
  describe("help_panel apply_cmd (47b9d9e)", function()
    -- The fix added `comp.context` to the guard in apply_cmd so that
    -- pressing <CR> on a line whose component has no context field
    -- (e.g. the heading) does not crash.

    ---Build a minimal HelpPanel-like object with a mock component tree.
    ---@param comp_on_line table? The component returned by get_comp_on_line.
    ---@return table
    local function make_help_panel(comp_on_line)
      local panel = {
        components = {
          comp = {
            get_comp_on_line = function(_, _line)
              return comp_on_line
            end,
          },
        },
      }
      -- Borrow apply_cmd from the real HelpPanel class.
      local HelpPanel = require("diffview.ui.panels.help_panel").HelpPanel
      panel.apply_cmd = HelpPanel.apply_cmd
      return panel
    end

    local orig_win_get_cursor, orig_win_getid, orig_winnr

    before_each(function()
      orig_win_get_cursor = vim.api.nvim_win_get_cursor
      orig_win_getid = vim.fn.win_getid
      orig_winnr = vim.fn.winnr
    end)

    after_each(function()
      vim.api.nvim_win_get_cursor = orig_win_get_cursor
      vim.fn.win_getid = orig_win_getid
      vim.fn.winnr = orig_winnr
    end)

    it("does not crash when comp is nil (no component on line)", function()
      vim.api.nvim_win_get_cursor = function()
        return { 1, 0 }
      end
      local panel = make_help_panel(nil)

      assert.has_no.errors(function()
        panel:apply_cmd()
      end)
    end)

    it("does not crash when comp exists but has no context field", function()
      vim.api.nvim_win_get_cursor = function()
        return { 1, 0 }
      end
      -- Simulate a component returned for a heading line: it has
      -- lstart/lend but no context.
      local panel = make_help_panel({ lstart = 0, lend = 1 })

      assert.has_no.errors(function()
        panel:apply_cmd()
      end)
    end)

    it("does not crash when comp.context exists but mapping is nil", function()
      vim.api.nvim_win_get_cursor = function()
        return { 1, 0 }
      end
      local panel = make_help_panel({ context = {} })

      assert.has_no.errors(function()
        panel:apply_cmd()
      end)
    end)

    it("invokes the mapping when comp.context.mapping is present", function()
      local feedkeys_called = false
      local close_called = false

      vim.api.nvim_win_get_cursor = function()
        return { 3, 0 }
      end
      vim.fn.win_getid = function()
        return 42
      end
      vim.fn.winnr = function()
        return 1
      end

      local orig_win_call = vim.api.nvim_win_call
      local orig_feedkeys = vim.api.nvim_feedkeys

      vim.api.nvim_win_call = function(_winid, fn)
        fn()
      end
      vim.api.nvim_feedkeys = function()
        feedkeys_called = true
      end

      local panel = make_help_panel({
        context = {
          mapping = { "n", "q" },
        },
      })
      panel.close = function()
        close_called = true
      end

      local ok, err = pcall(function()
        panel:apply_cmd()
      end)

      vim.api.nvim_win_call = orig_win_call
      vim.api.nvim_feedkeys = orig_feedkeys

      if not ok then
        error(err)
      end
      assert.is_true(feedkeys_called)
      assert.is_true(close_called)
    end)
  end)

  describe("layout sync_scroll (e144466)", function()
    -- The fix guards against target being nil when all windows have
    -- zero-line buffers (or self.windows is empty), which previously
    -- caused an attempt to index nil.

    local orig_buf_line_count, orig_win_get_buf, orig_win_get_cursor
    local orig_win_call, orig_win_set_cursor, orig_exec_autocmds
    local orig_get_current_win

    before_each(function()
      orig_buf_line_count = vim.api.nvim_buf_line_count
      orig_win_get_buf = vim.api.nvim_win_get_buf
      orig_win_get_cursor = vim.api.nvim_win_get_cursor
      orig_win_call = vim.api.nvim_win_call
      orig_win_set_cursor = vim.api.nvim_win_set_cursor
      orig_exec_autocmds = vim.api.nvim_exec_autocmds
      orig_get_current_win = vim.api.nvim_get_current_win
    end)

    after_each(function()
      vim.api.nvim_buf_line_count = orig_buf_line_count
      vim.api.nvim_win_get_buf = orig_win_get_buf
      vim.api.nvim_win_get_cursor = orig_win_get_cursor
      vim.api.nvim_win_call = orig_win_call
      vim.api.nvim_win_set_cursor = orig_win_set_cursor
      vim.api.nvim_exec_autocmds = orig_exec_autocmds
      vim.api.nvim_get_current_win = orig_get_current_win
    end)

    ---Build a mock layout with the given window list.
    ---@param windows table[]
    ---@param main_win table?
    ---@return table
    local function make_layout(windows, main_win)
      local layout = {
        windows = windows,
        get_main_win = function()
          return main_win or windows[1]
        end,
      }
      setmetatable(layout, { __index = Layout })
      return layout
    end

    it("does not crash when windows list is empty (target stays nil)", function()
      vim.api.nvim_get_current_win = function()
        return 1
      end

      -- get_main_win must return something with an id for the cursor read.
      local layout = make_layout({}, { id = 1 })
      vim.api.nvim_win_get_cursor = function()
        return { 1, 0 }
      end

      assert.has_no.errors(function()
        layout:sync_scroll()
      end)
    end)

    it("does not crash when all windows have zero-length buffers", function()
      local win_a = { id = 10 }
      local win_b = { id = 20 }

      vim.api.nvim_get_current_win = function()
        return 10
      end
      vim.api.nvim_win_get_buf = function()
        return 1
      end
      vim.api.nvim_buf_line_count = function()
        return 0
      end
      vim.api.nvim_win_get_cursor = function()
        return { 1, 0 }
      end
      vim.api.nvim_win_call = function(_, fn)
        fn()
      end
      vim.api.nvim_exec_autocmds = function() end
      vim.api.nvim_win_set_cursor = function() end

      local layout = make_layout({ win_a, win_b }, win_a)

      assert.has_no.errors(function()
        layout:sync_scroll()
      end)
    end)

    it("sets cursor on the target window when target is found", function()
      local win_a = { id = 10 }
      local win_b = { id = 20 }
      local set_cursor_calls = {}

      vim.api.nvim_get_current_win = function()
        return 10
      end
      vim.api.nvim_win_get_buf = function(winid)
        if winid == 10 then
          return 1
        end
        return 2
      end
      vim.api.nvim_buf_line_count = function(bufnr)
        if bufnr == 1 then
          return 5
        end
        return 100
      end
      vim.api.nvim_win_get_cursor = function()
        return { 3, 0 }
      end
      vim.api.nvim_win_call = function(_, fn)
        fn()
      end
      vim.api.nvim_exec_autocmds = function() end
      vim.api.nvim_win_set_cursor = function(winid, cursor)
        set_cursor_calls[#set_cursor_calls + 1] = { winid = winid, cursor = cursor }
      end

      local layout = make_layout({ win_a, win_b }, win_a)
      layout:sync_scroll()

      -- target should be win_b (100 lines > 5 lines), cursor restored there.
      eq(1, #set_cursor_calls)
      eq(20, set_cursor_calls[1].winid)
      eq({ 3, 0 }, set_cursor_calls[1].cursor)
    end)
  end)

  describe("update_files nil guards (3b4d355)", function()
    -- The fix wraps each edit-script operation in nil checks so that
    -- stale indices into cur_files / new_files during async race
    -- conditions do not cause crashes. We test the guarded logic
    -- by directly applying the edit script operations against mock
    -- file lists, mirroring the pattern in DiffView:update_files.

    ---Minimal mock panel that tracks cur_file changes.
    ---@return table
    local function make_panel()
      local panel = {
        cur_file = nil,
        set_cur_file = function(self, f)
          self.cur_file = f
        end,
        ordered_file_list = function(self)
          return {}
        end,
        prev_file = function(self)
          return nil
        end,
      }
      return panel
    end

    ---Apply a single NOOP operation the same way update_files does.
    ---@param cur_files table[]
    ---@param new_files table[]
    ---@param ai integer
    ---@param bi integer
    local function apply_noop(cur_files, new_files, ai, bi)
      local cur_file = cur_files[ai]
      local new_file = new_files[bi]
      if cur_file and new_file then
        local a_stats = cur_file.stats
        local b_stats = new_file.stats
        if a_stats then
          cur_file.stats = vim.tbl_extend("force", a_stats, b_stats or {})
        else
          cur_file.stats = new_file.stats
        end
        cur_file.status = new_file.status
      end
    end

    ---Apply a single DELETE operation the same way update_files does.
    ---@param cur_files table[]
    ---@param ai integer
    ---@param panel table
    local function apply_delete(cur_files, ai, panel)
      local cur_file = cur_files[ai]
      if cur_file then
        if panel.cur_file == cur_file then
          panel:set_cur_file(nil)
        end
        cur_file.destroyed = true
        table.remove(cur_files, ai)
      end
    end

    ---Apply a single INSERT operation the same way update_files does.
    ---@param cur_files table[]
    ---@param new_files table[]
    ---@param ai integer
    ---@param bi integer
    ---@return integer ai The (possibly incremented) ai index.
    local function apply_insert(cur_files, new_files, ai, bi)
      local new_file = new_files[bi]
      if new_file then
        table.insert(cur_files, ai, new_file)
        ai = ai + 1
      end
      return ai
    end

    ---Apply a single REPLACE operation the same way update_files does.
    ---@param cur_files table[]
    ---@param new_files table[]
    ---@param ai integer
    ---@param bi integer
    ---@param panel table
    local function apply_replace(cur_files, new_files, ai, bi, panel)
      local cur_file = cur_files[ai]
      local new_file = new_files[bi]
      if cur_file then
        if panel.cur_file == cur_file then
          panel:set_cur_file(nil)
        end
        cur_file.destroyed = true
      end
      if new_file then
        cur_files[ai] = new_file
      end
    end

    -- NOOP tests.

    it("NOOP does not crash when cur_files[ai] is nil", function()
      local cur_files = {}
      local new_files = { { path = "a.lua", status = "M", stats = {} } }

      assert.has_no.errors(function()
        apply_noop(cur_files, new_files, 1, 1)
      end)
    end)

    it("NOOP does not crash when new_files[bi] is nil", function()
      local cur_files = { { path = "a.lua", status = "M", stats = { additions = 1 } } }
      local new_files = {}

      assert.has_no.errors(function()
        apply_noop(cur_files, new_files, 1, 1)
      end)
      -- cur_file should be unchanged since new_file was nil.
      eq("M", cur_files[1].status)
    end)

    it("NOOP does not crash when both entries are nil", function()
      assert.has_no.errors(function()
        apply_noop({}, {}, 1, 1)
      end)
    end)

    it("NOOP merges stats when both entries exist", function()
      local cur_files = {
        { path = "a.lua", status = "M", stats = { additions = 5 } },
      }
      local new_files = {
        { path = "a.lua", status = "A", stats = { additions = 10, deletions = 2 } },
      }

      apply_noop(cur_files, new_files, 1, 1)

      eq("A", cur_files[1].status)
      eq(10, cur_files[1].stats.additions)
      eq(2, cur_files[1].stats.deletions)
    end)

    it("NOOP copies stats from new_file when cur_file.stats is nil", function()
      local cur_files = {
        { path = "a.lua", status = "M", stats = nil },
      }
      local new_files = {
        { path = "a.lua", status = "M", stats = { additions = 3 } },
      }

      apply_noop(cur_files, new_files, 1, 1)

      eq(3, cur_files[1].stats.additions)
    end)

    -- DELETE tests.

    it("DELETE does not crash when cur_files[ai] is nil", function()
      local panel = make_panel()

      assert.has_no.errors(function()
        apply_delete({}, 1, panel)
      end)
    end)

    it("DELETE removes the entry and clears cur_file if it matches", function()
      local panel = make_panel()
      local f = { path = "a.lua" }
      panel.cur_file = f
      local cur_files = { f }

      apply_delete(cur_files, 1, panel)

      eq(0, #cur_files)
      eq(nil, panel.cur_file)
      eq(true, f.destroyed)
    end)

    it("DELETE removes the entry without touching cur_file if it differs", function()
      local panel = make_panel()
      local other = { path = "other.lua" }
      panel.cur_file = other
      local f = { path = "a.lua" }
      local cur_files = { f }

      apply_delete(cur_files, 1, panel)

      eq(0, #cur_files)
      eq(other, panel.cur_file)
    end)

    -- INSERT tests.

    it("INSERT does not crash when new_files[bi] is nil", function()
      local cur_files = { { path = "existing.lua" } }

      local ai
      assert.has_no.errors(function()
        ai = apply_insert(cur_files, {}, 1, 1)
      end)
      -- ai should not be incremented when new_file is nil.
      eq(1, ai)
      -- cur_files should be unchanged.
      eq(1, #cur_files)
    end)

    it("INSERT adds the new entry at the correct position", function()
      local existing = { path = "b.lua" }
      local new_entry = { path = "a.lua" }
      local cur_files = { existing }
      local new_files = { new_entry }

      local ai = apply_insert(cur_files, new_files, 1, 1)

      eq(2, ai)
      eq(2, #cur_files)
      eq(new_entry, cur_files[1])
      eq(existing, cur_files[2])
    end)

    -- REPLACE tests.

    it("REPLACE does not crash when cur_files[ai] is nil", function()
      local panel = make_panel()
      local cur_files = {}
      local new_files = { { path = "new.lua" } }

      assert.has_no.errors(function()
        apply_replace(cur_files, new_files, 1, 1, panel)
      end)
    end)

    it("REPLACE does not crash when new_files[bi] is nil", function()
      local panel = make_panel()
      local f = { path = "old.lua" }
      local cur_files = { f }

      assert.has_no.errors(function()
        apply_replace(cur_files, {}, 1, 1, panel)
      end)
      eq(true, f.destroyed)
    end)

    it("REPLACE does not crash when both entries are nil", function()
      local panel = make_panel()

      assert.has_no.errors(function()
        apply_replace({}, {}, 1, 1, panel)
      end)
    end)

    it("REPLACE substitutes the entry and clears cur_file if it matches", function()
      local panel = make_panel()
      local old = { path = "a.lua" }
      panel.cur_file = old
      local replacement = { path = "a.lua" }
      local cur_files = { old }

      apply_replace(cur_files, { replacement }, 1, 1, panel)

      eq(replacement, cur_files[1])
      eq(nil, panel.cur_file)
      eq(true, old.destroyed)
    end)

    -- Integration: full edit script with nil entries.

    it("processes a full edit script with sparse nil entries without crashing", function()
      -- Simulate a race condition where some indices are out of range.
      -- cur_files has one entry; new_files has two. The diff produces
      -- NOOP + INSERT, but we artificially make the second new_file nil
      -- to simulate the race.
      local panel = make_panel()
      local f1 = { path = "a.lua", status = "M", stats = { additions = 1 } }
      local f2 = { path = "a.lua", status = "M", stats = { additions = 2 } }
      local cur_files = { f1 }
      local new_files = { f2 }

      -- The diff algorithm produces NOOP for matching entries.
      local diff = Diff(cur_files, new_files, function(a, b)
        return a.path == b.path
      end)
      local script = diff:create_edit_script()
      eq({ EditToken.NOOP }, script)

      -- Now apply with one index deliberately out of range to simulate
      -- the race condition that the nil guard protects against.
      assert.has_no.errors(function()
        apply_noop(cur_files, new_files, 999, 1)
      end)
      -- The original entry should be untouched.
      eq(1, cur_files[1].stats.additions)

      assert.has_no.errors(function()
        apply_delete(cur_files, 999, panel)
      end)
      eq(1, #cur_files)

      assert.has_no.errors(function()
        apply_insert(cur_files, new_files, 1, 999)
      end)
      eq(1, #cur_files)

      assert.has_no.errors(function()
        apply_replace(cur_files, new_files, 999, 999, panel)
      end)
      eq(1, #cur_files)
    end)
  end)

  -- Same class of bug as #74 (FilePanel), but in FileHistoryPanel.
  -- update_components() called render_data:reset() without a nil guard.
  describe("FileHistoryPanel update_components nil render_data", function()
    local FileHistoryPanel =
      require("diffview.scene.views.file_history.file_history_panel").FileHistoryPanel

    it("returns early without error when render_data is nil", function()
      -- Build a minimal panel-shaped object with the method under test.
      local panel = {
        render_data = nil,
        components = nil,
        entries = {},
        updating = false,
        update_components = FileHistoryPanel.update_components,
      }

      assert.has_no.errors(function()
        panel:update_components()
      end)
      eq(nil, panel.components)
    end)
  end)
end)
