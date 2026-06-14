local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local AsyncListStream = lazy.access("diffview.stream", "AsyncListStream") ---@type AsyncListStream|LazyModule
local Job = lazy.access("diffview.job", "Job") ---@type diffview.Job|LazyModule
local Rev = lazy.access("diffview.vcs.rev", "Rev") ---@type Rev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

local M = {}

---@class vcs.adapter.LayoutOpt
---@field default_layout Layout
---@field merge_layout? Layout
---@field pin_local? boolean # When true, file-history entries are constructed with revs.b = LOCAL so the b-window can pin to the working-tree file.
---@field pinned_path? string # Working-tree path used for the b-side File when `pin_local` is true for a single-file history; preserves the pin across renames in older commits.
---@field pinned_b_file_for? fun(path: string): vcs.File # Resolves the shared, view-owned working-tree File for a given path. Set by `FileHistoryPanel` when `pin_local` is active so adapters can hand the same `vcs.File` instance to every entry's b-side; see `FileHistoryView:get_pinned_b_file`. The returned file outlives entry/log destruction (its layout symbol lives in `Diff2*Pinned.shared_symbols`), so adapters must not destroy it.

---@class vcs.adapter.VCSAdapter.Bootstrap
---@field done boolean # Did the bootstrapping
---@field ok boolean # Bootstrapping was successful
---@field err? string
---@field version? table
---@field version_string? string
---@field target_version? table
---@field target_version_string? string

---@class vcs.adapter.VCSAdapter.Flags
---@field switches FlagOption[]
---@field options FlagOption[]

---@class vcs.adapter.VCSAdapter.Ctx
---@field toplevel? string # VCS repository toplevel directory
---@field dir? string # VCS directory
---@field git_override? string[] # Global flags pinning the git dir and work tree when they diverge
---@field path_args? string[] # Resolved path arguments

---@class VCSAdapter: diffview.Object
---@field bootstrap vcs.adapter.VCSAdapter.Bootstrap
---@field ctx vcs.adapter.VCSAdapter.Ctx
---@field flags vcs.adapter.VCSAdapter.Flags
local VCSAdapter = oop.create_class("VCSAdapter")

VCSAdapter.Rev = Rev
VCSAdapter.config_key = nil
VCSAdapter.bootstrap = {
  done = false,
  ok = false,
  version = {},
}

function VCSAdapter.run_bootstrap()
  VCSAdapter.bootstrap.done = true
  VCSAdapter.bootstrap.ok = false
end

---Common bootstrap preamble: marks bootstrap as started and checks the
---configured command is executable. Returns the err reporting function on
---success, or nil if the executable check failed.
---@param bs vcs.adapter.VCSAdapter.Bootstrap
---@param cmd string[]
---@param adapter_name string
---@param cmd_config_key string Config field name (e.g. "git_cmd").
---@return (fun(msg: string?): nil)?
function VCSAdapter.bootstrap_preamble(bs, cmd, adapter_name, cmd_config_key)
  bs.done = true

  local function err(msg)
    if msg then
      bs.err = msg
      logger:error(fmt("[%s] %s", adapter_name, bs.err))
    end
  end

  if vim.fn.executable(cmd[1]) ~= 1 then
    err(fmt("Configured `%s` is not executable: '%s'", cmd_config_key, cmd[1]))
    return nil
  end

  return err
end

---@diagnostic disable: unused-local, missing-return

---@abstract
---@param path_args string[] # Raw path args
---@param cpath string? # Cwd path given by the `-C` flag option
---@return string[] path_args # Resolved path args
---@return string[] top_indicators # Top-level indicators
function VCSAdapter.get_repo_paths(path_args, cpath)
  oop.abstract_stub()
end

---Try to find the top-level of a working tree by using the given indicative
---paths.
---@abstract
---@param top_indicators string[] A list of paths that might indicate what working tree we are in.
---@return string? err
---@return string toplevel # Absolute path
function VCSAdapter.find_toplevel(top_indicators)
  oop.abstract_stub()
end

---@diagnostic enable: unused-local, missing-return

