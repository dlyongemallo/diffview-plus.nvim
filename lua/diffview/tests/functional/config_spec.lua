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

  it("section-specific keymaps are not leaked to other sections", function()
    local keymaps = config.defaults.keymaps
    -- "s" (stage) is file_panel-only.
    assert.truthy(find_keymap(keymaps.file_panel, "s"))
    assert.falsy(find_keymap(keymaps.file_history_panel, "s"))

    -- "H" toggles reviewed-file visibility only in the file panel.
    local hide_map = find_keymap(keymaps.file_panel, "H")
    assert.truthy(hide_map)
    assert.equals(config.actions.toggle_hide_selected, hide_map[3])
    assert.equals("Toggle hiding reviewed (selected) files", hide_map[4].desc)

    -- "g!" (options) is file_history_panel-only.
    assert.truthy(find_keymap(keymaps.file_history_panel, "g!"))
    assert.falsy(find_keymap(keymaps.file_panel, "g!"))
  end)

  it("allows the hide-reviewed mapping to be changed", function()
    local original = vim.deepcopy(config.get_config())
    local ok, err = pcall(function()
      config.setup({
        keymaps = {
          file_panel = {
            ["H"] = false,
            { "n", "<leader>h", config.actions.toggle_hide_selected },
          },
        },
      })

      local keymaps = config.get_config().keymaps.file_panel
      assert.falsy(find_keymap(keymaps, "H"))

      local replacement = find_keymap(keymaps, "<leader>h")
      assert.truthy(replacement)
      assert.equals(config.actions.toggle_hide_selected, replacement[3])
    end)

    config.setup(original)
    if not ok then
      error(err)
    end
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
