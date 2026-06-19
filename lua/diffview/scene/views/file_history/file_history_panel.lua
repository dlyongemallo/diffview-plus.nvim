local async = require("diffview.async")
local lazy = require("diffview.lazy")

local FHOptionPanel = lazy.access("diffview.scene.views.file_history.option_panel", "FHOptionPanel") ---@type FHOptionPanel|LazyModule
local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local LogEntry = lazy.access("diffview.vcs.log_entry", "LogEntry") ---@type LogEntry|LazyModule
local Panel = lazy.access("diffview.ui.panel", "Panel") ---@type Panel|LazyModule
local PerfTimer = lazy.access("diffview.perf", "PerfTimer") ---@type PerfTimer|LazyModule
local Signal = lazy.access("diffview.control", "Signal") ---@type Signal|LazyModule
local WorkPool = lazy.access("diffview.control", "WorkPool") ---@type WorkPool|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local panel_renderer = lazy.require("diffview.scene.views.file_history.render") ---@module "diffview.scene.views.file_history.render"
local renderer = lazy.require("diffview.renderer") ---@module "diffview.renderer"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger

local M = {}

---@type PerfTimer
local perf_render = PerfTimer("[FileHistoryPanel] render")
---@type PerfTimer
local perf_update = PerfTimer("[FileHistoryPanel] update")

---@alias FileHistoryPanel.CurItem { [1]: LogEntry, [2]: FileEntry }

---@class FileHistoryPanel : Panel
---@field parent FileHistoryView
---@field adapter VCSAdapter
---@field entries LogEntry[]
---@field rev_range RevRange
---@field log_options ConfigLogOptions
---@field cur_item FileHistoryPanel.CurItem
---@field single_file boolean
---@field work_pool WorkPool
---@field shutdown Signal
---@field updating boolean
---@field render_data RenderData
---@field option_panel FHOptionPanel
---@field option_mapping string
---@field help_mapping string
---@field components CompStruct
---@field constrain_cursor function
local FileHistoryPanel = oop.create_class("FileHistoryPanel", Panel.__get())

FileHistoryPanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
  },
})

FileHistoryPanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewFileHistory",
})

---@class FileHistoryPanel.init.Opt
---@field parent FileHistoryView
---@field adapter VCSAdapter
---@field entries LogEntry[]
---@field log_options LogOptions

---FileHistoryPanel constructor.
---@param opt FileHistoryPanel.init.Opt
function FileHistoryPanel:init(opt)
  local conf = config.get_config()

  self:super({
    config = conf.file_history_panel.win_config,
    bufname = "DiffviewFileHistoryPanel",
  })

  self.parent = opt.parent
  self.adapter = opt.adapter
  self.entries = opt.entries
  self.cur_item = {}
  self.single_file = opt.entries[1] and opt.entries[1].single_file
  self.work_pool = WorkPool()
  self.shutdown = Signal()
  self.updating = false
  self.option_panel = FHOptionPanel(self, self.adapter.flags)
  self.log_options = {
    single_file = vim.tbl_extend(
      "force",
      conf.file_history_panel.log_options[self.adapter.config_key].single_file,
      opt.log_options
    ),
    multi_file = vim.tbl_extend(
      "force",
      conf.file_history_panel.log_options[self.adapter.config_key].multi_file,
      opt.log_options
    ),
  }

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })
end

---@override
function FileHistoryPanel:open()
  FileHistoryPanel.super_class.open(self)
  local conf = self:get_config()
  if not (conf.type == "split" and conf.width == "auto") then
    vim.cmd("wincmd =")
  end
  if self.cur_item[2] then
    self:highlight_item(self.cur_item[2])
  end
end

