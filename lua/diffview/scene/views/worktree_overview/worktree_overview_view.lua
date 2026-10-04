local lazy = require("diffview.lazy")

local Job = lazy.access("diffview.job", "Job") ---@type diffview.Job|LazyModule
local View = lazy.access("diffview.scene.view", "View") ---@type View|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local oop = lazy.require("diffview.oop") ---@module "diffview.oop"
local renderer = lazy.require("diffview.renderer") ---@module "diffview.renderer"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api

---Highlight-group aliases for the overview columns, named by role rather
---than by the underlying group so a future theme pass can be rerouted in
---one place. Groups are the standard diffview palette shared with every
---other panel; see `lua/diffview/hl.lua`.
local HL = {
  cursor_marker = "DiffviewFilePanelSelected",
  branch_cur = "DiffviewFilePanelSelected",
  branch = "DiffviewReference",
  bare = "DiffviewNonText",
  detached = "DiffviewReference",
  status = "DiffviewFilePanelCounter",
  arrow = "DiffviewNonText",
  counter = "DiffviewFilePanelCounter",
  files_suffix = "DiffviewNonText",
  insertions = "DiffviewFilePanelInsertions",
  deletions = "DiffviewFilePanelDeletions",
  staged = "DiffviewStatusAdded",
  unstaged = "DiffviewStatusModified",
  untracked = "DiffviewFilePanelCounter",
  dim = "DiffviewNonText",
  path = "DiffviewFilePanelPath",
}

local M = {}

---@alias WorktreeOverviewView.StatusProvider fun(entry: GitAdapter.WorktreeEntry): string?

---Forward-declared so `WorktreeOverviewView:refresh` can call it to resolve
---each row's status outside the render path. Definition is further below.
---@type fun(entry: GitAdapter.WorktreeEntry): string
local format_status

---Companion plugins (`diffview-coding-agents.nvim` and friends) register
---here to fill the overview's status column from external state. Multiple
---providers are supported; the view calls each one per entry, filters nil
---and empty returns, and joins the rest with a space.
---@type WorktreeOverviewView.StatusProvider[]
local status_providers = {}

---Register a status provider. Return `nil` or `""` to leave an entry blank.
---
---Contract:
---  - Providers are called synchronously on the main loop during a refresh,
---    once per entry. They must return quickly: perform any blocking work
---    (shell-outs, `/proc` scans, HTTP calls) off the main loop and return
---    the latest cached value here. A slow provider blocks the refresh and
---    the editor.
---  - Returned strings must not contain `\n` or `\r`; the view defensively
---    collapses them to spaces to avoid E5086 at render time, but a provider
---    that passes multi-line output through will lose structure.
---  - Errors raised by the provider are swallowed with `pcall` so a broken
---    companion plugin cannot take the overview down.
---@param fn WorktreeOverviewView.StatusProvider
function M.register_status_provider(fn)
  table.insert(status_providers, fn)
end

---@param fn WorktreeOverviewView.StatusProvider
function M.unregister_status_provider(fn)
  for i = #status_providers, 1, -1 do
    if status_providers[i] == fn then
      table.remove(status_providers, i)
    end
  end
end

---Remove every registered status provider. Mainly for tests.
function M.clear_status_providers()
  status_providers = {}
end

---Skeleton view that lists every linked git worktree in a single buffer.
---@class WorktreeOverviewView : View
---@field adapter GitAdapter
---@field cwd_path? string # Toplevel of the worktree the overview was launched from. Nil when launched from outside any worktree (e.g., a bare repo root); the view then stars no row.
---@field entries GitAdapter.WorktreeEntry[]
---@field bufnr integer?
---@field winid integer?
---@field render_data RenderData?
---@field _status_by_path? table<string, string> # `refresh` resolves each row's status column into this map so `render` reads strings instead of calling providers in its hot path.
---@field _spinner_timer uv_timer_t?
---@field _spinner_start? integer # hrtime nanoseconds at the start of this spin.
---@field _spinner_frame? integer # Next frame index to paint.
---@operator call : WorktreeOverviewView
local WorktreeOverviewView = oop.create_class("WorktreeOverviewView", View.__get())

---@class WorktreeOverviewView.InitOpt
---@field adapter GitAdapter
---@field cwd_path? string

