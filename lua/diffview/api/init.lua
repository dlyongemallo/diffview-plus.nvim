-- Public API surface for diffview+.
--
-- Usage:
--   local api = require("diffview.api")
--   api.selections.get()
--   api.set_revs("abc123..def456")

local lazy = require("diffview.lazy")

local lib = lazy.require("diffview.lib") ---@module "diffview.lib"

local M = {}

M.selections = lazy.require("diffview.api.selections") ---@module "diffview.api.selections"

---Replace the revision range of an open DiffView in-place.
---
---The file list is refreshed to reflect the new range.  File selections
---are preserved for paths that still appear in the updated diff.
---
---@param new_rev_arg string New revision argument (e.g. "abc123..def456").
---@param opts? { cached?: boolean, imply_local?: boolean, merge_base?: boolean, view?: View }
function M.set_revs(new_rev_arg, opts)
  opts = opts or {}
  local view = opts.view or lib.get_current_view()
  if not view then
    return
  end
  ---@cast view DiffView
  if not view.set_revs then
    return
  end
  view:set_revs(new_rev_arg, opts)
end

return M
