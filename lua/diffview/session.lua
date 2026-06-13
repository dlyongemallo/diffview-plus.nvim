-- Session restoration.
--
-- `:mksession` saves buffer names but not contents, so `diffview://...`
-- buffers come back empty and inert. On `SessionLoadPost` this module
-- wipes those stale buffers, then replays the `:DiffviewOpen` /
-- `:DiffviewFileHistory` invocations recorded in a `<session>.diffview.json`
-- sidecar (written on `SessionWritePost` / `VimLeave`), restoring per-file
-- cursor and viewport via `winrestview`.
--
-- Gated by `restore_session` (default true). When false, the cleanup pass
-- still runs but save and restore are skipped.

local api = vim.api

local M = {}

-- Bump on any breaking change to the sidecar entry shape; older versions
-- are rejected on read.
local SIDECAR_VERSION = 1

---Returns `true` if `bufnr` belongs to this plugin's UI.
---@param bufnr integer
---@return boolean
local function is_diffview_buf(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if api.nvim_buf_get_name(bufnr):match("^diffview://") then
    return true
  end
  local ft = vim.bo[bufnr].filetype
  return ft == "DiffviewFiles" or ft == "DiffviewFileHistory"
end

---Returns `true` if `bufnr` is the internal `diffview://null` singleton
---owned by `vcs/file.lua`.
---@param bufnr integer
---@return boolean
local function is_null_buf(bufnr)
  return api.nvim_buf_is_valid(bufnr) and api.nvim_buf_get_name(bufnr) == "diffview://null"
end

---Returns the set of tabpages hosting a live Diffview view, marked
---`t:diffview_view_initialized` by `StandardView`/`NullDiffView`.
---@return table<integer, true>
local function live_tab_set()
  local set = {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if vim.t[tab].diffview_view_initialized then
      set[tab] = true
    end
  end
  return set
end

---Returns `true` if `bufnr` is a stale, session-restored diffview buffer
---safe to wipe. A live view sets `b:diffview_loaded` on file buffers
---(see `vcs/file.lua`), but panel/commit-log buffers don't carry that
---flag, so we also exclude any buffer displayed in a live-view tab. This
---preserves a Diffview opened during `SessionLoadPost` (e.g. from a user
---autocmd) along with its panel buffers. The `diffview://null` singleton
---owned by `vcs/file.lua` is also excluded: wiping it dangles the cached
---`File.NULL_FILE.bufnr` handle until the next `_get_null_buffer` call.
---@param bufnr integer
---@param live_tabs table<integer, true>
---@return boolean
local function is_stale_diffview_buf(bufnr, live_tabs)
  if not is_diffview_buf(bufnr) or vim.b[bufnr].diffview_loaded then
    return false
  end
  if is_null_buf(bufnr) then
    return false
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if live_tabs[api.nvim_win_get_tabpage(win)] then
      return false
    end
  end
  return true
end

---Wipe leftover diffview buffers and close any tabpage that held only
---diffview windows. Safe to call when no such buffers exist.
---
---`stale_local_paths` are absolute paths of LOCAL files the prior
---diffview session created. Their buffers count as stale for the
---tab-classification pass but are *unlisted*, not wiped: third-party
---plugins (LSP, gitsigns, ...) may hold scheduled callbacks against the
---bufnr that would hit `E680` if it disappeared. Modified buffers are
---left alone so the user's edits stay visible.
---@param stale_local_paths? string[]
local function cleanup(stale_local_paths)
  stale_local_paths = stale_local_paths or {}

  local stale_local_bufs = {}
  for _, path in ipairs(stale_local_paths) do
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 and api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modified then
      stale_local_bufs[bufnr] = true
    end
  end

  -- Tabs hosting a live Diffview view are excluded entirely.
  local live_tabs = live_tab_set()

  local function is_stale(bufnr)
    return is_stale_diffview_buf(bufnr, live_tabs) or stale_local_bufs[bufnr] == true
  end

  -- Seed `tab_has_other` only from stale `diffview://` buffers. A stale
  -- LOCAL can also appear in a user-owned tab opened during the same
  -- session, and seeding from those would auto-close that user tab.
  -- LOCAL staleness still factors into the second pass so it doesn't
  -- keep a diffview tab alive.
  local tab_has_other = {}
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if is_stale_diffview_buf(bufnr, live_tabs) then
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        local tab = api.nvim_win_get_tabpage(win)
        if tab_has_other[tab] == nil then
          tab_has_other[tab] = false
        end
      end
    end
  end
  for tab in pairs(tab_has_other) do
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      local b = api.nvim_win_get_buf(win)
      -- The `diffview://null` singleton is diffview UI but isn't "stale";
      -- counting it as "other" would strand orphan null-buffer tabs.
      if not is_stale(b) and not is_null_buf(b) then
        tab_has_other[tab] = true
        break
      end
    end
  end

  -- Wipe `diffview://` buffers; only unlist stale LOCALs (see docstring).
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if is_stale_diffview_buf(bufnr, live_tabs) then
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    elseif stale_local_bufs[bufnr] then
      vim.bo[bufnr].buflisted = false
    end
  end

  -- Never close the last tabpage: Neovim would exit.
  for tab, has_other in pairs(tab_has_other) do
    if not has_other and api.nvim_tabpage_is_valid(tab) and #api.nvim_list_tabpages() > 1 then
      local pagenr = api.nvim_tabpage_get_number(tab)
      local ok, err = pcall(api.nvim_command, "tabclose " .. pagenr)
      if not ok and type(err) == "string" and err:match("E445") then
        vim.cmd("tabclose! " .. pagenr)
      end
    end
  end
end

M.cleanup = cleanup

---Returns the sidecar path for the currently-loaded session, or nil if no
---named session is associated with this Neovim instance.
---@return string?
local function sidecar_path()
  local sess = vim.v.this_session
  if sess == nil or sess == "" then
    return nil
  end
  return sess .. ".diffview.json"
end

---Returns the effective `restore_session` config value (defaults to true
---if `diffview.config` fails to load).
---@return boolean
local function enabled()
  local ok, config = pcall(require, "diffview.config")
  if not ok then
    return true
  end
  return config.get_config().restore_session ~= false
end

---Returns the 1-based tabnr of `tabpage`, or a large sentinel if invalid
---(so it sorts last).
---@param tabpage integer
---@return integer
local function tabpage_order(tabpage)
  if tabpage and api.nvim_tabpage_is_valid(tabpage) then
    return api.nvim_tabpage_get_number(tabpage)
  end
  return math.huge
end

---@class diffview.session.ViewEntry
---@field kind "diffview_open"|"file_history"
---@field args string[] Original command-line args as passed to `lib.*`.
---@field range? integer[] `{line1, line2}` for `:DiffviewFileHistory` ranges.
---@field tabpage_order integer Sort key so restored views come back in their original tab order.
---@field selected_file? string Repo-relative path of the active file (`DiffviewOpen` only).
---@field cursor_map? table<string, table> Repo-relative path → `winsaveview()` dict for every file visited at save time.
---@field toplevel? string Repo root, for debugging.

---Absolute paths of LOCAL buffers the prior diffview session created
---(via `File.created_bufs`), so restore can unlist them without touching
---user-owned buffers.
---@return string[]
local function capture_created_paths()
  local ok, vcs_file = pcall(require, "diffview.vcs.file")
  if not ok then
    return {}
  end
  local paths = {}
  for bufnr in pairs(vcs_file.File.created_bufs or {}) do
    if api.nvim_buf_is_valid(bufnr) then
      local name = api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        paths[#paths + 1] = name
      end
    end
  end
  return paths
end

---Build a serializable entry for `view`, or nil if the view wasn't created
---through one of the recorded entry points or is no longer valid.
---@param view any
---@return diffview.session.ViewEntry?
local function capture_view(view)
  local rec = view._session_record
  if not rec then
    return nil
  end
  if not (view.tabpage and api.nvim_tabpage_is_valid(view.tabpage)) then
    return nil
  end

  local entry = {
    kind = rec.kind,
    args = rec.args,
    range = rec.range,
    tabpage_order = tabpage_order(view.tabpage),
  }

  if view.adapter and view.adapter.ctx then
    entry.toplevel = view.adapter.ctx.toplevel
  end

  -- `selected_file` is `DiffView`-only and feeds the constructor on
  -- restore. `FileHistoryPanel:cur_file()` is a method, and its active
  -- file is meaningful only inside an entry, so we don't record one.
  local cur_file_path
  if rec.kind == "diffview_open" and view.panel and view.panel.cur_file then
    cur_file_path = view.panel.cur_file.path
    entry.selected_file = cur_file_path
  elseif rec.kind == "file_history" and view.panel and view.panel.cur_file then
    local ok, file = pcall(view.panel.cur_file, view.panel)
    if ok and file and file.path then
      cur_file_path = file.path
    end
  end

  -- `file_open_pre` snapshots files the user navigated *away* from;
  -- refresh the still-active one before serializing.
  if cur_file_path and view.snapshot_main_view then
    view:snapshot_main_view(cur_file_path)
  end

  if view.cursor_map and next(view.cursor_map) ~= nil then
    entry.cursor_map = view.cursor_map
  end

  return entry
end

---Walk the live view list, build sidecar entries, and write them to disk.
---When no eligible views exist, deletes any stale sidecar instead.
function M.save()
  if not enabled() then
    return
  end
  local path = sidecar_path()
  if not path then
    return
  end

  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return
  end

  local entries = {}
  for _, view in ipairs(lib.views or {}) do
    local entry = capture_view(view)
    if entry then
      entries[#entries + 1] = entry
    end
  end

  if #entries == 0 then
    -- Nothing to restore: remove any stale sidecar from a previous save.
    os.remove(path)
    return
  end

  table.sort(entries, function(a, b)
    return a.tabpage_order < b.tabpage_order
  end)

  -- Atomic write via temp file + rename (mirrors `selection_store.lua`)
  -- so a crash mid-write can't strand a half-encoded sidecar.
  local payload = vim.json.encode({
    version = SIDECAR_VERSION,
    views = entries,
    created_paths = capture_created_paths(),
  })
  local tmp = path .. ".tmp"
  if vim.fn.writefile({ payload }, tmp) ~= 0 then
    DiffviewGlobal.logger:warn(("[session] failed to write sidecar at %q"):format(tmp))
    pcall(vim.fn.delete, tmp)
    return
  end
  local rename_ok, rename_err = vim.uv.fs_rename(tmp, path)
  if not rename_ok then
    DiffviewGlobal.logger:warn(
      ("[session] failed to rename sidecar %q -> %q: %s"):format(tmp, path, tostring(rename_err))
    )
    pcall(vim.fn.delete, tmp)
  end
end

---Read the sidecar (if any) and return the parsed entries plus the list
---of LOCAL paths the prior session's diffview created, or nil when the
---sidecar is absent / corrupt / wrong version.
---@return diffview.session.ViewEntry[]?, string[]?
local function read_sidecar()
  local path = sidecar_path()
  if not path then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then
    return nil
  end
  local ok, parsed = pcall(vim.json.decode, data)
  if not ok or type(parsed) ~= "table" or type(parsed.views) ~= "table" then
    return nil
  end
  if parsed.version ~= SIDECAR_VERSION then
    return nil
  end
  -- Drop non-table / non-string elements so a hand-edited sidecar can't
  -- crash the restore loop or feed garbage into `vim.fn.bufnr`.
  local entries = {}
  for _, e in ipairs(parsed.views) do
    if type(e) == "table" then
      entries[#entries + 1] = e
    end
  end
  local created_paths = {}
  if type(parsed.created_paths) == "table" then
    for _, p in ipairs(parsed.created_paths) do
      if type(p) == "string" and p ~= "" then
        created_paths[#created_paths + 1] = p
      end
    end
  end
  return entries, created_paths
end

---Unlist LOCAL buffers the prior diffview session created so they drop
---out of `:ls`/`:bnext` and the next `:mksession`. Modified buffers are
---skipped. Why unlist and not wipe: see `cleanup`'s docstring.
---@param paths string[] Absolute paths captured at save time.
local function unlist_stale_locals(paths)
  for _, path in ipairs(paths) do
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 and api.nvim_buf_is_valid(bufnr) and not vim.bo[bufnr].modified then
      vim.bo[bufnr].buflisted = false
    end
  end
end

-- Re-entry guard. `lib.diffview_open` runs adapter bootstraps that pump
-- the event loop via `vim.wait`, so a sibling `SessionLoadPost` firing
-- can schedule another `M.restore` during the wait. Those re-entrant
-- calls would see `bootstrap.done = true` and emit spurious "Not a repo"
-- errors. This collapses sibling firings to a single call.
local restore_in_progress = false

local function warn_failed(err)
  local ok, utils = pcall(require, "diffview.utils")
  if ok then
    utils.warn("Failed to restore view: " .. tostring(err))
  else
    vim.notify("[diffview+] Failed to restore view: " .. tostring(err), vim.log.levels.WARN)
  end
end

---Filter a raw sidecar `cursor_map` to string→table entries, or nil
---if nothing usable remains.
---@param raw any
---@return table<string, table>?
local function sanitize_cursor_map(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local out = {}
  for path, value in pairs(raw) do
    if type(path) == "string" and type(value) == "table" then
      out[path] = value
    end
  end
  if next(out) == nil then
    return nil
  end
  return out
end

---@param lib any
---@param entry diffview.session.ViewEntry
local function restore_diffview_entry(lib, entry)
  if type(entry.args) ~= "table" then
    return
  end
  local create_ok, view = pcall(lib.diffview_open, entry.args)
  if not create_ok then
    warn_failed(view)
    return
  end
  if not view then
    return
  end
  -- Cursor positioning is owned by `cursor_map` + `file_open_new`;
  -- `selected_file` only chooses which file the view opens first.
  if type(entry.selected_file) == "string" then
    view.options = view.options or {}
    view.options.selected_file = entry.selected_file
  end
  local cursor_map = sanitize_cursor_map(entry.cursor_map)
  if cursor_map then
    view.cursor_map = cursor_map
  end
  if not (view.tabpage and api.nvim_tabpage_is_valid(view.tabpage)) then
    local open_ok, open_err = pcall(view.open, view)
    if not open_ok then
      warn_failed(open_err)
    end
  end
end

---@param lib any
---@param entry diffview.session.ViewEntry
local function restore_file_history_entry(lib, entry)
  if type(entry.args) ~= "table" then
    return
  end
  local range = type(entry.range) == "table" and entry.range or nil
  local create_ok, view = pcall(lib.file_history, range, entry.args)
  if not create_ok then
    warn_failed(view)
    return
  end
  if not view then
    return
  end
  local cursor_map = sanitize_cursor_map(entry.cursor_map)
  if cursor_map then
    view.cursor_map = cursor_map
  end
  local open_ok, open_err = pcall(view.open, view)
  if not open_ok then
    warn_failed(open_err)
  end
end

---Re-open the diffview views captured in the sidecar associated with the
---current session, in approximately their original tab order.
function M.restore()
  if restore_in_progress then
    return
  end
  if not enabled() then
    return
  end
  local entries, created_paths = read_sidecar()
  if not entries then
    return
  end

  -- Run unconditionally so callers that bypass `cleanup` still get the
  -- buflist cleaned. `_create_local_buffer` re-lists the selected file
  -- when the view opens.
  if created_paths then
    unlist_stale_locals(created_paths)
  end

  if #entries == 0 then
    return
  end

  -- Force the main diffview module to load so its global autocmds are
  -- wired up before any view opens.
  local ok_diffview = pcall(require, "diffview")
  if not ok_diffview then
    return
  end
  local lib = require("diffview.lib")

  -- If a view is already live (e.g., from `-c DiffviewOpen ...` or a
  -- user's own autocmd), honour that instead of overwriting it.
  for _, view in ipairs(lib.views or {}) do
    if view.tabpage and api.nvim_tabpage_is_valid(view.tabpage) then
      return
    end
  end

  -- Defensive: a hand-edited sidecar may have non-numeric tabpage_order.
  table.sort(entries, function(a, b)
    local ao = type(a.tabpage_order) == "number" and a.tabpage_order or math.huge
    local bo = type(b.tabpage_order) == "number" and b.tabpage_order or math.huge
    return ao < bo
  end)

  -- Set before any `lib.diffview_open` (which can yield); pcall-wrap so
  -- a throw doesn't leave the guard latched.
  restore_in_progress = true
  local ok, err = pcall(function()
    for _, entry in ipairs(entries) do
      if entry.kind == "diffview_open" then
        restore_diffview_entry(lib, entry)
      elseif entry.kind == "file_history" then
        restore_file_history_entry(lib, entry)
      end
    end
  end)
  restore_in_progress = false
  if not ok then
    warn_failed(err)
  end
end

---Record the args used to create `view` so they can be re-invoked on
---session restore. Called from `lua/diffview/init.lua` entry points.
---@param view any
---@param kind "diffview_open"|"file_history"
---@param args string[]
---@param range? integer[]
function M.record_view(view, kind, args, range)
  if not view then
    return
  end
  view._session_record = {
    kind = kind,
    args = vim.deepcopy(args or {}),
    range = range and vim.deepcopy(range) or nil,
  }
end

---Register session autocmds. The save path uses both `VimLeave` and
---`SessionWritePost`; either alone is incomplete (see comments inside).
function M.setup()
  local group = api.nvim_create_augroup("diffview_session", { clear = true })

  api.nvim_create_autocmd("SessionLoadPost", {
    group = group,
    -- Defer past the autocmd context: deleting the cursor's buffer
    -- inside the autocmd hits `E814` (would leave only the autocmd
    -- window). The next tick drops into `[No Name]` instead.
    callback = function()
      vim.schedule(function()
        local _, created_paths = read_sidecar()
        cleanup(created_paths)
        -- Defer restore so TabClosed/WinClosed autocmds queued by
        -- cleanup fire before any view is created.
        vim.schedule(M.restore)
      end)
    end,
  })

  -- Session managers run `:mksession` from `VimLeavePre`, and nested
  -- `SessionWritePost` events are suppressed unless the parent was
  -- registered `nested = true` -- so we can't rely on it. `VimLeave`
  -- fires after every `VimLeavePre`, by which point `v:this_session`
  -- is set.
  --
  -- TODO: when Neovim ports Vim 9.1's `SessionWritePre`
  -- (neovim/neovim#39004, neovim/neovim#22814), switch to it and embed
  -- the payload in a `g:` variable so it rides inside the session file.
  api.nvim_create_autocmd("VimLeave", {
    group = group,
    callback = M.save,
  })

  -- Catch interactive `:mksession` outside any session-manager exit
  -- hook. A duplicate save on exit is harmless.
  if vim.fn.exists("##SessionWritePost") ~= 0 then
    api.nvim_create_autocmd("SessionWritePost", {
      group = group,
      callback = M.save,
    })
  end
end

return M