---@override
---@param self FileHistoryPanel
FileHistoryPanel.destroy = async.sync_void(function(self)
  self.shutdown:send()

  await(self.work_pool)
  await(async.scheduler())

  for _, entry in ipairs(self.entries) do
    entry:destroy()
  end

  self.entries = nil
  self.cur_item = nil
  self.option_panel:destroy()
  self.option_panel = nil
  self.render_data:destroy()

  if self.components then
    renderer.destroy_comp_struct(self.components)
  end

  FileHistoryPanel.super_class.destroy(self)
end)

function FileHistoryPanel:setup_buffer()
  local conf = self:apply_keymaps("file_history_panel", { nowait = true })
  local option_keymap = config.find_option_keymap(conf.keymaps.file_history_panel)
  if option_keymap then
    self.option_mapping = option_keymap[2]
  end
  local help_keymap = config.find_help_keymap(conf.keymaps.file_history_panel)
  if help_keymap then
    self.help_mapping = help_keymap[2]
  end
end

function FileHistoryPanel:update_components()
  if not self.render_data then
    return
  end

  self.render_data:destroy()
  if self.components then
    renderer.destroy_comp_struct(self.components)
  end

  local entry_schema = { name = "entries" }
  for i, entry in ipairs(utils.vec_slice(self.entries)) do
    if self.updating and i > 128 then
      break
    end
    table.insert(entry_schema, {
      name = "entry",
      context = entry,
      { name = "commit" },
      { name = "files" },
    })
  end

  self.components = self.render_data:create_component({
    { name = "header" },
    {
      name = "log",
      { name = "title" },
      entry_schema,
    },
  }) --[[@as CompStruct ]]

  self.constrain_cursor = renderer.create_cursor_constraint({ self.components.log.entries.comp })
end

---@class FileHistoryPanel.StateSnapshot
---@field unfolded table<string, boolean> Set of unfolded entries, keyed by commit hash.
---@field cur? { hash: string, path: string } The focused file, identified by commit and path.

---Snapshot the fold and cursor state so it can be restored after a rebuild.
---Keyed by commit hash, so the synthetic working-tree entry (`nil` hash) is
---excluded; `cur` stays nil when nothing is focused.
---@return FileHistoryPanel.StateSnapshot
function FileHistoryPanel:_snapshot_state()
  local unfolded = {}

  for _, entry in ipairs(self.entries) do
    if not entry.folded and entry.commit and entry.commit.hash then
      unfolded[entry.commit.hash] = true
    end
  end

  local cur
  local cur_entry, cur_file = self.cur_item[1], self.cur_item[2]

  if cur_entry and cur_file and cur_entry.commit and cur_entry.commit.hash then
    cur = { hash = cur_entry.commit.hash, path = cur_file.path }
  end

  return { unfolded = unfolded, cur = cur }
end

---Re-apply the snapshotted fold state to the rebuilt entries and return the
---`FileEntry` to re-focus (the caller reloads its diff via `set_file`). Entries
---absent from the snapshot are left folded (the default for a fresh entry).
---
---Returns nil on an empty snapshot (first open): the streaming bootstrap has
---already focused, unfolded, and loaded the first entry, so re-folding and
---reloading it would just flash the diff. Otherwise a file is always returned
---(the previous file, else its commit's first file, else the first entry's
---first file); the bootstrap is skipped when there's state to restore, so this
---is the only thing that re-establishes the cursor and loads its diff.
---
---`pin_local` mode is left untouched: the bootstrap in `set_file_by_offset`
---already re-targets the pinned file there, and a pinned commit's focused file
---may be a transient overlay that isn't in `entry.files`.
---@param prev_state FileHistoryPanel.StateSnapshot
---@return FileEntry?
function FileHistoryPanel:_restore_state(prev_state)
  if self.parent.pin_local then
    return
  end

  -- First open: nothing to restore; keep the streaming bootstrap's result.
  if not prev_state.cur and next(prev_state.unfolded) == nil then
    return
  end

  if not self.single_file then
    for _, entry in ipairs(self.entries) do
      local hash = entry.commit and entry.commit.hash
      entry.folded = not (hash and prev_state.unfolded[hash])
    end
  end

  -- Set the cursor to `file` and return it for the caller to re-focus.
  local function focus(entry, file)
    self:set_cur_item({ entry, file })
    return file
  end

  local cur = prev_state.cur

  if cur then
    for _, entry in ipairs(self.entries) do
      if entry.commit and entry.commit.hash == cur.hash then
        -- Match on path alone: paths are unique within a commit, and rename
        -- detection (`oldpath`) can resolve differently across a refresh,
        -- which would spuriously drop the match.
        for _, file in ipairs(entry.files) do
          if file.path == cur.path then
            return focus(entry, file)
          end
        end

        -- File gone but commit survived: fall back to its first file.
        if entry.files[1] then
          return focus(entry, entry.files[1])
        end
      end
    end
  end

  -- Focused commit gone (or never set): fall back to the first entry so the
  -- cursor stays consistent with the re-applied folds.
  local first = self.entries[1]
  if first and first.files[1] then
    return focus(first, first.files[1])
  end
