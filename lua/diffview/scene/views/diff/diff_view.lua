local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local CommitLogPanel = lazy.access("diffview.ui.panels.commit_log_panel", "CommitLogPanel") ---@type CommitLogPanel|LazyModule
local Diff = lazy.access("diffview.diff", "Diff") ---@type Diff|LazyModule
local EditToken = lazy.access("diffview.diff", "EditToken") ---@type EditToken|LazyModule
local EventName = lazy.access("diffview.events", "EventName") ---@type EventName|LazyModule
local FileDict = lazy.access("diffview.vcs.file_dict", "FileDict") ---@type FileDict|LazyModule
local FileEntry = lazy.access("diffview.scene.file_entry", "FileEntry") ---@type FileEntry|LazyModule
local FilePanel = lazy.access("diffview.scene.views.diff.file_panel", "FilePanel") ---@type FilePanel|LazyModule
local PerfTimer = lazy.access("diffview.perf", "PerfTimer") ---@type PerfTimer|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local debounce = lazy.require("diffview.debounce") ---@module "diffview.debounce"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local GitAdapter = lazy.access("diffview.vcs.adapters.git", "GitAdapter") ---@type GitAdapter|LazyModule

local api = vim.api
local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

local rev_lib = lazy.require("diffview.vcs.rev") ---@module "diffview.vcs.rev"
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule

local M = {}

local same_rev = lazy.access(rev_lib, "same_rev") --[[@as fun(a: Rev?, b: Rev?): boolean ]]

local function rev_to_panel_name(adapter, rev_arg, left, right)
  if adapter.rev_to_panel_name then
    return adapter:rev_to_panel_name(rev_arg, left, right)
  end

  return rev_arg or adapter:rev_to_pretty_string(left, right)
end

---@class DiffViewOptions
---@field show_untracked? boolean
---@field selected_file? string Path to the preferred initially selected file.
---@field selected_row? integer Row to position the cursor on after opening the selected file.

---@class DiffView : StandardView
---@operator call : DiffView
---@field adapter VCSAdapter
---@field rev_arg string
---@field path_args string[]
---@field left Rev
---@field right Rev
---@field options DiffViewOptions
---@field panel FilePanel
---@field commit_log_panel CommitLogPanel
---@field files FileDict
---@field file_idx integer
---@field merge_ctx? vcs.MergeContext
---@field initialized boolean
---@field valid boolean
---@field update_needed? boolean # Set by external listeners to force a refresh on next redraw.
---@field watcher uv_fs_poll_t # UV fs poll handle.
local DiffView = oop.create_class("DiffView", StandardView.__get())

---DiffView constructor
function DiffView:init(opt)
  self.valid = false
  self.files = FileDict()
  self.adapter = opt.adapter
  self.path_args = opt.path_args
  self.rev_arg = opt.rev_arg
  self.left = opt.left
  self.right = opt.right
  self.no_panel = opt.no_panel
  self.initialized = false
  self.is_loading = true
  self.options = opt.options or {}
  self.options.selected_file = self.options.selected_file
    and pl:chain(self.options.selected_file):absolute():relative(self.adapter.ctx.toplevel):get()

  self:super({
    panel = FilePanel(
      self.adapter,
      self.files,
      self.path_args,
      rev_to_panel_name(self.adapter, self.rev_arg, self.left, self.right)
    ),
  })

  self.attached_bufs = {}
  DiffView._seed_cursor_map_from_selection(self.cursor_map, self.options)

  self.emitter:on("file_open_post", utils.bind(self.file_open_post, self))
  self:_init_selection_events()
  self.valid = true
end

