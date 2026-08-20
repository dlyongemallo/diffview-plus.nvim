local helpers = require("diffview.tests.helpers")
local listeners_factory = require("diffview.scene.views.diff.listeners")

local eq = helpers.eq

describe("hide-reviewed navigation", function()
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
end)
