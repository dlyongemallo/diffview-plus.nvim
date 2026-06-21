local async = require("diffview.async")
local debounce = require("diffview.debounce")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local CommitLogPanel = lazy.access("diffview.ui.panels.commit_log_panel", "CommitLogPanel") ---@type CommitLogPanel|LazyModule
local EventName = lazy.access("diffview.events", "EventName") ---@type EventName|LazyModule
local FileEntry = lazy.access("diffview.scene.file_entry", "FileEntry") ---@type FileEntry|LazyModule
local FileHistoryPanel =
  lazy.access("diffview.scene.views.file_history.file_history_panel", "FileHistoryPanel") ---@type FileHistoryPanel|LazyModule
local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local LogEntry = lazy.access("diffview.vcs.log_entry", "LogEntry") ---@type LogEntry|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local await = async.await

local M = {}

---@class FileHistoryView : StandardView
---@operator call:FileHistoryView
---@field adapter VCSAdapter
---@field panel FileHistoryPanel
---@field commit_log_panel CommitLogPanel
---@field valid boolean
---@field pin_local? boolean # When true, the b-window stays bound to the working-tree LOCAL buffer across log navigation; resolved from `--pin-local` or `view.file_history.pin_local`.
---@field pinned_path? string # Working-tree path the b-window is pinned to. Seeded from `path_args[1]` for single-file pinning; the cursor follower updates it when the user highlights a file row in multi-file mode.
---@field _pinned_cursor_follow? CancellableFn # Debounced CursorMoved handler installed in pin_local mode; closed in `close()` to release the underlying uv timer.
---@field _pinned_b_files table<string, vcs.File> # View-owned cache of working-tree `vcs.File` instances keyed by path. Each pinned-mode b-window across the entire history reuses the entry for its path, so identity is stable across panel refreshes; entry destruction skips these files (see `Diff2*Pinned.shared_symbols`) and the view destroys them in `close()`.
local FileHistoryView = oop.create_class("FileHistoryView", StandardView.__get())

function FileHistoryView:init(opt)
  self.valid = false
  self.adapter = opt.adapter
  self.pin_local = opt.pin_local
  self.pinned_path = opt.pinned_path
  self.no_panel = opt.no_panel
  self._pinned_b_files = {}

  self:super({
    panel = FileHistoryPanel({
      parent = self,
      adapter = self.adapter,
      entries = {},
      log_options = opt.log_options,
    }),
  })

  self.valid = true
end

function FileHistoryView:post_open()
  self:init_event_listeners()
  self:_install_pinned_cursor_follower()

  self.commit_log_panel = CommitLogPanel(self, self.adapter, {
    name = ("diffview://%s/log/%d/%s"):format(self.adapter.ctx.dir, self.tabpage, "commit_log"),
  })

  vim.schedule(function()
    self:file_safeguard()

    ---@diagnostic disable-next-line: unused-local
    self.panel:update_entries(function(entries, status)
      if status < JobStatus.ERROR and not self.panel:cur_file() then
        local file = self.panel:next_file()
        if file then
          local conf = config.get_config()
          self:set_file(file, conf.view.file_history.focus_diff)
        end
      end
    end)

    self.ready = true
  end)
end

---@override
function FileHistoryView:close()
  if not self.closing:check() then
    self.closing:send()

    -- Cancel any pending debounced fire so a `CursorMoved` that already
    -- queued a `vim.schedule` callback can't run after teardown begins.
    -- Releasing the timer handle is deferred until after `super:close()`
    -- has destroyed the panel and unsubscribed the autocmd: the wrapper
    -- restarts the timer on every invocation, so a `CursorMoved`
    -- reaching a still-subscribed listener after the timer was closed
    -- would error on the closed uv handle.
    if self._pinned_cursor_follow then
      self._pinned_cursor_follow:cancel()
    end

    -- Entry teardown (including `_pin_overlays`) is owned by
    -- `FileHistoryPanel:destroy()`, called from `StandardView:close()` below.
    -- The pinned working-tree files belong to the view, not to entries
    -- (every pinned-mode b-window references them via
    -- `Diff2*Pinned.shared_symbols`), so the view detaches them here.
    self:_destroy_pinned_b_files()

    -- Clean up LOCAL buffers created by diffview that the user didn't have open before.
    if config.get_config().clean_up_buffers then
      for bufnr, _ in pairs(File.created_bufs) do
        if api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modified then
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
    FileHistoryView.super_class.close(self)

    -- `super:close()` destroyed the panel and unsubscribed the
    -- `CursorMoved` listener; the timer handle is now safe to release.
    if self._pinned_cursor_follow then
      self._pinned_cursor_follow:close()
      self._pinned_cursor_follow = nil
    end
  end
