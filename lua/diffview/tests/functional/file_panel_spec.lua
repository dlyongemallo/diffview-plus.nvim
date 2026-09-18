require("diffview").setup({ use_icons = false })

local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel
local FileDict = require("diffview.vcs.file_dict").FileDict
local RenderData = require("diffview.renderer").RenderData

describe("file panel render components", function()
  local panel

  after_each(function()
    if panel then
      panel:destroy()
      panel = nil
    end
  end)

  for _, style in ipairs({ "tree", "list" }) do
    it("releases previous components when refreshing a " .. style .. " listing", function()
      panel = FilePanel({}, FileDict(), {})
      panel.listing_style = style
      panel.render_data = RenderData("file_panel_refresh_" .. style)
      panel:update_components()
      local previous = setmetatable({ panel.components.comp }, { __mode = "v" })

      for _ = 1, 100 do
        panel:update_components()
        assert.equals(1, #panel.render_data.components)
      end

      collectgarbage("collect")
      assert.is_nil(previous[1])
      assert.equals(panel.components.comp, panel.render_data.components[1])
    end)
  end
end)