---@param opt WorktreeOverviewView.InitOpt
function WorktreeOverviewView:init(opt)
  self:super(opt)
  self.adapter = assert(opt.adapter, "WorktreeOverviewView requires an adapter")
  self.cwd_path = opt.cwd_path
  self.entries = {}
  self:init_event_listeners()
end

---Attach the handlers the keymap config routes action events to. The actions
---live on `require("diffview").emit`, which dispatches to the current view's
---local emitter (see `diffview.init._emit`).
function WorktreeOverviewView:init_event_listeners()
  self.emitter:on("close", function()
    if self:is_cur_tabpage() then
      require("diffview").close()
    end
  end)
  self.emitter:on("refresh_files", function()
    self:refresh()
  end)
  self.emitter:on("worktree_overview_enter", function()
    self:enter_selected()
  end)
end

---@override
function WorktreeOverviewView:init_layout()
  self.winid = api.nvim_get_current_win()
  self.bufnr = api.nvim_create_buf(false, true)

  api.nvim_win_set_buf(self.winid, self.bufnr)

  vim.bo[self.bufnr].bufhidden = "wipe"
  vim.bo[self.bufnr].buftype = "nofile"
  vim.bo[self.bufnr].swapfile = false
  vim.bo[self.bufnr].modifiable = false
  vim.bo[self.bufnr].filetype = "DiffviewWorktreeOverview"
  -- Per-buffer URI so multiple overview tabs can coexist without E95.
  api.nvim_buf_set_name(self.bufnr, ("diffview:///worktree_overview/%d"):format(self.bufnr))

  self:bind_keys()
  self:paint_placeholder()
end

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL_MS = 100

