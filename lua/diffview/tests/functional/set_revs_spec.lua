local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("DiffView:set_revs", function()
  local DiffView_class = require("diffview.scene.views.diff.diff_view").DiffView
  local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel
  local RevType = require("diffview.vcs.rev").RevType

  ---Create a mock Rev object.
  ---@param commit string
  ---@return table
  local function make_rev(commit)
    return {
      type = RevType.COMMIT,
      commit = commit,
      track_head = false,
      stage = nil,
      abbrev = function(self, len)
        return self.commit:sub(1, len or 7)
      end,
      object_name = function(self)
        return self.commit
      end,
    }
  end

  ---Create a mock FileDict that supports iteration.
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

  ---Create a mock adapter with controllable parse_revs.
  ---@param parse_results table<string, { [1]: table, [2]: table }>
  ---@return table
  local function make_adapter(parse_results)
    return {
      ctx = { toplevel = "/tmp/repo", dir = "/tmp/repo/.git" },
      parse_revs = function(_, rev_arg, _)
        local result = parse_results[rev_arg]
        if result then
          return result[1], result[2]
        end
        return nil, nil
      end,
      rev_to_pretty_string = function(_, left, right)
        return (left.commit or "?") .. ".." .. (right.commit or "?")
      end,
      instanceof = function()
        return false
      end,
    }
  end

  ---Create a minimal DiffView-like object for testing set_revs without a
  ---full DiffView instantiation (which requires a real adapter, tabpage, etc.).
  ---@param adapter table
  ---@param left table
  ---@param right table
  ---@param rev_arg string
  ---@return table view, FilePanel panel
  local function make_view(adapter, left, right, rev_arg)
    local panel = FilePanel(adapter, make_mock_files(), {})
    local view = {
      adapter = adapter,
      left = left,
      right = right,
      rev_arg = rev_arg,
      panel = panel,
      _save_selections = nil,
      _selection_scope_key = nil,
      -- Stub update_files as a no-op; we test state changes, not the async
      -- file refresh pipeline.
      update_files = function() end,
    }

    -- Bind DiffView:set_revs to our mock via metatables.
    setmetatable(view, { __index = DiffView_class })

    return view, panel
  end

  describe("revision update", function()
    it("updates left, right, and rev_arg", function()
      local old_left = make_rev("aaa111")
      local old_right = make_rev("bbb222")
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")

      local adapter = make_adapter({
        ["aaa111..bbb222"] = { old_left, old_right },
        ["ccc333..ddd444"] = { new_left, new_right },
      })

      local view = make_view(adapter, old_left, old_right, "aaa111..bbb222")

      view:set_revs("ccc333..ddd444")

      eq("ccc333..ddd444", view.rev_arg)
      eq("ccc333", view.left.commit)
      eq("ddd444", view.right.commit)
    end)

    it("updates panel rev_pretty_name", function()
      local old_left = make_rev("aaa111")
      local old_right = make_rev("bbb222")
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")

      local adapter = make_adapter({
        ["ccc333..ddd444"] = { new_left, new_right },
      })

      local view = make_view(adapter, old_left, old_right, "aaa111..bbb222")

      view:set_revs("ccc333..ddd444")

      eq("ccc333..ddd444", view.panel.rev_pretty_name)
    end)

    it("uses adapter panel labels when available", function()
      local old_left = make_rev("aaa111")
      local old_right = make_rev("bbb222")
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")

      local adapter = make_adapter({
        ["ccc333..ddd444"] = { new_left, new_right },
      })
      adapter.rev_to_panel_name = function(_, rev_arg, left, right)
        return table.concat({ "label", rev_arg, left.commit, right.commit }, ":")
      end

      local view = make_view(adapter, old_left, old_right, "aaa111..bbb222")

      view:set_revs("ccc333..ddd444")

      eq("label:ccc333..ddd444:ccc333:ddd444", view.panel.rev_pretty_name)
    end)

    it("does nothing when parse_revs fails", function()
      local left = make_rev("aaa111")
      local right = make_rev("bbb222")
      local adapter = make_adapter({}) -- No valid results for any rev_arg.

      local view = make_view(adapter, left, right, "aaa111..bbb222")

      view:set_revs("invalid..ref")

      -- State should be unchanged.
      eq("aaa111..bbb222", view.rev_arg)
      eq("aaa111", view.left.commit)
      eq("bbb222", view.right.commit)
    end)

    it("calls update_files after updating state", function()
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")
      local adapter = make_adapter({
        ["ccc333..ddd444"] = { new_left, new_right },
      })

      local update_called = false
      local view = make_view(adapter, make_rev("aaa111"), make_rev("bbb222"), "aaa111..bbb222")
      view.update_files = function()
        update_called = true
      end

      view:set_revs("ccc333..ddd444")

      eq(true, update_called)
    end)

    it("does not call update_files when parse_revs fails", function()
      local adapter = make_adapter({})
      local update_called = false
      local view = make_view(adapter, make_rev("aaa111"), make_rev("bbb222"), "aaa111..bbb222")
      view.update_files = function()
        update_called = true
      end

      view:set_revs("invalid..ref")

      eq(false, update_called)
    end)

    it("passes opts through to parse_revs", function()
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")
      local captured_opts

      local adapter = make_adapter({})
      adapter.parse_revs = function(_, rev_arg, opts)
        captured_opts = opts
        return new_left, new_right
      end

      local view = make_view(adapter, make_rev("aaa111"), make_rev("bbb222"), "aaa111..bbb222")
      view:set_revs("ccc333..ddd444", { imply_local = true, cached = false })

      eq(true, captured_opts.imply_local)
      eq(false, captured_opts.cached)
    end)
  end)

  describe("selection preservation", function()
    local selection_store = require("diffview.selection_store")
    local saved_get_path
    local tmpdir

    before_each(function()
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      saved_get_path = selection_store.get_path
      selection_store.get_path = function()
        return tmpdir .. "/test.json"
      end
    end)

    after_each(function()
      selection_store.get_path = saved_get_path
      vim.fn.delete(tmpdir, "rf")
    end)

    it("preserves in-memory selections across rev change", function()
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")
      local adapter = make_adapter({
        ["ccc333..ddd444"] = { new_left, new_right },
      })

      local a = { path = "a.lua", kind = "working" }
      local view = make_view(adapter, make_rev("aaa111"), make_rev("bbb222"), "aaa111..bbb222")
      view.panel.files = make_mock_files({ a })
      view.panel:select_file(a)

      view:set_revs("ccc333..ddd444")

      -- Selections keyed by kind:path should survive.
      eq(true, view.panel:is_selected(a))
    end)

    it("updates selection scope key for persistence", function()
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")
      local adapter = make_adapter({
        ["ccc333..ddd444"] = { new_left, new_right },
      })

      local view = make_view(adapter, make_rev("aaa111"), make_rev("bbb222"), "aaa111..bbb222")
      view._selection_scope_key = selection_store.scope_key("/tmp/repo", "aaa111..bbb222")

      view:set_revs("ccc333..ddd444")

      local expected = selection_store.scope_key("/tmp/repo", "ccc333..ddd444")
      eq(expected, view._selection_scope_key)
    end)

    it("merges saved selections from the new scope", function()
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")
      local adapter = make_adapter({
        ["ccc333..ddd444"] = { new_left, new_right },
      })

      -- Pre-save some selections under the new scope.
      local new_scope = selection_store.scope_key("/tmp/repo", "ccc333..ddd444")
      selection_store.save(new_scope, { "working:b.lua" })

      local a = { path = "a.lua", kind = "working" }
      local view = make_view(adapter, make_rev("aaa111"), make_rev("bbb222"), "aaa111..bbb222")
      view._selection_scope_key = selection_store.scope_key("/tmp/repo", "aaa111..bbb222")
      view.panel.files = make_mock_files({ a })
      view.panel:select_file(a)

      view:set_revs("ccc333..ddd444")

      -- Both the old in-memory selection and the new scope's saved selection
      -- should be present.
      eq(true, view.panel.selected_files["working:a.lua"] == true)
      eq(true, view.panel.selected_files["working:b.lua"] == true)
    end)

    it("persists selections under the new scope key", function()
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")
      local adapter = make_adapter({
        ["ccc333..ddd444"] = { new_left, new_right },
      })

      local old_scope = selection_store.scope_key("/tmp/repo", "aaa111..bbb222")
      local new_scope = selection_store.scope_key("/tmp/repo", "ccc333..ddd444")
      local a = { path = "a.lua", kind = "working" }
      local b = { path = "b.lua", kind = "working" }
      local view = make_view(adapter, make_rev("aaa111"), make_rev("bbb222"), "aaa111..bbb222")
      view._selection_scope_key = old_scope
      -- Stub _save_selections as a callable (simulating the debounced handle).
      view._save_selections = function() end

      view.panel.files = make_mock_files({ a, b })
      view.panel:select_file(a)
      view.panel:select_file(b)

      view:set_revs("ccc333..ddd444")

      -- Selections should be persisted under the new scope key so they
      -- survive a Neovim restart. The store writes keys in sorted order.
      local saved = selection_store.load(new_scope)
      eq({ "working:a.lua", "working:b.lua" }, saved)
    end)

    it("persists old selections before switching scope", function()
      local new_left = make_rev("ccc333")
      local new_right = make_rev("ddd444")
      local adapter = make_adapter({
        ["ccc333..ddd444"] = { new_left, new_right },
      })

      local old_scope = selection_store.scope_key("/tmp/repo", "aaa111..bbb222")
      local a = { path = "a.lua", kind = "working" }
      local b = { path = "b.lua", kind = "staged" }
      local view = make_view(adapter, make_rev("aaa111"), make_rev("bbb222"), "aaa111..bbb222")
      view._selection_scope_key = old_scope
      -- Stub _save_selections as a callable (simulating the debounced handle).
      view._save_selections = function() end

      view.panel.files = make_mock_files({ a, b })
      view.panel:select_file(a)
      view.panel:select_file(b)

      -- The _save_selections_now method should have been called; verify by
      -- checking the store directly.  We bind DiffView's method via metatable.
      view:set_revs("ccc333..ddd444")

      local saved = selection_store.load(old_scope)
      eq({ "staged:b.lua", "working:a.lua" }, saved)
    end)
  end)
end)

describe("diffview.api.set_revs", function()
  local api_mod = require("diffview.api")

  it("is safe when no view exists", function()
    assert.has_no.errors(function()
      api_mod.set_revs("abc..def")
    end)
  end)

  it("is safe when view has no set_revs method", function()
    local lib = require("diffview.lib")
    local saved = lib.get_current_view
    lib.get_current_view = function()
      return { panel = {} } -- Not a DiffView, no set_revs.
    end

    assert.has_no.errors(function()
      api_mod.set_revs("abc..def")
    end)

    lib.get_current_view = saved
  end)
end)
