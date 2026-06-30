local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local Diff3Hor = lazy.access("diffview.scene.layouts.diff_3_hor", "Diff3Hor") ---@type Diff3Hor|LazyModule
local Diff4Mixed = lazy.access("diffview.scene.layouts.diff_4_mixed", "Diff4Mixed") ---@type Diff4Mixed|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local FileEntry = lazy.access("diffview.scene.file_entry", "FileEntry") ---@type FileEntry|LazyModule
local NullDiffView = lazy.access("diffview.scene.views.diff.null_diff_view", "NullDiffView") ---@type NullDiffView|LazyModule
local NullRev = lazy.access("diffview.vcs.adapters.null.rev", "NullRev") ---@type NullRev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local fmt = string.format
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

local M = {}

---FileMergeView is the entry point used by external merge drivers (jj, hg
---resolve, etc.) that pass on-disk file paths to the editor. Unlike
---`DiffView` it does not query a VCS: the four buffer sources come straight
---from the filesystem. The `output` window is bound to the real file on
---disk via `RevType.LOCAL` so `:write` flushes there; the read-only sides
---use `RevType.CUSTOM` with a `get_data` reader.
---@class FileMergeView : NullDiffView
---@operator call : FileMergeView
---@field output_path string # Absolute path the resolved content writes back to.
---@field base_path? string # Absolute path of the common ancestor; nil for 3-way merges.
---@field left_path string # Absolute path of OURS / "left" side.
---@field right_path string # Absolute path of THEIRS / "right" side.
local FileMergeView = oop.create_class("FileMergeView", NullDiffView.__get())

---@class FileMergeView.init.Opt
---@field adapter NullAdapter
---@field output_path string
---@field base_path? string
---@field left_path string
---@field right_path string

---@param opt FileMergeView.init.Opt
function FileMergeView:init(opt)
  local output_rev = NullRev(RevType.LOCAL)
  local left_rev = NullRev(RevType.CUSTOM)
  local right_rev = NullRev(RevType.CUSTOM)
  local base_rev = opt.base_path and NullRev(RevType.CUSTOM) or nil

  -- DiffView's `left`/`right` are used for the panel header and rev-arg
  -- bookkeeping. We pass the OURS/THEIRS revs here since they correspond
  -- to the visual left and right sides of the diff.
  self:super({
    adapter = opt.adapter,
    path_args = {},
    rev_arg = nil,
    left = left_rev,
    right = right_rev,
    options = {},
  })

  self.output_path = opt.output_path
  self.base_path = opt.base_path
  self.left_path = opt.left_path
  self.right_path = opt.right_path

  self.panel.rev_pretty_name = pl:basename(self.output_path)

  local read_lines = NullDiffView.__get().read_lines
  local function make_file(path, rev, label, reader_path)
    local f = File({
      adapter = self.adapter,
      path = path,
      kind = "conflicting",
      get_data = reader_path and function()
        return read_lines(reader_path)
      end or nil,
      rev = rev,
    }) --[[@as vcs.File ]]
    f.winbar = fmt(" %s - %s", label, pl:basename(path))
    return f
  end

  local a_file = make_file(self.left_path, left_rev, "OURS (Current changes)", self.left_path)
  local b_file = make_file(self.output_path, output_rev, "MERGED (Output)", nil)
  local c_file = make_file(self.right_path, right_rev, "THEIRS (Incoming changes)", self.right_path)

  local layout
  if self.base_path then
    local d_file = make_file(self.base_path, base_rev, "BASE (Common ancestor)", self.base_path)
    layout = Diff4Mixed.__get()({ a = a_file, b = b_file, c = c_file, d = d_file })
  else
    layout = Diff3Hor.__get()({ a = a_file, b = b_file, c = c_file })
  end

  local entry = FileEntry({
    adapter = self.adapter,
    path = self.output_path,
    status = "U",
    kind = "conflicting",
    revs = { a = left_rev, b = output_rev, c = right_rev, d = base_rev },
    layout = layout,
  })

  self.files:set_conflicting({ entry })
  self.files:update_file_trees()

  -- Keep `merge_only` keymaps visible in the help panel (filtered by
  -- `actions._is_applicable` via `merge_ctx ~= nil`). Field values are
  -- unread: their only consumer, `FileEntry:update_merge_context`, runs
  -- from `DiffView:update_files`, which `NullDiffView` no-ops.
  self.merge_ctx = { ours = { hash = "" }, theirs = { hash = "" }, base = { hash = "" } }
end

-- `post_open`, `init_layout`, and `update_files` are inherited from
-- `NullDiffView`.

M.FileMergeView = FileMergeView

return M