end

---@return FileEntry?
function FileHistoryView:cur_file()
  return self.panel.cur_item[2]
end

---Tear down the pin_local cache. Called from `close()` and exposed as a
---method so the destroy-policy contract can be exercised in a test.
---
---Each cached `vcs.File` is detached with `force=false`: pinned b-files are
---LOCAL and their underlying buffer is typically the user's pre-existing
---working-tree buffer (possibly with unsaved edits). `File:destroy(true)`
---would unconditionally delete that buffer, so we never use it here. The
---diffview-created subset is reaped separately by the `clean_up_buffers`
---block in `close()`, which consults `File.created_bufs` and skips
---modified or cross-tab buffers.
---@private
function FileHistoryView:_destroy_pinned_b_files()
  for _, file in pairs(self._pinned_b_files) do
    file:destroy(false)
  end
  self._pinned_b_files = {}
end

---@override
---Use the swap variant so pinned layouts can keep the pinned (b) window
---bound across the swap; tab-leave / view-close still call `detach_files`
---and tear down everything. Passing the next entry lets pinned variants
---compare the upcoming b-file against the current one and detach when
---they differ (multi-file pinning crossing a row to a different path).
---@param next_file FileEntry
function FileHistoryView:_detach_files_for_next(next_file)
  self.cur_layout:detach_files_for_swap(next_file)
end

function FileHistoryView:next_item()
  self:ensure_layout()

  if self:file_safeguard() then
    return
  end

  if self.panel:num_items() > 1 or self.nulled then
    local cur = self.panel:next_file()

    if cur then
      self.panel:highlight_item(cur)
      self.nulled = false
      self:_set_file(cur)

      return cur
    end
  end
end

function FileHistoryView:prev_item()
  self:ensure_layout()

  if self:file_safeguard() then
    return
  end

  if self.panel:num_items() > 1 or self.nulled then
    local cur = self.panel:prev_file()

    if cur then
      self.panel:highlight_item(cur)
      self.nulled = false
      self:_set_file(cur)

      return cur
    end
  end
end

---@param self FileHistoryView
---@param file FileEntry
---@param focus? boolean
---@param keep_cursor? boolean # When true, skip the cur-entry fold and panel highlight that would otherwise move the cursor. The pinned cursor follower passes this so a header-driven diff swap doesn't snap the cursor onto a file row (which would also re-trigger CursorMoved).
FileHistoryView.set_file = async.void(function(self, file, focus, keep_cursor)
  ---@diagnostic disable: invisible
  self:ensure_layout()

  if self:file_safeguard() or not file then
    return
  end

  local entry = self.panel:find_entry(file)
  local cur_entry = self.panel.cur_item[1]

  if entry then
    -- Centralised pinned_path update: any "this file is now active"
    -- transition (cursor follower, commit-nav, file-row navigation,
    -- programmatic switches) flows through here, so updating
    -- `pinned_path` once at the canonical write point keeps it in sync
    -- without each caller having to remember. Skipped in single-file
    -- mode where `pinned_path` is the rename anchor (the working-tree
    -- name) and may legitimately differ from the entry's commit-side
    -- name; the adapter resolves the rename in that mode.
    if self.pin_local and not self.panel.single_file then
      self.pinned_path = file.path
    end

    if not keep_cursor and cur_entry and entry ~= cur_entry then
      self.panel:set_entry_fold(cur_entry, false)
    end

    self.panel:set_cur_item({ entry, file })
    if not keep_cursor then
      self.panel:highlight_item(file)
    end
    self.nulled = false
    await(self:_set_file(file))

    if focus then
      api.nvim_set_current_win(self.cur_layout:get_main_win().id)
    end
  end
  ---@diagnostic enable: invisible
end)

---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function FileHistoryView:file_safeguard()
  if self.panel:num_items() == 0 then
    local cur = self.panel.cur_item[2]

    if cur then
      cur.layout:detach_files()
    end

    self.cur_layout:open_null()
    self.nulled = true

    return true
  end

  return false
end

function FileHistoryView:on_files_staged(callback)
  self.emitter:on(EventName.FILES_STAGED, callback)
end

