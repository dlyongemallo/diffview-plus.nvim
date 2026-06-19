local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

local make_listeners = require("diffview.scene.views.file_history.listeners")

-- Build a fake FileHistoryView whose panel records update_entries calls.
---@return table view
---@return table calls
local function fake_view()
  local calls = { update_entries = 0 }

  local view = {
    panel = {
      update_entries = function(_, _)
        calls.update_entries = calls.update_entries + 1
      end,
    },
    cur_file = function()
      return {}
    end,
    next_item = function() end,
  }

  return view, calls
end

describe("file_history refresh_files listener", function()
  it("skips update_entries on a focus-triggered refresh", function()
    local view, calls = fake_view()
    make_listeners(view).refresh_files(nil, { focus_gained = true })
    eq(0, calls.update_entries)
  end)

  it("updates entries on an explicit refresh (no opts)", function()
    local view, calls = fake_view()
    make_listeners(view).refresh_files(nil, nil)
    eq(1, calls.update_entries)
  end)

  it("updates entries on a forced, non-focus refresh", function()
    local view, calls = fake_view()
    make_listeners(view).refresh_files(nil, { force = true })
    eq(1, calls.update_entries)
  end)
end)
