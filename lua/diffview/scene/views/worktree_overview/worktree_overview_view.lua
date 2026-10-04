local lazy = require("diffview.lazy")

local View = lazy.access("diffview.scene.view", "View") ---@type View|LazyModule
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
  path = "DiffviewFilePanelPath",
}

local M = {}

---Skeleton view that lists every linked git worktree in a single buffer.
---Later passes layer on stats, status, selection->DiffView wiring, and
---companion-plugin hooks; the skeleton establishes the plumbing (open,
---refresh, close, command registration) and the coloured, aligned
---rendering surface that those passes extend.
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

---Set up the single scratch window inside the new tabpage. The parent
---`View:open()` creates the tab and calls into here.
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

---Pull the worktree list from the adapter and redraw the buffer. Sync for
---now; stats collection and parallel probing come in follow-up passes.
function WorktreeOverviewView:refresh()
  local entries = self.adapter:worktree_list()
  if entries == nil then
    -- Keep the previous entries so a transient failure doesn't flash the
    -- view to empty, and distinguish failure from a genuinely empty list.
    utils.err("Failed to query worktree list.")
  else
    self.entries = entries
  end
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

---Build the coloured buffer contents using the project's renderer. Each
---entry becomes one row: `<marker> <branch>  <path>`, with the branch
---label left-padded by display width so double-wide chars don't break
---alignment. The current worktree's marker and branch pick up the
---"selected" group, matching `DiffviewFileHistory`'s active-file styling.
function WorktreeOverviewView:render()
  if not (self.bufnr and api.nvim_buf_is_valid(self.bufnr)) then
    return
  end

  self.render_data = self.render_data or renderer.RenderData("diffview-worktree-overview")
  local data = self.render_data ---@cast data RenderData
  data:clear()

  local cwd_top = self.cwd_path

  if #self.entries == 0 then
    data.lines = { "(no worktrees)" }
    renderer.render(self.bufnr, data)
    return
  end

  -- Branch column width, measured by display width so unicode in branch
  -- names (arrows, emoji) doesn't throw off alignment.
  local branch_w = 1
  for _, e in ipairs(self.entries) do
    local label = branch_label(e, false)
    branch_w = math.max(branch_w, vim.fn.strdisplaywidth(label))
  end

  for i, e in ipairs(self.entries) do
    local is_current = cwd_top and e.path == cwd_top or false
    local line = {}
    local col = 0

    local function push(text, hl)
      if text == "" then
        return
      end
      if hl then
        data.hl[#data.hl + 1] = {
          group = hl,
          line_idx = i - 1,
          first = col,
          last = col + #text,
        }
      end
      line[#line + 1] = text
      col = col + #text
    end

    push(is_current and "* " or "  ", is_current and HL.cursor_marker or nil)
    local label, label_hl = branch_label(e, is_current)
    push(label, label_hl)
    push(string.rep(" ", branch_w - vim.fn.strdisplaywidth(label) + 2))
    push(e.path, HL.path)

    data.lines[i] = table.concat(line)
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

---Placeholder: resolves the entry under the cursor and (eventually) opens
---a DiffView scoped to that worktree. The real implementation needs the
---base resolution logic from the next commit; for the skeleton we just
---surface the selection so the UI loop is exercisable.
function WorktreeOverviewView:enter_selected()
  -- Read from the current window, not the cached `self.winid`, so a split
  -- that leaves the overview buffer in a different window doesn't crash
  -- with "Invalid window id" when the original window is closed.
  local lnum = api.nvim_win_get_cursor(0)[1]
  local entry = self.entries[lnum]
  if not entry then
    utils.info("No worktree on this line.")
    return
  end
  utils.info(("Selected worktree: %s"):format(entry.path))
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
