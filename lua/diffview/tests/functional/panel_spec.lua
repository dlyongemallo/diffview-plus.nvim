local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("diffview.ui.panel", function()
  local Panel = require("diffview.ui.panel").Panel

  describe("interface contract", function()
    -- The tab_enter/tab_leave listeners in diff and file_history views
    -- depend on panel instances exposing a `winid` field and an `is_open`
    -- method.  Verify these exist on the base class so that a future
    -- refactor cannot silently break the contract (see issue #611).

    it("has a winid field after init", function()
      local panel = Panel({
        bufname = "TestPanel",
        config = Panel.default_config_split,
      })
      -- winid starts nil (panel not yet opened).
      eq(nil, panel.winid)
    end)

    it("exposes is_open as a callable method", function()
      local panel = Panel({
        bufname = "TestPanel",
        config = Panel.default_config_split,
      })
      eq("function", type(panel.is_open))
    end)

    it("is_open returns falsy when winid is nil", function()
      local panel = Panel({
        bufname = "TestPanel",
        config = Panel.default_config_split,
      })
      assert.falsy(panel:is_open())
    end)

    it("does not expose a get_winid method", function()
      -- get_winid has never been part of the Panel API.  Callers should
      -- access the winid field directly.  This test guards against
      -- accidental re-introduction of calls to a non-existent method.
      local panel = Panel({
        bufname = "TestPanel",
        config = Panel.default_config_split,
      })
      eq(nil, panel.get_winid)
    end)
  end)

  describe("auto-width", function()
    local api = vim.api

    ---Create a minimal panel with the given width config.
    local function make_panel(width)
      local conf = vim.tbl_deep_extend("force", Panel.default_config_split, {
        position = "left",
        width = width,
      })
      return Panel({
        bufname = "TestAutoWidth",
        config = conf,
      })
    end

    it("get_config accepts 'auto' as a width value", function()
      local panel = make_panel("auto")
      local config = panel:get_config()
      eq("auto", config.width)
    end)

    it("get_config accepts a numeric width value", function()
      local panel = make_panel(42)
      local config = panel:get_config()
      eq(42, config.width)
    end)

    it("get_config rejects an invalid width value", function()
      local panel = make_panel("bogus")
      assert.has_error(function()
        panel:get_config()
      end)
    end)

    it("infer_width returns vim.o.columns when width is 'auto' and panel is closed", function()
      local panel = make_panel("auto")
      eq(vim.o.columns, panel:infer_width())
    end)

    it("infer_width returns window width when width is 'auto' and panel is open", function()
      local panel = make_panel("auto")
      panel.update_components = function() end
      panel.render = function() end
      panel:init_buffer()
      panel:open()
      assert.truthy(panel:is_open())

      local win_width = api.nvim_win_get_width(panel.winid)
      eq(win_width, panel:infer_width())

      panel:destroy()
    end)

    it("infer_width returns configured width for numeric values", function()
      local panel = make_panel(50)
      -- Panel is not open, so it falls through to config.width.
      eq(50, panel:infer_width())
    end)

    it("get_autosize_components returns nil by default", function()
      local panel = make_panel("auto")
      eq(nil, panel:get_autosize_components())
    end)

    it("compute_content_width measures buffer lines", function()
      local panel = make_panel("auto")
      -- Manually create a buffer and populate it so we can test measurement.
      local bufid = api.nvim_create_buf(false, true)
      panel.bufid = bufid
      api.nvim_buf_set_lines(bufid, 0, -1, false, {
        "short",
        "a moderately long line here",
        "x",
      })

      local width = panel:compute_content_width()
      -- Panel is not open, so textoff defaults to 2 (signcolumn).
      -- Expected: max display width (27) + 2 + 1 = 30.
      local expected = api.nvim_strwidth("a moderately long line here") + 2 + 1
      eq(expected, width)

      api.nvim_buf_delete(bufid, { force = true })
    end)

    it("compute_content_width falls back when buffer is not loaded", function()
      -- With "auto" width and no class-level default, falls back to 35.
      local panel = make_panel("auto")
      eq(35, panel:compute_content_width())
    end)

    it("compute_content_width uses class default width when buffer is not loaded", function()
      -- When the panel subclass defines a numeric default width, use that.
      local panel = make_panel("auto")
      local saved = Panel.default_config_split.width
      Panel.default_config_split.width = 40
      eq(40, panel:compute_content_width())
      Panel.default_config_split.width = saved
    end)

    it("compute_content_width skips lines outside autosize components", function()
      local panel = make_panel("auto")
      local bufid = api.nvim_create_buf(false, true)
      panel.bufid = bufid
      api.nvim_buf_set_lines(bufid, 0, -1, false, {
        "this is a very long header line that should be ignored",
        "short file entry",
        "another entry",
      })

      -- Mock a component covering only lines 1-2 (0-indexed: lstart=1, lend=3).
      local mock_comp = { lstart = 1, lend = 3 }
      panel.get_autosize_components = function()
        return { mock_comp }
      end

      local width = panel:compute_content_width()
      -- Should measure only "short file entry" (17 chars) + textoff(2) + 1 = 20.
      local expected = api.nvim_strwidth("short file entry") + 2 + 1
      eq(expected, width)

      api.nvim_buf_delete(bufid, { force = true })
    end)

    it(
      "compute_content_width falls back to all lines when autosize components are empty",
      function()
        local panel = make_panel("auto")
        local bufid = api.nvim_create_buf(false, true)
        panel.bufid = bufid
        api.nvim_buf_set_lines(bufid, 0, -1, false, {
          "header line",
          "another line here!",
        })

        -- Mock zero-height components (lend <= lstart), as during loading.
        local mock_comp = { lstart = 0, lend = 0 }
        panel.get_autosize_components = function()
          return { mock_comp }
        end

        local width = panel:compute_content_width()
        -- Should fall back to measuring all lines.
        local expected = api.nvim_strwidth("another line here!") + 2 + 1
        eq(expected, width)

        api.nvim_buf_delete(bufid, { force = true })
      end
    )

    it("compute_content_width clamps to half the editor width", function()
      local panel = make_panel("auto")
      local bufid = api.nvim_create_buf(false, true)
      panel.bufid = bufid
      -- Create a line wider than half the editor.
      local long_line = string.rep("x", vim.o.columns)
      api.nvim_buf_set_lines(bufid, 0, -1, false, { long_line })

      local width = panel:compute_content_width()
      -- Raw content width would exceed the clamp, but compute_content_width
      -- itself does not clamp; clamping is done in resize(). So the raw
      -- value should exceed half the editor width.
      local raw_expected = api.nvim_strwidth(long_line) + 2 + 1
      eq(raw_expected, width)

      api.nvim_buf_delete(bufid, { force = true })
    end)
    it("resize applies computed auto-width to an open split panel", function()
      local panel = make_panel("auto")
      -- Stub abstract methods so init_buffer can complete.
      panel.update_components = function() end
      panel.render = function() end
      panel:init_buffer()

      -- Populate the buffer with known content.
      vim.bo[panel.bufid].modifiable = true
      api.nvim_buf_set_lines(panel.bufid, 0, -1, false, {
        "short",
        "a moderately long line here",
      })
      vim.bo[panel.bufid].modifiable = false

      panel:open()
      assert.truthy(panel:is_open())

      -- The window should have been sized to fit the content.
      local win_width = api.nvim_win_get_width(panel.winid)
      local info = vim.fn.getwininfo(panel.winid)
      local textoff = (info and info[1]) and info[1].textoff or 2
      local expected = api.nvim_strwidth("a moderately long line here") + textoff + 1
      eq(expected, win_width)

      panel:destroy()
    end)

    it("resize clamps auto-width to half the editor width", function()
      local panel = make_panel("auto")
      panel.update_components = function() end
      panel.render = function() end
      panel:init_buffer()

      -- Populate with an extremely long line.
      vim.bo[panel.bufid].modifiable = true
      api.nvim_buf_set_lines(panel.bufid, 0, -1, false, {
        string.rep("x", vim.o.columns),
      })
      vim.bo[panel.bufid].modifiable = false

      panel:open()
      assert.truthy(panel:is_open())

      local win_width = api.nvim_win_get_width(panel.winid)
      local max_width = math.floor(vim.o.columns * 0.5)
      assert.is_true(win_width <= max_width)

      panel:destroy()
    end)
  end)

  describe("stop external treesitter parsers", function()
    -- Panel content is rendered manually via extmarks, so a tree-sitter
    -- parser attached by an external plugin (e.g. render-markdown.nvim)
    -- can mis-interpret file paths like `foo_bar_baz` as markdown italics.

    local function make_panel()
      return Panel({
        bufname = "TestStopTreesitter",
        config = Panel.default_config_split,
      })
    end

    it("stops treesitter on the panel buffer during init_buffer", function()
      local saved = vim.treesitter.stop
      local calls = {}
      vim.treesitter.stop = function(buf)
        table.insert(calls, buf)
      end

      local panel = make_panel()
      panel.update_components = function() end
      panel.render = function() end
      panel:init_buffer()

      eq(true, vim.tbl_contains(calls, panel.bufid))

      vim.treesitter.stop = saved
      panel:destroy()
    end)

    it("registers a BufWinEnter autocmd on the panel buffer", function()
      local panel = make_panel()
      panel.update_components = function() end
      panel.render = function() end
      panel:init_buffer()

      -- The re-stop runs on window entry so plugins that re-attach their
      -- parser get stopped again.  A structural check avoids relying on
      -- scheduled-callback timing.
      local autocmds = vim.api.nvim_get_autocmds({
        buffer = panel.bufid,
        event = "BufWinEnter",
      })
      eq(true, #autocmds > 0)

      panel:destroy()
    end)
  end)

  describe("subclass contracts", function()
    -- The actual panels used by the two view types must inherit the same
    -- interface.

    local function assert_panel_interface(panel_class, name)
      it(name .. " inherits winid field", function()
        eq(nil, rawget(panel_class, "get_winid"))
      end)

      it(name .. " inherits is_open method", function()
        eq("function", type(panel_class.is_open))
      end)
    end

    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel
    local FileHistoryPanel =
      require("diffview.scene.views.file_history.file_history_panel").FileHistoryPanel

    assert_panel_interface(FilePanel, "FilePanel")
    assert_panel_interface(FileHistoryPanel, "FileHistoryPanel")
  end)

  describe("close with only floating sibling windows", function()
    -- A normal panel sharing the tab with only floats must still get the
    -- temp split, since floats don't anchor a tabpage. Surfaced as a
    -- diffview tab disappearing on a layout swap.

    local api = vim.api

    it("creates a temp split when only floats accompany the panel", function()
      vim.cmd("tabnew")
      local tabpage = api.nvim_get_current_tabpage()
      local panel = Panel({ bufname = "TestCloseFloats", config = Panel.default_config_split })
      panel.update_components = function() end
      panel.render = function() end
      panel:open()
      assert.truthy(panel:is_open())

      -- Reduce the tab to the panel only to match the post-`old_layout:destroy`
      -- state during a layout swap.
      for _, w in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
        if w ~= panel.winid and api.nvim_win_get_config(w).relative == "" then
          api.nvim_win_close(w, true)
        end
      end

      local float_buf = api.nvim_create_buf(false, true)
      local float_win = api.nvim_open_win(float_buf, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 10,
        height = 5,
        style = "minimal",
      })

      panel:close()

      assert.is_true(api.nvim_tabpage_is_valid(tabpage))
      local remaining = api.nvim_tabpage_list_wins(tabpage)
      local normals = vim.tbl_filter(function(w)
        return api.nvim_win_get_config(w).relative == ""
      end, remaining)
      assert.is_true(#normals >= 1)

      if api.nvim_win_is_valid(float_win) then
        api.nvim_win_close(float_win, true)
      end
      if api.nvim_buf_is_valid(float_buf) then
        api.nvim_buf_delete(float_buf, { force = true })
      end
      panel:destroy()
      if api.nvim_tabpage_is_valid(tabpage) then
        api.nvim_set_current_tabpage(tabpage)
        vim.cmd("tabclose")
      end
    end)

    it("does not split when a float panel closes alongside an editor window", function()
      -- Closing a float panel (`HelpPanel`, `CommitLogPanel`) must leave
      -- a lone editor window untouched, since the panel itself doesn't
      -- count toward `normal_wins`.
      vim.cmd("tabnew")
      local tabpage = api.nvim_get_current_tabpage()
      local editor_win = api.nvim_get_current_win()
      local editor_buf = api.nvim_win_get_buf(editor_win)

      local float_config = vim.tbl_deep_extend("force", Panel.default_config_float, {
        width = 20,
        height = 5,
        row = 1,
        col = 1,
      })
      local panel = Panel({ bufname = "TestFloatPanelClose", config = float_config })
      panel.update_components = function() end
      panel.render = function() end
      panel:open()
      assert.truthy(panel:is_open())
      assert.are.equal("editor", api.nvim_win_get_config(panel.winid).relative)

      local editor_wins_before = #vim.tbl_filter(function(w)
        return api.nvim_win_get_config(w).relative == ""
      end, api.nvim_tabpage_list_wins(tabpage))

      panel:close()

      local editor_wins_after = #vim.tbl_filter(function(w)
        return api.nvim_win_get_config(w).relative == ""
      end, api.nvim_tabpage_list_wins(tabpage))
      assert.are.equal(editor_wins_before, editor_wins_after)
      assert.is_true(api.nvim_win_is_valid(editor_win))
      assert.are.equal(editor_buf, api.nvim_win_get_buf(editor_win))

      panel:destroy()
      if api.nvim_tabpage_is_valid(tabpage) then
        api.nvim_set_current_tabpage(tabpage)
        vim.cmd("tabclose")
      end
    end)
  end)

  describe("FilePanel multi-selection", function()
    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel

    ---Create a mock FileDict that supports iteration over the given entries.
    ---@param entries table[]?
    ---@return table
    local function make_mock_files(entries)
      local all = entries or {}
      local files = {}
      function files:iter()
        local i = 0
        return function()
          i = i + 1
          if i <= #all then
            return i, all[i]
          end
        end
      end
      function files:len()
        return #all
      end
      return files
    end

    ---Minimal stub that satisfies FilePanel:init without needing a real adapter.
    ---@param entries table[]?
    local function make_panel(entries)
      local adapter = { ctx = { toplevel = "/tmp", dir = "/tmp/.git" } }
      return FilePanel(adapter, make_mock_files(entries), {})
    end

    -- Lightweight stand-in for a FileEntry (only identity matters).
    local function make_entry(path, kind)
      return { path = path, kind = kind or "working" }
    end

    it("starts with no selections", function()
      local panel = make_panel()
      eq({}, panel:get_selected_files())
    end)

    it("toggle_selection marks a file", function()
      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      panel:toggle_selection(f)
      eq(true, panel:is_selected(f))
      eq(1, #panel:get_selected_files())
    end)

    it("toggle_selection unmarks a previously marked file", function()
      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      panel:toggle_selection(f)
      panel:toggle_selection(f)
      eq(false, panel:is_selected(f))
      eq(0, #panel:get_selected_files())
    end)

    it("tracks multiple selections independently", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local c = make_entry("c.lua")
      local panel = make_panel({ a, b, c })
      panel:toggle_selection(a)
      panel:toggle_selection(b)
      eq(true, panel:is_selected(a))
      eq(true, panel:is_selected(b))
      eq(false, panel:is_selected(c))
      eq(2, #panel:get_selected_files())
    end)

    it("clear_selections removes all marks", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local panel = make_panel({ a, b })
      panel:toggle_selection(a)
      panel:toggle_selection(b)
      panel:clear_selections()
      eq(false, panel:is_selected(a))
      eq(false, panel:is_selected(b))
      eq(0, #panel:get_selected_files())
    end)

    it("is_selected returns false for unknown entries", function()
      local panel = make_panel()
      eq(false, panel:is_selected(make_entry("nope.lua")))
    end)

    it("selections survive file entry replacement", function()
      -- Simulate what happens on tab switch: a selected file entry is
      -- replaced by a new object with the same path and kind.
      local old = make_entry("src/foo.lua")
      local panel = make_panel({ old })
      panel:toggle_selection(old)
      eq(true, panel:is_selected(old))

      -- Replace with a new object (same path/kind, different identity).
      local new = make_entry("src/foo.lua")
      assert.is_not.equal(old, new)
      panel.files = make_mock_files({ new })

      -- Selection should carry over to the replacement entry.
      eq(true, panel:is_selected(new))
      local selected = panel:get_selected_files()
      eq(1, #selected)
      eq(new, selected[1])
    end)

    it("prune_selections removes stale entries", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local panel = make_panel({ a, b })
      panel:toggle_selection(a)
      panel:toggle_selection(b)

      -- Remove 'b' from the file list (simulating a file disappearing).
      panel.files = make_mock_files({ a })
      panel:prune_selections()

      eq(true, panel:is_selected(a))
      -- 'b' is no longer in the file list, so it should be pruned.
      eq(false, panel:is_selected(b))
      eq(1, #panel:get_selected_files())
    end)

    it("select_file and deselect_file work", function()
      local f = make_entry("x.lua")
      local panel = make_panel({ f })
      panel:select_file(f)
      eq(true, panel:is_selected(f))
      panel:deselect_file(f)
      eq(false, panel:is_selected(f))
    end)

    it("distinguishes files by kind", function()
      local working = make_entry("f.lua", "working")
      local staged = make_entry("f.lua", "staged")
      local panel = make_panel({ working, staged })
      panel:toggle_selection(working)
      eq(true, panel:is_selected(working))
      eq(false, panel:is_selected(staged))
    end)
  end)

  describe("FilePanel set_dir_collapsed", function()
    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel
    local Node = require("diffview.ui.models.file_tree.node").Node

    local function make_panel()
      local adapter = { ctx = { toplevel = "/tmp", dir = "/tmp/.git" } }
      local files = {}
      function files:iter()
        return function() end
      end
      function files:len()
        return 0
      end
      return FilePanel(adapter, files, {})
    end

    it("propagates collapsed state to tree nodes in a flattened chain", function()
      -- Build a simple tree chain: A -> B -> leaf
      local a_data = { name = "a", path = "a", kind = "working", collapsed = false }
      local b_data = { name = "b", path = "a/b", kind = "working", collapsed = false }

      local a_node = Node("a", a_data)
      local b_node = Node("b", b_data)
      local leaf_node = Node("file.lua", { path = "a/b/file.lua" })
      a_node:add_child(b_node)
      b_node:add_child(leaf_node)

      -- Simulate a flattened DirData created by create_comp_schema.
      local flattened = {
        name = "a/b",
        path = "a/b",
        kind = "working",
        collapsed = false,
        _node = a_node,
      }

      local panel = make_panel()
      panel:set_dir_collapsed(flattened, true)

      eq(true, flattened.collapsed)
      eq(true, a_data.collapsed)
      eq(true, b_data.collapsed)
    end)

    it("does not walk past the end of a flatten chain", function()
      -- Tree: a -> b -> [c (dir), x.lua]
      -- Flatten combines a/b (single-child chain). c is a separate subdir.
      local a_data = { name = "a", path = "a", kind = "working", collapsed = false }
      local b_data = { name = "b", path = "a/b", kind = "working", collapsed = false }
      local c_data = { name = "c", path = "a/b/c", kind = "working", collapsed = false }

      local a_node = Node("a", a_data)
      local b_node = Node("b", b_data)
      local c_node = Node("c", c_data)
      local leaf1 = Node("x.lua", { path = "a/b/x.lua" })
      local leaf2 = Node("y.lua", { path = "a/b/c/y.lua" })
      a_node:add_child(b_node)
      b_node:add_child(c_node)
      b_node:add_child(leaf1)
      c_node:add_child(leaf2)

      local flattened = {
        name = "a/b",
        path = "a/b",
        kind = "working",
        collapsed = false,
        _node = a_node,
      }

      local panel = make_panel()
      panel:set_dir_collapsed(flattened, true)

      eq(true, flattened.collapsed)
      -- a and b are part of the flatten chain (a has one child: b).
      eq(true, a_data.collapsed)
      -- b has multiple children, so the walk stops after b.
      eq(true, b_data.collapsed)
      -- c is a separate subdir, not part of the flatten chain.
      eq(false, c_data.collapsed)
    end)

    it("dir_selection_state reflects none/some/all", function()
      local a_data = { name = "a", path = "a", kind = "working", collapsed = false }
      local a_node = Node("a", a_data)
      local f1 = { path = "a/x.lua", kind = "working" }
      local f2 = { path = "a/y.lua", kind = "working" }
      a_node:add_child(Node("x.lua", f1))
      a_node:add_child(Node("y.lua", f2))
      a_data._node = a_node

      local panel = make_panel()
      eq("none", panel:dir_selection_state(a_data))

      panel:select_file(f1)
      eq("some", panel:dir_selection_state(a_data))

      panel:select_file(f2)
      eq("all", panel:dir_selection_state(a_data))

      panel:deselect_file(f1)
      eq("some", panel:dir_selection_state(a_data))
    end)

    it("dir_selection_state returns none without _node", function()
      local panel = make_panel()
      eq("none", panel:dir_selection_state({ collapsed = false }))
    end)
  end)

  describe("FileTree collapsed state with flatten_dirs", function()
    local FileTree = require("diffview.ui.models.file_tree.file_tree").FileTree

    ---Create a minimal FileEntry stub.
    local function make_entry(path, kind)
      return { path = path, kind = kind or "working", status = "M", basename = path }
    end

    it("get_collapsed_state reads from tree nodes (not flattened DirData)", function()
      -- Build a tree with a flattenable chain: src/components/foo.lua
      local tree = FileTree({ make_entry("src/components/foo.lua") })

      -- Manually collapse the tree nodes (simulating set_dir_collapsed propagation).
      local function collapse_nodes(node)
        if node:has_children() and node.data and node.data.collapsed ~= nil then
          node.data.collapsed = true
        end
        for _, child in ipairs(node.children) do
          collapse_nodes(child)
        end
      end
      for _, child in ipairs(tree.root.children) do
        collapse_nodes(child)
      end

      local state = tree:get_collapsed_state()

      -- Both intermediate nodes should report collapsed = true.
      eq(true, state["src"])
      eq(true, state["src/components"])
    end)

    it("set_collapsed_state restores to tree nodes", function()
      local tree = FileTree({ make_entry("src/components/foo.lua") })

      tree:set_collapsed_state({ ["src"] = true, ["src/components"] = true })

      local state = tree:get_collapsed_state()
      eq(true, state["src"])
      eq(true, state["src/components"])
    end)

    it("create_comp_schema sets _node to outermost node in flattened chain", function()
      local tree = FileTree({ make_entry("src/components/foo.lua") })
      local schema = tree:create_comp_schema({ flatten_dirs = true })

      -- With flatten_dirs, "src" and "components" should be combined into
      -- a single directory component.
      eq("directory", schema[1].name)
      local dir_data = schema[1].context
      assert.truthy(dir_data._node)

      -- _node should point to the outermost node ("src"), not an inner one.
      eq("src", dir_data._node.name)
    end)
  end)

  describe("FilePanel update_components", function()
    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel

    ---Build a mock FileDict with named sub-lists.
    local function make_files(conflicting, working, staged)
      local files =
        { conflicting = conflicting or {}, working = working or {}, staged = staged or {} }
      function files:iter()
        local all = {}
        for _, f in ipairs(self.conflicting) do
          all[#all + 1] = f
        end
        for _, f in ipairs(self.working) do
          all[#all + 1] = f
        end
        for _, f in ipairs(self.staged) do
          all[#all + 1] = f
        end
        local i = 0
        return function()
          i = i + 1
          if i <= #all then
            return i, all[i]
          end
        end
      end
      function files:len()
        return #self.conflicting + #self.working + #self.staged
      end
      return files
    end

    it("list mode builds file components from list entries", function()
      local renderer = require("diffview.renderer")
      local orig_create_cursor_constraint = renderer.create_cursor_constraint

      local f1 = { path = "a.lua" }
      local f2 = { path = "b.lua" }
      local adapter = { ctx = { toplevel = "/tmp", dir = "/tmp/.git" } }
      local panel = FilePanel(adapter, make_files({}, { f1, f2 }, {}), {})
      panel.listing_style = "list"

      -- Capture the schema passed to render_data:create_component.
      local comp_schema
      panel.render_data = {
        create_component = function(_, schema)
          comp_schema = schema
          return {
            conflicting = { files = { comp = {} } },
            working = { files = { comp = {} } },
            staged = { files = { comp = {} } },
          }
        end,
      }
      renderer.create_cursor_constraint = function()
        return function() end
      end

      local ok, err = pcall(function()
        panel:update_components()

        -- The working section is the 3rd top-level entry; its files sub-entry
        -- should contain the two file components built by build_file_list.
        local working_section = comp_schema[3] -- { name="working", title, files, margin }
        eq("working", working_section.name)
        local working_files = working_section[2] -- the files component
        eq("files", working_files.name)
        eq(f1, working_files[1].context)
        eq(f2, working_files[2].context)
      end)

      renderer.create_cursor_constraint = orig_create_cursor_constraint
      if not ok then
        error(err)
      end
    end)

    it("tree mode calls update_statuses and create_comp_schema on each tree", function()
      local renderer = require("diffview.renderer")
      local orig_create_cursor_constraint = renderer.create_cursor_constraint

      local statuses_updated = {}
      local schemas_created = {}

      local function mock_tree(name)
        return {
          update_statuses = function()
            statuses_updated[#statuses_updated + 1] = name
          end,
          create_comp_schema = function(_, opts)
            schemas_created[#schemas_created + 1] = { name = name, opts = opts }
            return { { name = "directory", context = {} } }
          end,
        }
      end

      local files = {
        conflicting = {},
        working = {},
        staged = {},
        conflicting_tree = mock_tree("conflicting"),
        working_tree = mock_tree("working"),
        staged_tree = mock_tree("staged"),
      }
      function files:iter()
        local i = 0
        return function()
          i = i + 1
        end
      end
      function files:len()
        return 0
      end

      local adapter = { ctx = { toplevel = "/tmp", dir = "/tmp/.git" } }
      local panel = FilePanel(adapter, files, {})
      panel.listing_style = "tree"
      panel.tree_options = { flatten_dirs = true }
      panel.render_data = {
        create_component = function()
          return {
            conflicting = { files = { comp = {} } },
            working = { files = { comp = {} } },
            staged = { files = { comp = {} } },
          }
        end,
      }
      renderer.create_cursor_constraint = function()
        return function() end
      end

      local ok, err = pcall(function()
        panel:update_components()

        eq(3, #statuses_updated)
        eq("conflicting", statuses_updated[1])
        eq("working", statuses_updated[2])
        eq("staged", statuses_updated[3])

        eq(3, #schemas_created)
        for _, entry in ipairs(schemas_created) do
          eq(true, entry.opts.flatten_dirs)
        end
      end)

      renderer.create_cursor_constraint = orig_create_cursor_constraint
      if not ok then
        error(err)
      end
    end)
  end)

  describe("Panel apply_keymaps", function()
    local Panel = require("diffview.ui.panel").Panel

    it("calls vim.keymap.set for each mapping with merged options", function()
      local orig_keymap_set = vim.keymap.set
      local config = require("diffview.config")
      local orig_get_config = config.get_config

      local keymap_calls = {}
      local panel = Panel({ bufname = "TestKeymaps", config = Panel.default_config_split })
      panel.bufid = vim.api.nvim_create_buf(false, true)

      local ok, err = pcall(function()
        vim.keymap.set = function(mode, lhs, rhs, opts)
          keymap_calls[#keymap_calls + 1] = { mode = mode, lhs = lhs, opts = opts }
        end

        config.get_config = function()
          return {
            keymaps = {
              test_panel = {
                { "n", "q", function() end, { desc = "Quit" } },
                { "n", "j", function() end },
              },
            },
          }
        end

        local conf = panel:apply_keymaps("test_panel", { nowait = true })

        -- Should have called vim.keymap.set twice.
        eq(2, #keymap_calls)

        -- First mapping should have desc merged in plus nowait.
        eq("n", keymap_calls[1].mode)
        eq("q", keymap_calls[1].lhs)
        eq(true, keymap_calls[1].opts.silent)
        eq(true, keymap_calls[1].opts.nowait)
        eq("Quit", keymap_calls[1].opts.desc)

        -- Second mapping has no desc in the mapping, nowait from defaults.
        eq(true, keymap_calls[2].opts.nowait)

        -- Returns the config.
        assert.is_table(conf)
        assert.is_table(conf.keymaps)
      end)

      pcall(vim.api.nvim_buf_delete, panel.bufid, { force = true })
      vim.keymap.set = orig_keymap_set
      config.get_config = orig_get_config
      if not ok then
        error(err)
      end
    end)

    it("apply_keymaps without extra_defaults omits nowait", function()
      local orig_keymap_set = vim.keymap.set
      local config = require("diffview.config")
      local orig_get_config = config.get_config

      local keymap_calls = {}
      local panel = Panel({ bufname = "TestNoWait", config = Panel.default_config_split })
      panel.bufid = vim.api.nvim_create_buf(false, true)

      local ok, err = pcall(function()
        vim.keymap.set = function(mode, lhs, rhs, opts)
          keymap_calls[#keymap_calls + 1] = { opts = opts }
        end

        config.get_config = function()
          return {
            keymaps = {
              option_panel = {
                { "n", "<tab>", function() end, { desc = "Select" } },
              },
            },
          }
        end

        -- FHOptionPanel calls apply_keymaps("option_panel") without extra defaults.
        panel:apply_keymaps("option_panel")

        eq(1, #keymap_calls)
        eq(true, keymap_calls[1].opts.silent)
        -- nowait should NOT be present since no extra_defaults were passed.
        eq(nil, keymap_calls[1].opts.nowait)
      end)

      pcall(vim.api.nvim_buf_delete, panel.bufid, { force = true })
      vim.keymap.set = orig_keymap_set
      config.get_config = orig_get_config
      if not ok then
        error(err)
      end
    end)
  end)

  describe("FilePanel show=false lifecycle", function()
    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel

    ---Build a mock FileDict with named sub-lists and an iter method.
    local function make_files(conflicting, working, staged)
      local files =
        { conflicting = conflicting or {}, working = working or {}, staged = staged or {} }
      function files:iter()
        local all = {}
        for _, f in ipairs(self.conflicting) do
          all[#all + 1] = f
        end
        for _, f in ipairs(self.working) do
          all[#all + 1] = f
        end
        for _, f in ipairs(self.staged) do
          all[#all + 1] = f
        end
        local i = 0
        return function()
          i = i + 1
          if i <= #all then
            return i, all[i]
          end
        end
      end
      function files:len()
        return #self.conflicting + #self.working + #self.staged
      end
      function files:update_file_trees() end
      return files
    end

    local function make_entry(path)
      return { path = path, set_active = function() end }
    end

    local function make_panel(entries)
      local adapter = { ctx = { toplevel = "/tmp", dir = "/tmp/.git" } }
      local panel = FilePanel(adapter, make_files({}, entries or {}, {}), {})
      panel.listing_style = "list"
      return panel
    end

    -- When show=false, the panel is never opened so init_buffer is never
    -- called and render_data stays nil. The update_files code path in
    -- DiffView calls these methods unconditionally; none should error.

    it("update_components is safe when render_data is nil", function()
      local panel = make_panel()
      eq(nil, panel.render_data)
      assert.has_no.errors(function()
        panel:update_components()
      end)
      eq(nil, panel.components)
    end)

    it("render is safe when render_data is nil", function()
      local panel = make_panel()
      eq(nil, panel.render_data)
      assert.has_no.errors(function()
        panel:render()
      end)
    end)

    it("redraw is safe when render_data is nil", function()
      local panel = make_panel()
      eq(nil, panel.render_data)
      assert.has_no.errors(function()
        panel:redraw()
      end)
    end)

    it("reconstrain_cursor is safe when panel is not open", function()
      local panel = make_panel({ make_entry("a.lua") })
      assert.falsy(panel:is_open())
      assert.has_no.errors(function()
        panel:reconstrain_cursor()
      end)
    end)

    it("reconstrain_cursor uses the repository path when all files are hidden", function()
      local panel = make_panel({ make_entry("a.lua") })
      local original_set_cursor = vim.api.nvim_win_set_cursor
      local cursor_writes = {}

      local ok, err = pcall(function()
        panel.is_open = function()
          return true
        end
        panel.buf_loaded = function()
          return true
        end
        panel.ordered_file_list = function()
          return {}
        end
        panel.cursor_winids = function()
          return { 11, 12 }
        end
        panel.components = { path = { comp = { lstart = 3 } } }
        panel.constrain_cursor = function()
          error("file-row constraint should not be used")
        end
        vim.api.nvim_win_set_cursor = function(winid, cursor)
          cursor_writes[#cursor_writes + 1] = { winid, cursor }
        end

        panel:reconstrain_cursor()

        eq({ { 11, { 4, 0 } }, { 12, { 4, 0 } } }, cursor_writes)
      end)

      vim.api.nvim_win_set_cursor = original_set_cursor
      if not ok then
        error(err)
      end
    end)

    it("ordered_file_list works without components", function()
      local f1 = make_entry("a.lua")
      local f2 = make_entry("b.lua")
      local panel = make_panel({ f1, f2 })
      eq(nil, panel.components)
      local list = panel:ordered_file_list()
      eq(2, #list)
      eq(f1, list[1])
      eq(f2, list[2])
    end)

    it("next_file and set_cur_file work without components", function()
      local f1 = make_entry("a.lua")
      local f2 = make_entry("b.lua")
      local panel = make_panel({ f1, f2 })
      eq(nil, panel.components)
      local file = panel:next_file()
      eq(f1, file)
      eq(f1, panel.cur_file)
    end)

    it("highlight_file is safe when panel is not open", function()
      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      assert.falsy(panel:is_open())
      assert.has_no.errors(function()
        panel:highlight_file(f)
      end)
    end)

    it("toggling on after show=false initialises the panel fully", function()
      local panel = make_panel({ make_entry("a.lua") })

      -- Panel starts without a buffer or render_data.
      eq(nil, panel.render_data)
      assert.falsy(panel:buf_loaded())

      -- toggle(true) calls focus() which calls open() -> init_buffer().
      panel:toggle(true)

      assert.truthy(panel:is_open())
      assert.truthy(panel:buf_loaded())
      assert.truthy(panel.render_data)
      assert.truthy(panel.components)

      panel:destroy()
    end)

    it("toggling off and back on preserves a working panel", function()
      local panel = make_panel({ make_entry("a.lua") })

      -- First toggle on.
      panel:toggle(true)
      assert.truthy(panel:is_open())
      local bufid = panel.bufid

      -- Toggle off.
      panel:toggle(true)
      assert.falsy(panel:is_open())

      -- Toggle back on; buffer should be reused.
      panel:toggle(true)
      assert.truthy(panel:is_open())
      eq(bufid, panel.bufid)
      assert.truthy(panel.render_data)

      panel:destroy()
    end)

    it("get_autosize_components returns nil when components are unset", function()
      local panel = make_panel()
      eq(nil, panel.components)
      eq(nil, panel:get_autosize_components())
    end)
  end)

  describe("FileHistoryPanel show=false lifecycle", function()
    local FileHistoryPanel =
      require("diffview.scene.views.file_history.file_history_panel").FileHistoryPanel

    -- Build a stub FileHistoryPanel that bypasses real window creation:
    -- `is_open`/`buf_loaded` short-circuit `Panel:open`, and `get_config`
    -- returns split+auto so the post-open `wincmd =` branch is skipped.
    local function make_panel(cur_item, on_highlight)
      return setmetatable({
        cur_item = cur_item or {},
        is_open = function()
          return true
        end,
        buf_loaded = function()
          return true
        end,
        get_config = function()
          return { type = "split", width = "auto" }
        end,
        highlight_item = function(_, item)
          if on_highlight then
            on_highlight(item)
          end
        end,
      }, { __index = FileHistoryPanel })
    end

    it("places the cursor on cur_item[2] when toggled open (#161)", function()
      local file = { path = "a.txt" }
      local entry = { files = { file } }
      local highlighted

      local panel = make_panel({ entry, file }, function(item)
        highlighted = item
      end)

      panel:open()
      eq(file, highlighted)
    end)

    it("does not call highlight_item when cur_item is empty", function()
      local panel = make_panel({}, function()
        error("highlight_item should not be called")
      end)

      assert.has_no.errors(function()
        panel:open()
      end)
    end)

    -- Regression: pressing `<tab>`/`<s-tab>` while the panel is toggled off
    -- routes through `set_file_by_offset` -> `set_entry_fold`, which used to
    -- call `utils.set_cursor` against `self.winid` unconditionally. Once the
    -- panel was closed the stored winid was stale, so `nvim_win_get_buf`
    -- raised "Invalid window id".
    it("set_entry_fold does not touch the cursor when the panel is closed", function()
      local cursor_calls = 0
      local entry = {
        folded = false,
        files = {},
      }

      local panel = setmetatable({
        single_file = false,
        winid = 999999,
        is_open = function()
          return false
        end,
        render = function() end,
        redraw = function() end,
        components = {
          log = {
            entries = {
              comp = {
                some = function(_, _)
                  cursor_calls = cursor_calls + 1
                end,
              },
            },
          },
        },
      }, { __index = FileHistoryPanel })

      assert.has_no.errors(function()
        panel:set_entry_fold(entry, false)
      end)
      eq(true, entry.folded)
      eq(0, cursor_calls)
    end)

    -- Companion to the regression above: when the panel *is* open the
    -- iteration must still run so the cursor lands on the collapsed entry.
    it("set_entry_fold iterates components when the panel is open", function()
      local iter_calls = 0
      local entry = {
        folded = false,
        files = {},
      }

      local panel = setmetatable({
        single_file = false,
        winid = 1,
        is_open = function()
          return true
        end,
        render = function() end,
        redraw = function() end,
        components = {
          log = {
            entries = {
              comp = {
                some = function(_, _)
                  iter_calls = iter_calls + 1
                end,
              },
            },
          },
        },
      }, { __index = FileHistoryPanel })

      assert.has_no.errors(function()
        panel:set_entry_fold(entry, false)
      end)
      eq(true, entry.folded)
      eq(1, iter_calls)
    end)
  end)

  describe("Panel on_autocmd dispatch", function()
    local Panel = require("diffview.ui.panel").Panel

    -- Without buffer-matching for non Win*/Buf* events, subscribers to
    -- events like `CursorMoved` would never be invoked: the dispatcher
    -- defaults `win_match` and `buf_match` to nil and the gating check
    -- silently swallows the event. The pinned-mode cursor follower in
    -- `FileHistoryView` relies on this dispatch path.
    it("dispatches CursorMoved to subscribers matching the panel buffer", function()
      local panel = Panel({
        bufname = "TestOnAutocmdPanel",
        config = Panel.default_config_split,
      })
      panel.bufid = vim.api.nvim_create_buf(false, true)

      local fired = 0
      panel:on_autocmd("CursorMoved", {
        callback = function()
          fired = fired + 1
        end,
      })

      Panel.au.emitter:emit("CursorMoved", {
        event = "CursorMoved",
        buf = panel.bufid,
      })

      eq(1, fired)

      pcall(vim.api.nvim_buf_delete, panel.bufid, { force = true })
      panel:destroy()
    end)

    it("ignores CursorMoved events fired in other buffers", function()
      local panel = Panel({
        bufname = "TestOnAutocmdPanelOther",
        config = Panel.default_config_split,
      })
      panel.bufid = vim.api.nvim_create_buf(false, true)
      local other_buf = vim.api.nvim_create_buf(false, true)

      local fired = 0
      panel:on_autocmd("CursorMoved", {
        callback = function()
          fired = fired + 1
        end,
      })

      Panel.au.emitter:emit("CursorMoved", {
        event = "CursorMoved",
        buf = other_buf,
      })

      eq(0, fired)

      pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
      pcall(vim.api.nvim_buf_delete, panel.bufid, { force = true })
      panel:destroy()
    end)
  end)
end)
