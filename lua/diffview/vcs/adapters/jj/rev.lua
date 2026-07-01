local oop = require("diffview.oop")
local Rev = require("diffview.vcs.rev").Rev
local RevType = require("diffview.vcs.rev").RevType

local M = {}

---@class JjRev : Rev
local JjRev = oop.create_class("JjRev", Rev)

-- 40-hex-zero commit_id emitted by jj for the null tree (added by the
-- git-backend for the empty root parent). Used by the null-tree Rev that
-- backs the left side of an initial-commit diff.
JjRev.NULL_TREE_SHA = "0000000000000000000000000000000000000000"

-- 32-`z` change_id emitted by jj for the synthetic root commit. Used by the
-- file-history parser to strip the root from its parent list and from the
-- pushed/merged reachability sets, which key by change_id.
JjRev.NULL_CHANGE_ID = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"

---@param rev_type RevType
---@param revision? string|number
---@param track_head? boolean
function JjRev:init(rev_type, revision, track_head)
  self:super(rev_type, revision, track_head)
end

---@return JjRev
function JjRev.new_null_tree()
  return JjRev(RevType.COMMIT, JjRev.NULL_TREE_SHA)
end

---@param abbrev_len? integer
---@return string
function JjRev:object_name(abbrev_len)
  if self.commit then
    if abbrev_len then
      return self.commit:sub(1, abbrev_len)
    end

    return self.commit
  end

  return "UNKNOWN"
end

---@param rev_from JjRev|string
---@param rev_to JjRev|string
---@return string?
function JjRev.to_range(rev_from, rev_to)
  local name_from
  if type(rev_from) == "string" then
    name_from = rev_from
  else
    name_from = rev_from:object_name()
  end
  local name_to

  if rev_to then
    if type(rev_to) == "string" then
      name_to = rev_to
    elseif rev_to.type == RevType.COMMIT then
      name_to = rev_to:object_name()
    end
  end

  if name_to then
    return name_from .. ".." .. name_to
  end

  -- Single revision: just return the identifier directly. Unlike Git's
  -- "A^!" syntax, Jujutsu treats a bare revision ID as a valid revset.
  return name_from
end

M.JjRev = JjRev
return M
