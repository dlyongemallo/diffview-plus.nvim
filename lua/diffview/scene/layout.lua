local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local EventEmitter = lazy.access("diffview.events", "EventEmitter") ---@type EventEmitter|LazyModule
local Window = lazy.access("diffview.scene.window", "Window") ---@type Window|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

---@class Layout : diffview.Object
---@field windows Window[]
---@field emitter EventEmitter
---@field pivot_producer fun(): integer?
---@field name string
---@field state table
---@field symbols string[] # Set on subclasses: ordered window-slot keys (e.g. {"a","b"}).
local Layout = oop.create_class("Layout")

function Layout:init(opt)
  opt = opt or {}
  self.windows = opt.windows or {}
  self.emitter = opt.emitter or EventEmitter()
  self.state = {}
end

---@diagnostic disable: unused-local, missing-return

---@abstract
---@param self Layout
---@param pivot? integer The window ID of the window around which the layout will be created.
Layout.create = async.void(function(self, pivot)
  oop.abstract_stub()
end)

---@abstract
---@param rev Rev
---@param status string Git status symbol.
---@param sym string
---@return boolean
function Layout.should_null(rev, status, sym)
  oop.abstract_stub()
end

---Set a file on the window for the given symbol and tag it.
---@param sym string
---@param file vcs.File
function Layout:set_file_for(sym, file)
  self[sym]:set_file(file)
  file.symbol = sym
end

---Default use_entry: copy files from the entry's layout using self.symbols.
---Subclasses may override if they need different behaviour.
---@param self Layout
---@param entry FileEntry
Layout.use_entry = async.void(function(self, entry)
  local layout = entry.layout
  assert(layout:instanceof(self.class))

  for _, sym in ipairs(self.symbols) do
    self:set_file_for(sym, layout[sym].file)
  end

  if self:is_valid() then
    await(self:open_files())
  end
end)

---@abstract
---@return Window
function Layout:get_main_win()
  oop.abstract_stub()
end

---@diagnostic enable: unused-local, missing-return

function Layout:destroy()
  for _, win in ipairs(self.windows) do
    win:destroy()
  end
end

