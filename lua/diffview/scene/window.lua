local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local EventEmitter = lazy.access("diffview.events", "EventEmitter") ---@type EventEmitter|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local FileHistoryView =
  lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await, pawait = async.await, async.pawait
local fmt = string.format
local logger = DiffviewGlobal.logger

local M = {}

---@class Window : diffview.Object
---@field id integer
---@field file vcs.File
---@field parent Layout
---@field emitter EventEmitter
local Window = oop.create_class("Window")

Window.winopt_store = {}
Window._set_buf_warned = false

---@class Window.init.opt
---@field id integer
---@field file vcs.File
---@field parent Layout

---@param opt Window.init.opt
function Window:init(opt)
  self.id = opt.id
  self.file = opt.file
  self.parent = opt.parent
  self.emitter = EventEmitter()

  self.emitter:on("post_open", utils.bind(self.post_open, self))
end

function Window:destroy()
  self:_restore_winopts()
  self:close(true)
end

function Window:clone()
  return Window({ file = self.file })
end

---@return boolean
function Window:is_valid()
  return self.id and api.nvim_win_is_valid(self.id)
end

---@return boolean
function Window:is_file_open()
  return self:is_valid()
    and self.file
    and self.file:is_valid()
    and api.nvim_win_get_buf(self.id) == self.file.bufnr
end

---@param force? boolean
function Window:close(force)
  if self:is_valid() then
    api.nvim_win_close(self.id, not not force)
    self:set_id(nil)
  end
end

function Window:focus()
  if self:is_valid() then
    api.nvim_set_current_win(self.id)
  end
end

function Window:is_focused()
  return self:is_valid() and api.nvim_get_current_win() == self.id
end

function Window:post_open() end

---@param self Window
---@param callback fun(ok: boolean)
Window.load_file = async.wrap(function(self, callback)
  assert(self.file)

  if self.file:is_valid() then
    return callback(true)
  end

  -- Skip loading if the file has been deactivated (e.g. user navigated
  -- away). This avoids queueing unnecessary git jobs during rapid
  -- navigation.
  if not self.file.active then
    return callback(false)
  end

  local ok, err = pawait(self.file.create_buffer, self.file)

  if ok and not self.file:is_valid() then
    -- The buffer may have been destroyed during the await
    ok = false
    err = "The file buffer is invalid!"
  end

  if not ok then
    -- Suppress error messages for cancelled buffer creation (e.g. user
    -- navigated away during async loading).
    if err and type(err) == "string" and err:find(File.CANCELLED, 1, true) then
      logger:debug("Buffer creation cancelled for: " .. self.file.path)
    else
      logger:error(err)
      utils.err(fmt("Failed to create diff buffer: '%s:%s'", self.file.rev, self.file.path), true)
    end
  end

  callback(ok)
end)

---@private
function Window:open_fallback()
  self.emitter:emit("pre_open")

  File.load_null_buffer(self.id)
  self:apply_null_winopts()

  if self:show_winbar_info() then
    vim.wo[self.id].winbar = self.file.winbar
  else
    vim.wo[self.id].winbar = ""
  end

  self.emitter:emit("post_open")
end