function DiffView:post_open()
  vim.cmd("redraw")

  self:init_event_listeners()

  self.commit_log_panel = CommitLogPanel(self, self.adapter, {
    name = fmt("diffview://%s/log/%d/%s", self.adapter.ctx.dir, self.tabpage, "commit_log"),
  })

  if config.get_config().watch_index and self.adapter:instanceof(GitAdapter.__get()) then
    local index_path = self.adapter.ctx.dir .. "/index"
    self.watcher = assert(vim.uv.new_fs_poll(), "Failed to create fs poll handle!")

    -- The git index always ends with a SHA-1 (20B) or SHA-256 (32B) checksum
    -- of the preceding content, so reading its trailing bytes gives a cheap
    -- content fingerprint. We use it to short-circuit spurious mtime updates
    -- where the index was rewritten but its content didn't actually change
    -- (e.g., another process touching the file, or git refreshing an empty
    -- stat diff). Without this guard, the 1 s poll can drive `update_files`
    -- repeatedly even when nothing of interest has changed, causing visible
    -- panel/diff flicker.
    local function read_index_trailer()
      local fd = vim.uv.fs_open(index_path, "r", 0)
      if not fd then
        return nil
      end
      local stat = vim.uv.fs_fstat(fd)
      if not stat then
        vim.uv.fs_close(fd)
        return nil
      end
      local offset = math.max(0, stat.size - 32)
      local data = vim.uv.fs_read(fd, 32, offset)
      vim.uv.fs_close(fd)
      return data
    end

    local last_trailer = read_index_trailer()
    local refreshing = false
    local change_during_refresh = false

    -- Snapshot the trailer *after* our own refresh completes so any writes
    -- the refresh triggered (e.g., `git diff --name-status` refreshing stat
    -- info on a dirty worktree) don't re-fire this watcher on the next
    -- tick and drive a 1 Hz feedback loop. Without this, an external
    -- process that modifies a tracked file (a backup/sync/auto-save tool)
    -- only has to dirty the worktree once: every subsequent diff refresh
    -- writes the index, which trips the watcher, which schedules another
    -- refresh, which writes the index again, indefinitely.
    --
    -- If a poll observed a *new* trailer while a refresh was in flight,
    -- `change_during_refresh` is set; in that case we must not absorb the
    -- post-refresh trailer (it may belong to an external write the UI
    -- hasn't reflected yet), so we re-schedule another refresh.
    local on_completion, start_refresh

    start_refresh = function()
      refreshing = true
      self:update_files(nil, function(err)
        -- `update_files_impl` invokes its callback with an `err` table on
        -- cancellation (view closing / off-tabpage) or git failure, and
        -- does *not* emit "files_updated" in those paths. Leaving
        -- `last_trailer` unchanged ensures the next poll tick re-detects
        -- the change and retries, instead of absorbing a trailer whose
        -- contents never made it to the UI.
        if err then
          refreshing = false
          change_during_refresh = false
          return
        end
        on_completion()
      end)
    end

    on_completion = function()
      -- `update_files_impl` emits "files_updated" *and* invokes the callback
      -- on success, so this fires twice per refresh. The `not refreshing`
      -- guard makes the second call a no-op.
      if not refreshing then
        return
      end
      refreshing = false
      if change_during_refresh then
        change_during_refresh = false
        -- Defer the follow-up via `vim.schedule` so the second `on_completion`
        -- call (whichever of the callback or emitter fires last) sees
        -- `refreshing = false` and hits the no-op guard above, instead of the
        -- synchronous `start_refresh()` flipping it back to true.
        vim.schedule(function()
          if not self.closing:check() and self:is_cur_tabpage() then
            start_refresh()
          end
        end)
      else
        last_trailer = read_index_trailer()
      end
    end

    -- "files_updated" fires on any successful refresh, not just the ones
    -- we initiated via `start_refresh`. We need to handle both:
    --
    --   * Watcher-initiated refreshes: route through `on_completion` so
    --     the `change_during_refresh` race is honoured. This also acts as
    --     belt-and-suspenders for `update_files`'s `debounce_trailing(100,
    --     ...)`, which silently drops intermediate calls' callbacks when
    --     several invocations coalesce within the debounce window.
    --   * Other refresh paths (the initial `self:update_files()` in the
    --     `vim.schedule` block below, the GitSignsChanged autocmd): these
    --     can rewrite the index and change the trailer, so we must absorb
    --     it here. Otherwise `last_trailer` stays stale and the next poll
    --     tick observes a "new" trailer, scheduling a redundant refresh.
    --
    -- The emitter passes a `FileDict`, which we drop via the wrapper;
    -- error/cancellation paths never emit "files_updated" and are handled
    -- by the `start_refresh` callback above.
    self.emitter:on("files_updated", function()
      if refreshing then
        on_completion()
      else
        last_trailer = read_index_trailer()
      end
    end)

    self.watcher:start(
      index_path,
      1000,
      vim.schedule_wrap(function(err)
        if err then
          return
        end
        local new_trailer = read_index_trailer()
        if new_trailer == last_trailer then
          return
        end
        if refreshing then
          -- An external change landed mid-refresh. Don't absorb it on
          -- completion; `on_completion` will chase it with another
          -- refresh.
          change_during_refresh = true
          return
        end
        if self:is_cur_tabpage() then
          start_refresh()
        else
          -- Off-tabpage: `update_files` would no-op anyway, so just absorb
          -- the new fingerprint to avoid re-firing on the same change until
          -- the user returns and triggers their own refresh.
          last_trailer = new_trailer
        end
      end)
    )

    -- Listen for gitsigns repository-changing actions (hunk stage/unstage/reset)
    -- to refresh the panel immediately instead of waiting for index polling.
    -- Unlike GitSignsUpdate (which fires on every buffer enter and caused
    -- spurious refreshes), GitSignsChanged only fires on actual repo changes.
    self._gitsigns_augroup =
      api.nvim_create_augroup("diffview_gitsigns_" .. self.tabpage, { clear = true })
    api.nvim_create_autocmd("User", {
      group = self._gitsigns_augroup,
      pattern = "GitSignsChanged",
      callback = function()
        if not self.closing:check() and self:is_cur_tabpage() then
          self:update_files()
        end
      end,
    })
  end

  vim.schedule(function()
    self:file_safeguard()
    if self.files:len() == 0 then
      self:update_files()
    else
      -- Files were pre-populated (e.g., by an integrating plugin via
      -- CDiffView). Clear the loading state so the panel can render.
      self.is_loading = false
      self.panel.is_loading = false
      self.panel:update_components()
      self.panel:render()
      self.panel:redraw()
      self.emitter:emit("files_updated", self.files)
    end
    self.ready = true
  end)
end

---@param e Event
---@param new_entry FileEntry
---@param old_entry FileEntry
---@diagnostic disable-next-line: unused-local
function DiffView:file_open_post(e, new_entry, old_entry)
  if new_entry.layout:is_nulled() then
    return
  end
  if new_entry.kind == "conflicting" then
    local file = new_entry.layout:get_main_win().file

    local count_conflicts = vim.schedule_wrap(function()
      local conflicts = vcs_utils.parse_conflicts(api.nvim_buf_get_lines(file.bufnr, 0, -1, false))

      new_entry.stats = new_entry.stats or {}
      new_entry.stats.conflicts = #conflicts

      self.panel:render()
      self.panel:redraw()
    end)

    count_conflicts()

    if file.bufnr and not self.attached_bufs[file.bufnr] then
      self.attached_bufs[file.bufnr] = true

      local work = debounce.throttle_trailing(
        1000,
        true,
        vim.schedule_wrap(function()
          if not self:is_cur_tabpage() or self.cur_entry ~= new_entry then
            self.attached_bufs[file.bufnr] = false
            return
          end

          count_conflicts()
        end)
      )

      api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = file.bufnr,
        callback = function()
          if not self.attached_bufs[file.bufnr] then
            work:close()
            return true
          end

          work()
        end,
      })
    end
  end
end

---Wire up selection change events and, when enabled, persistence.
function DiffView:_init_selection_events()
  local conf = config.get_config()
  local persist = conf.persist_selections and conf.persist_selections.enabled

  if persist then
    local selection_store = require("diffview.selection_store")
    self._selection_scope_key = selection_store.scope_key(self.adapter.ctx.toplevel, self.rev_arg)

    -- Load previously saved selections.
    local saved = selection_store.load(self._selection_scope_key)
    for _, key in ipairs(saved) do
      self.panel.selected_files[key] = true
    end

    -- Debounced save (500ms trailing).
    self._save_selections = debounce.debounce_trailing(500, false, function()
      self:_save_selections_now()
    end)
  end

  -- Always wire the panel callback so the User event fires regardless of
  -- whether persistence is enabled.
  self.panel.on_selection_changed = function(_)
    if self._save_selections then
      self._save_selections()
    end
    DiffviewGlobal.emitter:emit("selection_changed", self)
  end
end

---Immediately persist current selections to disk.
function DiffView:_save_selections_now()
  if not self._selection_scope_key then
    return
  end
  local selection_store = require("diffview.selection_store")
  local keys = vim.tbl_keys(self.panel.selected_files)
  table.sort(keys)
  selection_store.save(self._selection_scope_key, keys)
end

---Replace the revision range for this view in-place and refresh the file
---list.  Existing file selections are preserved for files whose paths
---still appear in the new diff.
---
---NOTE: The underlying `update_files()` is gated on the view's tabpage
---being focused.  If this view is not in the current tabpage the state
---(rev_arg, left, right, scope key) will be updated immediately but the
---file list refresh will be deferred until the view regains focus.
---
---@param new_rev_arg string New revision argument (e.g. "abc123..def456").
---@param opts? { cached?: boolean, imply_local?: boolean, merge_base?: boolean }
function DiffView:set_revs(new_rev_arg, opts)
  opts = opts or {}
  local new_left, new_right = self.adapter:parse_revs(new_rev_arg, opts)
  if not (new_left and new_right) then
    logger:error("[DiffView] Failed to parse new rev arg: " .. tostring(new_rev_arg))
    return
  end

  -- Persist selections under the old scope key before switching.
  if self._save_selections then
    self:_save_selections_now()
  end

  -- Update the view identity.
  self.rev_arg = new_rev_arg
  self.left = new_left
  self.right = new_right
  self.panel.rev_pretty_name = rev_to_panel_name(self.adapter, new_rev_arg, self.left, self.right)

  -- Migrate selection persistence to the new scope key.
  if self._selection_scope_key then
    local selection_store = require("diffview.selection_store")
    local old_scope = self._selection_scope_key
    self._selection_scope_key = selection_store.scope_key(self.adapter.ctx.toplevel, new_rev_arg)

    -- If the new scope already has saved selections, merge them with the
    -- current in-memory set so nothing is lost.
    if old_scope ~= self._selection_scope_key then
      local saved = selection_store.load(self._selection_scope_key)
      for _, key in ipairs(saved) do
        self.panel.selected_files[key] = true
      end

      -- Persist under the new scope key so selections survive a restart.
      -- The update_files() machinery will trigger another save via
      -- prune_selections if any stale entries need removing.
      self:_save_selections_now()
    end
  end

  -- Refresh files.  The existing update_files machinery diffs old entries
  -- against new ones and replaces those whose revisions changed, which
  -- disposes stale buffers and lazily loads new content.
  self:update_files()
end

---Collect paths of file entries whose STAGE-rev sub-buffers have unsaved
---edits. Used by `close` (via `can_close`) to decide whether to abort, and
---by the BufWritePost auto-close retry path to silently re-check the gate
---without warning on every save.
---@return string[]
function DiffView:_modified_stage_paths()
  local paths = {}
  for _, file in self.files:iter() do
    for _, f in ipairs(file.layout:files()) do
      if
        f.rev.type == RevType.STAGE
        and f.bufnr
        and api.nvim_buf_is_loaded(f.bufnr)
        and vim.bo[f.bufnr].modified
      then
        paths[#paths + 1] = file.path
        break
      end
    end
  end
  return paths
end

---Pre-flight gate for `close`: returns whether a guarded close would be
---allowed to proceed *now*, surfacing the same warning as `close` would on
---abort. Use this from callers that have visible side effects which must be
---ordered around the close (e.g. `goto_file_edit_close` navigates first and
---would otherwise strand the user if the close aborts).
---@param opts? diffview.View.CloseOpts
---@return boolean ok
function DiffView:can_close(opts)
  opts = opts or {}
  local force = opts.force
  if force == nil then
    force = true
  end
  if force then
    return true
  end

  local modified = self:_modified_stage_paths()
  if #modified > 0 then
    utils.err(
      ("Stage buffer(s) have unsaved changes: %s. Use :DiffviewClose! to discard, or :write to apply to the index."):format(
        table.concat(modified, ", ")
      )
    )
    return false
  end
  return true
end

---@override
---@param opts? diffview.View.CloseOpts # `force = true` (default) bypasses the
---unsaved-stage-edit check, mirroring the `:DiffviewClose!` semantics.
---@return boolean closed # `false` if the close was aborted.
function DiffView:close(opts)
  if not self:can_close(opts) then
    return false
  end

  if not self.closing:check() then
    self.closing:send()

    -- Final save and clean up the debounced handle.
    if self._save_selections then
      self:_save_selections_now()
      self._save_selections:close()
      self._save_selections = nil
    end

    if self.watcher then
      self.watcher:stop()
      self.watcher:close()
    end

    if self._gitsigns_augroup then
      api.nvim_del_augroup_by_id(self._gitsigns_augroup)
    end

    for _, file in self.files:iter() do
      file:destroy()
    end

    -- Clean up LOCAL buffers created by diffview that the user didn't have open before.
    if config.get_config().clean_up_buffers then
      for bufnr, _ in pairs(File.created_bufs) do
        if api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modified then
          -- Only delete if not displayed in a window outside this tabpage.
          local dominated = true
          for _, winid in ipairs(utils.win_find_buf(bufnr, 0)) do
            if api.nvim_win_get_tabpage(winid) ~= self.tabpage then
              dominated = false
              break
            end
          end

          if dominated then
            pcall(api.nvim_buf_delete, bufnr, { force = false })
          end
        end

        File.created_bufs[bufnr] = nil
      end
    end

    self.commit_log_panel:destroy()
    DiffView.super_class.close(self)
  end
  return true
end

---Open the next file.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
---@return FileEntry?
function DiffView:next_file(highlight)
  self:ensure_layout()

  if self:file_safeguard() then
    return
  end

  if self.files:len() > 1 or self.nulled then
    local cur = self.panel:next_file()

    if cur then
      if highlight or not self.panel:is_focused() then
        self.panel:highlight_file(cur)
      end

      self:_set_file(cur)

      return cur
    end
  end
end

---Open the previous file.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
---@return FileEntry?
function DiffView:prev_file(highlight)
  self:ensure_layout()

  if self:file_safeguard() then
    return
  end

  if self.files:len() > 1 or self.nulled then
    local cur = self.panel:prev_file()

    if cur then
      if highlight or not self.panel:is_focused() then
        self.panel:highlight_file(cur)
      end

      self:_set_file(cur)

      return cur
    end
  end
end

---Set the active file.
---@param self DiffView
---@param file FileEntry
---@param focus? boolean Bring focus to the diff buffers.
---@param highlight? boolean|nil true=force highlight, false=suppress, nil=auto (highlight when panel not focused).
DiffView.set_file = async.void(function(self, file, focus, highlight)
  ---@diagnostic disable: invisible
  self:ensure_layout()

  if self:file_safeguard() or not file then
    return
  end

  for _, f in self.files:iter() do
    if f == file then
      self.panel:set_cur_file(file)

      if highlight ~= false and (highlight or not self.panel:is_focused()) then
        self.panel:highlight_file(file)
      end

      await(self:_set_file(file))

      if focus then
        api.nvim_set_current_win(self.cur_layout:get_main_win().id)
      end
    end
  end
  ---@diagnostic enable: invisible
end)

---Set the active file.
---@param self DiffView
---@param path string
---@param focus? boolean Bring focus to the diff buffers.
---@param highlight? boolean Bring the cursor to the file entry in the panel.
DiffView.set_file_by_path = async.void(function(self, path, focus, highlight)
  ---@type FileEntry
  for _, file in self.files:iter() do
    if file.path == path then
      await(self:set_file(file, focus, highlight))
      return
    end
  end
end)

---Get an updated list of files.
---@param self DiffView
---@param callback fun(err?: string[], files: FileDict)
DiffView.get_updated_files = async.wrap(function(self, callback)
  vcs_utils.diff_file_list(self.adapter, self.left, self.right, self.path_args, self.options, {
    default_layout = DiffView.get_default_layout(),
    merge_layout = DiffView.get_default_merge_layout(),
  }, callback)
end)

---Seed `cursor_map` from `--selected-row`/`--selected-file` so the first-open
---listener handles it the same as session-restored state. `winrestview` (the
---consumer in `restore_main_view`) clamps the upper bound; we clamp the
---lower at 1 so non-positive rows don't reach `nvim_win_set_cursor`.
---@param cursor_map table<string, table>
---@param options DiffViewOptions
function DiffView._seed_cursor_map_from_selection(cursor_map, options)
  if options.selected_row and options.selected_file then
    cursor_map[options.selected_file] = { lnum = math.max(1, options.selected_row) }
  end
end

---Determine whether to focus the diff window on initial open.
---@param next_file FileEntry?
---@return boolean
function DiffView:_should_focus_diff(next_file)
  if self.initialized then
    return false
  end
  local conf = config.get_config()
  local view_conf = next_file and next_file.kind == "conflicting" and conf.view.merge_tool
    or conf.view.default
  return view_conf.focus_diff
end

-- Update the file list, including stats and status for all files.
--
-- When `opts.force` is true, entries that would otherwise be updated in place
-- are replaced (destroyed and recreated) when they include a STAGE-rev side,
-- discarding any unsaved edits in those stage buffers. This powers
-- `actions.refresh_files({ force = true })`. LOCAL working-tree buffers are
-- unaffected.
local update_files_impl = debounce.debounce_trailing(
  100,
  true,
  ---@param self DiffView
  ---@param opts { force?: boolean }
  ---@param callback fun(err?: string[])
  async.wrap(function(self, opts, callback)
    -- Never update if the view is closing (prevents coroutine failure from race conditions).
    if self.closing:check() then
      callback({ "The update was cancelled." })
      return
    end

    await(async.scheduler())

    -- Never update unless the view is in focus
    if self.closing:check() or self.tabpage ~= api.nvim_get_current_tabpage() then
      callback({ "The update was cancelled." })
      return
    end

    ---@type PerfTimer
    local perf = PerfTimer("[DiffView] Status Update")
    self:ensure_layout()

    local new_left, new_right = self.adapter:refresh_revs(self.rev_arg, self.left, self.right)
    if new_left and new_right then
      self.left = new_left
      self.right = new_right
    end
    perf:lap("refreshed revs")

    -- If left is tracking HEAD: Update HEAD rev.  This applies regardless
    -- of the right side's type, since a cached/staged view (right = STAGE)
    -- also needs its left refreshed when HEAD moves.
    local new_head
    if self.left.track_head then
      new_head = self.adapter:head_rev()
      if new_head and self.left.commit ~= new_head.commit then
        self.left = new_head
      else
        new_head = nil
      end
      perf:lap("updated head rev")
    end

    self.panel.rev_pretty_name =
      rev_to_panel_name(self.adapter, self.rev_arg, self.left, self.right)
    perf:lap("updated rev label")

    local index_stat = pl:stat(pl:join(self.adapter.ctx.dir, "index"))

    ---@type string[]?, FileDict
    local err, new_files = await(self:get_updated_files())
    await(async.scheduler())

    if err then
      utils.err("Failed to update files in a diff view!", true)
      logger:error("[DiffView] Failed to update files!")
      self.is_loading = false
      self.panel.is_loading = false
      self.panel:render()
      self.panel:redraw()
      callback(err)
      return
    end

    -- Stop the update if the view is closing or no longer in focus.
    if self.closing:check() or self.tabpage ~= api.nvim_get_current_tabpage() then
      callback({ "The update was cancelled." })
      return
    end

    perf:lap("received new file list")

    local prev_cur_file = self.panel.cur_file

    local files = {
      { cur_files = self.files.conflicting, new_files = new_files.conflicting },
      { cur_files = self.files.working, new_files = new_files.working },
      { cur_files = self.files.staged, new_files = new_files.staged },
    }

    for _, v in ipairs(files) do
      -- We diff the old file list against the new file list in order to find
      -- the most efficient way to morph the current list into the new. This
      -- way we avoid having to discard and recreate buffers for files that
      -- exist in both lists.
      ---@param aa FileEntry
      ---@param bb FileEntry
      local diff = Diff(v.cur_files, v.new_files, function(aa, bb)
        return aa.path == bb.path and aa.oldpath == bb.oldpath
      end)

      local script = diff:create_edit_script()
      local ai = 1
      local bi = 1

      for _, opr in ipairs(script) do
        if opr == EditToken.NOOP then
          local old_file = v.cur_files[ai]
          local new_file = v.new_files[bi]

          -- Guard against nil entries that can occur during async race conditions (#395).
          if old_file and new_file then
            local replace_noop = self.adapter:force_entry_refresh_on_noop(self.left, self.right)

            -- Force-refresh recreates buffers for entries that include a
            -- STAGE-rev side. STAGE buffers are diffview-virtual: edits to
            -- them only apply to the index when the user runs `:write`, so
            -- discarding unsaved edits here matches the documented
            -- semantics of `actions.refresh_files({ force = true })`.
            -- LOCAL buffers are intentionally excluded (the user can
            -- `:edit!` them via the standard Vim mechanism), and
            -- COMMIT/HEAD buffers have no editable state to drop.
            if not replace_noop and opts.force then
              for _, f in ipairs(old_file.layout:files()) do
                if f.rev.type == RevType.STAGE then
                  replace_noop = true
                  break
                end
              end
            end

            -- Even with a stable path, rev endpoints can change on refresh
            -- (e.g. symbolic revs like `master...@`). Replace the entry so
            -- the displayed content comes from the latest rev pair.
            if not replace_noop then
              replace_noop = not (
                same_rev(utils.tbl_access(old_file, "revs.a"), utils.tbl_access(new_file, "revs.a"))
                and same_rev(
                  utils.tbl_access(old_file, "revs.b"),
                  utils.tbl_access(new_file, "revs.b")
                )
                and same_rev(
                  utils.tbl_access(old_file, "revs.c"),
                  utils.tbl_access(new_file, "revs.c")
                )
                and same_rev(
                  utils.tbl_access(old_file, "revs.d"),
                  utils.tbl_access(new_file, "revs.d")
                )
              )
            end

            if replace_noop then
              if self.panel.cur_file == old_file then
                self.panel:set_cur_file(new_file)
              end

              old_file:destroy(true)
              v.cur_files[ai] = new_file
            else
              -- Update status and stats
              local a_stats = old_file.stats
              local b_stats = new_file.stats

              if a_stats then
                old_file.stats = vim.tbl_extend("force", a_stats, b_stats or {})
              else
                old_file.stats = new_file.stats
              end

              old_file.status = new_file.status
              old_file:validate_stage_buffers(index_stat)

              if new_head then
                old_file:update_heads(new_head)
              end
            end
          end

          ai = ai + 1
          bi = bi + 1
        elseif opr == EditToken.DELETE then
          local cur_file = v.cur_files[ai]
          if cur_file then
            if self.panel.cur_file == cur_file then
              local file_list = self.panel:ordered_file_list()
              if file_list[1] == self.panel.cur_file then
                self.panel:set_cur_file(nil)
              else
                self.panel:set_cur_file(self.panel:prev_file())
              end
            end

            cur_file:destroy()
            table.remove(v.cur_files, ai)
          end
        elseif opr == EditToken.INSERT then
          local new_file = v.new_files[bi]
          if new_file then
            table.insert(v.cur_files, ai, new_file)
            ai = ai + 1
          end
          bi = bi + 1
        elseif opr == EditToken.REPLACE then
          local cur_file = v.cur_files[ai]
          local new_file = v.new_files[bi]

          if cur_file then
            if self.panel.cur_file == cur_file then
              local file_list = self.panel:ordered_file_list()
              if file_list[1] == self.panel.cur_file then
                self.panel:set_cur_file(nil)
              else
                self.panel:set_cur_file(self.panel:prev_file())
              end
            end

            cur_file:destroy()
          end

          if new_file then
            v.cur_files[ai] = new_file
          end
          ai = ai + 1
          bi = bi + 1
        end
      end
    end

    perf:lap("updated file list")

    self.merge_ctx = next(new_files.conflicting) and self.adapter:get_merge_context() or nil

    if self.merge_ctx then
      for _, entry in ipairs(self.files.conflicting) do
        entry:update_merge_context(self.merge_ctx)
      end
    end

    FileEntry.update_index_stat(self.adapter, index_stat)
    self.files:update_file_trees()
    self.panel:update_components()
    -- Clear the loading state before rendering so the first paint shows
    -- the file list directly rather than another frame of "Fetching
    -- changes...". `redraw()` (via `renderer.render()`) then populates
    -- the file components' `lstart`/`lend`/`height` fields that
    -- `reconstrain_cursor` (below) relies on to clamp the cursor row.
    self.is_loading = false
    self.panel.is_loading = false
    self.panel:render()
    self.panel:redraw()
    perf:lap("panel redrawn")
    self.panel:reconstrain_cursor()

    local prev_panel_cur_file = self.panel.cur_file

    if utils.vec_indexof(self.panel:ordered_file_list(), self.panel.cur_file) == -1 then
      self.panel:set_cur_file(nil)
    end

    -- Set initially selected file
    if not self.initialized and self.options.selected_file then
      for _, file in self.files:iter() do
        if file.path == self.options.selected_file then
          self.panel:set_cur_file(file)
          break
        end
      end
    end

    -- Re-render only when the two blocks above actually changed `cur_file`,
    -- so the panel's active-file highlight matches the file `set_file` is
    -- about to open. In the common refresh path `cur_file` is unchanged
    -- and the earlier render still reflects the correct state.
    if self.panel.cur_file ~= prev_panel_cur_file then
      self.panel:render()
      self.panel:redraw()
    end

    local next_file = self.panel.cur_file or self.panel:next_file()

    -- Only re-open the current entry when something actually changed:
    -- first init, cur_file identity changed, or buffers were invalidated.
    local needs_reopen = not self.initialized
      or next_file ~= prev_cur_file
      or not (self.cur_layout and self.cur_layout:is_valid() and self.cur_layout:is_files_loaded())

    if needs_reopen then
      local focus = self:_should_focus_diff(next_file)
      self:set_file(next_file, focus, not self.initialized or nil)
    end

    -- Cursor positioning lives in the `file_open_new` listener; setting
    -- it here races the async file open and gets overwritten.

    self.update_needed = false
    perf:time()
    logger:lvl(5):debug(perf)
    logger:fmt_info(
      "[%s] Completed update for %d files successfully (%.3f ms)",
      self.class:name(),
      self.files:len(),
      perf.final_time
    )
    self.emitter:emit("files_updated", self.files)

    callback()
  end)
)

---Refresh the file list. See `update_files_impl` above for the heavy lifting.
---
---Normalizes args so legacy `update_files(callback)` callers don't trip the
---new `(opts, callback)` shape: a function in the `opts` slot is treated as
---the callback, and any non-table `opts` is coerced to an empty table.
---@param opts? { force?: boolean }|fun(err?: string[])
---@param callback? fun(err?: string[])
function DiffView:update_files(opts, callback)
  if type(opts) == "function" and callback == nil then
    opts, callback = nil, opts
  end
  if type(opts) ~= "table" then
    opts = {}
  end
  return update_files_impl(self, opts, callback)
end

---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function DiffView:file_safeguard()
  if self.files:len() == 0 then
    local cur = self.panel.cur_file

    if cur then
      cur.layout:detach_files()
    end

    self.cur_layout:open_null()
    self.nulled = true

    return true
  end
  return false
end

function DiffView:on_files_staged(callback)
  self.emitter:on(EventName.FILES_STAGED, callback)
end

function DiffView:init_event_listeners()
  local listeners = require("diffview.scene.views.diff.listeners")(self)
  for event, callback in pairs(listeners) do
    self.emitter:on(event, callback)
  end

  -- Forward to global emitter so the User autocmd bridge can pick it up.
  self.emitter:on(EventName.FILES_STAGED, function(_, view)
    DiffviewGlobal.emitter:emit("files_staged", view)
  end)
end

---Infer the current selected file. If the file panel is focused: return the
---file entry under the cursor. Otherwise return the file open in the view.
---Returns nil if no file is open in the view, or there is no entry under the
---cursor in the file panel.
---@param allow_dir? boolean Allow directory nodes from the file tree.
---@return (FileEntry|DirData)?
function DiffView:infer_cur_file(allow_dir)
  if self.panel:is_focused() then
    ---@type any
    local item = self.panel:get_item_at_cursor()
    if not item then
      return
    end
    if not allow_dir and type(item.collapsed) == "boolean" then
      return
    end

    return item
  else
    return self.panel.cur_file
  end
end

---Check whether or not the instantiation was successful.
---@return boolean
function DiffView:is_valid()
  return self.valid
end

M.DiffView = DiffView

return M
