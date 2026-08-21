local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("diffview.api.selections", function()
  local selections = require("diffview.api").selections
  local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel

  it("is accessible via the public api entrypoint", function()
    -- The public entrypoint is a lazy proxy; verify it exposes the same functions.
    for _, name in ipairs({
      "get",
      "get_paths",
      "is_selected",
      "select",
      "deselect",
      "set",
      "clear",
      "any",
      "count",
    }) do
      eq("function", type(selections[name]), "missing function: " .. name)
    end
  end)

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

  ---Lightweight stand-in for a FileEntry (only identity matters).
  local function make_entry(path, kind)
    return { path = path, kind = kind or "working" }
  end

  ---Create a minimal mock view wrapping a FilePanel.
  ---@param entries table[]?
  ---@return table view, FilePanel panel
  local function make_view(entries)
    local adapter = { ctx = { toplevel = "/tmp", dir = "/tmp/.git" } }
    local panel = FilePanel(adapter, make_mock_files(entries or {}), {})
    local view = { panel = panel }
    return view, panel
  end

  ---Assert that a mutation refreshes a loaded panel without rebuilding its
  ---component tree.
  ---@param panel FilePanel
  ---@param mutate fun()
  local function assert_panel_refresh(panel, mutate)
    local renders = 0
    local redraws = 0
    panel.buf_loaded = function()
      return true
    end
    panel.update_components = function()
      error("selection API must not rebuild component trees")
    end
    panel.render = function()
      renders = renders + 1
    end
    panel.redraw = function()
      redraws = redraws + 1
    end

    mutate()

    eq(1, renders)
    eq(1, redraws)
  end

  describe("get", function()
    it("returns empty list when no view is given and none is current", function()
      eq({}, selections.get())
    end)

    it("returns selected files with path and kind", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local view = make_view({ a, b })
      view.panel:select_file(a)

      local result = selections.get(view)
      eq(1, #result)
      eq("a.lua", result[1].path)
      eq("working", result[1].kind)
    end)

    it("returns multiple selections", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua", "staged")
      local view = make_view({ a, b })
      view.panel:select_file(a)
      view.panel:select_file(b)

      local result = selections.get(view)
      eq(2, #result)
    end)
  end)

  describe("get_paths", function()
    it("returns empty list when no view is given", function()
      eq({}, selections.get_paths())
    end)

    it("returns just the paths", function()
      local a = make_entry("src/a.lua")
      local b = make_entry("src/b.lua")
      local view = make_view({ a, b })
      view.panel:select_file(a)
      view.panel:select_file(b)

      local result = selections.get_paths(view)
      table.sort(result)
      eq({ "src/a.lua", "src/b.lua" }, result)
    end)
  end)

  describe("is_selected", function()
    it("returns false when no view is given", function()
      eq(false, selections.is_selected("a.lua"))
    end)

    it("returns true for a selected file", function()
      local a = make_entry("a.lua")
      local view = make_view({ a })
      view.panel:select_file(a)

      eq(true, selections.is_selected("a.lua", { view = view }))
    end)

    it("returns false for an unselected file", function()
      local a = make_entry("a.lua")
      local view = make_view({ a })

      eq(false, selections.is_selected("a.lua", { view = view }))
    end)

    it("returns false for a non-existent path", function()
      local view = make_view({})
      eq(false, selections.is_selected("nope.lua", { view = view }))
    end)

    it("respects the kind filter", function()
      local working = make_entry("f.lua", "working")
      local staged = make_entry("f.lua", "staged")
      local view = make_view({ working, staged })
      view.panel:select_file(working)

      eq(true, selections.is_selected("f.lua", { view = view, kind = "working" }))
      eq(false, selections.is_selected("f.lua", { view = view, kind = "staged" }))
    end)
  end)

  describe("select", function()
    it("selects files by path", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local c = make_entry("c.lua")
      local view = make_view({ a, b, c })

      selections.select({ "a.lua", "c.lua" }, { view = view })

      eq(true, view.panel:is_selected(a))
      eq(false, view.panel:is_selected(b))
      eq(true, view.panel:is_selected(c))
    end)

    it("ignores paths that do not exist in the file list", function()
      local a = make_entry("a.lua")
      local view = make_view({ a })

      selections.select({ "a.lua", "nonexistent.lua" }, { view = view })
      eq(true, view.panel:is_selected(a))
    end)

    it("does not deselect already-selected files not in the list", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local view = make_view({ a, b })
      view.panel:select_file(a)

      selections.select({ "b.lua" }, { view = view })

      -- a should still be selected (select is additive).
      eq(true, view.panel:is_selected(a))
      eq(true, view.panel:is_selected(b))
    end)

    it("respects the kind filter", function()
      local working = make_entry("f.lua", "working")
      local staged = make_entry("f.lua", "staged")
      local view = make_view({ working, staged })

      selections.select({ "f.lua" }, { view = view, kind = "staged" })

      eq(false, view.panel:is_selected(working))
      eq(true, view.panel:is_selected(staged))
    end)

    it("fires a single notification via batch_selection", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local view = make_view({ a, b })
      local called = 0
      view.panel.on_selection_changed = function()
        called = called + 1
      end

      selections.select({ "a.lua", "b.lua" }, { view = view })
      eq(1, called)
    end)

    it("refreshes a loaded panel after changing selections", function()
      local a = make_entry("a.lua")
      local view, panel = make_view({ a })
      panel.hide_selected = true

      assert_panel_refresh(panel, function()
        selections.select({ "a.lua" }, { view = view })
      end)

      eq(true, panel:is_selected(a))
    end)

    it("is safe when no view exists", function()
      assert.has_no.errors(function()
        selections.select({ "a.lua" })
      end)
    end)
  end)

  describe("deselect", function()
    it("deselects files by path", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local view = make_view({ a, b })
      view.panel:select_file(a)
      view.panel:select_file(b)

      selections.deselect({ "a.lua" }, { view = view })

      eq(false, view.panel:is_selected(a))
      eq(true, view.panel:is_selected(b))
    end)

    it("ignores paths not in the file list", function()
      local a = make_entry("a.lua")
      local view = make_view({ a })
      view.panel:select_file(a)

      selections.deselect({ "nonexistent.lua" }, { view = view })
      eq(true, view.panel:is_selected(a))
    end)

    it("respects the kind filter", function()
      local working = make_entry("f.lua", "working")
      local staged = make_entry("f.lua", "staged")
      local view = make_view({ working, staged })
      view.panel:select_file(working)
      view.panel:select_file(staged)

      selections.deselect({ "f.lua" }, { view = view, kind = "working" })

      eq(false, view.panel:is_selected(working))
      eq(true, view.panel:is_selected(staged))
    end)

    it("refreshes a loaded panel after changing selections", function()
      local a = make_entry("a.lua")
      local view, panel = make_view({ a })
      panel:select_file(a)
      panel.hide_selected = true

      assert_panel_refresh(panel, function()
        selections.deselect({ "a.lua" }, { view = view })
      end)

      eq(false, panel:is_selected(a))
    end)
  end)

  describe("set", function()
    it("replaces the entire selection set", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local c = make_entry("c.lua")
      local view = make_view({ a, b, c })
      view.panel:select_file(a)
      view.panel:select_file(b)

      selections.set({ "c.lua" }, { view = view })

      eq(false, view.panel:is_selected(a))
      eq(false, view.panel:is_selected(b))
      eq(true, view.panel:is_selected(c))
    end)

    it("setting to empty deselects everything", function()
      local a = make_entry("a.lua")
      local view = make_view({ a })
      view.panel:select_file(a)

      selections.set({}, { view = view })

      eq(false, view.panel:is_selected(a))
    end)

    it("fires a single notification", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local view = make_view({ a, b })
      view.panel:select_file(a)
      local called = 0
      view.panel.on_selection_changed = function()
        called = called + 1
      end

      selections.set({ "b.lua" }, { view = view })
      eq(1, called)
    end)

    it("respects the kind filter", function()
      local working = make_entry("f.lua", "working")
      local staged = make_entry("f.lua", "staged")
      local view = make_view({ working, staged })
      view.panel:select_file(working)

      -- Set only staged selections; working should be untouched because it
      -- does not match the kind filter.
      selections.set({ "f.lua" }, { view = view, kind = "staged" })

      eq(true, view.panel:is_selected(working))
      eq(true, view.panel:is_selected(staged))
    end)

    it("kind filter deselects non-matching same-kind files", function()
      local a = make_entry("a.lua", "staged")
      local b = make_entry("b.lua", "staged")
      local working = make_entry("a.lua", "working")
      local view = make_view({ a, b, working })
      view.panel:select_file(a)
      view.panel:select_file(working)

      -- Only b.lua should be selected in staged; a.lua staged deselected.
      -- a.lua working should be untouched (different kind).
      selections.set({ "b.lua" }, { view = view, kind = "staged" })

      eq(false, view.panel:is_selected(a))
      eq(true, view.panel:is_selected(b))
      eq(true, view.panel:is_selected(working))
    end)

    it("refreshes a loaded panel after changing selections", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local view, panel = make_view({ a, b })
      panel:select_file(a)
      panel.hide_selected = true

      assert_panel_refresh(panel, function()
        selections.set({ "b.lua" }, { view = view })
      end)

      eq(false, panel:is_selected(a))
      eq(true, panel:is_selected(b))
    end)
  end)

  describe("clear", function()
    it("clears all selections", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local view = make_view({ a, b })
      view.panel:select_file(a)
      view.panel:select_file(b)

      selections.clear(view)

      eq(false, view.panel:is_selected(a))
      eq(false, view.panel:is_selected(b))
    end)

    it("refreshes a loaded panel after changing selections", function()
      local a = make_entry("a.lua")
      local view, panel = make_view({ a })
      panel:select_file(a)
      panel.hide_selected = true

      assert_panel_refresh(panel, function()
        selections.clear(view)
      end)

      eq(false, panel:is_selected(a))
    end)

    it("does not refresh when selections are already empty", function()
      local view, panel = make_view({ make_entry("a.lua") })
      panel.buf_loaded = function()
        return true
      end
      panel.render = function()
        error("no-op selection changes must not render")
      end
      panel.redraw = function()
        error("no-op selection changes must not redraw")
      end

      selections.clear(view)
    end)

    it("is safe when no view exists", function()
      assert.has_no.errors(function()
        selections.clear()
      end)
    end)
  end)

  describe("any", function()
    it("returns false when nothing is selected", function()
      local view = make_view({ make_entry("a.lua") })
      eq(false, selections.any(view))
    end)

    it("returns true when something is selected", function()
      local a = make_entry("a.lua")
      local view = make_view({ a })
      view.panel:select_file(a)
      eq(true, selections.any(view))
    end)

    it("returns false when no view exists", function()
      eq(false, selections.any())
    end)
  end)

  describe("count", function()
    it("returns 0 when nothing is selected", function()
      local view = make_view({})
      eq(0, selections.count(view))
    end)

    it("returns the number of selected files", function()
      local a = make_entry("a.lua")
      local b = make_entry("b.lua")
      local view = make_view({ a, b })
      view.panel:select_file(a)
      view.panel:select_file(b)
      eq(2, selections.count(view))
    end)

    it("returns 0 when no view exists", function()
      eq(0, selections.count())
    end)
  end)
end)