---@param self Window
Window.open_file = async.void(function(self)
  ---@diagnostic disable: invisible
  assert(self.file)

  if not self:is_valid() then
    return
  end

  if not self.file:is_valid() then
    -- Skip the load entirely if the file was already deactivated by the
    -- time we got here -- the user has navigated past this target, so a
    -- fresh `git show` would be wasted work. Once the load is in flight,
    -- `create_buffer` raises `CANCELLED` on its own active checks, which
    -- surfaces as `ok = false` below.
    if not self.file.active then
      return
    end
    local ok = await(self:load_file())
    await(async.scheduler())

    -- Ensure validity after await
    if not self:is_valid() then
      return
    end

    if not ok then
      self:open_fallback()
      return
    end
  end

  -- The file is loaded; display it regardless of `self.file.active`.
  -- `Layout.open_files` yields on `async.scheduler()` between its load
  -- loop and its open loop, and a rapid navigation in that gap can
  -- deactivate the file. Bailing here on `active=false` used to leave
  -- the window holding the prior `open_null` placeholder while
  -- `file.loaded=true` claimed the buffer was ready -- a stale state
  -- that trips `jump_to_first_change` (silent `]c` on an empty buffer
  -- in the default branch; `Cursor position outside buffer` in
  -- `diff1_inline`, which looks up hunks on `file.bufnr` and writes the
  -- cursor in `main.id`'s current buffer). The buffer is already
  -- populated, so setting it in the window is cheap; the next worker
  -- iteration replaces it with the user's actual target.

  self.emitter:emit("pre_open")

  -- Disable context plugins BEFORE the buffer enters the window.
  -- This must happen before BufWinEnter fires, when context plugins decide to show.
  -- Save original state for restoration later (only for LOCAL files that we'll restore).
  if not self.file._context_state_saved then
    self.file._orig_ts_context_disable = vim.b[self.file.bufnr].ts_context_disable
    self.file._orig_context_enabled = vim.b[self.file.bufnr].context_enabled
    self.file._context_state_saved = true
  end
  vim.b[self.file.bufnr].ts_context_disable = true -- nvim-treesitter-context
  vim.b[self.file.bufnr].context_enabled = false -- context.vim

  local conf = config.get_config()
  local set_buf_ok, set_buf_err, recovered = utils.set_win_buf(self.id, self.file.bufnr)
  if recovered and not Window._set_buf_warned then
    Window._set_buf_warned = true
    utils.warn(
      "An external autocommand failed while opening a Diffview buffer. "
        .. "Diffview retried without window events.",
      true
    )
  end

  if recovered then
    logger:warn(set_buf_err)
  end

  if not set_buf_ok then
    logger:error(set_buf_err)
    self:open_fallback()
    return
  end

  -- Apply the configured foldlevel before `_save_winopts` so the saved
  -- value covers the key we're about to override. Scope this to diff
  -- buffers (where `diff` is not explicitly false), matching the
  -- documented purpose of `view.foldlevel`; non-diff layouts like
  -- `diff1_raw` opt out via `diff = false` and supply their own
  -- foldlevel via the layout winopts.
  if self.file.winopts and self.file.winopts.diff ~= false then
    self.file.winopts.foldlevel = conf.view.foldlevel
  end

  if self.file.rev.type == RevType.LOCAL then
    self:_save_winopts()
  end

  if self:is_nulled() then
    self:apply_null_winopts()
  else
    self:apply_file_winopts()
  end

  local view = lib.get_current_view()
  local disable_diagnostics = false

  if self.file.kind == "conflicting" then
    disable_diagnostics = conf.view.merge_tool.disable_diagnostics
  elseif view and FileHistoryView.__get():ancestorof(view) then
    disable_diagnostics = conf.view.file_history.disable_diagnostics
  else
    disable_diagnostics = conf.view.default.disable_diagnostics
  end

  self.file:attach_buffer(false, {
    keymaps = config.get_layout_keymaps(self.parent),
    disable_diagnostics = disable_diagnostics,
    saved_keymaps = {},
  })

  if self:show_winbar_info() then
    vim.wo[self.id].winbar = self.file.winbar
  else
    vim.wo[self.id].winbar = ""
  end

  self.emitter:emit("post_open")

  api.nvim_win_call(self.id, function()
    DiffviewGlobal.emitter:emit("diff_buf_win_enter", self.file.bufnr, self.id, {
      symbol = self.file.symbol,
      layout_name = self.parent.name,
    })
  end)
  ---@diagnostic enable: invisible
end)

---@return boolean
function Window:show_winbar_info()
  if self.file and self.file.winbar then
    local conf = config.get_config()
    local view = lib.get_current_view()

    if self.file.kind == "conflicting" then
      return conf.view.merge_tool.winbar_info
    else
      if view and view.class == FileHistoryView.__get() then
        return conf.view.file_history.winbar_info
      else
        return conf.view.default.winbar_info
      end
    end
  end

  return false
end

function Window:is_nulled()
  return self:is_valid() and api.nvim_win_get_buf(self.id) == File.NULL_FILE.bufnr
end

function Window:open_null()
  if self:is_valid() then
    self.emitter:emit("pre_open")
    File.load_null_buffer(self.id)
  end
end

function Window:detach_file()
  if self.file then
    -- Restore context plugin state for local files.
    if self.file._context_state_saved and self.file:is_valid() then
      vim.b[self.file.bufnr].ts_context_disable = self.file._orig_ts_context_disable
      vim.b[self.file.bufnr].context_enabled = self.file._orig_context_enabled
    end

    if self.file:is_valid() then
      self.file:detach_buffer()
    end
  end
end

---Check if the file buffer is in use in the current view's layout.
---@private
---@return boolean
function Window:_is_file_in_use()
  local view = lib.get_current_view() --[[@as StandardView? ]]

  if view and view.cur_layout ~= self.parent then
    local main = view.cur_layout:get_main_win()
    return main.file.bufnr ~= nil and main.file.bufnr == self.file.bufnr
  end

  return false
end

-- Options that are global-only and cannot be accessed via vim.wo.
local global_only_opts = {
  scrollopt = true,
}

function Window:_save_winopts()
  if Window.winopt_store[self.file.bufnr] then
    return
  end

  Window.winopt_store[self.file.bufnr] = {}
  for option, _ in pairs(self.file.winopts) do
    if global_only_opts[option] then
      -- Global options: save from vim.o.
      Window.winopt_store[self.file.bufnr][option] = vim.o[option]
    else
      -- Window-local options: save from vim.wo to get actual window values.
      Window.winopt_store[self.file.bufnr][option] = vim.wo[self.id][option]
    end
  end
end

function Window:_restore_winopts()
  if
    Window.winopt_store[self.file.bufnr]
    and api.nvim_buf_is_loaded(self.file.bufnr)
    and not self:_is_file_in_use()
  then
    utils.no_win_event_call(function()
      local winid = utils.temp_win(self.file.bufnr)
      utils.set_local(winid, Window.winopt_store[self.file.bufnr])

      vim.wo[winid].winbar = nil

      api.nvim_win_close(winid, true)
    end)
  end
end

function Window:apply_file_winopts()
  assert(self.file)
  if self.file.winopts then
    utils.set_local(self.id, self.file.winopts)
  end
end

function Window:apply_null_winopts()
  if File.NULL_FILE.winopts then
    utils.set_local(self.id, File.NULL_FILE.winopts)
  end

  local file_winhl = utils.tbl_access(self, "file.winopts.winhl")
  if file_winhl then
    utils.set_local(self.id, { winhl = file_winhl })
  end
end

---Use the given map of local options. These options are saved and restored
---when the file gets unloaded.
---@param opts WindowOptions
function Window:use_winopts(opts)
  if not self:is_file_open() then
    self.emitter:once("post_open", utils.bind(self.use_winopts, self, opts))
    return
  end

  local opt_store = utils.tbl_ensure(Window.winopt_store, { self.file.bufnr })

  api.nvim_win_call(self.id, function()
    for option, v in pairs(opts) do
      if opt_store[option] == nil then
        opt_store[option] = vim.o[option]
      end

      self.file.winopts[option] = v
      utils.set_local(self.id, { [option] = v })
    end
  end)
end

function Window:set_id(id)
  self.id = id
end

function Window:set_file(file)
  self.file = file
end

M.Window = Window
return M
