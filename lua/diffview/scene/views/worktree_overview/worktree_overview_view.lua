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

---Skeleton view that lists every linked git worktree in a single buffer.
---@class WorktreeOverviewView : View
---@field adapter GitAdapter
---@field cwd_path? string # Toplevel of the worktree the overview was launched from. Nil when launched from outside any worktree (e.g., a bare repo root); the view then stars no row.
---@field entries GitAdapter.WorktreeEntry[]
---@field bufnr integer?
---@field winid integer?
---@field render_data RenderData?
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
end

---@override
function WorktreeOverviewView:post_open()
  self:refresh()
  self.ready = true
end

---Fire a batch of jobs concurrently and wait for all of them. The main
---thread blocks inside each `job:sync()`, but libuv keeps every other job
---running during the wait, so the batch is bounded by the slowest single
---call rather than their sum.
---@param jobs diffview.Job[]
local function run_batch(jobs)
  if #jobs == 0 then
    return
  end
  Job.start_all(jobs)
  for _, j in ipairs(jobs) do
    j:sync()
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
  run_batch(base_jobs)

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
  run_batch(stats_jobs)

  for _, e in ipairs(entries) do
    local parse = stats_parsers[e.path]
    if parse then
      e.stats = parse()
    end
  end

  self.entries = entries
  self:render()
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

---Measure the per-column widths needed to align every visible row. Numeric
---columns are measured as digit counts; the branch column is measured by
---display width so that double-wide chars don't break alignment.
---@param entries GitAdapter.WorktreeEntry[]
---@return table
local function compute_widths(entries)
  local w = {
    branch = 1,
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

  local w = compute_widths(visible)

  for i, e in ipairs(visible) do
    local is_current = cwd_top and e.path == cwd_top or false
    local ctx = { data = data, line_idx = i - 1, line = {}, col = 0 }

    push(ctx, is_current and "* " or "  ", is_current and HL.cursor_marker or nil)

    local label, label_hl = branch_label(e, is_current)
    push(ctx, label, label_hl)
    pad(ctx, w.branch - vim.fn.strdisplaywidth(label))
    push(ctx, "  ")

    push_stats_cells(ctx, e, w)
    push(ctx, " ")
    push(ctx, e.path, HL.path)

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
