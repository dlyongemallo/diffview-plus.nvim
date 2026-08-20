local helpers = require("diffview.tests.helpers")
local listeners_factory = require("diffview.scene.views.diff.listeners")

local eq = helpers.eq
local api = vim.api

describe("reviewed-file navigation", function()
  local original_get_mode
  local original_feedkeys
  local original_replace_termcodes
  local original_line

  before_each(function()
    original_get_mode = api.nvim_get_mode
    original_feedkeys = api.nvim_feedkeys
    original_replace_termcodes = api.nvim_replace_termcodes
    original_line = vim.fn.line
    api.nvim_get_mode = function()
      return { mode = "n" }
    end
  end)

  after_each(function()
    api.nvim_get_mode = original_get_mode
    api.nvim_feedkeys = original_feedkeys
    api.nvim_replace_termcodes = original_replace_termcodes
    vim.fn.line = original_line
  end)

  it("advances past a directory whose last children are already hidden", function()
    local first = { path = "dir/a.lua" }
    local hidden_middle = { path = "dir/b.lua" }
    local hidden_last = { path = "dir/c.lua" }
    local next_file = { path = "other.lua" }
    local selected = {
      [hidden_middle] = true,
      [hidden_last] = true,
    }
    local directory = {
      collapsed = false,
      _node = {
        leaves = function()
          return {
            { data = first },
            { data = hidden_middle },
            { data = hidden_last },
          }
        end,
      },
    }

    local panel = {
      hide_selected = true,
      is_open = function()
        return true
      end,
      get_item_at_cursor = function()
        return directory
      end,
      is_selected = function(_, file)
        return selected[file] == true
      end,
      ordered_file_list = function()
        return { first, next_file }
      end,
      batch_selection = function(_, callback)
        callback()
      end,
      select_file = function(_, file)
        selected[file] = true
      end,
      update_components = function() end,
      render = function() end,
      redraw = function() end,
    }
    local opened
    local view = {
      panel = panel,
      set_file = function(_, file, focus, highlight)
        opened = { file, focus, highlight }
      end,
    }

    listeners_factory(view).toggle_select_entry()

    eq(true, selected[first])
    eq(true, selected[hidden_middle])
    eq(true, selected[hidden_last])
    eq({ next_file, false, true }, opened)
  end)

  it("opens the file selected by the panel after marking an entry", function()
    local current = { path = "b.lua" }
    local next_file = { path = "c.lua" }
    local cursor_item = current
    local selected = {}
    local panel = {
      hide_selected = false,
      is_open = function()
        return true
      end,
      get_item_at_cursor = function()
        return cursor_item
      end,
      is_selected = function(_, file)
        return selected[file] == true
      end,
      batch_selection = function(_, callback)
        callback()
      end,
      select_file = function(_, file)
        selected[file] = true
      end,
      highlight_next_file = function()
        cursor_item = next_file
      end,
      render = function() end,
      redraw = function() end,
    }
    local opened
    local view = {
      panel = panel,
      set_file = function(_, file, focus, highlight)
        opened = { file, focus, highlight }
      end,
    }

    listeners_factory(view).toggle_select_entry()

    eq(true, selected[current])
    eq({ next_file, false, true }, opened)
  end)

  it("opens the next visible file when H hides the active file", function()
    local previous = { path = "a.lua" }
    local current = { path = "b.lua" }
    local next_file = { path = "c.lua" }
    local selected = { [current] = true }
    local panel = {
      cur_file = current,
      hide_selected = false,
      is_focused = function()
        return true
      end,
      ordered_file_list = function()
        return { previous, current, next_file }
      end,
      is_selected = function(_, file)
        return selected[file] == true
      end,
      toggle_hide_selected = function(self)
        self.hide_selected = not self.hide_selected
      end,
      update_components = function() end,
      render = function() end,
      redraw = function() end,
    }
    local opened
    local view = {
      panel = panel,
      set_file = function(_, file, focus, highlight)
        opened = { file, focus, highlight }
      end,
      _save_selections_now = function() end,
    }

    listeners_factory(view).toggle_hide_selected()

    eq(true, panel.hide_selected)
    eq({ next_file, false, true }, opened)
  end)

  it("opens the next visible file when a visual selection hides the active file", function()
    local previous = { path = "a.lua" }
    local current = { path = "b.lua" }
    local next_file = { path = "c.lua" }
    local selected = {}
    api.nvim_get_mode = function()
      return { mode = "V" }
    end
    api.nvim_feedkeys = function() end
    api.nvim_replace_termcodes = function(keys)
      return keys
    end
    vim.fn.line = function()
      return 1
    end

    local panel = {
      cur_file = current,
      hide_selected = true,
      is_open = function()
        return true
      end,
      ordered_file_list = function()
        return { previous, current, next_file }
      end,
      get_item_at_line = function()
        return current
      end,
      toggle_selection = function(_, file)
        selected[file] = not selected[file]
      end,
      is_selected = function(_, file)
        return selected[file] == true
      end,
      batch_selection = function(_, callback)
        callback()
      end,
      update_components = function() end,
      render = function() end,
      redraw = function() end,
    }
    local opened
    local view = {
      panel = panel,
      set_file = function(_, file, focus, highlight)
        opened = { file, focus, highlight }
      end,
    }

    listeners_factory(view).toggle_select_entry()

    eq(true, selected[current])
    eq({ next_file, false, true }, opened)
  end)
end)
