local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff1Inline = lazy.access("diffview.scene.layouts.diff_1_inline", "Diff1Inline") ---@type Diff1Inline|LazyModule
local Diff1Raw = lazy.access("diffview.scene.layouts.diff_1_raw", "Diff1Raw") ---@type Diff1Raw|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

local M = {}

local fstat_cache = {}

---Safely evaluate a layout's should_null predicate. Returns false if the
---call errors so that a broken predicate never accidentally nulls a file.
---@param layout Layout (class)
---@param rev Rev
---@param status string
---@param symbol string
---@return boolean
local function try_should_null(layout, rev, status, symbol)
  local ok, res = pcall(layout.should_null, rev, status, symbol)
  return ok and res or false
end

---@class GitStats
---@field additions? integer
---@field deletions? integer
---@field conflicts? integer

---@class RevMap
---@field a Rev
---@field b Rev
---@field c? Rev
---@field d? Rev

---@class FileEntry : diffview.Object
---@field adapter VCSAdapter
---@field path string
---@field oldpath string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field revs RevMap
---@field layout Layout
---@field status string
---@field stats? GitStats
---@field kind vcs.FileKind
---@field commit Commit|nil
---@field merge_ctx vcs.MergeContext?
---@field active boolean
---@field opened boolean
---@field _extra_owned vcs.File[] # Files this entry owns that aren't reachable through `layout:owned_files()` (e.g. one-off nulled fallbacks built for a window whose symbol is in `shared_symbols`).
local FileEntry = oop.create_class("FileEntry")

---@class FileEntry.init.Opt
---@field adapter VCSAdapter
---@field path string
---@field oldpath? string
---@field revs RevMap
---@field layout? Layout
---@field status? string
---@field stats? GitStats
---@field kind vcs.FileKind
---@field commit? Commit
---@field merge_ctx? vcs.MergeContext
---@field _extra_owned? vcs.File[]

