require("diffview").setup({ use_icons = false })

local FHOptionPanel = require("diffview.scene.views.file_history.option_panel").FHOptionPanel
local RenderData = require("diffview.renderer").RenderData

describe("fh option panel render components", function()
  local panel

  after_each(function()
    if panel then
      panel:destroy()
      panel = nil
    end
  end)

  it("releases previous components when syncing repeatedly", function()
    local parent = { adapter = { flags = { switches = {}, options = {} } } }
    panel = FHOptionPanel(parent)
    panel.render_data = RenderData("fh_option_panel_refresh")
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
end)
