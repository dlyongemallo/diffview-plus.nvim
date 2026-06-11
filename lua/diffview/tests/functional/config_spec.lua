local actions = require("diffview.actions")
local config = require("diffview.config")
local utils = require("diffview.utils")

describe("diffview.config", function()
  it("validates rename_threshold", function()
    local original = vim.deepcopy(config.get_config())
    local old_warn = utils.warn
    utils.warn = function() end

    local ok, err = pcall(function()
      config.setup({ rename_threshold = "40" })
      assert.equals(40, config.get_config().rename_threshold)

      config.setup({ rename_threshold = 101 })
      assert.is_nil(config.get_config().rename_threshold)

      config.setup({ rename_threshold = 12.5 })
      assert.is_nil(config.get_config().rename_threshold)
    end)

    utils.warn = old_warn
    config.setup(original)

    if not ok then
      error(err)
    end
  end)
end)

describe("diffview.config default keymaps", function()
  ---Search a keymap table for an entry with the given lhs binding.
  local function find_keymap(keymaps, lhs)
    for _, km in ipairs(keymaps) do
      if km[2] == lhs then
        return km
      end
    end
    return nil
  end

  local function has_action(keymaps, action)
    for _, section in pairs(keymaps) do
      if type(section) == "table" then
        for _, km in ipairs(section) do
          if km[3] == action then
            return true
          end
        end
      end
    end
    return false
  end

  it("shared nav keymaps appear in view section", function()
    local keymaps = config.defaults.keymaps
    -- <tab> is a common nav keymap that should be in view.
    assert.truthy(find_keymap(keymaps.view, "<tab>"))
    assert.truthy(find_keymap(keymaps.view, "gf"))
    assert.truthy(find_keymap(keymaps.view, "<leader>e"))
  end)

  it("shared nav keymaps appear in file_panel section", function()
    local keymaps = config.defaults.keymaps
    assert.truthy(find_keymap(keymaps.file_panel, "<tab>"))
    assert.truthy(find_keymap(keymaps.file_panel, "gf"))
    assert.truthy(find_keymap(keymaps.file_panel, "<leader>b"))
  end)

  it("shared nav keymaps appear in file_history_panel section", function()
    local keymaps = config.defaults.keymaps
    assert.truthy(find_keymap(keymaps.file_history_panel, "<tab>"))
    assert.truthy(find_keymap(keymaps.file_history_panel, "gf"))
    assert.truthy(find_keymap(keymaps.file_history_panel, "<leader>e"))
  end)

  it("shared panel keymaps appear in both panel sections", function()
    local keymaps = config.defaults.keymaps
    -- j, <cr>, zo are common panel keymaps.
    for _, lhs in ipairs({ "j", "<cr>", "zo", "zM" }) do
      assert.truthy(find_keymap(keymaps.file_panel, lhs), "file_panel missing " .. lhs)
      assert.truthy(
        find_keymap(keymaps.file_history_panel, lhs),
        "file_history_panel missing " .. lhs
      )
    end
  end)

  it("follow-navigation actions are opt-in and do not replace j/k defaults", function()
    local keymaps = config.defaults.keymaps
    assert.is_false(config.defaults.file_panel.follow_navigation)
    assert.same(actions.next_entry, find_keymap(keymaps.file_panel, "j")[3])
    assert.same(actions.prev_entry, find_keymap(keymaps.file_panel, "k")[3])
    assert.falsy(has_action(keymaps, actions.next_entry_follow))
    assert.falsy(has_action(keymaps, actions.prev_entry_follow))
  end)

  it("section-specific keymaps are not leaked to other sections", function()
    local keymaps = config.defaults.keymaps
    -- "s" (stage) is file_panel-only.
    assert.truthy(find_keymap(keymaps.file_panel, "s"))
    assert.falsy(find_keymap(keymaps.file_history_panel, "s"))

    -- "g!" (options) is file_history_panel-only.
    assert.truthy(find_keymap(keymaps.file_history_panel, "g!"))
    assert.falsy(find_keymap(keymaps.file_panel, "g!"))
  end)

  it("conflict keymaps live on the merge-tool layouts, not the view section", function()
    local keymaps = config.defaults.keymaps
    -- They should be active in every layout that appears in the default
    -- `merge_tool` cycle (`diff3`, `diff4`, and `diff1_plain`) and absent
    -- from the general `view` section.
    for _, lhs in ipairs({
      "<leader>co",
      "<leader>ct",
      "<leader>cb",
      "<leader>ca",
      "dx",
      "[x",
      "]x",
    }) do
      assert.truthy(find_keymap(keymaps.diff1, lhs), "diff1 missing " .. lhs)
      assert.truthy(find_keymap(keymaps.diff3, lhs), "diff3 missing " .. lhs)
      assert.truthy(find_keymap(keymaps.diff4, lhs), "diff4 missing " .. lhs)
      assert.falsy(find_keymap(keymaps.view, lhs), "view should not contain " .. lhs)
    end
  end)
end)
