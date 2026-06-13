local lazy = require("diffview.lazy")

-- Ensure bootstrap has run before accessing DiffviewGlobal.
require("diffview.bootstrap")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local FileDiffView = lazy.access("diffview.scene.views.diff.file_diff_view", "FileDiffView") ---@type FileDiffView|LazyModule
local FileDirDiffView =
  lazy.access("diffview.scene.views.diff.file_dir_diff_view", "FileDirDiffView") ---@type FileDirDiffView|LazyModule
local FileMergeView = lazy.access("diffview.scene.views.diff.file_merge_view", "FileMergeView") ---@type FileMergeView|LazyModule
local FileHistoryView =
  lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local GitAdapter = lazy.access("diffview.vcs.adapters.git", "GitAdapter") ---@type GitAdapter|LazyModule
local HgAdapter = lazy.access("diffview.vcs.adapters.hg", "HgAdapter") ---@type HgAdapter|LazyModule
local NullAdapter = lazy.access("diffview.vcs.adapters.null", "NullAdapter") ---@type NullAdapter|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local rev_lib = lazy.require("diffview.vcs.rev") ---@module "diffview.vcs.rev"
local session = lazy.require("diffview.session") ---@module "diffview.session"
local vcs = lazy.require("diffview.vcs") ---@module "diffview.vcs"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

local M = {}

---@type View[]
M.views = {}

local same_rev = lazy.access(rev_lib, "same_rev") --[[@as fun(a: Rev?, b: Rev?): boolean ]]

---Find an existing DiffView matching the given parameters.
---@param adapter VCSAdapter
---@param rev_arg string?
---@param path_args string[]
---@param left Rev?
---@param right Rev?
---@return DiffView?
function M.find_existing_view(adapter, rev_arg, path_args, left, right)
  for _, view in ipairs(M.views) do
    ---@cast view DiffView
    if
      DiffView.__get():ancestorof(view)
      and view.adapter.ctx.toplevel == adapter.ctx.toplevel
      and view.rev_arg == rev_arg
      and vim.deep_equal(view.path_args or {}, path_args or {})
      and same_rev(view.left, left)
      and same_rev(view.right, right)
    then
      return view
    end
  end
  return nil
end

function M.diffview_open(args)
  local default_args = config.get_config().default_args.DiffviewOpen
  local argo = arg_parser.parse(utils.flatten({ default_args, args }))
  local rev_arg = argo.args[1]

  logger:info("[command call] :DiffviewOpen " .. table.concat(
    utils.flatten({
      default_args,
      args,
    }),
    " "
  ))

  local err, adapter = vcs.get_adapter({
    cmd_ctx = {
      path_args = argo.post_args,
      cpath = argo:get_flag("C", { no_empty = true, expand = true }) --[[@as string? ]],
    },
  })

  if err then
    utils.err(err)
    return
  end

  ---@cast adapter -?

  local opts = adapter:diffview_options(argo)

  if opts == nil then
    return
  end

  -- Check for existing view with matching parameters (including revisions).
  local existing =
    M.find_existing_view(adapter, rev_arg, adapter.ctx.path_args, opts.left, opts.right)
  if existing and existing.tabpage and api.nvim_tabpage_is_valid(existing.tabpage) then
    api.nvim_set_current_tabpage(existing.tabpage)
    logger:debug("Switched to existing DiffView")
    return existing
  end

  local v = DiffView({
    adapter = adapter,
    rev_arg = rev_arg,
    path_args = adapter.ctx.path_args,
    left = opts.left,
    right = opts.right,
    options = opts.options,
  })

  if not v:is_valid() then
    return
  end

  table.insert(M.views, v)
  -- Record at the canonical creation site so every caller (user
  -- commands, `M.restore`, third-party plugins) gets session coverage.
  session.record_view(v, "diffview_open", args)
  logger:debug("DiffView instantiation successful!")

  return v
