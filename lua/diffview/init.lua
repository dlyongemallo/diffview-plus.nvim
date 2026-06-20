if not require("diffview.bootstrap") then
  return
end

local hl = require("diffview.hl")
local lazy = require("diffview.lazy")

local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs = lazy.require("diffview.vcs") ---@module "diffview.vcs"

local api = vim.api
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

local M = {}

---@param user_config? DiffviewConfig.user
function M.setup(user_config)
  config.setup(user_config or {})
end

function M.init()
  -- Fix the strange behavior that "<afile>" expands non-files
  -- as file name in some cases.
  --
  local function get_tabnr(state)
    return tonumber(state.file)
  end

  local au = api.nvim_create_autocmd

  -- Set up highlighting
  hl.setup()

  -- Set up autocommands
  M.augroup = api.nvim_create_augroup("diffview_nvim", {})
  au("TabEnter", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      M.emit("tab_enter")
    end,
  })
  -- Throttle `FocusGained` so bursts of focus events can't drive
  -- `refresh_files` faster than it can complete.
  local refresh_files_throttled = debounce.throttle_trailing(500, true, function()
    M.emit("refresh_files")
  end)
  au("FocusGained", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      refresh_files_throttled()
    end,
  })
  au("TabLeave", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      M.emit("tab_leave")
    end,
  })
  au("TabClosed", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      -- The tab is already gone by the time this fires, so there is nothing
      -- to close: just dispose of any views whose tabpage no longer exists.
      -- Schedule it so the tabpage list has settled first.
      vim.schedule(function()
        lib.dispose_stray_views()
      end)
    end,
  })
  au("BufWritePost", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      M.emit("buf_write_post")
    end,
  })
  au("WinClosed", {
    group = M.augroup,
    pattern = "*",
    callback = function(state)
      M.emit("win_closed", get_tabnr(state))
    end,
  })
  au("ColorScheme", {
    group = M.augroup,
    pattern = "*",
    callback = function(_)
      M.update_colors()
    end,
  })
  au("User", {
    group = M.augroup,
    pattern = "FugitiveChanged",
    callback = function(_)
      M.emit("refresh_files")
    end,
  })

  -- Set up user autocommand emitters
  DiffviewGlobal.emitter:on("view_opened", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewOpened", modeline = false })
  end)
  DiffviewGlobal.emitter:on("view_closed", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewClosed", modeline = false })
  end)
  DiffviewGlobal.emitter:on("view_enter", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewEnter", modeline = false })
  end)
  DiffviewGlobal.emitter:on("view_leave", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewLeave", modeline = false })
  end)
  DiffviewGlobal.emitter:on("view_post_layout", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewViewPostLayout", modeline = false })
  end)
  DiffviewGlobal.emitter:on("diff_buf_read", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufRead", modeline = false })
  end)
  DiffviewGlobal.emitter:on("diff_buf_win_enter", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter", modeline = false })
  end)
  DiffviewGlobal.emitter:on("selection_changed", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewSelectionChanged", modeline = false })
  end)
  DiffviewGlobal.emitter:on("files_staged", function(_)
    api.nvim_exec_autocmds("User", { pattern = "DiffviewFilesStaged", modeline = false })
  end)

  -- Set up completion wrapper used by `vim.ui.input()`
  vim.cmd([[
    function! Diffview__ui_input_completion(...) abort
      return luaeval("DiffviewGlobal.state.current_completer(
            \ unpack(vim.fn.eval('a:000')))")
    endfunction
  ]])
end

---@param args string[]
function M.open(args)
  local view = lib.diffview_open(args)
  if view and not (view.tabpage and api.nvim_tabpage_is_valid(view.tabpage)) then
    view:open()
  end
end

---@param range? { [1]: integer, [2]: integer }
---@param args string[]
function M.file_history(range, args)
  local view = lib.file_history(range, args)
  if view then
    view:open()
  end
end

---@param args string[]
function M.diff_files(args)
  local view = lib.diffview_diff_files(args)
  if view then
    view:open()
  end
end

---@param args string[]
function M.merge_files(args)
  local view = lib.diffview_merge_files(args)
  if view then
    view:open()
  end
end

---@param args string[]
function M.dir_diff(args)
  local view = lib.diffview_dir_diff(args)
  if view then
    view:open()
  end
end