---Build top-level indicators from path args and context.
---This is the shared implementation used by most adapters.  Git overrides
---this to handle its pathspec syntax.
---@param path_args string[]
---@param cpath string?
---@return string[] paths # Resolved path args
---@return string[] top_indicators
function VCSAdapter.build_top_indicators(path_args, cpath)
  local paths = {}
  local top_indicators = {}

  for _, path_arg in ipairs(path_args) do
    for _, path in
      ipairs(pl:vim_expand(path_arg, false, true) --[[@as string[] ]])
    do
      path = pl:readlink(path) or path
      table.insert(paths, path)
    end
  end

  for _, path in ipairs(paths) do
    table.insert(top_indicators, pl:absolute(path, cpath))
    break
  end

  VCSAdapter.append_implicit_indicators(top_indicators, cpath)

  return paths, top_indicators
end

---Append the implicit indicator (the one used when no explicit path arg
---resolves to a repo) to `top_indicators`.  When `cpath` is given (from the
---`-C` flag), it is the sole implicit indicator; otherwise a three-tier
---fallback is tried in order until one resolves to a repo:
---  1. The buffer's literal path: the common case of editing a real file in a repo.
---  2. `cwd`: the explicit-`cd` workflow, and the rescue when the buffer is a symlink
---     whose literal location is outside any repo (e.g., a session-restored file linked
---     from `$HOME`).
---  3. The buffer's `readlink`'d target: last-resort rescue for symlink-managed dotfiles
---     (stow, chezmoi, etc.) where the literal path isn't in a repo but the target is.
---@param top_indicators string[]
---@param cpath string?
function VCSAdapter.append_implicit_indicators(top_indicators, cpath)
  if cpath then
    table.insert(top_indicators, pl:realpath(cpath))
    return
  end

  local cfile = pl:vim_expand("%")
  if vim.bo.buftype ~= "" or cfile == "" then
    table.insert(top_indicators, pl:realpath("."))
    return
  end

  local absolute_cfile = pl:absolute(cfile)
  table.insert(top_indicators, absolute_cfile)
  table.insert(top_indicators, pl:realpath("."))
  local resolved = pl:readlink(cfile)
  if resolved and resolved ~= cfile then
    table.insert(top_indicators, pl:absolute(resolved, pl:parent(absolute_cfile)))
  end
end

---Iterate top-level indicators and resolve the repository root using a
---VCS-specific lookup function.  Returns the first successful match or a
---formatted error message.
---@param top_indicators string[]
---@param lookup_fn fun(path: string): string? # VCS-specific root lookup
---@param vcs_name string # For the error message (e.g. "git", "mercurial")
---@return string? err
---@return string toplevel
function VCSAdapter.find_toplevel_with(top_indicators, lookup_fn, vcs_name)
  for _, p in ipairs(top_indicators) do
    if not pl:is_dir(p) then
      ---@diagnostic disable-next-line: cast-local-type
      p = pl:parent(p)
    end

    if p and pl:readable(p) then
      local toplevel = lookup_fn(p)
      if toplevel then
        return nil, toplevel
      end
    end
  end

  local msg_paths = vim.tbl_map(function(v)
    local rel_path = pl:relative(v, ".")
    return utils.str_quote(rel_path == "" and "." or rel_path)
  end, top_indicators)

  return fmt("Path not a %s repo (or any parent): %s", vcs_name, table.concat(msg_paths, ", ")), ""
end

---@class vcs.adapter.VCSAdapter.Opt
---@field cpath string? # CWD path
---@field toplevel string # VCS toplevel path
---@field path_args string[] # Extra path arguments

function VCSAdapter:init()
  self.ctx = {}
  self.comp = {
    file_history = arg_parser.FlagValueMap(),
    open = arg_parser.FlagValueMap(),
  }
end

---@diagnostic disable: unused-local, missing-return

---@param path string
---@param rev Rev
---@return boolean -- True if the file was binary for the given rev, or it didn't exist.
function VCSAdapter:is_binary(path, rev)
  oop.abstract_stub()
end

---Initialize completion parameters
function VCSAdapter:init_completion()
  oop.abstract_stub()
end

---Return the adapter's default branch name (e.g., "main", "master"), or nil
---if the concept does not apply or cannot be determined.
---@return string?
function VCSAdapter:get_default_branch()
  return nil
end

---Return the adapter's current branch (or analogous) name, or nil if the
---concept does not apply or the state can't be determined.
---@return string?
function VCSAdapter:get_branch_name()
  return nil
end

---Return a URL for viewing the given commit in the VCS's web UI, or nil if
---the adapter does not support it.
---@param commit_hash string
---@return string?
function VCSAdapter:get_commit_url(commit_hash)
  return nil
end

