local health = vim.health
local fmt = string.format

local M = {}

-- Icon plugins are alternatives; only one is needed for icons to render.
M.icon_providers = { "nvim-web-devicons", "mini.icons" }

local function lualib_available(name)
  local ok, _ = pcall(require, name)
  return ok
end

function M.check()
  if vim.fn.has("nvim-0.10") == 0 then
    health.error("Diffview.nvim requires Neovim 0.10.0+")
  end

  -- LuaJIT
  if not _G.jit then
    health.error(
      "Not running on LuaJIT! Non-JIT Lua runtimes are not officially supported by the plugin. Mileage may vary."
    )
  end

  health.start("Checking icon provider")

  local found_provider
  for _, name in ipairs(M.icon_providers) do
    if lualib_available(name) then
      found_provider = name
      break
    end
  end

  if found_provider then
    health.ok(fmt("Icon provider found: %s.", found_provider))
  else
    health.info(
      fmt(
        "No icon provider found (%s). Icons will be disabled; set `use_icons = false` to silence this.",
        table.concat(M.icon_providers, " or ")
      )
    )
  end

  health.start("Checking VCS tools");
  (function()
    health.info("The plugin requires at least one of the supported VCS tools to be valid.")

    local adapter_kinds = {
      { class = require("diffview.vcs.adapters.jj").JjAdapter, name = "Jujutsu" },
      { class = require("diffview.vcs.adapters.git").GitAdapter, name = "Git" },
      { class = require("diffview.vcs.adapters.hg").HgAdapter, name = "Mercurial" },
      { class = require("diffview.vcs.adapters.p4").P4Adapter, name = "Perforce" },
    }

    local ok_adapters = {}
    local failed_adapters = {}

    for _, kind in ipairs(adapter_kinds) do
      local bs = kind.class.bootstrap
      if not bs.done then
        kind.class.run_bootstrap()
      end

      if bs.ok then
        table.insert(ok_adapters, { name = kind.name, bs = bs })
      else
        table.insert(failed_adapters, { name = kind.name, bs = bs })
      end
    end

    for _, entry in ipairs(ok_adapters) do
      health.ok(fmt("%s is up-to-date. (%s)", entry.name, entry.bs.version_string))
    end

    if #ok_adapters > 0 then
      return
    end

    for _, entry in ipairs(failed_adapters) do
      health.warn(entry.bs.err or (entry.name .. ": Unknown error"))
    end
    health.error("No valid VCS tool was found!")
  end)()
end

return M
