local oop = require("diffview.oop")
local Rev = require("diffview.vcs.rev").Rev
local RevType = require("diffview.vcs.rev").RevType

local M = {}

---@class P4Rev : Rev
local P4Rev = oop.create_class("P4Rev", Rev)

-- Perforce uses #none or @0 for non-existent revisions
P4Rev.NULL_TREE_SHA = "#none" -- Or perhaps @0 is better? Let's stick with #none for clarity.

---P4Rev constructor
---@param rev_type RevType
---@param revision string|number Changelist number, #head, #none, @client, @label etc.
---@param track_head? boolean
function P4Rev:init(rev_type, revision, track_head)
  -- Convert changelist numbers to @CL string format before delegating to the
  -- base class, which would otherwise interpret numbers as stage indices.
  -- A bare number in a string is a changelist too: `P4Commit.hash` is one,
  -- and `get_show_args` appends the name to the path as it is.
  if type(revision) == "number" or (type(revision) == "string" and revision:match("^%d+$")) then
    revision = "@" .. tostring(revision)
  end

  self:super(rev_type, revision, track_head)
end

---@param rev_from P4Rev|string
---@param rev_to? P4Rev|string
---@return string?
function P4Rev.to_range(rev_from, rev_to)
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
    else
      name_to = rev_to:object_name()
    end
  end

  if name_from and name_to and name_from ~= name_to then
    -- Perforce range specifier for filelog/changes etc.
    return name_from .. "," .. name_to
  elseif name_from then
    -- Single revision often implies comparison or description of that point
    return name_from
  end
  return nil
end

---@param name string # Revision specifier like @CL, CL, #head
---@param adapter P4Adapter
---@return Rev?
function P4Rev.from_name(name, adapter)
  -- Attempt to resolve the revision specifier using p4 changes
  local rev_spec = name
  if tonumber(name) then
    rev_spec = "@" .. name -- Ensure it's in @CL format if just a number
  end

  -- Use 'p4 changes -m1' to verify the revision exists.
  -- #head, #none, @client are usually implicitly valid if p4 client is set up.
  if rev_spec == "#head" or rev_spec == "#none" or rev_spec == "@" then
    -- Assume these are valid in a working client context
    return P4Rev(RevType.COMMIT, rev_spec) -- Treat #head etc. as COMMIT type for simplicity
  end

  local out, code = adapter:exec_sync({ "changes", "-m1", rev_spec }, adapter.ctx.toplevel)

  if code ~= 0 or #out == 0 then
    -- Could also check labels etc., but let's keep it simple for now
    return nil -- Revision not found or invalid
  end

  -- Extract the validated CL number if possible, otherwise use the original spec
  local cl_match = out[1] and out[1]:match("^Change (%d+)")
  local validated_rev = cl_match and ("@" .. cl_match) or rev_spec

  return P4Rev(RevType.COMMIT, validated_rev)
end

---@param adapter P4Adapter
---@return Rev?
function P4Rev.earliest_commit(adapter)
  -- Get the first changelist
  local out, code = adapter:exec_sync({ "changes", "-m1", "-r", "//..." }, adapter.ctx.toplevel)
  if code ~= 0 or #out == 0 then
    return nil
  end
  local cl = out[1]:match("^Change (%d+)")
  return cl and P4Rev(RevType.COMMIT, "@" .. cl) or nil
end

---Create a new commit rev representing a non-existent state.
---@return Rev
function P4Rev.new_null_tree()
  return P4Rev(RevType.COMMIT, P4Rev.NULL_TREE_SHA)
end

---Determine if this rev is currently the head.
---@param adapter P4Adapter
---@return boolean?
function P4Rev:is_head(adapter)
  return self.commit == "#head"
end

---@param abbrev_len? integer -- Ignored for P4
---@return string
function P4Rev:object_name(abbrev_len)
  if self.type == RevType.COMMIT then
    return self.commit -- e.g., @12345, #head, @labelname
  elseif self.type == RevType.LOCAL then
    return "@" -- Perforce often uses '@' to denote workspace files implicitly in diffs
  end
  return "UNKNOWN"
end

M.P4Rev = P4Rev
return M
