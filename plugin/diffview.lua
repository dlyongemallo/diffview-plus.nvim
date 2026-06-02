if vim.g.diffview_nvim_loaded or not require("diffview.bootstrap") then
  return
end

vim.g.diffview_nvim_loaded = 1

local lazy = require("diffview.lazy")

---@module "diffview"
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local diffview = lazy.require("diffview") ---@module "diffview"

-- Eagerly register the session-cleanup autocmd so the hook is in place
-- before any `:source Session.vim` fires.
require("diffview.session").setup()

local api = vim.api
local command = api.nvim_create_user_command

-- NOTE: Need this wrapper around the completion function because it doesn't
-- exist yet.
local function completion(...)
  return diffview.completion(...)
end

-- Create commands
command("DiffviewOpen", function(ctx)
  diffview.open(arg_parser.scan(ctx.args).args)
end, { nargs = "*", complete = completion })

command("DiffviewToggle", function(ctx)
  diffview.toggle(arg_parser.scan(ctx.args).args)
end, { nargs = "*", complete = completion })

command("DiffviewDiffFiles", function(ctx)
  diffview.diff_files(arg_parser.scan(ctx.args).args)
end, { nargs = "+", complete = completion })

command("DiffviewMergeFiles", function(ctx)
  diffview.merge_files(arg_parser.scan(ctx.args).args)
end, { nargs = "+", complete = completion })

command("DiffviewDiffDirs", function(ctx)
  diffview.dir_diff(arg_parser.scan(ctx.args).args)
end, { nargs = "+", complete = completion })

command("DiffviewFileHistory", function(ctx)
  local range

  if ctx.range > 0 then
    range = { ctx.line1, ctx.line2 }
  end

  diffview.file_history(range, arg_parser.scan(ctx.args).args)
end, { nargs = "*", complete = completion, range = true })

command("DiffviewClose", function(ctx)
  diffview.close(nil, { force = ctx.bang })
end, { nargs = 0, bang = true })

command("DiffviewFocusFiles", function()
  diffview.emit("focus_files")
end, { nargs = 0 })

command("DiffviewToggleFiles", function()
  diffview.emit("toggle_files")
end, { nargs = 0 })

command("DiffviewRefresh", function(ctx)
  diffview.emit("refresh_files", ctx.bang and { force = true } or nil)
end, { nargs = 0, bang = true })

command("DiffviewLog", function()
  vim.cmd(("sp %s | norm! G"):format(
    vim.fn.fnameescape(DiffviewGlobal.logger.outfile)
  ))
end, { nargs = 0 })