---Parse a revision argument (e.g. "HEAD^..HEAD") into left/right revisions.
---When `rev_arg` is `nil`, adapters should fall back to their default revs
---(typically HEAD vs working tree).
---@param rev_arg string?
---@param opt table
---@return Rev? left
---@return Rev? right
function VCSAdapter:parse_revs(rev_arg, opt)
  oop.abstract_stub()
end

---@class RevCompletionSpec
---@field accept_range boolean

---Completion for revisions.
---@param arg_lead string
---@param opt? RevCompletionSpec
---@return string[]
function VCSAdapter:rev_candidates(arg_lead, opt)
  oop.abstract_stub()
end

---@return Rev?
function VCSAdapter:head_rev()
  oop.abstract_stub()
end

---Get the hash for a file's blob in a given rev.
---@param path string
---@param rev_arg string?
---@return string?
function VCSAdapter:file_blob_hash(path, rev_arg)
  oop.abstract_stub()
end

---Whether `path` exists at `rev_arg`. Cheaper than `file_blob_hash` for
---adapters where blob identity isn't a first-class concept (e.g. Mercurial),
---and the only thing the pin_local overlay path actually needs.
---@param path string
---@param rev_arg string
---@return boolean
function VCSAdapter:file_exists_at_rev(path, rev_arg)
  oop.abstract_stub()
end

---@return string[] # path to binary for VCS command
function VCSAdapter:get_command()
  oop.abstract_stub()
end

---@diagnostic enable: unused-local, missing-return

---Build a synthetic LogEntry representing the working tree as a top-of-log
---"commit" paired with `revs.a = HEAD` on each FileEntry. Used to render the
---working tree as a navigable entry in file-history when `pin_local` is true.
---Returns nil when the working tree has no path-arg-relevant changes, when
---the adapter has no working-tree concept, or when HEAD cannot be resolved
---(e.g. a fresh repo with no commits). The default implementation returns
---nil; git and hg adapters override.
---@param opt { path_args: string[], layout_opt: vcs.adapter.LayoutOpt, single_file: boolean }
---@return LogEntry?
function VCSAdapter:build_local_log_entry(opt) ---@diagnostic disable-line: unused-local
  return nil
end

---@class vcs.adapter.HistoryScope
---@field single_file boolean # Whether the resulting history is logically scoped to one file.
---@field path? string # The scoped working-tree path when `single_file` is true. Drives `pin_local`'s rename anchor and the synthetic entry's path filter.

---@class vcs.adapter.PinLocalFileEntryOpt
---@field layout_class Layout (class)
---@field layout_opt vcs.adapter.LayoutOpt
---@field path string # Working-tree path emitted for this row.
---@field oldpath? string # Rename old name. Caller is responsible for nilling it when `revs.a` is the commit being browsed (pin_local non-synth case); the helper passes it through unchanged.
---@field rev_a Rev
---@field rev_b Rev
---@field status? string
---@field stats? GitStats
---@field commit Commit
---@field single_file boolean # The history's single-file scope, computed via `history_scope`. Drives the b-side cache key.

---Build a `FileEntry` that respects the pin_local invariants. Centralises
---the rules `parse_fh_data` and `build_local_log_entry` were both
---duplicating: in pin_local mode the b-side `vcs.File` is resolved through
---`layout_opt.pinned_b_file_for` keyed by `pinned_path` in single-file
---mode and `opt.path` otherwise, so the synthetic top-of-history entry
---and the streamed entries share the same view-owned File for a given
---path. Each call site computes its own `rev_a` / `rev_b` / `oldpath`
---(those differ between streamed and synthetic entries) and passes them
---in.
---@param opt vcs.adapter.PinLocalFileEntryOpt
---@return FileEntry
function VCSAdapter:build_pin_local_file_entry(opt)
  local FileEntry = lazy.access("diffview.scene.file_entry", "FileEntry").__get()

  local pin_local = opt.layout_opt.pin_local == true
  local pinned_b_file
  if pin_local and opt.layout_opt.pinned_b_file_for then
    local b_path = (opt.single_file and opt.layout_opt.pinned_path) or opt.path
    pinned_b_file = opt.layout_opt.pinned_b_file_for(b_path)
  end

  return FileEntry.with_layout(opt.layout_class, {
    adapter = self,
    path = opt.path,
    oldpath = opt.oldpath,
    status = opt.status,
    stats = opt.stats,
    kind = "working",
    commit = opt.commit,
    revs = { a = opt.rev_a, b = opt.rev_b },
    pinned_b_file = pinned_b_file,
  })
end