---FileEntry constructor
---@param opt FileEntry.init.Opt
function FileEntry:init(opt)
  self.adapter = opt.adapter
  self.path = opt.path
  self.oldpath = opt.oldpath
  self.absolute_path = pl:absolute(opt.path, opt.adapter.ctx.toplevel)
  self.parent_path = pl:parent(opt.path) or ""
  self.basename = pl:basename(opt.path)
  self.extension = pl:extension(opt.path) or ""
  self.revs = opt.revs
  self.layout = opt.layout
  self.status = opt.status
  self.stats = opt.stats
  self.kind = opt.kind
  self.commit = opt.commit
  self.merge_ctx = opt.merge_ctx
  self.active = false
  self.opened = false
  -- Files this FileEntry owns that aren't reachable through `layout:owned_files()`
  -- (e.g. one-off nulled fallbacks for shared-symbol windows when the
  -- shared instance can't be used). Populated by `with_layout`.
  self._extra_owned = opt._extra_owned or {}
end

---Destroy owned Files. `force` still drops COMMIT/STAGE/CUSTOM buffers
---unconditionally, but LOCAL buffers stay guarded by `is_buf_in_use`: they
---represent the user's real file buffer and may be visible in windows
---outside the diffview (e.g., the tab the user opened from). Force-deleting
---one would collapse that tab and lose the cursor position there.
---@param force? boolean
function FileEntry:destroy(force)
  local function force_for(f)
    return force and f.rev and f.rev.type ~= RevType.LOCAL
  end

  for _, f in ipairs(self.layout:owned_files()) do
    f:destroy(force_for(f))
  end

  for _, f in ipairs(self._extra_owned) do
    f:destroy(force_for(f))
  end
  self._extra_owned = {}

  self.layout:destroy()
end

---@param new_head Rev
function FileEntry:update_heads(new_head)
  for _, file in ipairs(self.layout:owned_files()) do
    if file.rev.track_head then
      file:dispose_buffer()
      file.rev = new_head
    end
  end
end

---@param flag boolean
function FileEntry:set_active(flag)
  self.active = flag

  for _, f in ipairs(self.layout:owned_files()) do
    f.active = flag
  end
end

---@param target_layout Layout
function FileEntry:convert_layout(target_layout)
  if not self.revs then
    return
  end

  -- Let the old layout drop any buffer-level render state before it's
  -- replaced; the new layout reuses the same files/buffers, so leftover
  -- visuals (e.g. inline-diff extmarks) would otherwise persist.
  if self.layout.teardown_render then
    self.layout:teardown_render()
  end

  local get_data

  -- Scan `owned_files()` rather than `files()` so non-window files
  -- (e.g. `Diff1Inline.a_file`) still contribute a `get_data` producer
  -- when converting away from a layout that owns them.
  for _, file in ipairs(self.layout:owned_files()) do
    if file.get_data then
      get_data = file.get_data
      break
    end
  end

  local function create_file(rev, symbol)
    return File({
      adapter = self.adapter,
      path = symbol == "a" and self.oldpath or self.path,
      kind = self.kind,
      commit = self.commit,
      get_data = get_data,
      rev = rev,
      nulled = try_should_null(target_layout, rev, self.status, symbol),
    }) --[[@as vcs.File ]]
  end

  self.layout = target_layout({
    a = self.layout:get_file_for("a") or create_file(self.revs.a, "a"),
    b = self.layout:get_file_for("b") or create_file(self.revs.b, "b"),
    c = self.layout:get_file_for("c") or create_file(self.revs.c, "c"),
    d = self.layout:get_file_for("d") or create_file(self.revs.d, "d"),
  })
  self:update_merge_context()
end

---@param stat? table
function FileEntry:validate_stage_buffers(stat)
  stat = stat or pl:stat(pl:join(self.adapter.ctx.dir, "index"))
  local cached_stat = utils.tbl_access(fstat_cache, { self.adapter.ctx.toplevel, "index" })

  if stat and (not cached_stat or cached_stat.mtime < stat.mtime.sec) then
    for _, f in ipairs(self.layout:files()) do
      if f.rev.type == RevType.STAGE and f:is_valid() then
        if f.rev.stage > 0 then
          -- We only care about stage 0 here
          f:dispose_buffer()
        else
          local is_modified = vim.bo[f.bufnr].modified

          if f.blob_hash then
            -- `new_hash` is nil when the path no longer has a stage-0 blob at
            -- all (e.g. a newly added file that was unstaged, leaving it
            -- untracked). That is a content change like any other: the buffer
            -- still shows the old staged blob and must be invalidated.
            local new_hash = self.adapter:file_blob_hash(f.path)

            if new_hash ~= f.blob_hash then
              if is_modified then
                utils.warn(
                  (
                    "A file was changed in the index since you started editing it!"
                    .. " Be careful not to lose any staged changes when writing to this buffer: %s"
                  ):format(api.nvim_buf_get_name(f.bufnr))
                )
              else
                f:dispose_buffer()
              end
            end
          elseif not is_modified then
            -- Should be very rare that we don't have an index-buffer's blob
            -- hash. But in that case, we can't warn the user when a file
            -- changes in the index while they're editing its index buffer.
            f:dispose_buffer()
          end
        end
      end
    end
  end
end

---Update winbar info
---@param ctx? vcs.MergeContext
function FileEntry:update_merge_context(ctx)
  ctx = ctx or self.merge_ctx
  if ctx then
    self.merge_ctx = ctx
  else
    return
  end

  local layout = self.layout --[[@as Diff4 ]]

  if layout.a and ctx.ours.hash then
    layout.a.file.winbar = (" OURS (Current changes) %s %s"):format(
      (ctx.ours.hash):sub(1, 10),
      ctx.ours.ref_names and ("(" .. ctx.ours.ref_names .. ")") or ""
    )
  end

  if layout.b then
    layout.b.file.winbar = " LOCAL (Working tree)"
  end

  if layout.c and ctx.theirs.hash then
    layout.c.file.winbar = (" THEIRS (Incoming changes) %s %s"):format(
      (ctx.theirs.hash):sub(1, 10),
      ctx.theirs.ref_names and ("(" .. ctx.theirs.ref_names .. ")") or ""
    )
  end

  if layout.d and ctx.base.hash then
    layout.d.file.winbar = (" BASE (Common ancestor) %s %s"):format(
      (ctx.base.hash):sub(1, 10),
      ctx.base.ref_names and ("(" .. ctx.base.ref_names .. ")") or ""
    )
  end
end

---@return boolean
function FileEntry:is_null_entry()
  return self.path == "null" and self.layout:get_main_win().file == File.NULL_FILE
end

---@static
---@param adapter VCSAdapter
function FileEntry.update_index_stat(adapter, stat)
  stat = stat or pl:stat(pl:join(adapter.ctx.toplevel, "index"))

  if stat then
    if not fstat_cache[adapter.ctx.toplevel] then
      fstat_cache[adapter.ctx.toplevel] = {}
    end

    fstat_cache[adapter.ctx.toplevel].index = {
      mtime = stat.mtime.sec,
    }
  end
end

---@class FileEntry.with_layout.Opt : FileEntry.init.Opt
---@field nulled? boolean
---@field get_data? git.FileDataProducer
---@field pinned_path? string # Deprecated: when `pinned_b_file` is supplied the layout takes its b-side from that shared File and `pinned_path` is ignored. Retained as a fallback for adapters that haven't been wired to the view's pin_local cache yet.
---@field pinned_b_file? vcs.File # The view-owned, shared working-tree `vcs.File` for `pin_local` mode. When set, the layout's b-side reuses this exact instance instead of constructing a fresh one, so identity is preserved across every entry the view ever shows. The instance outlives entry teardown via the layout's `shared_symbols`, and is destroyed by `FileHistoryView:close()`. One carve-out: if the layout's `should_null` says the b-side should render as absent AND the working-tree path no longer exists on disk, the b-side falls back to a one-off nulled file so a status="D" entry doesn't open an empty/editable buffer for a missing path.

---Class-level "is `cls` equal to `target` or a subclass of `target`?". The
---`instanceof` method on `Object` requires an instance; here we walk the
---`super_class` chain directly so the check works on raw class tables.
---@param cls table?
---@param target table
---@return boolean
local function class_descends_from(cls, target)
  while cls do
    if cls == target then
      return true
    end
    cls = cls.super_class
  end
  return false
end

---Pick the effective layout class for an entry. Substitutes `Diff1Raw` for a
---Diff1 or Diff2 base when `view.one_sided_layout` is `"raw"` and the file's
---diff is one-sided (status `A`/`?`/`D`). Falls through (returns the input
---class) when the precondition isn't met, leaving every other layout path
---untouched. Bails out for pinned-b mode (the view owns the b-side), for
---`diff1_inline` (which already renders one-sided content coherently as
---all-added or all-deleted virt_lines), for `diff1_raw` itself (no-op), and
---for merge layouts (Diff3/Diff4).
---@param default_class Layout (class)
---@param opt FileEntry.with_layout.Opt
---@return Layout (class)
local function select_layout_for_status(default_class, opt)
  if config.get_config().view.one_sided_layout ~= "raw" then
    return default_class
  end
  if opt.pinned_b_file then
    return default_class
  end
  if not vim.tbl_contains({ "A", "?", "D" }, opt.status) then
    return default_class
  end
  if
    class_descends_from(default_class, Diff1Inline.__get())
    or class_descends_from(default_class, Diff1Raw.__get())
  then
    return default_class
  end
  if
    class_descends_from(default_class, Diff1.__get())
    or class_descends_from(default_class, Diff2.__get())
  then
    return Diff1Raw.__get()
  end
  return default_class
end

---@param layout_class Layout (class)
---@param opt FileEntry.with_layout.Opt
---@return FileEntry
function FileEntry.with_layout(layout_class, opt)
  local extra_owned = {}
  local effective_class = select_layout_for_status(layout_class, opt)
  local using_raw = effective_class == Diff1Raw.__get()
  -- For status `D` against a LOCAL/STAGE b-side, Diff2 would null the b-pane.
  -- Substitute `revs.a` for the b-rev so the single Diff1Raw window shows
  -- the pre-deletion content instead of being empty.
  local b_substituted = using_raw
      and opt.revs.b
      and try_should_null(Diff2.__get(), opt.revs.b, opt.status, "b")
    or false

  local function create_file(rev, symbol)
    local fallback_for_shared = false
    if symbol == "b" and opt.pinned_b_file then
      -- Fall through to a fresh nulled file when the layout says the
      -- b-side should render as absent AND the shared LOCAL path no
      -- longer exists on disk. Without this, status="D" entries whose
      -- working-tree path is also gone would open an empty/editable
      -- buffer for the missing path. The disk check preserves the
      -- overlay case (file exists in WT but not in this commit), where
      -- `try_should_null` would also return true but the b-side must
      -- still show the LOCAL file.
      local null_b = try_should_null(effective_class, rev, opt.status, symbol)
        and vim.fn.filereadable(opt.pinned_b_file.absolute_path) ~= 1
      if not null_b then
        return opt.pinned_b_file
      end
      -- We're constructing a one-off File for a window whose symbol is in
      -- `shared_symbols`, so `Layout:owned_files()` would skip it and
      -- `FileEntry:destroy` would otherwise leak it. Track it as an extra
      -- owned file below.
      fallback_for_shared = true
    end

    local path
    if symbol == "a" then
      path = opt.oldpath or opt.path
    elseif symbol == "b" and opt.pinned_path then
      path = opt.pinned_path
    else
      path = opt.path
    end

    -- For Diff1Raw, the windowed b-side is guaranteed non-null (we
    -- substituted to revs.a when the natural b would have been nulled).
    -- Unwindowed slots fall back to Diff2's nulled semantics so a
    -- round-trip via `FileEntry:convert_layout` produces correct flags.
    local nulled_flag
    if using_raw and symbol == "b" then
      nulled_flag = false
    elseif using_raw then
      nulled_flag = try_should_null(Diff2.__get(), rev, opt.status, symbol)
    else
      nulled_flag = try_should_null(effective_class, rev, opt.status, symbol)
    end

    local file = File({
      adapter = opt.adapter,
      path = path,
      kind = opt.kind,
      commit = opt.commit,
      get_data = opt.get_data,
      rev = rev,
      nulled = utils.sate(opt.nulled, nulled_flag),
    }) --[[@as vcs.File ]]

    if fallback_for_shared then
      extra_owned[#extra_owned + 1] = file
    end

    return file
  end

  -- For substituted Diff1Raw, dropping the unwindowed a-side avoids fetching
  -- the same content twice (the windowed b-side already uses revs.a). The a
  -- slot is rebuilt on demand by `convert_layout`'s fallback when the user
  -- cycles back to a Diff2 layout. Use an explicit branch instead of a
  -- `cond and nil or create_file(...)` ternary, which would always fall
  -- through to `create_file` because `nil or X == X` in Lua.
  local a_file
  if not (using_raw and b_substituted) then
    a_file = create_file(opt.revs.a, "a")
  end
  local b_file = create_file(b_substituted and opt.revs.a or opt.revs.b, "b")

  return FileEntry({
    adapter = opt.adapter,
    path = opt.path,
    oldpath = opt.oldpath,
    status = opt.status,
    stats = opt.stats,
    kind = opt.kind,
    commit = opt.commit,
    revs = opt.revs,
    _extra_owned = extra_owned,
    layout = effective_class({
      a = a_file,
      b = b_file,
      c = create_file(opt.revs.c, "c"),
      d = create_file(opt.revs.d, "d"),
      b_substituted = b_substituted,
    }),
  })
end

function FileEntry.new_null_entry(adapter)
  return FileEntry({
    adapter = adapter,
    path = "null",
    kind = "working",
    binary = false,
    nulled = true,
    layout = Diff1({
      b = File.NULL_FILE,
    }),
  })
end

M.FileEntry = FileEntry

return M
