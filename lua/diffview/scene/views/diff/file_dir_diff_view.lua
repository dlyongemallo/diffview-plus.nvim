local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local Diff4Mixed = lazy.access("diffview.scene.layouts.diff_4_mixed", "Diff4Mixed") ---@type Diff4Mixed|LazyModule
local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local FileEntry = lazy.access("diffview.scene.file_entry", "FileEntry") ---@type FileEntry|LazyModule
local NullDiffView = lazy.access("diffview.scene.views.diff.null_diff_view", "NullDiffView") ---@type NullDiffView|LazyModule
local NullRev = lazy.access("diffview.vcs.adapters.null.rev", "NullRev") ---@type NullRev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local View = lazy.access("diffview.scene.view", "View") ---@type View|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local fmt = string.format
local pl = lazy.access(utils, "path") --[[@as PathLib ]]
local uv = vim.uv

local M = {}

local FILES_EQUAL_CHUNK = 65536

---Content-equality check used to filter out files that exist on both sides
---but are identical. Reads both files in 64 KiB chunks via `uv.fs_read` and
---bails on the first mismatch, so identical files no larger than the
---kernel's read-ahead cache pay one buffer's worth of memory and differing
---files don't have to be fully read.
---@param a string
---@param b string
---@return boolean
local function files_equal(a, b)
  local stat_a = pl:stat(a)
  local stat_b = pl:stat(b)
  if stat_a and stat_b and stat_a.size ~= stat_b.size then
    return false
  end

  local fd_a = uv.fs_open(a, "r", 0)
  if not fd_a then
    return false
  end
  local fd_b = uv.fs_open(b, "r", 0)
  if not fd_b then
    uv.fs_close(fd_a)
    return false
  end

  local equal = true
  while true do
    local chunk_a = uv.fs_read(fd_a, FILES_EQUAL_CHUNK) or ""
    local chunk_b = uv.fs_read(fd_b, FILES_EQUAL_CHUNK) or ""
    if chunk_a ~= chunk_b then
      equal = false
      break
    end
    if chunk_a == "" then
      break
    end
  end
  uv.fs_close(fd_a)
  uv.fs_close(fd_b)
  return equal
end

---Resolve the per-file status by comparing existence and content on the two
---reference sides ($left and $right). The $output side, when present, does
---not participate in the diff classification: it starts as a copy of one
---side and the user mutates it.
---@param left_root string
---@param right_root string
---@return table<string, "A"|"D"|"M">
function M.diff_dirs(left_root, right_root)
  local left_set, right_set = {}, {}
  for _, rel in ipairs(pl:files_under(left_root)) do
    left_set[rel] = true
  end
  for _, rel in ipairs(pl:files_under(right_root)) do
    right_set[rel] = true
  end

  local entries = {}
  for rel in pairs(left_set) do
    if right_set[rel] then
      if not files_equal(pl:join(left_root, rel), pl:join(right_root, rel)) then
        entries[rel] = "M"
      end
    else
      entries[rel] = "D"
    end
  end
  for rel in pairs(right_set) do
    if not left_set[rel] then
      entries[rel] = "A"
    end
  end
  return entries
end

---FileDirDiffView compares two on-disk directories (and optionally writes
---results into a third "$output" directory) without consulting any VCS. The
---file panel lists every path that differs in content or existence between
---`$left` and `$right`. Each file entry's b-side is bound to a real on-disk
---path via `RevType.LOCAL` so `:write` flushes to that location.
---
---Two-pane mode mirrors `FileDiffView`: a = `$left/<rel>`, b = `$right/<rel>`,
---both LOCAL and editable. Three-pane mode mirrors jj's diff-editor 3-pane
---contract: a = `$left/<rel>` (read-only), b = `$output/<rel>` (LOCAL,
---editable), c = `$right/<rel>` (read-only).
---@class FileDirDiffView : NullDiffView
---@operator call : FileDirDiffView
---@field left_path string Absolute path to the "$left" directory.
---@field right_path string Absolute path to the "$right" directory.
---@field output_path? string Absolute path to the editable "$output" directory; nil for 2-pane mode.
local FileDirDiffView = oop.create_class("FileDirDiffView", NullDiffView.__get())

---@class FileDirDiffView.init.Opt
---@field adapter NullAdapter
---@field left_path string
---@field right_path string
---@field output_path? string
---@field diffs? table<string, "A"|"D"|"M"> # Precomputed `M.diff_dirs` result; lets callers skip a redundant walk after checking for empty diffs.