---Resolve the history's working-tree scope. Single source of truth for
---"is this single-file?" and "what file?", consulted by `pin_local`'s
---`pinned_path` seed, the synthetic entry's `single_file` field, and the
---synth's `git diff` path filter. Adapters override to handle their own
---history modes (git's `-L` line-trace adds a path that doesn't live in
---`path_args`). Default: multi-file (no scoped path).
---@param path_args string[]
---@param log_options table
---@return vcs.adapter.HistoryScope
function VCSAdapter:history_scope(path_args, log_options) ---@diagnostic disable-line: unused-local
  return { single_file = false }
end

---@return string cmd The VCS binary.
function VCSAdapter:bin()
  return self:get_command()[1]
end

---@return string[] args The default VCS args.
function VCSAdapter:args()
  return utils.vec_slice(self:get_command(), 2)
end

---Execute a VCS command synchronously.
---@param args string[]
---@param cwd_or_opt? string|utils.job.Opt
---@return string[] stdout
---@return integer code
---@return string[] stderr
---@overload fun(self: VCSAdapter, args: string[], cwd?: string)
---@overload fun(self: VCSAdapter, args: string[], opt?: utils.job.Opt)
function VCSAdapter:exec_sync(args, cwd_or_opt)
  if not self.class.bootstrap.done then
    self.class.run_bootstrap()
  end

  local cmd = utils.flatten({ self:get_command(), args })

  if not self.class.bootstrap.ok then
    logger:error(
      ("[VCSAdapter] Can't exec adapter command because bootstrap failed! Cmd: %s"):format(
        table.concat(cmd, " ")
      )
    )
    return
  end

  return utils.job(cmd, cwd_or_opt)
end

---@param thread thread
---@param ok boolean
---@param result any
---@return boolean ok
---@return any result
function VCSAdapter:handle_co(thread, ok, result)
  if not ok then
    local err_msg = utils.vec_join("Coroutine failed!", debug.traceback(thread, result, 1))
    utils.err(err_msg, true)
    logger:error(table.concat(err_msg, "\n"))
  end
  return ok, result
end

-- File History

---@diagnostic disable: unused-local, missing-return

---@param path string
---@param rev Rev?
---@return string[] args to show commit content
function VCSAdapter:get_show_args(path, rev)
  oop.abstract_stub()
end

---@param args string[]
---@return string[] args to show commit log message
function VCSAdapter:get_log_args(args)
  oop.abstract_stub()
end

---@class vcs.MergeContext
---@field ours { hash: string, ref_names: string? }
---@field theirs { hash: string, ref_names: string? }
---@field base { hash: string, ref_names: string? }

---@return vcs.MergeContext?
function VCSAdapter:get_merge_context()
  oop.abstract_stub()
end

---@param range? { [1]: integer, [2]: integer }
---@param paths string[]
---@param argo ArgObject
---@return string[] # Options to show file history
function VCSAdapter:file_history_options(range, paths, argo)
  oop.abstract_stub()
end

---@param self VCSAdapter
---@param out_stream AsyncListStream
---@param opt vcs.adapter.FileHistoryWorkerSpec
VCSAdapter.file_history_worker = async.void(function(self, out_stream, opt)
  oop.abstract_stub()
end)

---@diagnostic enable: unused-local, missing-return

---@class vcs.adapter.FileHistoryWorkerSpec
---@field log_opt ConfigLogOptions
---@field layout_opt vcs.adapter.LayoutOpt

---@param opt vcs.adapter.FileHistoryWorkerSpec
---@return AsyncListStream out_stream
function VCSAdapter:file_history(opt)
  local out_stream = AsyncListStream()
  self:file_history_worker(out_stream, opt)

  return out_stream
end

-- Diff View

---@diagnostic disable: unused-local, missing-return

---Convert revs to rev args.
---@param left Rev
---@param right Rev
---@return string[]
function VCSAdapter:rev_to_args(left, right)
  oop.abstract_stub()
end

---Refresh rev endpoints for an existing view.
---@param rev_arg string?
---@param left Rev
---@param right Rev
---@return Rev? new_left
---@return Rev? new_right
function VCSAdapter:refresh_revs(rev_arg, left, right)
  return nil, nil
end

---Whether NOOP diff entries should still be replaced during a refresh.
---@param left Rev
---@param right Rev
---@return boolean
function VCSAdapter:force_entry_refresh_on_noop(left, right)
  return false
end

