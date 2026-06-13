local config = require("diffview.config")

describe("view.focus_diff config", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("defaults to false for view.default", function()
    config.setup({})
    assert.is_false(config.get_config().view.default.focus_diff)
  end)

  it("defaults to false for view.merge_tool", function()
    config.setup({})
    assert.is_false(config.get_config().view.merge_tool.focus_diff)
  end)

  it("defaults to false for view.file_history", function()
    config.setup({})
    assert.is_false(config.get_config().view.file_history.focus_diff)
  end)

  it("can be set to true for view.default", function()
    config.setup({ view = { default = { focus_diff = true } } })
    assert.is_true(config.get_config().view.default.focus_diff)
  end)

  it("can be set to true for view.merge_tool", function()
    config.setup({ view = { merge_tool = { focus_diff = true } } })
    assert.is_true(config.get_config().view.merge_tool.focus_diff)
  end)

  it("can be set to true for view.file_history", function()
    config.setup({ view = { file_history = { focus_diff = true } } })
    assert.is_true(config.get_config().view.file_history.focus_diff)
  end)

  it("does not affect other view options when overriding focus_diff", function()
    config.setup({ view = { default = { focus_diff = true } } })
    local conf = config.get_config()
    -- Other defaults should be preserved.
    assert.equals("diff2_horizontal", conf.view.default.layout)
    assert.is_false(conf.view.default.disable_diagnostics)
  end)

  it("preserves independent values across view sections", function()
    config.setup({
      view = {
        default = { focus_diff = false },
        merge_tool = { focus_diff = true },
        file_history = { focus_diff = false },
      },
    })
    local conf = config.get_config()
    assert.is_false(conf.view.default.focus_diff)
    assert.is_true(conf.view.merge_tool.focus_diff)
    assert.is_false(conf.view.file_history.focus_diff)
  end)
end)

describe("DiffView._should_focus_diff", function()
  local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("returns true for a working file when view.default.focus_diff is true", function()
    config.setup({ view = { default = { focus_diff = true } } })
    local view = { initialized = false }
    assert.is_true(DiffView._should_focus_diff(view, { kind = "working" }))
  end)

  it("returns false for a working file when view.default.focus_diff is false", function()
    config.setup({ view = { default = { focus_diff = false } } })
    local view = { initialized = false }
    assert.is_false(DiffView._should_focus_diff(view, { kind = "working" }))
  end)

  it("reads merge_tool config for conflicting files", function()
    config.setup({
      view = {
        default = { focus_diff = false },
        merge_tool = { focus_diff = true },
      },
    })
    local view = { initialized = false }
    assert.is_true(DiffView._should_focus_diff(view, { kind = "conflicting" }))
  end)

  it("returns false when initialized is true, even with focus_diff enabled", function()
    config.setup({ view = { default = { focus_diff = true } } })
    local view = { initialized = true }
    assert.is_false(DiffView._should_focus_diff(view, { kind = "working" }))
  end)
end)