end

---@param self FileHistoryPanel
---@param callback function
FileHistoryPanel.update_entries = async.wrap(function(self, callback)
  perf_update:reset()
  local checkout = self.work_pool:check_in()

  -- Snapshot fold/cursor state before the rebuild so a refresh that doesn't
  -- change the history (`R`, `FugitiveChanged`) keeps the user's expanded
  -- entries and cursor instead of collapsing and snapping to the top.
  local prev_state = self:_snapshot_state()

  for _, entry in ipairs(self.entries) do
    entry:destroy()
  end

  panel_renderer.clear_cache(self)
  self.cur_item = {}
  self.entries = {}
  self.updating = true

  local layout_opt = {
    default_layout = self.parent:get_default_layout(),
    pin_local = self.parent.pin_local,
    pinned_path = self.parent.pinned_path,
    -- Closure into the view's pin_local cache: adapters call this when
    -- constructing a pinned-mode entry's b-side, so every entry across the
    -- whole history shares the same `vcs.File` instance for a given path
    -- (and therefore the same Neovim buffer state). The view owns the
    -- cache's lifetime; adapters and entries treat the returned files as
    -- borrowed (see `Diff2*Pinned.shared_symbols`).
    pinned_b_file_for = self.parent.pin_local and function(path)
      return self.parent:get_pinned_b_file(path)
    end or nil,
  }

  -- Prepend a synthetic LOCAL "commit" so the working tree appears as the
  -- top-of-log entry. The synth is omitted when the working tree is clean
  -- or when the adapter doesn't override the base no-op.
  --
  -- Path filter: in `-L` line-trace mode `adapter.ctx.path_args` is empty
  -- (the path lives in the L spec), so passing it raw would make
  -- `git diff HEAD --` pick up every dirty file in the repo. Use the
  -- adapter's `history_scope` to recover the scoped path and restrict the
  -- synth to it.
  if self.parent.pin_local then
    local raw_path_args = self.adapter.ctx.path_args or {}
    -- `self.log_options` is the `{ single_file, multi_file }` wrapper, but
    -- `history_scope` expects a flat `LogOptions` (it reads `.L` for the
    -- line-trace branch). The `L` and `path_args` fields are mirrored
    -- across both variants (seeded together in `:init`, mutated together
    -- by the option panel), so reading from the single_file form gives
    -- the right specs to recover the scoped path.
    local scope = self.adapter:history_scope(raw_path_args, self.log_options.single_file)
    local synth_path_args = (scope.single_file and scope.path) and { scope.path } or raw_path_args

    local synth = self.adapter:build_local_log_entry({
      path_args = synth_path_args,
      layout_opt = layout_opt,
      -- Pass scope's verdict directly: recomputing single_file inside the
      -- adapter from `path_args` would mismark a single-arg multi-file
      -- pathspec (e.g. `*.txt` matching multiple files) as single-file.
      single_file = scope.single_file,
    })

    if synth then
      self.entries[#self.entries + 1] = synth
      self.single_file = synth.single_file
    end
  end

  local stream = self.adapter:file_history({
    log_opt = self.log_options,
    layout_opt = layout_opt,
  })

  self:sync()

  local render = debounce.throttle_render(15, function()
    if self.shutdown:check() then
      return
    end

    local bootstrap_file
    -- Skip the bootstrap diff when a file will be restored at completion:
    -- loading the first entry here would just flash before the restore.
    if not prev_state.cur and not self:cur_file() and self:num_items() > 0 then
      bootstrap_file = self:next_file()
    end

    self:sync()

    if bootstrap_file then
      self.parent:set_file(bootstrap_file)
    end

    vim.cmd("redraw")
  end)

  local ret = {}

  for _, item in stream:iter() do
    if self.shutdown:check() then
      stream:close(self.shutdown:new_consumer())
      ret = { nil, JobStatus.KILLED }
      break
    end

    ---@type JobStatus, LogEntry?, string?
    local status, entry, msg = unpack(item, 1, 3)

    if status == JobStatus.ERROR then
      utils.err(fmt("Updating file history failed! Error message: %s", msg), true)
      ret = { nil, JobStatus.ERROR, msg }
      break
    elseif status == JobStatus.SUCCESS then
      ret = { self.entries, status }
      perf_update:time()
      logger:fmt_info(
        "[FileHistory] Completed update for %d entries successfully (%.3f ms).",
        #self.entries,
        perf_update.final_time
      )
    elseif status == JobStatus.PROGRESS then
      ---@cast entry -?
      local was_empty = #self.entries == 0
      self.entries[#self.entries + 1] = entry

      if was_empty then
        self.single_file = self.entries[1].single_file
      end

      render()
    else
      error("Unexpected state!")
    end
  end

  await(async.scheduler())
  self.updating = false

  if not self.shutdown:check() then
    -- Restore the pre-refresh folds and focused file. `set_file` loads the
    -- diff; on first open restore is a no-op and the bootstrap's diff stands.
    local restore_file = self:_restore_state(prev_state)
    self:sync()
    self.option_panel:sync()
    if restore_file then
      self.parent:set_file(restore_file)
    end
    vim.cmd("redraw")
  end

  checkout:send()
  callback(unpack(ret, 1, 3))
end)

function FileHistoryPanel:num_items()
  if self.single_file then
    return #self.entries
  else
    local count = 0

    for _, entry in ipairs(self.entries) do
      count = count + #entry.files
    end

    return count
  end
end

---@return FileEntry[]
function FileHistoryPanel:list_files()
  local files = {}

  for _, entry in ipairs(self.entries) do
    for _, file in ipairs(entry.files) do
      table.insert(files, file)
    end
  end

  return files
end

---@param file FileEntry
function FileHistoryPanel:find_entry(file)
  for _, entry in ipairs(self.entries) do
    for _, f in ipairs(entry.files) do
      if f == file then
        return entry
      end
    end
    -- Pinned-RHS overlay FileEntries are stored separately on the entry so
    -- they don't render as extra rows; we still match against them so
    -- `set_file` can route diff updates correctly.
    if entry._pin_overlays then
      for _, f in pairs(entry._pin_overlays) do
        if f == file then
          return entry
        end
      end
    end
  end
end

---Get the log or file entry under the cursor.
---@return (LogEntry|FileEntry)?
function FileHistoryPanel:get_item_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local cursor = api.nvim_win_get_cursor(self.winid)
  local line = cursor[1]
  local comp = self.components.comp:get_comp_on_line(line)

  if comp and (comp.name == "commit" or comp.name == "files") then
    local entry = comp.parent.context --[[@as table ]]

    if comp.name == "files" then
      return entry.files[line - comp.lstart]
    end

    return entry
  end
end

---Get the parent log entry of the item under the cursor.
---@return LogEntry?
function FileHistoryPanel:get_log_entry_at_cursor()
  local item = self:get_item_at_cursor()
  if not item then
    return
  end

  if item:instanceof(LogEntry.__get()) then
    return item --[[@as LogEntry ]]
  end

  return self:find_entry(item --[[@as FileEntry ]])
end

---@param new_item FileHistoryPanel.CurItem
function FileHistoryPanel:set_cur_item(new_item)
  if self.cur_item[2] then
    self.cur_item[2]:set_active(false)
  end

  self.cur_item = new_item

  if self.cur_item and self.cur_item[2] then
    self.cur_item[2]:set_active(true)
  end
end

function FileHistoryPanel:set_entry_from_file(item)
  local file = self.cur_item[2]

  if item:instanceof(LogEntry.__get()) then
    self:set_cur_item({ item, item.files[1] })
  else
    local entry = self:find_entry(file)

    if entry then
      self:set_cur_item({ entry, file })
    end
  end
end

function FileHistoryPanel:cur_file()
  return self.cur_item[2]
end

---@private
---@param entry_idx integer
---@param file_idx integer
---@param offset integer
---@param wrap boolean
---@return LogEntry?
---@return FileEntry?
function FileHistoryPanel:_get_entry_by_file_offset(entry_idx, file_idx, offset, wrap)
  local cur_entry = self.entries[entry_idx]

  if cur_entry.files[file_idx + offset] then
    return cur_entry, cur_entry.files[file_idx + offset]
  end

  local sign = utils.sign(offset)
  local delta = math.abs(offset) - (sign > 0 and #cur_entry.files - file_idx or file_idx - 1)

  if wrap then
    local i = (entry_idx + (sign > 0 and 0 or -2)) % #self.entries + 1

    while i ~= entry_idx do
      local files = self.entries[i].files

      if (#files - delta) >= 0 then
        local target_file = sign > 0 and files[delta] or files[#files - (delta - 1)]
        return self.entries[i], target_file
      end

      delta = delta - #files
      i = (i + (sign > 0 and 0 or -2)) % #self.entries + 1
    end
  else
    local i = entry_idx + sign

    while i >= 1 and i <= #self.entries do
      local files = self.entries[i].files

      if (#files - delta) >= 0 then
        local target_file = sign > 0 and files[delta] or files[#files - (delta - 1)]
        return self.entries[i], target_file
      end

      delta = delta - #files
      i = i + sign
    end

    -- Reached the boundary: return nil to signal no movement.
  end
end

function FileHistoryPanel:set_file_by_offset(offset)
  if self:num_items() == 0 then
    return
  end

  local entry, file = self.cur_item[1], self.cur_item[2]

  if not (entry and file) and self:num_items() > 0 then
    -- Bootstrap (post-rebuild / first-open). In pin_local mode this is the
    -- code path that runs after `update_entries`; pick the file matching
    -- `pinned_path` (or its overlay) so refresh/options-change preserves
    -- the user's pinned file instead of snapping to `entries[1].files[1]`.
    local first = self.entries[1]
    local target = self.parent:pick_entry_target(first) or first.files[1]
    self:set_cur_item({ first, target })
    return self.cur_item[2]
  end

  if self:num_items() > 1 then
    local entry_idx = utils.vec_indexof(self.entries, entry)
    local file_idx = utils.vec_indexof(entry.files, file)

    -- pin_local overlays (transient FileEntries built by
    -- `_resolve_pinned_target` for commits that don't touch the pinned
    -- path) aren't in `entry.files`, so `vec_indexof` returns -1 and
    -- offset navigation would silently no-op when the user is standing
    -- on an overlay. Treat the overlay's position as `entry.files[1]`
    -- so j/k/next-item/prev-item still advance the cursor.
    if
      entry_idx ~= -1
      and file_idx == -1
      and entry._pin_overlays
      and entry._pin_overlays[file.path] == file
    then
      file_idx = 1
    end

    if entry_idx ~= -1 and file_idx ~= -1 then
      local wrap = config.get_config().wrap_entries
      local next_entry, next_file =
        self:_get_entry_by_file_offset(entry_idx, file_idx, offset, wrap)

      if not next_entry then
        return
      end

      self:set_cur_item({ next_entry, next_file })

      if next_entry ~= entry then
        self:set_entry_fold(entry, false)
      end

      return self.cur_item[2]
    end
  else
    -- See the bootstrap branch above for the pin_local rationale.
    local first = self.entries[1]
    local target = self.parent:pick_entry_target(first) or first.files[1]
    self:set_cur_item({ first, target })
    return self.cur_item[2]
  end
end

function FileHistoryPanel:prev_file()
  return self:set_file_by_offset(-vim.v.count1)
end

function FileHistoryPanel:next_file()
  return self:set_file_by_offset(vim.v.count1)
end

---@param item LogEntry|FileEntry
function FileHistoryPanel:highlight_item(item)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  if item:instanceof(LogEntry.__get()) then
    ---@cast item LogEntry
    for _, comp_struct in ipairs(self.components.log.entries) do
      if comp_struct.comp.context == item then
        pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart, 0 })
      end
    end
  else
    ---@cast item FileEntry
    for _, comp_struct in ipairs(self.components.log.entries) do
      local entry = comp_struct.comp.context --[[@as LogEntry ]]
      local i = utils.vec_indexof(entry.files --[[@as FileEntry[] ]], item)

      if i ~= -1 then
        if self.single_file then
          pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart + 1, 0 })
        else
          if entry.folded then
            entry.folded = false
            self:render()
            self:redraw()
          end

          pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart + i + 1, 0 })
        end
      elseif entry._pin_overlays and entry._pin_overlays[item.path] == item then
        -- pin_local overlays are transient FileEntries that aren't rendered
        -- as their own row, so there's no file-line to land on. Park the
        -- cursor on the entry header instead so commit-navigation actions
        -- still move the visible selection in lock-step with the diff.
        pcall(api.nvim_win_set_cursor, self.winid, { comp_struct.comp.lstart, 0 })
      end
    end
  end

  -- Needed to update the cursorline highlight when the panel is not focused.
  utils.update_win(self.winid)
end

function FileHistoryPanel:highlight_prev_item()
  if not (self:is_open() and self:buf_loaded()) or #self.entries == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, -vim.v.count1),
    0,
  })

  utils.update_win(self.winid)