function FileHistoryView:init_event_listeners()
  local listeners = require("diffview.scene.views.file_history.listeners")(self)
  for event, callback in pairs(listeners) do
    self.emitter:on(event, callback)
  end
end

-- When `pin_local` is true, follow the panel cursor so any movement (j/k,
-- gg, search, etc.) updates the right-side diff against the highlighted
-- entry without the user having to confirm with <cr>. The b-side stays
-- pinned via Diff2HorPinned/Diff2VerPinned, so only the commit-side window
-- actually rebuilds.
function FileHistoryView:_install_pinned_cursor_follower()
  if not self.pin_local then
    return
  end

  -- Debounce coalesces rapid j/k presses into a single layout update; the
  -- 75ms window is short enough that single keystrokes feel immediate.
  -- Stored on `self` so `close()` can release the underlying uv timer.
  self._pinned_cursor_follow = debounce.debounce_trailing(75, false, function()
    if not (self.panel:is_focused() and self:is_valid()) then
      return
    end

    local item = self.panel:get_item_at_cursor()
    if not item then
      return
    end

    local target
    if LogEntry.__get():ancestorof(item) then
      ---@cast item LogEntry
      target = self:_resolve_pinned_target(item)
    else
      ---@cast item FileEntry
      -- File row: navigate to this file. `set_file` will update
      -- `pinned_path` for us (centralised invariant), so subsequent
      -- commit-header navigation follows the path the user just landed on.
      target = item
    end

    if not target or target == self:cur_file() then
      return
    end

    -- `keep_cursor=true` because moving the panel cursor here would
    -- re-trigger CursorMoved and potentially snap off a header onto a file
    -- row when the previous entry gets folded.
    self:set_file(target, false, true)
  end)

  self.panel:on_autocmd("CursorMoved", {
    callback = self._pinned_cursor_follow --[[@as function ]],
  })
end

---Resolve, lazily constructing on first use, the working-tree `vcs.File`
---for `path`. The instance is shared across every pinned-mode FileEntry the
---view ever shows: each entry's b-window references the same `vcs.File`, so
---navigation across commits never swaps the b-side and the underlying
---buffer's diffview attachments survive every refresh. The view destroys
---all cached entries in `close()`; entry teardown skips them via
---`Layout.shared_symbols`.
---@param path string Working-tree path the b-side should pin to.
---@return vcs.File
function FileHistoryView:get_pinned_b_file(path)
  local cached = self._pinned_b_files[path]
  if cached then
    return cached
  end

  local file = File.__get()({
    adapter = self.adapter,
    path = path,
    kind = "working",
    rev = self.adapter.Rev(RevType.__get().LOCAL),
  }) --[[@as vcs.File ]]

  self._pinned_b_files[path] = file
  return file
end