end

---@param range? { [1]: integer, [2]: integer }
---@param args string[]
function M.file_history(range, args)
  local default_args = config.get_config().default_args.DiffviewFileHistory
  local argo = arg_parser.parse(utils.flatten({ default_args, args }))

  logger:info("[command call] :DiffviewFileHistory " .. table.concat(
    utils.flatten({
      default_args,
      args,
    }),
    " "
  ))

  local err, adapter = vcs.get_adapter({
    cmd_ctx = {
      path_args = argo.args,
      cpath = argo:get_flag("C", { no_empty = true, expand = true }) --[[@as string? ]],
    },
  })

  if err then
    utils.err(err)
    return
  end

  ---@cast adapter -?

  local log_options = adapter:file_history_options(range, adapter.ctx.path_args, argo)

  if log_options == nil then
    return
  end

  -- Boolean flag: bare `--pin-local` enables, `--pin-local=false` overrides
  -- a value set in the user's config. Falls back to the config value when
  -- the flag isn't passed at all.
  local raw_pin_local = argo:get_flag("pin-local")
  local pin_local
  if raw_pin_local ~= nil then
    pin_local = raw_pin_local --[[@as boolean ]]
  else
    pin_local = config.get_config().view.file_history.pin_local or false
  end

  if
    pin_local
    and not (adapter:instanceof(GitAdapter.__get()) or adapter:instanceof(HgAdapter.__get()))
  then
    utils.err("`--pin-local` is only supported for git and mercurial repositories.")
    return
  end

  -- pin_local forces revs.b = LOCAL on every entry, which silently overrides
  -- a fixed-base RHS the user asked for via `--base`. Reject the combination
  -- so the conflict is loud rather than confusing.
  if pin_local and argo:get_flag("base", { no_empty = true }) then
    utils.err(
      "`--pin-local` and `--base` cannot be combined: pin_local forces the right-hand side to the working tree."
    )
    return
  end

  -- For single-file pinning, seed `pinned_path` so the b-side stays bound to
  -- the user's working-tree file even across renames in older commits. For
  -- multi-file pinning the path is dynamic (set by the cursor follower) so it
  -- starts unset. `history_scope` is the single source of truth: it knows
  -- about both `path_args` and `-L` line-trace (whose path lives in the L
  -- spec, not `path_args`), and rejects single-arg directory pathspecs that
  -- would otherwise produce a `pinned_path` no FileEntry can match.
  local pinned_path
  if pin_local then
    local scope = adapter:history_scope(adapter.ctx.path_args, log_options)
    if scope.single_file then
      pinned_path = scope.path
    end
  end

  local v = FileHistoryView({
    adapter = adapter,
    log_options = log_options,
    pin_local = pin_local,
    pinned_path = pinned_path,
  })

  if not v:is_valid() then
    return
  end

  table.insert(M.views, v)
  -- See `M.diffview_open` for why recording happens here.
  session.record_view(v, "file_history", args, range)
  logger:debug("FileHistoryView instantiation successful!")

  return v
end

---@param args string[]
function M.diffview_diff_files(args)
  local argo = arg_parser.parse(args)

  logger:info("[command call] :DiffviewDiffFiles " .. table.concat(args, " "))

  if #argo.args ~= 2 then
    utils.err("DiffviewDiffFiles requires exactly two file paths.")
    return
  end

  local left_path = pl:absolute(pl:vim_expand(argo.args[1]))
  local right_path = pl:absolute(pl:vim_expand(argo.args[2]))

  if vim.fn.filereadable(left_path) ~= 1 then
    utils.err(("File not readable: %s"):format(left_path))
    return
  end

  if vim.fn.filereadable(right_path) ~= 1 then
    utils.err(("File not readable: %s"):format(right_path))
    return
  end

  local toplevel = pl:parent(left_path) or "."
  -- LuaLS picks up `GitAdapter.create`'s 2-arg signature when both adapters
  -- are imported in this file, so suppress the spurious diagnostics.
  ---@diagnostic disable-next-line: missing-parameter, param-type-mismatch
  local adapter = NullAdapter.create({ toplevel = toplevel })

  local v = FileDiffView({
    adapter = adapter,
    left_path = left_path,
    right_path = right_path,
  })

  if not v:is_valid() then
    return
  end

  table.insert(M.views, v)
  logger:debug("FileDiffView instantiation successful!")

  return v