---Clear any render state the layout has layered on its buffers (e.g.
---`diff1_inline`'s extmarks). Called before the layout is replaced via
---`FileEntry:convert_layout`, since the buffers are reused by the new
---layout and would otherwise retain stale visuals. Default: no-op.
function Layout:teardown_render() end

function Layout:clone()
  local clone = self.class({ emitter = self.emitter }) --[[@as Layout ]]

  for i, win in ipairs(self.windows) do
    clone.windows[i]:set_id(win.id)
    clone.windows[i]:set_file(win.file)
  end

  return clone
end

function Layout:create_pre()
  self.state.save_equalalways = vim.o.equalalways
  vim.opt.equalalways = true
end

---@param self Layout
Layout.create_post = async.void(function(self)
  -- Immediately load null buffers to prevent flashing the pivot buffer content
  -- while waiting for async file loading (#509).
  self:open_null()
  await(self:open_files())
  vim.opt.equalalways = self.state.save_equalalways
end)

---Common window-creation helper used by concrete layout subclasses.
---@param self Layout
---@param pivot integer? Window ID to build the layout around.
---@param win_specs { [1]: string, [2]: string }[] Ordered list of { symbol, vim_cmd } pairs describing the windows to create.
---@param win_order string[] Symbols in the desired final self.windows order.
Layout.create_wins = async.void(function(self, pivot, win_specs, win_order)
  self:create_pre()
  pivot = pivot or self:find_pivot()
  assert(api.nvim_win_is_valid(pivot), "Layout creation requires a valid window pivot!")

  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      win:close(true)
    end
  end

  for _, spec in ipairs(win_specs) do
    local sym, cmd = spec[1], spec[2]
    api.nvim_win_call(pivot, function()
      vim.cmd(cmd)
      local curwin = api.nvim_get_current_win()
      if self[sym] then
        self[sym]:set_id(curwin)
      else
        self[sym] = Window({ id = curwin })
      end
    end)
  end

  api.nvim_win_close(pivot, true)
  self.windows = vim.tbl_map(function(s)
    return self[s]
  end, win_order)
  await(self:create_post())
end)

---Check if any of the windows in the lauout are focused.
---@return boolean
function Layout:is_focused()
  for _, win in ipairs(self.windows) do
    if win:is_focused() then
      return true
    end
  end

  return false
end

---@param ... Window
function Layout:use_windows(...)
  local wins = { ... }

  for i = 1, select("#", ...) do
    local win = wins[i]
    win.parent = self

    if utils.vec_indexof(self.windows, win) == -1 then
      table.insert(self.windows, win)
    end
  end
end

---Find or create a window that can be used as a pivot during layout
---creation.
---@return integer winid
function Layout:find_pivot()
  local last_win = api.nvim_get_current_win()

  for _, win in ipairs(self.windows) do
    if win:is_valid() then
      local ret

      api.nvim_win_call(win.id, function()
        vim.cmd("aboveleft vsp")
        ret = api.nvim_get_current_win()
      end)

      return ret
    end
  end

  if vim.is_callable(self.pivot_producer) then
    local ret = self.pivot_producer()

    if ret then
      return ret
    end
  end

  vim.cmd("1windo belowright vsp")

  local pivot = api.nvim_get_current_win()

  if api.nvim_win_is_valid(last_win) then
    api.nvim_set_current_win(last_win)
  end

  return pivot
end

---@return vcs.File[]
function Layout:files()
  return utils.tbl_fmap(self.windows, function(v)
    return v.file
  end)
end

---Symbols whose attached `vcs.File` is borrowed (owned elsewhere) and
---therefore must not be destroyed by `FileEntry:destroy`. Pinned variants
---set this to `{ "b" }` so the view-owned working-tree File survives entry
---teardown. Default: own everything.
---@type string[]
Layout.shared_symbols = {}

---Return the files this layout owns and is responsible for tearing down
---in `FileEntry:destroy`. Files whose symbol is listed in `shared_symbols`
---are excluded: those are owned by someone outside the entry (e.g. the
---view's pin_local cache).
---
---The default implementation walks the window-attached files for symbols
---in `self.symbols`. Subclasses with files outside the window set (e.g.
---`Diff1Inline.a_file`) MUST override `owned_files` to include them, or
---the entry teardown path will orphan those files.
---@return vcs.File[]
function Layout:owned_files()
  local skip = {}
  for _, sym in ipairs(self.shared_symbols) do
    skip[sym] = true
  end

  local out = {}
  for _, sym in ipairs(self.symbols) do
    local win = self[sym]
    if not skip[sym] and win and win.file then
      out[#out + 1] = win.file
    end
  end
  return out
end

---Look up the file the layout assigns to `sym`. Default behaviour reads
---`self[sym].file`; subclasses with files outside the window set can
---override to expose them (used by `FileEntry:convert_layout`).
---@param sym string
---@return vcs.File?
function Layout:get_file_for(sym)
  local win = self[sym]
  return win and win.file or nil
end

---Check if the buffers for all the files in the layout are loaded.
---@return boolean
function Layout:is_files_loaded()
  for _, f in ipairs(self:files()) do
    if not f:is_valid() then
      return false
    end
  end

  return true
end

---@param self Layout
Layout.open_files = async.void(function(self)
  if #self:files() < #self.windows then
    self:open_null()
    self.emitter:emit("files_opened")
    return
  end

  vim.cmd("diffoff!")

  if not self:is_files_loaded() then
    self:open_null()

    -- Wait for all files to be loaded before opening
    for _, win in ipairs(self.windows) do
      await(win:load_file())
    end
  end

  await(async.scheduler())

  for _, win in ipairs(self.windows) do
    await(win:open_file())
  end

  self:sync_scroll()
  self.emitter:emit("files_opened")
end)

function Layout:open_null()
  for _, win in ipairs(self.windows) do
    win:open_null()
  end
end

---Recover a broken layout.
---@param pivot? integer
function Layout:recover(pivot)
  pivot = pivot or self:find_pivot()
  ---@cast pivot -?

  for _, win in ipairs(self.windows) do
    if win.id ~= pivot then
      pcall(api.nvim_win_close, win.id, true)
    end
  end

  self.windows = {}
  self:create(pivot)
end

---@alias Layout.State { [Window]: boolean, valid: boolean }

---Check the validity of all composing layout windows.
---@return Layout.State
function Layout:validate()
  if not next(self.windows) then
    return { valid = false }
  end

  local state = { valid = true }

  for _, win in ipairs(self.windows) do
    state[win] = win:is_valid()
    if not state[win] then
      state.valid = false
    end
  end

  return state
end

---Check the validity if the layout.
---@return boolean
function Layout:is_valid()
  return self:validate().valid
end

---@return boolean
function Layout:is_nulled()
  if not self:is_valid() then
    return false
  end

  for _, win in ipairs(self.windows) do
    if not win:is_nulled() then
      return false
    end
  end

  return true
end

---Validate the layout and recover if necessary. Recover is only ever
---triggered against the `StandardView.cur_layout`, and `use_entry`
---publishes a new layout to `cur_layout` only AFTER its `create` future
---has fully resolved (and the old layout has been destroyed), so a
---call to `ensure` cannot land on a layout that is still mid-swap.
function Layout:ensure()
  local state = self:validate()

  if not state.valid then
    self:recover()
  end
end

---Save window local options.
function Layout:save_winopts()
  for _, win in ipairs(self.windows) do
    win:_save_winopts()
  end
end

---Restore saved window local options.
function Layout:restore_winopts()
  for _, win in ipairs(self.windows) do
    win:_restore_winopts()
  end
end

function Layout:detach_files()
  for _, win in ipairs(self.windows) do
    win:detach_file()
  end
end

---Variant of `detach_files` invoked by views during entry-to-entry swaps,
---where pinned variants want to keep specific windows bound across the
---swap. For symbols listed in `shared_symbols`, only detach when the next
---entry's same-symbol file is a different instance (multi-file pinning
---crossing rows), and never detach without a `next_entry` to compare
---against -- mirrors the pre-fix behaviour for legacy callers that
---haven't migrated to the new signature. All other symbols are detached
---unconditionally, matching the default tab-leave/view-close teardown.
---@param next_entry? FileEntry
function Layout:detach_files_for_swap(next_entry)
  local shared = {}
  for _, sym in ipairs(self.shared_symbols) do
    shared[sym] = true
  end

  for _, sym in ipairs(self.symbols) do
    local win = self[sym]
    if win then
      if shared[sym] then
        if next_entry then
          local next_layout = next_entry.layout
          local next_win = next_layout and next_layout[sym]
          local next_file = next_win and next_win.file
          if win.file ~= next_file then
            win:detach_file()
          end
        end
      else
        win:detach_file()
      end
    end
  end
end

---Sync the scrollbind.
function Layout:sync_scroll()
  local curwin = api.nvim_get_current_win()
  local target, max = nil, 0

  for _, win in ipairs(self.windows) do
    local lcount = api.nvim_buf_line_count(api.nvim_win_get_buf(win.id))
    if lcount > max then
      target, max = win, lcount
    end
  end

  local main_win = self:get_main_win()
  local cursor = api.nvim_win_get_cursor(main_win.id)

  for _, win in ipairs(self.windows) do
    api.nvim_win_call(win.id, function()
      if win == target then
        -- Scroll to trigger the scrollbind and sync the windows. This works more
        -- consistently than calling `:syncbind`.
        vim.cmd("norm! " .. api.nvim_replace_termcodes("<c-e><c-y>", true, true, true))
      end

      if win.id ~= curwin then
        api.nvim_exec_autocmds("WinLeave", { modeline = false })
      end
    end)
  end

  -- Cursor will sometimes move +- the value of 'scrolloff'
  if target ~= nil then
    api.nvim_win_set_cursor(target.id, cursor)
  end
end

M.Layout = Layout
return M