---Paint the placeholder line. Called without arguments for the static
---first frame; the spinner timer passes `frame_idx` and `elapsed_ms` to
---animate it. `render` later reuses `self.render_data` and overwrites
---whatever was last written here.
---@param frame_idx? integer
---@param elapsed_ms? integer
function WorktreeOverviewView:paint_placeholder(frame_idx, elapsed_ms)
  if not (self.bufnr and api.nvim_buf_is_valid(self.bufnr)) then
    return
  end
  self.render_data = self.render_data or renderer.RenderData("diffview-worktree-overview")
  local data = self.render_data ---@cast data RenderData
  data:clear()
  if frame_idx then
    local frame = SPINNER_FRAMES[(frame_idx % #SPINNER_FRAMES) + 1]
    data.lines = { ("%s Scanning worktrees... %.1fs"):format(frame, (elapsed_ms or 0) / 1000) }
  else
    data.lines = { "Scanning worktrees..." }
  end
  renderer.render(self.bufnr, data)
end

---Repaint the placeholder with the next spinner frame and flush. Driven
---by both the libuv timer (while `vim.wait` is pumping) and explicit
---calls from `refresh` at phase boundaries (where the main thread is
---doing pure Lua work the timer cannot preempt).
function WorktreeOverviewView:_tick_spinner()
  if not self._spinner_start then
    return
  end
  local elapsed_ms = math.floor((vim.uv.hrtime() - self._spinner_start) / 1e6)
  self:paint_placeholder(self._spinner_frame, elapsed_ms)
  self._spinner_frame = self._spinner_frame + 1
  vim.cmd("redraw")
end

---Start a libuv timer that calls `_tick_spinner` every `SPINNER_INTERVAL_MS`
---while `refresh` is blocked in `vim.wait`. `refresh` also ticks explicitly
---between phases, so a `render` pass that outlives the last timer-driven
---tick does not freeze on a stale frame.
function WorktreeOverviewView:_start_spinner()
  if self._spinner_timer then
    return
  end
  self._spinner_start = vim.uv.hrtime()
  self._spinner_frame = 0
  local timer = assert(vim.uv.new_timer())
  self._spinner_timer = timer
  timer:start(
    SPINNER_INTERVAL_MS,
    SPINNER_INTERVAL_MS,
    vim.schedule_wrap(function()
      if self._spinner_timer ~= timer then
        return
      end
      self:_tick_spinner()
    end)
  )
end

function WorktreeOverviewView:_stop_spinner()
  local timer = self._spinner_timer
  if not timer then
    return
  end
  self._spinner_timer = nil
  self._spinner_start = nil
  timer:stop()
  if not timer:is_closing() then
    timer:close()
  end
end

---@override
function WorktreeOverviewView:post_open()
  -- Force a redraw so the placeholder reaches the screen before
  -- `refresh` blocks on its synchronous git probes. Without this, nvim
  -- defers the new tabpage's first draw to the next event-loop return
  -- (well after refresh), so the user sees a frozen UI for the scan.
  vim.cmd("redraw")

  -- Emit `worktree_overview_opened` before the initial refresh so the
  -- lifecycle order a subscriber sees is `opened` then `refreshed`.
  -- The view is still being populated at this point (`self.ready` is
  -- false and `self.entries` is nil), but the handle alone is enough
  -- to prep per-view state; data arrives on the first
  -- `worktree_overview_refreshed`.
  DiffviewGlobal.emitter:emit("worktree_overview_opened", self)

  self:_start_spinner()
  local ok, err = pcall(function()
    self:refresh()
  end)
  self:_stop_spinner()
  if not ok then
    error(err)
  end
  self.ready = true
end

---Fire a batch of jobs concurrently and wait for all of them. The main
---thread blocks inside each `job:sync()`, but libuv keeps every other job
---running during the wait, so the batch is bounded by the slowest single
---call rather than their sum.
---@param jobs diffview.Job[]
---@param yield_between? boolean # When true, yield 1ms to the event loop
---  between syncs so a running spinner's scheduled callbacks drain. Omit
---  for refreshes with no spinner (e.g., `refresh_files`), so they don't
---  pay for a UI update that never happens.
local function run_batch(jobs, yield_between)
  if #jobs == 0 then
    return
  end
  Job.start_all(jobs)
  for _, j in ipairs(jobs) do
    j:sync()
    if yield_between then
      -- Yield to the event loop so the spinner timer's scheduled callback
      -- can run. Without this, when a `j:sync` returns immediately (the
      -- job finished during an earlier sync's `vim.wait`), the next sync
      -- starts before any main-loop iteration, scheduled callbacks pile
      -- up, and the user sees a stale spinner frame.
      vim.wait(1)
    end
  end
end

---Pull the worktree list from the adapter, collect per-worktree stats, and
---redraw the buffer. Runs two parallel batches: a shared base-resolution
---batch (5 `rev-parse` probes total, since linked worktrees share the ref
---database) then a stats batch (3 probes per non-bare worktree with the
---resolved base baked in). Everything in a batch runs concurrently;
---worktrees are not resolved serially.
function WorktreeOverviewView:refresh()
  local entries = self.adapter:worktree_list()
  if entries == nil then
    -- Keep the previous entries so a transient failure doesn't flash the
    -- view to empty, and distinguish failure from a genuinely empty list.
    utils.err("Failed to query worktree list.")
    self:render()
    return
  end
  local cfg = config.get_config().worktree_overview or {}

  -- Phase 1: resolve the default comparison base. Linked worktrees share
  -- the ref database, so `origin/HEAD`, `origin/main`, and friends are the
  -- same lookup in every worktree; one batch of probes (run against the
  -- first non-bare worktree) therefore answers for every row. A `base`
  -- override in config bypasses the probes entirely.
  local base_jobs = {}
  local base_parser
  local probe_cwd
  for _, e in ipairs(entries) do
    if not e.is_bare then
      probe_cwd = e.path
      break
    end
  end
  if not cfg.base and probe_cwd then
    local jobs, parse = self.adapter:build_default_base_probe_jobs(probe_cwd)
    base_parser = parse
    for _, j in ipairs(jobs) do
      base_jobs[#base_jobs + 1] = j
    end
  end
  local yield_between = self._spinner_start ~= nil
  run_batch(base_jobs, yield_between)
  self:_tick_spinner()

  local base = cfg.base or (base_parser and base_parser()) or nil

  -- Phase 2: with the shared base in hand, batch the three stats probes
  -- per worktree. Phase 2 cannot overlap phase 1 because each stats probe
  -- takes the resolved base as a CLI argument.
  local stats_jobs = {}
  local stats_parsers = {}
  for _, e in ipairs(entries) do
    if not e.is_bare then
      local jobs, parse = self.adapter:build_stats_probe_jobs(e.path, base)
      stats_parsers[e.path] = parse
      for _, j in ipairs(jobs) do
        stats_jobs[#stats_jobs + 1] = j
      end
    end
  end
  run_batch(stats_jobs, yield_between)
  self:_tick_spinner()

  for _, e in ipairs(entries) do
    local parse = stats_parsers[e.path]
    if parse then
      e.stats = parse()
    end
  end
  self:_tick_spinner()

  -- Resolve every row's status column up front so `render` is pure
  -- string plumbing instead of fanning out to each provider during the
  -- extmark pass. Providers may be expensive on first call (sidekick's,
  -- for instance, shells out to `/proc` + `lsof`); doing N of those
  -- while the spinner is stopped would freeze the UI post-spinner.
  self._status_by_path = {}
  for _, e in ipairs(entries) do
    self._status_by_path[e.path] = format_status(e)
  end
  self:_tick_spinner()

  self.entries = entries
  self:render()
  DiffviewGlobal.emitter:emit("worktree_overview_refreshed", self, entries)
end

---Collect the status column text for one entry, by polling every registered
---provider in order and joining their non-empty returns with a space.
---@param e GitAdapter.WorktreeEntry
---@return string
function format_status(e)
  if #status_providers == 0 then
    return ""
  end
  local parts = {}
  for _, fn in ipairs(status_providers) do
    local ok, result = pcall(fn, e)
    if ok and type(result) == "string" and result ~= "" then
      -- `nvim_buf_set_lines` rejects any embedded `\n` with E5086 and
      -- would propagate past the per-provider `pcall`, taking the whole
      -- view down. Flatten `\r` and `\n` to spaces defensively so a
      -- provider that leaks a trailing newline from a shell call (or
      -- returns a multi-line summary) cannot crash the render.
      result = result:gsub("[\r\n]+", " ")
      parts[#parts + 1] = result
    end
  end
  return table.concat(parts, " ")
end

---Pick the branch-column text and highlight for one entry.
---@param e GitAdapter.WorktreeEntry
---@param is_current boolean
---@return string label
---@return string hl
local function branch_label(e, is_current)
  if e.is_bare then
    return "(bare)", HL.bare
  end
  if e.is_detached then
    return ("(detached %s)"):format((e.head or ""):sub(1, 7)), HL.detached
  end
  return e.branch or "(unknown)", is_current and HL.branch_cur or HL.branch
end

---Byte length of the longest `/`-aligned prefix shared by every entry
---path (so no row ever shows a split basename). Returns 0 when there is
---nothing worth stripping; `path:sub(len + 1)` then yields the original
---path, so callers need no special case.
---@param entries GitAdapter.WorktreeEntry[]
---@return integer
local function common_dir_prefix_len(entries)
  if #entries < 2 then
    return 0
  end
  local first = entries[1].path
  local n = #first
  for i = 2, #entries do
    local other = entries[i].path
    local m = math.min(n, #other)
    local j = 0
    while j < m and first:byte(j + 1) == other:byte(j + 1) do
      j = j + 1
    end
    n = j
    if n == 0 then
      return 0
    end
  end
  -- Trim back to the last `/` so a split dir name is never shown. A match
  -- at position 1 is the Unix root `/`, and a match immediately after a
  -- `:` is a Windows drive-letter root like `C:/`; in either case the
  -- common prefix is just a filesystem root, so stripping it would turn
  -- absolute paths into relative ones (and leave a `/`-only entry empty).
  local sep = first:sub(1, n):find("/[^/]*$")
  if not sep or sep == 1 or first:sub(sep - 1, sep - 1) == ":" then
    return 0
  end
  return sep
end

---Measure the per-column widths needed to align every visible row. Numeric
---columns are measured as digit counts; the branch column is measured by
---display width so that double-wide chars don't break alignment. Pass
---`status_by_path` (nil when no status provider is registered) and the
---status column is sized to the widest resolved string across entries.
---@param entries GitAdapter.WorktreeEntry[]
---@param status_by_path? table<string, string>
---@return table
local function compute_widths(entries, status_by_path)
  local w = {
    branch = 1,
    status = 0,
    ahead = 1,
    behind = 1,
    files = 1,
    ins = 1,
    dels = 1,
    staged = 1,
    unstaged = 1,
    untracked = 1,
  }
  for _, e in ipairs(entries) do
    local label = branch_label(e, false)
    w.branch = math.max(w.branch, vim.fn.strdisplaywidth(label))
    if status_by_path then
      local s = status_by_path[e.path] or ""
      w.status = math.max(w.status, vim.fn.strdisplaywidth(s))
    end
    if e.stats then
      w.ahead = math.max(w.ahead, #tostring(e.stats.ahead))
      w.behind = math.max(w.behind, #tostring(e.stats.behind))
      w.files = math.max(w.files, #tostring(e.stats.changed_files))
      w.ins = math.max(w.ins, #tostring(e.stats.insertions))
      w.dels = math.max(w.dels, #tostring(e.stats.deletions))
      w.staged = math.max(w.staged, #tostring(e.stats.staged))
      w.unstaged = math.max(w.unstaged, #tostring(e.stats.unstaged))
      w.untracked = math.max(w.untracked, #tostring(e.stats.untracked))
      -- Reserve the trio's columns both when a dirty count is non-zero AND
      -- when a status probe errored on this row. Without the second
      -- condition an all-clean batch where one row's `git status` failed
      -- would leave `trio_w = 0`, so `push_stats_cells` returns before
      -- it can render the `status_unknown` markers, and the row visually
      -- claims a clean worktree the resolver could not actually confirm.
      if
        e.stats.staged > 0
        or e.stats.unstaged > 0
        or e.stats.untracked > 0
        or vim.tbl_contains(e.stats.errors, "status")
      then
        w.any_dirty = true
      end
    end
  end
  return w
end

---Push a `{text, hl?}` segment onto the current line and record its byte
---range as a highlight on `data.hl`. Byte offsets (not display width) are
---correct here because extmarks address bytes.
---@param ctx { data: RenderData, line_idx: integer, line: string[], col: integer }
---@param text string
---@param hl? string
local function push(ctx, text, hl)
  if text == "" then
    return
  end
  if hl then
    ctx.data.hl[#ctx.data.hl + 1] = {
      group = hl,
      line_idx = ctx.line_idx,
      first = ctx.col,
      last = ctx.col + #text,
    }
  end
  ctx.line[#ctx.line + 1] = text
  ctx.col = ctx.col + #text
end

---@param ctx table
---@param n integer # Number of spaces; nil-safe clamp to zero.
local function pad(ctx, n)
  if n and n > 0 then
    push(ctx, string.rep(" ", n))
  end
end

---Marker used when a probe is unavailable (e.g., no base resolved, or a
---sub-probe exited non-zero). Zero would silently misrepresent the row as
---clean, so each affected cell shows a dim dash instead of a digit.
local UNKNOWN = "─"

---Resolve a counter cell's `(text, display_width, hl)` tuple. When the
---probe is unavailable the cell collapses to a dim `UNKNOWN` marker
---(display width 1); otherwise it uses the formatted value with the
---caller-supplied highlight.
---@param unknown boolean
---@param n integer
---@param hl string
---@return string text, integer width, string hl
local function fmt_cell(unknown, n, hl)
  if unknown then
    return UNKNOWN, 1, HL.dim
  end
  local s = tostring(n)
  return s, #s, hl
end

---Push the ahead/behind/files/+ins/-dels run and the staged/unstaged/
---untracked run for one entry.
---@param ctx table
---@param e GitAdapter.WorktreeEntry
---@param w table
local function push_stats_cells(ctx, e, w)
  -- Display-column total of the dirty trio and the branch/diff run,
  -- including the inter-cell gaps that `push_stats_cells` emits around
  -- the arrows, 'f' suffix, and +/- prefixes. The arrows are 3 bytes but
  -- 1 display column each, so byte counts and display columns diverge in
  -- the populated row; this function pads by display column.
  local trio_w = w.any_dirty and (w.staged + 2 + w.unstaged + 2 + w.untracked + 2) or 0

  if e.is_bare or not e.stats then
    local blank = (w.ahead + 2) + (w.behind + 3) + (w.files + 3) + (w.ins + 2) + (w.dels + 3)
    pad(ctx, blank + trio_w)
    return
  end
  local s = e.stats ---@cast s GitAdapter.WorktreeStats

  -- Branch counters: nil base means the probes were skipped entirely, so
  -- ahead/behind would silently read as 0; `errors` lists sub-probes that
  -- exited non-zero. Either case renders the affected cells as unknown
  -- so a stale probe doesn't masquerade as a clean row.
  local branch_unknown = s.base == nil or vim.tbl_contains(s.errors, "rev-list")
  local diff_unknown = s.base == nil or vim.tbl_contains(s.errors, "diff")
  local status_unknown = vim.tbl_contains(s.errors, "status")

  local text, cw, hl
  text, cw, hl = fmt_cell(branch_unknown, s.ahead, HL.counter)
  pad(ctx, w.ahead - cw)
  push(ctx, "↑", HL.arrow)
  push(ctx, text, hl)
  push(ctx, " ")

  text, cw, hl = fmt_cell(branch_unknown, s.behind, HL.counter)
  pad(ctx, w.behind - cw)
  push(ctx, "↓", HL.arrow)
  push(ctx, text, hl)
  push(ctx, "  ")

  text, cw, hl = fmt_cell(diff_unknown, s.changed_files, HL.counter)
  pad(ctx, w.files - cw)
  push(ctx, text, hl)
  push(ctx, "f", HL.files_suffix)
  push(ctx, "  ")

  text, cw, hl = fmt_cell(diff_unknown, s.insertions, HL.insertions)
  pad(ctx, w.ins - cw)
  push(ctx, "+" .. text, hl)
  push(ctx, " ")

  text, cw, hl = fmt_cell(diff_unknown, s.deletions, HL.deletions)
  pad(ctx, w.dels - cw)
  push(ctx, "-" .. text, hl)
  push(ctx, "  ")

  -- Dirty trio (`<n>s <n>u <n>?`, mirroring the git-status trio): pad
  -- past it entirely for a clean row; otherwise show all three with
  -- zero components dim so the user can tell at a glance which kind of
  -- dirt is present. When the batch has no dirty rows at all, `trio_w`
  -- is zero and this pad is a no-op. When the status probe errored the
  -- counts are not meaningful, so render unknown markers in place of
  -- zeros rather than claiming a clean row.
  if trio_w == 0 then
    return
  end
  if not status_unknown and s.staged == 0 and s.unstaged == 0 and s.untracked == 0 then
    pad(ctx, trio_w)
    return
  end
  local function dirty(count, width, hl_known, suffix)
    local t, w1, h = fmt_cell(status_unknown, count, count > 0 and hl_known or HL.dim)
    pad(ctx, width - w1)
    push(ctx, t, h)
    push(ctx, suffix, h)
    push(ctx, " ")
  end
  dirty(s.staged, w.staged, HL.staged, "s")
  dirty(s.unstaged, w.unstaged, HL.unstaged, "u")
  dirty(s.untracked, w.untracked, HL.untracked, "?")
end

---Build the coloured, aligned buffer contents using the project's
---renderer. Each entry becomes a single row with these columns, left to
---right: cursor marker, branch label, branch state (ahead / behind /
---files / insertions / deletions), dirty counts, path. Numeric columns
---right-align to the widest value across entries, so the rows stack
---visually.
function WorktreeOverviewView:render()
  if not (self.bufnr and api.nvim_buf_is_valid(self.bufnr)) then
    return
  end

  self.render_data = self.render_data or renderer.RenderData("diffview-worktree-overview")
  local data = self.render_data ---@cast data RenderData
  data:clear()

  local cwd_top = self.cwd_path
  local cfg = config.get_config().worktree_overview or {}
  local has_status = #status_providers > 0

  -- Hide bare worktrees by default; `enter_selected` would reject them
  -- anyway. `self.entries` is left intact so callers that iterate it see
  -- every worktree; `_visible_entries` is what the cursor maps against.
  local visible = {}
  for _, e in ipairs(self.entries) do
    if cfg.include_bare or not e.is_bare then
      visible[#visible + 1] = e
    end
  end
  self._visible_entries = visible

  if #visible == 0 then
    data.lines = { "(no worktrees)" }
    renderer.render(self.bufnr, data)
    return
  end

  local w = compute_widths(visible, has_status and self._status_by_path or nil)
  local prefix_len = common_dir_prefix_len(visible)

  for i, e in ipairs(visible) do
    local is_current = cwd_top and e.path == cwd_top or false
    local ctx = { data = data, line_idx = i - 1, line = {}, col = 0 }

    push(ctx, is_current and "* " or "  ", is_current and HL.cursor_marker or nil)

    local label, label_hl = branch_label(e, is_current)
    push(ctx, label, label_hl)
    pad(ctx, w.branch - vim.fn.strdisplaywidth(label))
    push(ctx, "  ")

    -- Omit the status column entirely when no provider is registered so
    -- the stock view does not render dead space.
    if has_status then
      -- Resolved in `refresh`; the nil fallback covers a re-render
      -- after a transient `worktree_list` failure that returned before
      -- the map was populated.
      local status = (self._status_by_path or {})[e.path] or ""
      push(ctx, status, HL.status)
      pad(ctx, w.status - vim.fn.strdisplaywidth(status))
      push(ctx, "  ")
    end

    push_stats_cells(ctx, e, w)
    push(ctx, " ")
    push(ctx, e.path:sub(prefix_len + 1), HL.path)

    data.lines[i] = table.concat(ctx.line)
  end

  renderer.render(self.bufnr, data)
end

---Install the user's `keymaps.worktree_overview` block on the overview
---buffer. Each entry is `{ mode, lhs, rhs, opts? }` matching the shape of
---every other panel in diffview. The default rhs values are action stubs
---that emit on the current view's emitter, which `init_event_listeners`
---routes to the methods on this view.
function WorktreeOverviewView:bind_keys()
  local conf = require("diffview.config").get_config()
  local default_opt = { buffer = self.bufnr, nowait = true, silent = true }
  for _, mapping in ipairs(conf.keymaps.worktree_overview or {}) do
    local opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufnr })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end
end

---Open a DiffView scoped to the worktree on the cursor line.
---Builds a fresh git adapter at that worktree's toplevel so base probing
---sees that worktree's refs (branch state can differ across worktrees),
---then delegates to `diffview.open` via `-C=<path>`. When a default base
---resolves, the diff is scoped to `<base>...HEAD` (merge-base to HEAD) so
---only commits unique to the branch show up; otherwise the DiffView opens
---with no rev arg, falling back to working-tree-vs-HEAD.
function WorktreeOverviewView:enter_selected()
  -- Read from the current window, not the cached `self.winid`, so a split
  -- that leaves the overview buffer in a different window doesn't crash
  -- with "Invalid window id" when the original window is closed.
  local lnum = api.nvim_win_get_cursor(0)[1]
  local entry = (self._visible_entries or self.entries)[lnum]
  if not entry then
    utils.info("No worktree on this line.")
    return
  end
  if entry.is_bare then
    utils.err("Cannot open a DiffView on a bare worktree.")
    return
  end
  if entry.is_prunable then
    local msg = "Cannot open a DiffView on a prunable worktree: " .. entry.path
    if entry.prune_reason then
      msg = msg .. " (" .. entry.prune_reason .. ")"
    end
    utils.err(msg)
    return
  end

  local cfg = config.get_config().worktree_overview or {}
  local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
  local target = GitAdapter({
    toplevel = entry.path,
    cpath = entry.path,
    path_args = {},
  })

  local base = cfg.base or target:resolve_default_base()
  local args = { "-C=" .. entry.path }
  if base then
    -- `A...` is git shorthand for `A...HEAD`: commits reachable from HEAD
    -- but not from the merge-base with `A`. Matches the usual review scope.
    table.insert(args, base .. "...")
  end

  -- Emit before dispatching so a subscriber can prepare per-worktree state
  -- (focus a session, re-arm a status provider) in time for the DiffView.
  DiffviewGlobal.emitter:emit("worktree_overview_entered", self, entry)

  require("diffview").open(args)
end

---@override
function WorktreeOverviewView:close()
  if self.bufnr and api.nvim_buf_is_valid(self.bufnr) then
    pcall(api.nvim_buf_delete, self.bufnr, { force = true })
  end
  View.close(self)
end

M.WorktreeOverviewView = WorktreeOverviewView

return M