-- `--selected-row` is an explicit "land me here" request, so it focuses
-- the main diff window on the targeted file regardless of `focus_diff`.
-- Session restore reuses the `cursor_map` plumbing but must not yank
-- focus, so the listener discriminates on `view.options.selected_row`.
describe("file_open_new listener: --selected-row focus", function()
  local listeners_factory = require("diffview.scene.views.diff.listeners")
  local actions = require("diffview.actions")

  local MAIN_WIN_ID = 77

  local stubs = {}
  local focused

  --- Replace tbl[key] with val, automatically restored in after_each.
  local function stub(tbl, key, val)
    stubs[#stubs + 1] = { tbl, key, tbl[key] }
    tbl[key] = val
  end

  before_each(function()
    focused = nil
    stub(vim.api, "nvim_set_current_win", function(id)
      focused = id
    end)
    stub(vim.api, "nvim_win_is_valid", function()
      return true
    end)
  end)

  after_each(function()
    for i = #stubs, 1, -1 do
      local s = stubs[i]
      s[1][s[2]] = s[3]
    end
    stubs = {}
  end)

  local function make_view(opts)
    opts = opts or {}
    return {
      cur_entry = nil,
      options = opts.options,
      cur_layout = {
        get_main_win = function()
          return { id = MAIN_WIN_ID }
        end,
      },
      restore_main_view = function()
        return opts.restore_returns ~= false
      end,
      panel = {},
      adapter = {},
    }
  end

  it("focuses the main window when selected_row + matching file are set", function()
    local view = make_view({
      options = { selected_row = 42, selected_file = "foo.lua" },
    })
    local listeners = listeners_factory(view)
    local entry = { path = "foo.lua" }
    view.cur_entry = entry

    listeners.file_open_new(nil, entry)
    assert.equals(MAIN_WIN_ID, focused)
    -- One-shot: re-visits must not re-focus.
    assert.is_nil(view.options.selected_row)
  end)

  it("does not focus when selected_row is unset (session-restore path)", function()
    local view = make_view({
      options = { selected_file = "foo.lua" },
    })
    local listeners = listeners_factory(view)
    local entry = { path = "foo.lua" }
    view.cur_entry = entry

    listeners.file_open_new(nil, entry)
    assert.is_nil(focused)
  end)

  it("does not focus when selected_file does not match the opened entry", function()
    local view = make_view({
      options = { selected_row = 42, selected_file = "other.lua" },
    })
    local listeners = listeners_factory(view)
    local entry = { path = "foo.lua" }
    view.cur_entry = entry

    listeners.file_open_new(nil, entry)
    assert.is_nil(focused)
    -- selected_row belongs to a different file; leave it untouched.
    assert.equals(42, view.options.selected_row)
  end)

  it("does not focus when restore_main_view returns false", function()
    local view = make_view({
      options = { selected_row = 42, selected_file = "foo.lua" },
      restore_returns = false,
    })
    local listeners = listeners_factory(view)
    local entry = { path = "foo.lua" }
    view.cur_entry = entry

    -- Stub `jump_to_first_change` so we don't dive into real action code.
    stub(actions, "jump_to_first_change", function() end)

    listeners.file_open_new(nil, entry)
    assert.is_nil(focused)
  end)
end)

describe("DiffView._seed_cursor_map_from_selection", function()
  local DiffView = require("diffview.scene.views.diff.diff_view").DiffView

  it("populates cursor_map with the selected row when both args are set", function()
    local cursor_map = {}
    DiffView._seed_cursor_map_from_selection(cursor_map, {
      selected_row = 42,
      selected_file = "foo.lua",
    })
    assert.same({ lnum = 42 }, cursor_map["foo.lua"])
  end)

  it("clamps the row to 1 when selected_row is 0", function()
    local cursor_map = {}
    DiffView._seed_cursor_map_from_selection(cursor_map, {
      selected_row = 0,
      selected_file = "foo.lua",
    })
    assert.same({ lnum = 1 }, cursor_map["foo.lua"])
  end)

  it("clamps the row to 1 when selected_row is negative", function()
    local cursor_map = {}
    DiffView._seed_cursor_map_from_selection(cursor_map, {
      selected_row = -5,
      selected_file = "foo.lua",
    })
    assert.same({ lnum = 1 }, cursor_map["foo.lua"])
  end)

  it("leaves cursor_map untouched when selected_file is missing", function()
    local cursor_map = {}
    DiffView._seed_cursor_map_from_selection(cursor_map, { selected_row = 42 })
    assert.same({}, cursor_map)
  end)

  it("leaves cursor_map untouched when selected_row is missing", function()
    local cursor_map = {}
    DiffView._seed_cursor_map_from_selection(cursor_map, { selected_file = "foo.lua" })
    assert.same({}, cursor_map)
  end)

  it("does not overwrite unrelated entries", function()
    local cursor_map = { ["other.lua"] = { lnum = 7, col = 3 } }
    DiffView._seed_cursor_map_from_selection(cursor_map, {
      selected_row = 42,
      selected_file = "foo.lua",
    })
    assert.same({ lnum = 7, col = 3 }, cursor_map["other.lua"])
    assert.same({ lnum = 42 }, cursor_map["foo.lua"])
  end)
end)