---When the cursor is on a `LogEntry` header in pinned mode, find the
---`FileEntry` in that entry whose `path` matches `self.pinned_path`. If the
---commit didn't touch the pinned file, build a transient overlay so the LHS
---updates to that commit's snapshot of the file while the RHS keeps the
---working-tree buffer.
---@private
---@param entry LogEntry
---@return FileEntry?
function FileHistoryView:_resolve_pinned_target(entry)
  local pinned_path = self.pinned_path

  -- Bootstrap: with no pinned path yet, fall back to the entry's first file
  -- and let the next file-row interaction lock in a `pinned_path`.
  if not pinned_path then
    return entry.files[1]
  end

  -- Single-file history follows one logical file across renames, so the
  -- entry has exactly one `FileEntry` and it's the right target regardless
  -- of path. Path-matching against `pinned_path` (the working-tree name)
  -- would miss commits older than a rename, where `f.path` is the old name
  -- and the overlay path then misclassifies the file as deleted.
  if entry.single_file then
    return entry.files[1]
  end

  for _, f in ipairs(entry.files) do
    if f.path == pinned_path then
      return f
    end
  end

  -- Reuse a cached overlay so repeated visits don't re-allocate; the cache
  -- lives on the entry so it's torn down with the LogEntry on view close.
  entry._pin_overlays = entry._pin_overlays or {}
  if entry._pin_overlays[pinned_path] then
    local cached = entry._pin_overlays[pinned_path]
    -- Lazy layout sync: a `set_layout` / `cycle_layout` since the overlay
    -- was built may have moved the view to a different pinned `Diff2`
    -- orientation. Convert the overlay on-demand so navigating back
    -- doesn't silently flip the view to the stale orientation.
    local active_class = self.cur_layout and self.cur_layout.class
    if active_class and cached.layout.class ~= active_class then
      cached:convert_layout(active_class --[[@as Layout ]])
    end
    return cached
  end

  local sample = entry.files[1]
  if not sample then
    return nil
  end

  -- Probe whether `pinned_path` existed at `sample.revs.a` (the commit
  -- itself in pin_local mode). If it didn't (e.g. the user navigated to a
  -- commit before the file was introduced), mark the overlay status as "D"
  -- so the pinned layout's `should_null` nulls the a-side and the adapter
  -- doesn't try to fetch the missing blob, which would error with
  -- "Failed to create diff buffer". The probe is wrapped in pcall so a
  -- third-party adapter that doesn't implement `file_exists_at_rev` falls
  -- back to "M" rather than crashing the resolver.
  local status = "M"
  local rev_a = sample.revs.a
  if rev_a and rev_a.commit then
    local ok, exists =
      pcall(self.adapter.file_exists_at_rev, self.adapter, pinned_path, rev_a.commit)
    if ok and not exists then
      status = "D"
    end
  end

  -- Use the layout class the user is actively viewing, so a `set_layout` /
  -- `cycle_layout` to a non-default pinned orientation isn't undone the
  -- moment the user lands on a commit that needs an overlay. Falls back to
  -- the configured default for the very first overlay built before any view
  -- layout is attached.
  local overlay_layout = (self.cur_layout and self.cur_layout.class) or self:get_default_layout()
  local overlay = FileEntry.__get().with_layout(overlay_layout, {
    adapter = self.adapter,
    path = pinned_path,
    oldpath = nil,
    status = status,
    stats = nil,
    kind = "working",
    commit = entry.commit,
    revs = {
      a = sample.revs.a,
      b = sample.revs.b,
    },
    pinned_b_file = self:get_pinned_b_file(pinned_path),
  })

  entry._pin_overlays[pinned_path] = overlay
  return overlay
end

---Pick the FileEntry to display when navigating to `entry`. In pin_local
---mode this routes through `_resolve_pinned_target` so commit-navigation
---and post-refresh bootstrap preserve the pinned path (possibly via a
---transient overlay) rather than snapping back to `entry.files[1]`.
---@param entry LogEntry
---@return FileEntry?
function FileHistoryView:pick_entry_target(entry)
  if self.pin_local then
    return self:_resolve_pinned_target(entry)
  end
  return entry.files[1]
end

---Infer the current selected file. If the file panel is focused: return the
---file entry under the cursor. Otherwise return the file open in the view.
---Returns nil if no file is open in the view, or there is no entry under the
---cursor in the file panel.
---@return FileEntry?
function FileHistoryView:infer_cur_file()
  if self.panel:is_focused() then
    local item = self.panel:get_item_at_cursor()

    if LogEntry.__get():ancestorof(item) then
      ---@cast item LogEntry
      -- In pinned mode the displayed diff is whichever FileEntry
      -- `_resolve_pinned_target` picked (possibly a transient overlay), so
      -- align action helpers with the visible file rather than `files[1]`.
      return self:pick_entry_target(item)
    end

    return item --[[@as FileEntry ]]
  end

  return self.panel.cur_item[2]
end

---Check whether or not the instantiation was successful.
---@return boolean
function FileHistoryView:is_valid()
  return self.valid
end

---@override
function FileHistoryView:get_default_layout_name()
  return config.get_config().view.file_history.layout
end

---@override
function FileHistoryView:should_show_panel()
  return self:resolve_panel_visibility(config.get_config().file_history_panel.show)
end

-- Map a non-pinned layout name to its pinned counterpart. Pinned variants
-- share window orientation with their unpinned siblings; we re-route the
-- layout class so the b-window keeps its file across entry swaps via
-- `shared_symbols = { "b" }`. Diff1/Diff1Inline have pinned variants too
-- (their b-side is also bound to the view-owned working-tree file in
-- pin_local mode); names without a pinned sibling fall through unchanged.
local pinned_variant = {
  diff1_plain = "diff1_plain_pinned",
  diff1_inline = "diff1_inline_pinned",
  diff2_horizontal = "diff2_horizontal_pinned",
  diff2_vertical = "diff2_vertical_pinned",
}