---@param opt FileDirDiffView.init.Opt
function FileDirDiffView:init(opt)
  local three_pane = opt.output_path ~= nil
  local a_rev = NullRev(RevType.CUSTOM) -- read-only $left (3-pane) or LOCAL $left (2-pane); fixed up below
  local b_rev = NullRev(RevType.LOCAL) -- editable target ($right in 2-pane, $output in 3-pane)
  local c_rev = three_pane and NullRev(RevType.CUSTOM) or nil

  if not three_pane then
    -- 2-pane mirrors `FileDiffView`: both sides LOCAL so the user can edit
    -- either. jj reads back from `$right` after exit; edits to `$left` are
    -- ignored on the jj side and persist as filesystem edits otherwise.
    a_rev = NullRev(RevType.LOCAL)
  end

  self:super({
    adapter = opt.adapter,
    path_args = {},
    rev_arg = nil,
    left = a_rev,
    right = b_rev,
    options = {},
  })

  self.left_path = opt.left_path
  self.right_path = opt.right_path
  self.output_path = opt.output_path

  self.panel.rev_pretty_name = fmt(
    "%s \u{2194} %s",
    pl:basename(self.left_path),
    pl:basename(self.output_path or self.right_path)
  )

  local diffs = opt.diffs or M.diff_dirs(self.left_path, self.right_path)
  local rels = vim.tbl_keys(diffs)
  table.sort(rels)

  local entries = {}
  for _, rel in ipairs(rels) do
    entries[#entries + 1] = self:_build_entry(rel, diffs[rel], a_rev, b_rev, c_rev)
  end

  self.files:set_working(entries)
  self.files:update_file_trees()
end

---Build the FileEntry for a single differing path. Mirrors the per-symbol
---`File` construction used by `FileMergeView`: each window's underlying
---`File` is built by hand so its `path` can point at a different on-disk
---absolute path while sharing one `NullAdapter`.
---@param rel string Relative path under the diff roots.
---@param status "A"|"D"|"M"
---@param a_rev Rev
---@param b_rev Rev
---@param c_rev? Rev
---@return FileEntry
function FileDirDiffView:_build_entry(rel, status, a_rev, b_rev, c_rev)
  local three_pane = c_rev ~= nil
  local left_abs = pl:join(self.left_path, rel)
  local right_abs = pl:join(self.right_path, rel)
  local b_abs = three_pane and pl:join(self.output_path, rel) or right_abs

  local read_lines = NullDiffView.__get().read_lines

  local function make_file(path, rev, label, reader)
    local f = File({
      adapter = self.adapter,
      path = path,
      kind = "working",
      get_data = reader,
      rev = rev,
    }) --[[@as vcs.File ]]
    if label then
      f.winbar = fmt(" %s - %s", label, rel)
    end
    return f
  end

  local a_file, b_file, c_file
  if three_pane then
    a_file = make_file(left_abs, a_rev, "LEFT", function()
      return read_lines(left_abs)
    end)
    b_file = make_file(b_abs, b_rev, "OUTPUT", nil)
    c_file = make_file(right_abs, c_rev, "RIGHT", function()
      return read_lines(right_abs)
    end)
  else
    -- Both sides editable; mirrors `FileDiffView`. No winbar override so the
    -- default WORKING TREE winbar from `File:init` is used, matching
    -- `:DiffviewDiffFiles`.
    a_file = make_file(left_abs, a_rev, nil, nil)
    b_file = make_file(b_abs, b_rev, nil, nil)
  end

  local layout_class
  if three_pane then
    layout_class = View.__get().get_default_merge_layout()
    if layout_class == Diff4Mixed.__get() then
      layout_class = View.__get().get_default_diff3()
    end
  else
    layout_class = View.__get().get_default_layout()
  end
  local layout = layout_class({ a = a_file, b = b_file, c = c_file })

  return FileEntry({
    adapter = self.adapter,
    path = rel,
    status = status,
    kind = "working",
    revs = { a = a_rev, b = b_rev, c = c_rev },
    layout = layout,
  })
end

---@override
---Restore the default `StandardView` panel behaviour: a directory diff has
---N entries and the file panel is genuinely useful, unlike the single-entry
---`FileDiffView` / `FileMergeView` cases that `NullDiffView` defaults to
---hiding. We bypass `NullDiffView:init_layout` rather than skip-call its
---super because there is no `super:super` idiom in this OOP system.
function FileDirDiffView:init_layout()
  StandardView.__get().init_layout(self)
end

-- `post_open` and `update_files` are inherited from `NullDiffView`.

M.FileDirDiffView = FileDirDiffView

return M
