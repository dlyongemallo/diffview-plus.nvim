local api = vim.api

describe("highlight setup", function()
  it("defines diff fallbacks without loading diff syntax", function()
    assert.equals(0, vim.fn.hlexists("diffAdded"))
    api.nvim_buf_set_lines(0, 0, -1, false, {
      "- unchanged markdown",
      "+ unchanged markdown",
    })

    require("diffview.hl").setup()

    assert.is_nil(vim.b.current_syntax)
    assert.equals("", vim.fn.synIDattr(vim.fn.synID(1, 1, true), "name"))
    assert.equals("", vim.fn.synIDattr(vim.fn.synID(2, 1, true), "name"))
    assert.equals("Added", api.nvim_get_hl(0, { name = "diffAdded" }).link)
    assert.equals("Removed", api.nvim_get_hl(0, { name = "diffRemoved" }).link)
    assert.equals("Changed", api.nvim_get_hl(0, { name = "diffChanged" }).link)
  end)

  describe("with user-defined diff highlight groups", function()
    local saved

    before_each(function()
      saved = {
        diffAdded = api.nvim_get_hl(0, { name = "diffAdded" }),
        diffRemoved = api.nvim_get_hl(0, { name = "diffRemoved" }),
        diffChanged = api.nvim_get_hl(0, { name = "diffChanged" }),
      }
    end)

    after_each(function()
      for name, def in pairs(saved) do
        api.nvim_set_hl(0, name, def)
      end
    end)

    it("preserves them across setup()", function()
      api.nvim_set_hl(0, "diffAdded", { fg = 0x112233 })
      api.nvim_set_hl(0, "diffRemoved", { fg = 0x223344 })
      api.nvim_set_hl(0, "diffChanged", { fg = 0x334455 })

      require("diffview.hl").setup()

      assert.equals(0x112233, api.nvim_get_hl(0, { name = "diffAdded" }).fg)
      assert.equals(0x223344, api.nvim_get_hl(0, { name = "diffRemoved" }).fg)
      assert.equals(0x334455, api.nvim_get_hl(0, { name = "diffChanged" }).fg)
    end)
  end)
end)