end

function FileHistoryPanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or #self.entries == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, vim.v.count1),
    0,
  })

  utils.update_win(self.winid)
end

---@param entry LogEntry
---@param open boolean
function FileHistoryPanel:set_entry_fold(entry, open)
  if not self.single_file and open == entry.folded then
    entry.folded = not open
    self:render()
    self:redraw()

    if not (self:is_open() and entry.folded) then
      return
    end

    -- Set the cursor at the top of the log entry.
    self.components.log.entries.comp:some(function(comp, _, _)
      if comp.context == entry then
        utils.set_cursor(self.winid, comp.lstart + 1)
        return true
      end
    end)
  end
end

---@param entry LogEntry
function FileHistoryPanel:toggle_entry_fold(entry)
  self:set_entry_fold(entry, entry.folded)
end

---@override
function FileHistoryPanel:get_autosize_components()
  if not self.components then
    return nil
  end
  return {
    self.components.log.comp,
  }
end

function FileHistoryPanel:render()
  perf_render:reset()
  panel_renderer.file_history_panel(self)
  perf_render:time()
  logger:lvl(10):debug(perf_render)
end

---@return LogOptions
function FileHistoryPanel:get_log_options()
  if self.single_file then
    return self.log_options.single_file
  else
    return self.log_options.multi_file
  end
end

M.FileHistoryPanel = FileHistoryPanel
return M