-- Inverse of `pinned_variant`. Pinned classes only make sense in
-- `pin_local` mode: they all declare `shared_symbols = { "b" }` and expect
-- the FileHistoryView to own the b-side `vcs.File` via its pin_local cache,
-- so outside `pin_local` there's no shared owner and the b-side would
-- never be torn down. The Diff2 pinned variants are additionally unsafe
-- there because they override `should_null` with parent-vs-commit semantics
-- that assume `revs.a = COMMIT` (only injected under `pin_local`); applied
-- to a parent-vs-commit history they mis-classify status "A"/"?" and the
-- adapter then fails to `show <rev>:<missing>` (the Diff1 pinned variants
-- inherit `Diff1.should_null` unchanged, so they don't have that specific
-- bug, but the shared-b ownership mismatch still applies). The user-config
-- path is already gated by `config`'s `standard_layouts` validation
-- (pinned names aren't in the schema's allow-list), but we still fold
-- pinned → unpinned here as belt-and-suspenders for any other caller
-- (tests, future code) that reaches `get_default_layout` with a pinned
-- name and `pin_local` off.
local unpinned_variant = {}
for unpinned, pinned in pairs(pinned_variant) do
  unpinned_variant[pinned] = unpinned
end

---@override
---@return Layout # (class) The default layout class.
function FileHistoryView:get_default_layout()
  local name = self:get_default_layout_name()

  if name == -1 then
    name = FileHistoryView.get_default_diff2().name
  end

  local resolved
  if self.pin_local then
    -- Upgrade standard layout names to their pinned siblings so the
    -- shared-b mechanism engages: pinned variants declare
    -- `shared_symbols = { "b" }`, which keeps `FileEntry:destroy` from
    -- tearing down the view-owned working-tree file on every refresh.
    -- All standard layouts (`diff1_*`, `diff2_*`) have pinned siblings,
    -- so the `pinned_variant` lookup normally hits. If a non-standard
    -- name ever reaches here (e.g. via a future non-config caller that
    -- bypasses the `standard_layouts` allow-list), fall back to the
    -- default pinned Diff2 -- matching `resolve_pinned_layout` -- so the
    -- shared-b contract still holds.
    resolved = pinned_variant[name] or pinned_variant[FileHistoryView.get_default_diff2().name]
  else
    resolved = unpinned_variant[name] or name
  end

  return config.name_to_layout(resolved --[[@as string ]])
end

---Inverse of `resolve_pinned_layout`: map a pinned class to its unpinned
---sibling, returning the input unchanged for any other class. Used by
---`cycle_layout` to find the current layout's position in the unpinned
---cycle list (the cycle list contains `Diff2Hor`/`Diff2Ver`, but in
---pin_local mode the active class is `Diff2*Pinned`, so a direct
---`vec_indexof` would always miss and stick the user on the first layout).
---@param layout_class Layout (class)
---@return Layout (class)
function FileHistoryView:unpinned_layout(layout_class)
  local sibling = unpinned_variant[layout_class.name]
  if not sibling then
    return layout_class
  end
  return config.name_to_layout(sibling --[[@as string ]])
end

---Map an arbitrary layout class to the right one for this view's pin_local
---state. Used by `cycle_layout` / `set_layout` so neither action drops a
---pin_local FileHistoryView into an unpinned variant (which would cause
---`FileEntry:destroy` to tear down the view-owned working-tree file once
---per entry, and would untie the b-window from its shared LOCAL buffer).
---When `pin_local` is off, returns the input unchanged. When on:
---  - already a pinned variant: returns it unchanged (preserves the user's
---    chosen orientation).
---  - has a pinned sibling (e.g. `diff2_horizontal`, `diff1_inline`):
---    returns the pinned sibling.
---  - no pinned variant (e.g. `diff3_*`/`diff4_*` reaching us via a
---    user-supplied `view.cycle_layouts.default` entry or a direct
---    `actions.set_layout` call): falls back to the default Diff2's pinned
---    form so the shared-b contract still holds.
---@param layout_class Layout (class)
---@return Layout (class)
function FileHistoryView:resolve_pinned_layout(layout_class)
  if not self.pin_local then
    return layout_class
  end

  local name = layout_class.name

  if unpinned_variant[name] then
    return layout_class
  end

  local sibling = pinned_variant[name]
  if sibling then
    return config.name_to_layout(sibling --[[@as string ]])
  end

  return config.name_to_layout(
    pinned_variant[FileHistoryView.get_default_diff2().name] --[[@as string ]]
  )
end

M.FileHistoryView = FileHistoryView
return M
