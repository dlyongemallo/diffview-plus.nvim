local utils = require("diffview.utils")

local M = {}

---@class GitAdapter.WorktreeEntry
---@field path string # Absolute path to the worktree root.
---@field head? string # HEAD commit SHA. Nil for a bare worktree.
---@field branch? string # Short branch name (e.g., "main"). Nil if detached or bare.
---@field ref? string # Full ref (e.g., "refs/heads/main"). Same nil rules as `branch`.
---@field is_bare boolean
---@field is_detached boolean
---@field is_locked boolean
---@field lock_reason? string # Free-form reason from `git worktree lock -r`, if any.
---@field is_prunable boolean
---@field prune_reason? string # Reason git flagged this worktree as prunable, if any.
---@field stats? GitAdapter.WorktreeStats # Populated by callers that collect stats; the parser leaves it nil.

---Convert `git worktree list --porcelain` output into typed entries.
---
---Records are separated by blank lines. The first line of each record is
---`worktree <path>`; subsequent lines are either flag attributes (`bare`,
---`detached`) or `<key> <value>` pairs (`HEAD <sha>`, `branch <refname>`).
---The `locked` and `prunable` attributes are flags that may carry an
---optional reason after a single space.
---
---Unknown attributes are ignored so a newer git can add fields without
---breaking parsing. A record missing the leading `worktree` line is
---skipped rather than raised on; the porcelain format is stable and the
---caller already has to tolerate git version quirks.
---
---Paths are emitted verbatim by `git worktree list --porcelain`: git
---applies no quoting, so a path containing a newline will be split by
---this parser. Callers that must handle such paths should run
---`git worktree list --porcelain -z` and parse the NUL-delimited form
---instead. Lock and prune reasons are C-quoted (per git's
---`write_name_quoted`) when they contain unusual bytes, and are
---returned here with the quoting intact. Such values are rare in
---practice.
---
---@param output string|string[] # Raw command output; a string is split on newlines.
---@return GitAdapter.WorktreeEntry[]
function M.parse_worktree_list(output)
  local lines
  if type(output) == "string" then
    lines = utils.str_split(output, "\n")
  else
    lines = output
  end

  local entries = {}
  local cur ---@type GitAdapter.WorktreeEntry?

  local function finalize()
    if cur and cur.path ~= "" then
      entries[#entries + 1] = cur
    end
    cur = nil
  end

  for _, raw in ipairs(lines) do
    -- Tolerate a stray trailing CR on `\r\n` line endings.
    local line = raw:gsub("\r$", "")

    if line == "" then
      finalize()
    else
      -- `%S+` = attribute key; `%s?` skips exactly one separator space so
      -- values with embedded whitespace (paths, lock reasons) survive intact.
      local key, value = line:match("^(%S+)%s?(.*)$")

      if key == "worktree" then
        finalize()
        cur = {
          path = value,
          is_bare = false,
          is_detached = false,
          is_locked = false,
          is_prunable = false,
        }
      elseif cur then
        if key == "HEAD" then
          cur.head = value
        elseif key == "branch" then
          cur.ref = value
          cur.branch = (value:gsub("^refs/heads/", ""))
        elseif key == "bare" then
          cur.is_bare = true
        elseif key == "detached" then
          cur.is_detached = true
        elseif key == "locked" then
          cur.is_locked = true
          if value ~= "" then
            cur.lock_reason = value
          end
        elseif key == "prunable" then
          cur.is_prunable = true
          if value ~= "" then
            cur.prune_reason = value
          end
        end
      end
    end
  end

  finalize()
  return entries
end

return M
