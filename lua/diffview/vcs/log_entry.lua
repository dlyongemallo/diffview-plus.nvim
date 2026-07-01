local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local FileEntry = lazy.access("diffview.scene.file_entry", "FileEntry") --[[@as FileEntry ]]
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@class LogEntry : diffview.Object
---@operator call : LogEntry
---@field path_args string[]
---@field commit Commit
---@field files FileEntry[]
---@field status string
---@field stats GitStats
---@field single_file boolean
---@field folded boolean
---@field nulled boolean
---@field is_pushed boolean Whether this commit is reachable from a remote-tracking ref (i.e. has been pushed).
---@field is_merged boolean Whether this commit is reachable from a `main` or `master` branch (local or remote-tracking). For Git the set of trunk branch names is hard-coded; for jj it is resolved via `trunk()`. Only populated when `subject_highlight = "merge_aware"` on adapters that compute it (Git, jj); otherwise `false`.
---@field _pin_overlays? table<string, FileEntry> Cache of transient FileEntry overlays keyed by `pinned_path`, populated when a pinned file isn't touched by this commit.
local LogEntry = oop.create_class("LogEntry")

function LogEntry:init(opt)
  self.path_args = opt.path_args
  self.commit = opt.commit
  self.files = opt.files
  self.folded = true
  self.single_file = opt.single_file
  self.nulled = utils.sate(opt.nulled, false)
  if opt.is_pushed ~= nil then
    self.is_pushed = opt.is_pushed and true or false
  else
    -- Fallback used when no precomputed reachability info is supplied (e.g.
    -- the Mercurial adapter): infer "pushed" from a remote ref decoration.
    -- This only catches commits at remote branch/tag tips, not the full set
    -- reachable from upstream.
    self.is_pushed = opt.commit
        and opt.commit.ref_names
        and (opt.commit.ref_names:find("origin/") or opt.commit.ref_names:find("upstream/") or opt.commit.ref_names:find(
          "remotes/"
        ))
        and true
      or false
  end
  -- No decoration-based fallback: "reachable from a main branch" is
  -- supplied by the adapter's `merge_aware` precompute (Git and jj).
  -- Other adapters, or `subject_highlight ~= "merge_aware"`, leave this at
  -- false.
  self.is_merged = opt.is_merged and true or false
  self:update_status()
  self:update_stats()
end

function LogEntry:destroy()
  for _, file in ipairs(self.files) do
    file:destroy()
  end
  if self._pin_overlays then
    for _, overlay in pairs(self._pin_overlays) do
      overlay:destroy()
    end
    self._pin_overlays = nil
  end
end

function LogEntry:update_status()
  self.status = nil
  local missing_status = 0

  for _, file in ipairs(self.files) do
    if not file.status then
      missing_status = missing_status + 1
    else
      if self.status and file.status ~= self.status then
        self.status = "M"
        return
      elseif self.status ~= file.status then
        self.status = file.status
      end
    end
  end

  if missing_status < #self.files and not self.status then
    self.status = "X"
  end
end

function LogEntry:update_stats()
  self.stats = { additions = 0, deletions = 0 }
  local missing_stats = 0

  for _, file in ipairs(self.files) do
    if not file.stats then
      missing_stats = missing_stats + 1
    else
      self.stats.additions = self.stats.additions + file.stats.additions
      self.stats.deletions = self.stats.deletions + file.stats.deletions
    end
  end

  if missing_stats == #self.files then
    self.stats = nil
  end
end

---@param path string
---@return diff.FileEntry?
function LogEntry:get_diff(path)
  if not self.commit.diff then
    return nil
  end

  for _, diff_entry in ipairs(self.commit.diff) do
    if path == (diff_entry.path_new or diff_entry.path_old) then
      return diff_entry
    end
  end
end

---@param adapter VCSAdapter
---@param opt table
---@return LogEntry
function LogEntry.new_null_entry(adapter, opt)
  opt = opt or {}

  return LogEntry(vim.tbl_extend("force", opt, {
    nulled = true,
    files = { FileEntry.new_null_entry(adapter) },
  }))
end

M.LogEntry = LogEntry
return M