---@param tabpage? integer # A tabpage handle. When given, the view occupying
---that tabpage is closed (a no-op if it is not a valid tabpage); otherwise the
---view in the current tabpage is closed.
---@param opts? diffview.View.CloseOpts # Forwarded to `view:close`. With
---`force = false`, `DiffView` aborts when stage buffers are modified.
---@return boolean closed # `false` if the close was aborted.
function M.close(tabpage, opts)
  local view
  if tabpage then
    -- Only act on a live tabpage handle. This avoids closing the wrong view
    -- when a caller passes a stale handle, or a tab number that collides with
    -- some other view's handle.
    if not api.nvim_tabpage_is_valid(tabpage) then
      return true
    end
    view = lib.tabpage_to_view(tabpage)
  else
    view = lib.get_current_view()
  end

  if view then
    local closed = view:close(opts)
    if closed == false then
      return false
    end
    lib.dispose_view(view)
  end
  return true
end

---@param args string[]
function M.toggle(args)
  local view = lib.get_current_view()
  if view then
    M.close(nil, { force = false })
  else
    M.open(args)
  end
end

function M.completion(_, cmd_line, cur_pos)
  local ctx = arg_parser.scan(cmd_line, { cur_pos = cur_pos, allow_ex_range = true })
  local cmd = ctx.args[1]

  if cmd and M.completers[cmd] then
    return arg_parser.process_candidates(M.completers[cmd](ctx), ctx)
  end
end

---Create a temporary adapter to get relevant completions
---@return VCSAdapter?
function M.get_adapter()
  local cfile = pl:vim_expand("%")
  local top_indicators =
    utils.vec_join(vim.bo.buftype == "" and pl:absolute(cfile) or nil, pl:realpath("."))

  local err, adapter = vcs.get_adapter({ top_indicators = top_indicators })

  if err then
    logger:warn("[completion] Failed to create adapter: " .. err)
  end

  return adapter
end

M.completers = {
  ---@param ctx CmdLineContext
  DiffviewOpen = function(ctx)
    local has_rev_arg = false
    local adapter = M.get_adapter()

    for i = 2, math.min(#ctx.args, ctx.divideridx) do
      if ctx.args[i]:sub(1, 1) ~= "-" and i ~= ctx.argidx then
        has_rev_arg = true
        break
      end
    end

    local candidates = {}

    if ctx.argidx > ctx.divideridx then
      if adapter then
        utils.vec_extend(candidates, adapter:path_candidates(ctx.arg_lead))
      else
        utils.vec_extend(candidates, vim.fn.getcompletion(ctx.arg_lead, "file", false))
      end
    elseif adapter then
      if not has_rev_arg and ctx.arg_lead:sub(1, 1) ~= "-" then
        utils.vec_extend(candidates, adapter.comp.open:get_all_names())
        utils.vec_extend(
          candidates,
          adapter:rev_candidates(ctx.arg_lead, {
            accept_range = true,
          })
        )
      else
        utils.vec_extend(
          candidates,
          adapter.comp.open:get_completion(ctx.arg_lead) or adapter.comp.open:get_all_names()
        )
      end
    end

    return candidates
  end,
  ---@param ctx CmdLineContext
  DiffviewDiffFiles = function(ctx)
    return vim.fn.getcompletion(ctx.arg_lead, "file", false)
  end,
  ---@param ctx CmdLineContext
  DiffviewMergeFiles = function(ctx)
    return vim.fn.getcompletion(ctx.arg_lead, "file", false)
  end,
  ---@param ctx CmdLineContext
  DiffviewDiffDirs = function(ctx)
    return vim.fn.getcompletion(ctx.arg_lead, "dir", false)
  end,
  ---@param ctx CmdLineContext
  DiffviewFileHistory = function(ctx)
    local adapter = M.get_adapter()
    local candidates = {}

    if adapter then
      utils.vec_extend(
        candidates,
        adapter.comp.file_history:get_completion(ctx.arg_lead)
          or adapter.comp.file_history:get_all_names()
      )
      utils.vec_extend(candidates, adapter:path_candidates(ctx.arg_lead))
    else
      utils.vec_extend(candidates, vim.fn.getcompletion(ctx.arg_lead, "file", false))
    end

    return candidates
  end,
}

function M.update_colors()
  hl.setup()
  lib.update_colors()
end

local function _emit(no_recursion, event_name, ...)
  local view = lib.get_current_view()

  if view and not view.closing:check() then
    local that = view.emitter
    local fn = no_recursion and that.nore_emit or that.emit
    fn(that, event_name, ...)

    that = DiffviewGlobal.emitter
    fn = no_recursion and that.nore_emit or that.emit

    if event_name == "tab_enter" then
      fn(that, "view_enter", view)
    elseif event_name == "tab_leave" then
      fn(that, "view_leave", view)
    end
  end
end

function M.emit(event_name, ...)
  _emit(false, event_name, ...)
end

function M.nore_emit(event_name, ...)
  _emit(true, event_name, ...)
end

M.init()

return M