end

---Entry point for external merge drivers (jj, hg's external merge tool, etc.)
---that hand the editor four on-disk file paths. The `output` file is the
---resolved-content sink that the driver reads after the editor exits.
---Argument order matches `jj-diffconflicts` and jj's documented `$output
---$base $left $right` substitution order.
---@param args string[]
function M.diffview_merge_files(args)
  local argo = arg_parser.parse(args)

  logger:info("[command call] :DiffviewMergeFiles " .. table.concat(args, " "))

  if #argo.args ~= 3 and #argo.args ~= 4 then
    utils.err(
      "DiffviewMergeFiles requires three or four file paths: <output> [<base>] <left> <right>."
    )
    return
  end

  local output_path = pl:absolute(pl:vim_expand(argo.args[1]))
  local base_path, left_path, right_path

  if #argo.args == 4 then
    base_path = pl:absolute(pl:vim_expand(argo.args[2]))
    left_path = pl:absolute(pl:vim_expand(argo.args[3]))
    right_path = pl:absolute(pl:vim_expand(argo.args[4]))
  else
    left_path = pl:absolute(pl:vim_expand(argo.args[2]))
    right_path = pl:absolute(pl:vim_expand(argo.args[3]))
  end

  -- `$output` is the only path that must already exist on disk: jj creates
  -- it (empty or pre-populated with markers depending on
  -- `merge-tool-edits-conflict-markers`). Missing read-only sides are
  -- expected when the conflict has an add/delete side and render as empty
  -- buffers via `FileMergeView`'s reader.
  if vim.fn.filereadable(output_path) ~= 1 then
    utils.err(("Output file not readable: %s"):format(output_path))
    return
  end

  local toplevel = pl:parent(output_path) or "."
  ---@diagnostic disable-next-line: missing-parameter, param-type-mismatch
  local adapter = NullAdapter.create({ toplevel = toplevel })

  local v = FileMergeView({
    adapter = adapter,
    output_path = output_path,
    base_path = base_path,
    left_path = left_path,
    right_path = right_path,
  })

  if not v:is_valid() then
    return
  end

  table.insert(M.views, v)
  logger:debug("FileMergeView instantiation successful!")

  return v
end

---Entry point for external diff-editor drivers (jj's `diff-editor`, etc.)
---that hand the editor two directories plus optionally an editable
---`$output` directory. Argument order matches jj's documented `$left
---$right $output` substitution order; omit the third arg for 2-pane mode.
---@param args string[]
function M.diffview_dir_diff(args)
  local argo = arg_parser.parse(args)

  logger:info("[command call] :DiffviewDiffDirs " .. table.concat(args, " "))

  if #argo.args ~= 2 and #argo.args ~= 3 then
    utils.err("DiffviewDiffDirs requires two or three directory paths: <left> <right> [<output>].")
    return
  end

  local left_path = pl:absolute(pl:vim_expand(argo.args[1]))
  local right_path = pl:absolute(pl:vim_expand(argo.args[2]))
  local output_path = argo.args[3] and pl:absolute(pl:vim_expand(argo.args[3])) or nil

  for _, p in ipairs({ left_path, right_path, output_path }) do
    if p and not pl:is_dir(p) then
      utils.err(("Not a directory: %s"):format(p))
      return
    end
  end

  -- Walk before constructing the view so we can bail out with a clear
  -- message when the two sides match: an empty `FileDirDiffView` would
  -- otherwise present an editor with no file panel content, which is
  -- particularly opaque for external diff-editor drivers like jj.
  local FileDirDiffViewMod = require("diffview.scene.views.diff.file_dir_diff_view")
  local diffs = FileDirDiffViewMod.diff_dirs(left_path, right_path)
  if next(diffs) == nil then
    utils.info("No differences between the given directories.")
    return
  end

  local toplevel = output_path or right_path
  ---@diagnostic disable-next-line: missing-parameter, param-type-mismatch
  local adapter = NullAdapter.create({ toplevel = toplevel })

  local v = FileDirDiffView({
    adapter = adapter,
    left_path = left_path,
    right_path = right_path,
    output_path = output_path,
    diffs = diffs,
  })

  if not v:is_valid() then
    return
  end

  table.insert(M.views, v)
  logger:debug("FileDirDiffView instantiation successful!")

  return v
end

---@param view View
function M.add_view(view)
  if not M.has_view(view) then
    table.insert(M.views, view)
  end
end

---@param view View
---@return boolean
function M.has_view(view)
  return vim.tbl_contains(M.views, view)
end

---@param view View
function M.dispose_view(view)
  for j, v in ipairs(M.views) do
    if v == view then
      table.remove(M.views, j)
      return
    end
  end
end

---Close and dispose of views that have no tabpage.
function M.dispose_stray_views()
  local tabpage_map = {}
  for _, id in ipairs(api.nvim_list_tabpages()) do
    tabpage_map[id] = true
  end

  local dispose = {}
  for _, view in ipairs(M.views) do
    if not tabpage_map[view.tabpage] then
      -- Need to schedule here because the tabnr's don't update fast enough.
      vim.schedule(function()
        view:close()
      end)
      table.insert(dispose, view)
    end
  end

  for _, view in ipairs(dispose) do
    M.dispose_view(view)
  end
end

---Get the currently open Diffview.
---@return View?
function M.get_current_view()
  local tabpage = api.nvim_get_current_tabpage()
  for _, view in ipairs(M.views) do
    if view.tabpage == tabpage then
      return view
    end
  end

  return nil
end

function M.tabpage_to_view(tabpage)
  for _, view in ipairs(M.views) do
    if view.tabpage == tabpage then
      return view
    end
  end
end

---Get the first tabpage that is not a view. Tries the previous tabpage first.
---If there are no non-view tabpages: returns nil.
---@return number|nil
function M.get_prev_non_view_tabpage()
  local tabs = api.nvim_list_tabpages()
  if #tabs > 1 then
    local seen = {}
    for _, view in ipairs(M.views) do
      seen[view.tabpage] = true
    end

    local prev_tab = utils.tabnr_to_id(vim.fn.tabpagenr("#")) or -1
    if api.nvim_tabpage_is_valid(prev_tab) and not seen[prev_tab] then
      return prev_tab
    else
      for _, id in ipairs(tabs) do
        if not seen[id] then
          return id
        end
      end
    end
  end
end

---@param bufnr integer
---@param ignore? vcs.File[]
---@return boolean
function M.is_buf_in_use(bufnr, ignore)
  local ignore_map = ignore and utils.vec_slice(ignore) or {}
  utils.add_reverse_lookup(ignore_map)

  for _, view in ipairs(M.views) do
    if view:instanceof(StandardView.__get()) then
      ---@cast view StandardView

      for _, file in ipairs(view.cur_entry and view.cur_entry.layout:files() or {}) do
        if file:is_valid() and file.bufnr == bufnr then
          if not ignore_map[file] then
            return true
          end
        end
      end
    end
  end

  return false
end

function M.update_colors()
  for _, view in ipairs(M.views) do
    if view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      if view.panel:buf_loaded() then
        view.panel:render()
        view.panel:redraw()
      end
    end
  end
end

return M
