local async = require("diffview.async")
local lazy = require("diffview.lazy")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff1Raw = lazy.access("diffview.scene.layouts.diff_1_raw", "Diff1Raw") ---@type Diff1Raw|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3") ---@type Diff3|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4") ---@type Diff4|LazyModule
local Panel = lazy.access("diffview.ui.panel", "Panel") ---@type Panel|LazyModule
local View = lazy.access("diffview.scene.view", "View") ---@type View|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

---@class StandardView : View
---@field panel Panel
---@field winopts table
---@field nulled boolean
---@field cur_layout Layout
---@field cur_entry FileEntry
---@field layouts table<Layout, Layout>
---@field package _set_file_in_flight Future? # Active `_set_file` worker; queued callers await this so `await(set_file)` returns only after the latest pending file is opened.
---@field package _set_file_pending FileEntry? # Newest file queued while `_set_file_in_flight` is set; the worker picks it up before terminating.
local StandardView = oop.create_class("StandardView", View.__get())

---StandardView constructor
function StandardView:init(opt)
  opt = opt or {}
  self:super(opt)
  self.nulled = utils.sate(opt.nulled, false)
  self.panel = opt.panel or Panel()
  self.layouts = opt.layouts or {}
  self.winopts = opt.winopts
    or {
      diff1 = { a = {} },
      -- Force `diff` and diff folding off for Diff1Raw's single window,
      -- and drop only the diff remaps that `vcs.File` prepended so the
      -- buffer reads like a normal file without clobbering any other
      -- winhl entries the user inherited from the tab/window (#515).
      -- Scroll/cursor binding are irrelevant with only one window, but
      -- explicit `false` avoids inheriting stale binding state when the
      -- layout class swaps mid-session.
      diff1_raw = {
        b = {
          diff = false,
          scrollbind = false,
          cursorbind = false,
          foldmethod = "manual",
          foldenable = true,
          foldcolumn = "0",
          foldlevel = 99,
          winhl = {
            "DiffAdd:DiffviewDiffAdd",
            "DiffDelete:DiffviewDiffDelete",
            "DiffChange:DiffviewDiffChange",
            "DiffText:DiffviewDiffText",
            opt = { method = "remove" },
          },
        },
      },
      diff2 = { a = {}, b = {} },
      diff3 = { a = {}, b = {}, c = {} },
      diff4 = { a = {}, b = {}, c = {}, d = {} },
    }

  self.emitter:on("post_layout", utils.bind(self.post_layout, self))
end

---@override
function StandardView:close()
  self.panel:destroy()
  View.close(self)
end

---@override
function StandardView:init_layout()
  local first_init = not vim.t[self.tabpage].diffview_view_initialized
  local curwin = api.nvim_get_current_win()

  self:use_layout(StandardView.get_temp_layout())
  self.cur_layout:create()
  vim.t[self.tabpage].diffview_view_initialized = true

  if first_init then
    api.nvim_win_close(curwin, false)
  end

  self.panel:focus(not self:should_show_panel())
  self.emitter:emit("post_layout")
end

---Whether the view's panel should be opened on view init. Subclasses bound
---to a specific panel type (DiffView → file_panel, FileHistoryView →
---file_history_panel) override this to read their own config block.
---@return boolean
function StandardView:should_show_panel()
  return config.get_config().file_panel.show
end

function StandardView:post_layout()
  if config.get_config().enhanced_diff_hl then
    self.winopts.diff2.a.winhl = {
      "DiffAdd:DiffviewDiffAddAsDelete",
      "DiffDelete:DiffviewDiffDeleteDim",
      "DiffChange:DiffviewDiffChange",
      "DiffText:DiffviewDiffText",
    }
    self.winopts.diff2.b.winhl = {
      "DiffDelete:DiffviewDiffDeleteDim",
      "DiffAdd:DiffviewDiffAdd",
      "DiffChange:DiffviewDiffChange",
      "DiffText:DiffviewDiffText",
    }
  end

  DiffviewGlobal.emitter:emit("view_post_layout", self)
end

---@override
---Ensure both left and right windows exist in the view's tabpage.
function StandardView:ensure_layout()
  if self.cur_layout then
    self.cur_layout:ensure()
  else
    self:init_layout()
  end
end

---@param layout Layout
function StandardView:use_layout(layout)
  self.cur_layout = layout:clone()
  self.layouts[layout.class] = self.cur_layout

  self.cur_layout.pivot_producer = function()
    local was_open = self.panel:is_open()
    local was_only_win = was_open and #utils.tabpage_list_normal_wins(self.tabpage) == 1
    self.panel:close()

    -- If the panel was the only window before closing, then a temp window was
    -- already created by `Panel:close()`.
    if not was_only_win then
      vim.cmd("1windo aboveleft vsp")
    end

    local pivot = api.nvim_get_current_win()

    if was_open then
      self.panel:open()
    end

    return pivot
  end
end

---Save the panel cursor position for later restoration.
function StandardView:save_panel_cursor()
  if self.panel:is_open() then
    local winid = self.panel.winid
    if winid and api.nvim_win_is_valid(winid) then
      self.panel_cursor = api.nvim_win_get_cursor(winid)
    end
  end
end

---Restore the panel cursor position saved by save_panel_cursor.
function StandardView:restore_panel_cursor()
  if self.panel_cursor and self.panel:is_open() then
    local winid = self.panel.winid
    if winid and api.nvim_win_is_valid(winid) then
      pcall(api.nvim_win_set_cursor, winid, self.panel_cursor)
    end
  end
end

---@param panel_was_focused boolean
function StandardView:restore_focus_after_layout_swap(panel_was_focused)
  if panel_was_focused then
    self.panel:focus(true)
  elseif self.cur_layout:is_focused() then
    self.cur_layout:get_main_win():focus()
  end
end

---@param self StandardView
---@param entry FileEntry
StandardView.use_entry = async.void(function(self, entry)
  local layout_key

  -- Check Diff1Raw before Diff1 since it's a subclass.
  if entry.layout:instanceof(Diff1Raw.__get()) then
    layout_key = "diff1_raw"
  elseif entry.layout:instanceof(Diff1.__get()) then
    layout_key = "diff1"
  elseif entry.layout:instanceof(Diff2.__get()) then
    layout_key = "diff2"
  elseif entry.layout:instanceof(Diff3.__get()) then
    layout_key = "diff3"
  elseif entry.layout:instanceof(Diff4.__get()) then
    layout_key = "diff4"
  end

  for _, sym in ipairs({ "a", "b", "c", "d" }) do
    if entry.layout[sym] then
      entry.layout[sym].file.winopts =
        vim.tbl_extend("force", entry.layout[sym].file.winopts, self.winopts[layout_key][sym] or {})
    end
  end

  local old_layout = self.cur_layout
  local panel_was_focused = self.panel:is_focused()
  self.cur_entry = entry

  if entry.layout.class == self.cur_layout.class then
    self.cur_layout.emitter = entry.layout.emitter
    await(self.cur_layout:use_entry(entry))
  else
    if self.layouts[entry.layout.class] then
      self.cur_layout = self.layouts[entry.layout.class]
      self.cur_layout.emitter = entry.layout.emitter
    else
      self:use_layout(entry.layout)
      self.cur_layout.emitter = entry.layout.emitter
    end

    await(self.cur_layout:use_entry(entry))
    local future = self.cur_layout:create()
    old_layout:destroy()

    -- Wait for files to be created + opened
    await(future)

    if not vim.o.equalalways then
      vim.cmd("wincmd =")
    end

    self:restore_focus_after_layout_swap(panel_was_focused)
  end
end)

---Set the active file. Coalesces rapid navigation: if a previous
---`_set_file` is still running (e.g., user mashing `<Tab>` faster than
---the async HEAD~ git fetch can complete), only the newest pending file
---is kept; the in-flight worker picks it up after finishing its current
---target. Without this guard, two concurrent `_set_file` coroutines
---share the same windows: the second's `Layout.use_entry` overwrites
---`win.file`, and the first's `open_file` then runs `set_win_buf`
---against the second file's bufnr while its content is still loading,
---placing an empty buffer in the window so `]c` in
---`jump_to_first_change` finds no changes and leaves the cursor at line
---1.
---
---This is a plain (non-async) function so non-awaited callers (rapid
---`next_file`/`prev_file` taps) don't spawn a wrapper task per call;
---they just update the pending slot and reuse the existing worker
---Future. Awaited callers (e.g., `set_file` from conflict resolution)
---can still `await(view:_set_file(item))` and resume only once the view
---has actually switched to the latest pending file.
---@param file FileEntry
---@return Future
function StandardView:_set_file(file)
  self._set_file_pending = file
  if self._set_file_in_flight and not self._set_file_in_flight:is_done() then
    return self._set_file_in_flight
  end
  self._set_file_in_flight = self:_drain_set_file_pending()
  return self._set_file_in_flight
end

---@param self StandardView
StandardView._drain_set_file_pending = async.void(function(self)
  while self._set_file_pending do
    local target = self._set_file_pending --[[@as FileEntry]]
    self._set_file_pending = nil

    self.panel:render()
    self.panel:redraw()
    vim.cmd("redraw")

    self:_detach_files_for_next(target)
    local cur_entry = self.cur_entry
    self.emitter:emit("file_open_pre", target, cur_entry)
    self.nulled = false

    await(self:use_entry(target))

    -- NOTE: Do NOT set foldmethod=manual on these diff windows. The
    -- combination of diff=true and foldmethod=manual triggers a Neovim bug
    -- where the screen redraw enters an infinite loop for certain buffer
    -- pairs, permanently freezing the editor. Neovim's built-in
    -- foldmethod=diff already folds unchanged regions in the diff.
    -- See: sindrets/diffview.nvim#552

    self.emitter:emit("file_open_post", target, cur_entry)

    if not self.cur_entry.opened then
      self.cur_entry.opened = true
      DiffviewGlobal.emitter:emit("file_open_new", target)
    end
  end
  self._set_file_in_flight = nil
end)

---Detach files from the current layout before switching to `next_file`.
---Subclasses override when the swap semantics differ (e.g., pinned
---layouts in `FileHistoryView` keep specific windows bound across the
---swap).
---@param next_file FileEntry
function StandardView:_detach_files_for_next(next_file) ---@diagnostic disable-line: unused-local
  self.cur_layout:detach_files()
end

M.StandardView = StandardView

return M