---Called when `_create_local_buffer` reuses an existing buffer. Adapters
---whose VCS rewrites working-copy files (e.g. jj) should override this to
---ensure the buffer content reflects the current state on disk.
---@param bufnr integer
function VCSAdapter:on_local_buffer_reused(bufnr)
  -- Default: no-op. Git and Hg do not rewrite working-copy files.
end

---Restore a file to the requested state
---@param path string # file to restore
---@param kind '"staged"'|'"working"'
---@param commit string
---@return string? Command to undo the restore
function VCSAdapter:restore_file(path, kind, commit)
  oop.abstract_stub()
end

---Add file(s)
---@param paths string[]
---@return boolean # add was successful
function VCSAdapter:add_files(paths)
  oop.abstract_stub()
end

---Reset file(s)
---@param paths string[]?
---@return boolean # reset was successful
function VCSAdapter:reset_files(paths)
  oop.abstract_stub()
end

---@param argo ArgObject
---@return { left: Rev, right: Rev, options: DiffViewOptions }?
function VCSAdapter:diffview_options(argo)
  oop.abstract_stub()
end

---@class VCSAdapter.show_untracked.Opt
---@field dv_opt? DiffViewOptions
---@field revs? { left: Rev, right: Rev }

---Check whether untracked files should be listed.
---@param opt? VCSAdapter.show_untracked.Opt
---@return boolean
function VCSAdapter:show_untracked(opt)
  oop.abstract_stub()
end

---Restore file
---@param self VCSAdapter
---@param path string
---@param kind vcs.FileKind
---@param commit string?
---@return boolean success
---@return string? undo # If the adapter supports it: a command that will undo the restoration.
VCSAdapter.file_restore = async.void(function(self, path, kind, commit)
  oop.abstract_stub()
end)

---Update the index entry for a given file with the contents of an index buffer.
---@param file vcs.File
---@return boolean success
function VCSAdapter:stage_index_file(file)
  oop.abstract_stub()
end

---@param self VCSAdapter
---@param left Rev
---@param right Rev
---@param args string[]
---@param kind vcs.FileKind
---@param opt vcs.adapter.LayoutOpt
---@param callback function
VCSAdapter.tracked_files = async.wrap(function(self, left, right, args, kind, opt, callback)
  oop.abstract_stub()
end)

---@param self VCSAdapter
---@param left Rev
---@param right Rev
---@param opt vcs.adapter.LayoutOpt
---@param callback? function
VCSAdapter.untracked_files = async.wrap(function(self, left, right, opt, callback)
  oop.abstract_stub()
end)

---@diagnostic enable: unused-local, missing-return

---@param self VCSAdapter
---@param path string
---@param rev? Rev
---@param callback fun(stderr: string[]?, stdout: string[]?)
VCSAdapter.show = async.wrap(function(self, path, rev, callback)
  local job
  job = Job({
    command = self:bin(),
    args = self:get_show_args(path, rev),
    cwd = self.ctx.toplevel,
    retry = 2,
    fail_cond = Job.FAIL_COND.on_empty,
    log_opt = { label = "VCSAdapter:show()" },
    on_exit = async.void(function(_, ok, err)
      if not ok or job.code ~= 0 then
        callback(utils.vec_join(err, job.stderr), nil)
        return
      end

      callback(nil, job.stdout)
    end),
  })
  -- Problem: Running multiple 'show' jobs simultaneously may cause them to fail
  -- silently.
  -- Solution: queue them and run them one after another.
  await(vcs_utils.queue_sync_job(job))
end)

---Convert revs to string representation.
---@param left Rev
---@param right Rev
---@return string|nil
function VCSAdapter:rev_to_pretty_string(left, right)
  if left.track_head and right.type == RevType.LOCAL then
    return nil
  elseif left.commit and right.type == RevType.LOCAL then
    return left:abbrev()
  elseif left.commit and right.commit then
    return left:abbrev() .. ".." .. right:abbrev()
  end
  return nil
end

---Check if any of the given revs are LOCAL.
---@param left Rev
---@param right Rev
---@return boolean
function VCSAdapter:has_local(left, right)
  return left.type == RevType.LOCAL or right.type == RevType.LOCAL
end

VCSAdapter.flags = {
  ---@type FlagOption[]
  switches = {},
  ---@type FlagOption[]
  options = {},
}

---@param arg_lead string
---@return string[]
function VCSAdapter:path_candidates(arg_lead)
  return vim.fn.getcompletion(arg_lead, "file", false)
end

M.VCSAdapter = VCSAdapter
return M
