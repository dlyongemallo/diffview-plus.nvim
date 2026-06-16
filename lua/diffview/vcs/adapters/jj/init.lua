local AsyncListStream = require("diffview.stream").AsyncListStream
local Commit = require("diffview.vcs.adapters.jj.commit").JjCommit
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local FileEntry = require("diffview.scene.file_entry").FileEntry
local FlagOption = require("diffview.vcs.flag_option").FlagOption
local Job = require("diffview.job").Job
local JjRev = require("diffview.vcs.adapters.jj.rev").JjRev
local JobStatus = require("diffview.vcs.utils").JobStatus
local LogEntry = require("diffview.vcs.log_entry").LogEntry
local RevType = require("diffview.vcs.rev").RevType
local VCSAdapter = require("diffview.vcs.adapter").VCSAdapter
local arg_parser = require("diffview.arg_parser")
local async = require("diffview.async")
local config = require("diffview.config")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local vcs_utils = require("diffview.vcs.utils")

local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") --[[@as PathLib ]]
local uv = vim.uv

local M = {}

---@class JjAdapter : VCSAdapter
---@operator call : JjAdapter
local JjAdapter = oop.create_class("JjAdapter", VCSAdapter)

JjAdapter.Rev = JjRev
JjAdapter.config_key = "jj"
JjAdapter.bootstrap = {
  done = false,
  ok = false,
  version = {},
}

function JjAdapter.run_bootstrap()
  local jj_cmd = config.get_config().jj_cmd
  local bs = JjAdapter.bootstrap
  local err = VCSAdapter.bootstrap_preamble(bs, jj_cmd, "JjAdapter", "jj_cmd")
  if not err then
    return
  end

  local out = utils.job(utils.flatten({ jj_cmd, "--version" }))
  bs.version_string = out[1] and out[1]:match("jj (%S+)") or nil

  if not bs.version_string then
    return err("Could not get Jujutsu version!")
  end

  bs.ok = true
end

---@param path_args string[] # Raw path args
---@param cpath string? # Cwd path given by the `-C` flag option
---@return string[] path_args # Resolved path args
---@return string[] top_indicators # Top-level indicators
function JjAdapter.get_repo_paths(path_args, cpath)
  return VCSAdapter.build_top_indicators(path_args, cpath)
end

---@param path string
---@return string?
local function get_toplevel(path)
  local out, code = utils.job(utils.flatten({ config.get_config().jj_cmd, { "root" } }), path)
  if code ~= 0 then
    return nil
  end
  return out[1] and vim.trim(out[1])
end

---@param top_indicators string[]
---@return string? err
---@return string toplevel
function JjAdapter.find_toplevel(top_indicators)
  return VCSAdapter.find_toplevel_with(top_indicators, get_toplevel, "Jujutsu")
end

---@param toplevel string
---@param path_args string[]
---@param cpath string?
---@return string? err
---@return JjAdapter
function JjAdapter.create(toplevel, path_args, cpath)
  local err
  local adapter = JjAdapter({
    toplevel = toplevel,
    path_args = path_args,
    cpath = cpath,
  })

  if not adapter.ctx.toplevel then
    err = "Could not find the top-level of the repository!"
  elseif not pl:is_dir(adapter.ctx.toplevel) then
    err = "The top-level is not a readable directory: " .. adapter.ctx.toplevel
  end

  if not adapter.ctx.dir then
    err = "Could not find the Jujutsu directory!"
  elseif not pl:is_dir(adapter.ctx.dir) then
    err = "The Jujutsu directory is not readable: " .. adapter.ctx.dir
  end

  return err, adapter
end

---@param opt vcs.adapter.VCSAdapter.Opt
function JjAdapter:init(opt)
  opt = opt or {}
  self:super(opt)

  self.ctx = {
    toplevel = opt.toplevel,
    dir = self:get_dir(opt.toplevel),
    path_args = opt.path_args or {},
  }

  self:init_completion()
end

---@return string[]
function JjAdapter:get_command()
  return config.get_config().jj_cmd
end

---Escape a path as a jj fileset string literal: double-quoted, with `\` and
---`"` backslash-escaped to satisfy jj's string-literal grammar. Quoting stops
---jj from reading the fileset parser's metacharacters (`(`, `)`, `|`, `&`,
---`~`, whitespace) in a real path (e.g., a Svelte route group like `(group)`)
---as operators. The returned string still carries jj's default `cwd` pattern
---kind, which matches the path and its descendants and leaves glob symbols
---(`*`, `?`, `[`, `]`) active; callers needing an exact single file must use
---`fileset_exact` instead.
---@param path string
---@return string
local function fileset_string(path)
  return '"' .. path:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---Build an exact-file jj fileset pattern for `path`. The `file:` (a.k.a.
---`cwd-file:`) kind matches exactly one file relative to cwd, with no prefix
---or glob expansion, so a path containing parser metacharacters (`(`, `|`,
---...) or glob symbols (`*`, `?`, `[`, `]`) resolves to that one file rather
---than erroring or matching siblings. Used for single-file operations
---(`show`, `restore`) where `path` is a concrete tracked file.
---@param path string
---@return string
local function fileset_exact(path)
  return "file:" .. fileset_string(path)
end

---Build a literal `cwd:` jj fileset pattern for `path`. Like the default
---pattern kind, `cwd:` matches the path and its descendants, but it does not
---treat glob symbols (`*`, `?`, `[`, `]`) as wildcards, so a real file or
---directory whose name contains them (e.g. a SvelteKit route `[id]`) resolves
---to itself rather than globbing a sibling. Used for a file-history path
---argument that names an existing path on disk.
---@param path string
---@return string
local function fileset_cwd(path)
  return "cwd:" .. fileset_string(path)
end

-- jj's glob metacharacters (`*`, `?`, `[`, `]`). Their presence in a bare path
-- marks it as a potential glob rather than a plain literal.
local GLOB_METACHARS = "[*?%[%]]"

---Whether `p` contains a jj glob metacharacter (`*`, `?`, `[`, `]`).
---@param p string
---@return boolean
local function has_glob_metachar(p)
  return p:match(GLOB_METACHARS) ~= nil
end

-- The fileset pattern kinds jj recognises before a `:` (see `jj help -k
-- filesets`). A leading `<kind>:` marks an intentional fileset expression
-- rather than a literal path. Glob kinds also accept a case-insensitive `-i`
-- suffix, which is stripped before the lookup.
local JJ_PATTERN_KINDS = {
  cwd = true,
  root = true,
  file = true,
  ["cwd-file"] = true,
  ["root-file"] = true,
  glob = true,
  ["cwd-glob"] = true,
  ["root-glob"] = true,
  ["prefix-glob"] = true,
  ["cwd-prefix-glob"] = true,
  ["root-prefix-glob"] = true,
}

---The jj fileset kind named by `p`'s `<kind>:` prefix, or nil when `p` has no
---recognised kind prefix. Only jj's real kinds count, so an unknown `<word>:`
---(a literal filename with a colon, or a user-defined fileset alias) returns
---nil.
---@param p string
---@return string?
local function fileset_kind_prefix(p)
  local kind = p:match("^([%w-]+):")
  if not kind then
    return nil
  end
  -- Strip the optional case-insensitive `-i` suffix before the lookup.
  local base_kind = kind:gsub("%-i$", "")
  return JJ_PATTERN_KINDS[base_kind] and kind or nil
end

---Detect a non-literal jj pathspec: one carrying a known fileset kind prefix
---(`glob:`, `root:`, `file:`, ...) or a bare glob (`*.lua`). The per-path
---canonicalise in `compute_fh_scope_args` can't resolve either, and
---`quote_path_args` hands them to jj untouched so intentional filesets keep
---working. Only jj's recognised kinds count: an unknown `<word>:` prefix is
---treated as literal, so a real filename that merely contains a colon (e.g.
---`foo:bar.txt`, legal on Unix) gets quoted rather than parsed by jj as an
---invalid pattern kind. A user-defined fileset alias (also `<word>:`) is
---likewise treated as literal, which is the safe default for a path argument.
---@param p string
---@return boolean
local function is_non_literal_pathspec(p)
  if p == "." or p == "" then
    return false
  end
  if fileset_kind_prefix(p) then
    return true
  end
  if has_glob_metachar(p) then
    return true
  end
  return false
end

-- jj fileset parser operators (`(`, `)`, `|`, `&`, `~`) and whitespace, which
-- make a bare, unquoted path fail to parse as a fileset expression.
local FILESET_OPERATORS = "[()|&~%s]"

---True when diffview would hand `p` to jj as a bare fileset -- it carries a glob
---metacharacter (`*`, `?`, `[`, `]`) but no explicit kind prefix, so
---`quote_path_args` leaves it unquoted -- yet it also contains a fileset
---operator that jj rejects. Such an argument is almost always a literal
---filename (e.g. the SvelteKit route `src/routes/(app)/[id]/page.svelte`) that
---needs an explicit `file:` pattern. Used only to phrase a clearer error once
---jj has actually reported a fileset parse failure, so a valid bare fileset
---such as `(*.lua | *.md)` -- which matches this shape but parses fine -- is
---never wrongly flagged.
---@param p string
---@return boolean
local function is_ambiguous_literal_path(p)
  if fileset_kind_prefix(p) then
    return false
  end
  return has_glob_metachar(p) and p:match(FILESET_OPERATORS) ~= nil
end

---Whether `p` resolves to an existing file or directory. A relative `p` is
---resolved against `toplevel`, the workspace root jj runs the history commands
---in, so the probe predicts how jj itself will resolve the path.
---@param p string
---@param toplevel string
---@return boolean
local function path_exists(p, toplevel)
  return uv.fs_stat(pl:absolute(p, toplevel)) ~= nil
end

---Quote each literal path in `path_args` as a fileset string literal (see
---`fileset_string`) so jj matches it verbatim. Non-literal pathspecs
---(`glob:*.lua`, `root:foo`) and the `.`/empty sentinels are left untouched so
---intentional fileset expressions keep working. Applied at every boundary
---where user-supplied or derived paths are handed to a jj command after `--`,
---since jj parses those arguments as filesets.
---
---A glob metacharacter (`*`, `?`, `[`, `]`) usually marks an intentional glob,
---but it is also legal in a real filename (e.g. a SvelteKit route
---`(app)/[id]`). When `toplevel` is given and the path names something on disk,
---it is matched literally with the non-globbing `cwd:` kind; otherwise it is
---left as a glob. Without `toplevel` (callers that can't probe the filesystem),
---a glob-character path stays a glob.
---@param path_args string[]
---@param toplevel? string
---@return string[]
local function quote_path_args(path_args, toplevel)
  return vim.tbl_map(function(p)
    if p == "" or p == "." or fileset_kind_prefix(p) then
      return p
    end
    if has_glob_metachar(p) then
      if toplevel and path_exists(p, toplevel) then
        return fileset_cwd(p)
      end
      return p
    end
    return fileset_string(p)
  end, path_args) --[[@as string[] ]]
end

---List the files matching `path_args` at the working-copy revision (`@`). The
---path args are quoted (see `quote_path_args`) so fileset metacharacters in a
---literal path don't get parsed as operators. The scope helpers below use this
---to count matches and to canonicalise a pathspec to its concrete
---workspace-relative file(s).
---@param path_args string[]
---@return string[] # Workspace-relative paths, one per line
function JjAdapter:list_files_at_head(path_args)
  local out = self:exec_sync(
    utils.vec_join("file", "list", "-r", "@", "--", quote_path_args(path_args, self.ctx.toplevel)),
    { cwd = self.ctx.toplevel, silent = true }
  )
  return out or {}
end

---@param path string
---@param rev Rev?
---@return string[]
function JjAdapter:get_show_args(path, rev)
  return utils.vec_join(
    self:args(),
    "file",
    "show",
    "-r",
    rev and rev:object_name() or "@",
    "--",
    fileset_exact(path)
  )
end

---@param args string[]
---@return string[]
function JjAdapter:get_log_args(args)
  return utils.vec_join("log", args)
end

---@param path string
---@return string?
function JjAdapter:get_dir(path)
  local root = get_toplevel(path)
  if not root then
    return nil
  end

  local jj_dir = pl:join(root, ".jj")
  if pl:is_dir(jj_dir) then
    return jj_dir
  end

  return root
end

---@return table<string, boolean>
function JjAdapter:get_bookmark_map()
  if self._bookmark_map then
    return self._bookmark_map
  end

  local out, code = self:exec_sync(
    { "bookmark", "list", "-a", "-T", [[name ++ "\n"]] },
    { cwd = self.ctx.toplevel, silent = true }
  )

  local map = {}
  if code == 0 then
    for _, line in ipairs(out) do
      local name = vim.trim(line)
      if name ~= "" then
        map[name] = true
      end
    end
  end

  self._bookmark_map = map
  return map
end

---@param name string
---@return boolean
function JjAdapter:has_bookmark(name)
  return self:get_bookmark_map()[name] == true
end

---@param rev_arg string
---@return string
function JjAdapter:normalize_rev_arg(rev_arg)
  -- Special-case fallback for repositories that use 'master' instead of 'main'.
  if rev_arg == "main" and not self:has_bookmark("main") and self:has_bookmark("master") then
    return "master"
  end

  return rev_arg
end

---@param rev_arg string
---@return string?
function JjAdapter:resolve_rev_arg(rev_arg)
  rev_arg = self:normalize_rev_arg(rev_arg)

  local out, code, stderr = self:exec_sync({ "show", "-T", "commit_id", rev_arg, "--no-patch" }, {
    cwd = self.ctx.toplevel,
    retry = 2,
    fail_on_empty = true,
    log_opt = { label = "JjAdapter:resolve_rev_arg()" },
  })

  if code ~= 0 or not out[1] then
    utils.err(
      utils.vec_join(
        fmt("Failed to parse rev %s!", utils.str_quote(rev_arg)),
        "Jujutsu output: ",
        stderr
      )
    )
    return
  end

  return vim.trim(out[1])
end

---@return JjRev?
function JjAdapter:head_rev()
  local head_hash = self:resolve_rev_arg("@")
  if not head_hash then
    return
  end

  return JjRev(RevType.COMMIT, head_hash, true)
end

---@param rev_arg string
---@return JjRev? left
---@return JjRev? right
function JjAdapter:symmetric_diff_revs(rev_arg)
  local r1 = self:normalize_rev_arg(rev_arg:match("(.+)%.%.%.") or "@")
  local r2 = self:normalize_rev_arg(rev_arg:match("%.%.%.(.+)") or "@")

  local h1 = self:resolve_rev_arg(r1)
  local h2 = self:resolve_rev_arg(r2)

  if not (h1 and h2) then
    return
  end

  -- Resolve a single fork-point commit with JJ revsets. This mirrors
  -- merge-base style behavior, but works in pure JJ repositories as well.
  local revset = fmt('latest(fork_point(commit_id("%s") | commit_id("%s")), 1)', h1, h2)
  local out, code, stderr = self:exec_sync(
    { "log", "-r", revset, "-T", [[commit_id ++ "\n"]], "--no-graph" },
    {
      cwd = self.ctx.toplevel,
      retry = 2,
      fail_on_empty = true,
      log_opt = { label = "JjAdapter:symmetric_diff_revs()" },
    }
  )

  if code ~= 0 or not out[1] then
    utils.err(
      utils.vec_join(
        fmt("Failed to compute merge-base for rev range %s!", utils.str_quote(rev_arg)),
        "Jujutsu output: ",
        stderr
      )
    )
    return
  end

  local left_hash = vim.trim(out[1])

  return JjRev(RevType.COMMIT, left_hash), JjRev(RevType.COMMIT, h2)
end

---@param rev_arg string
---@return boolean
function JjAdapter:is_rev_arg_range(rev_arg)
  if rev_arg:match("%.%.%.") then
    return true
  end

  if rev_arg:match("::") then
    return false
  end

  return rev_arg:match(".*%.%..*") ~= nil
end

---@param rev_arg string?
---@param opt table
---@return Rev? left
---@return Rev? right
function JjAdapter:parse_revs(rev_arg, opt)
  local left
  local right

  if not rev_arg then
    local parent_hash = self:resolve_rev_arg("@-") or self:resolve_rev_arg("root()")
    left = parent_hash and JjRev(RevType.COMMIT, parent_hash) or JjRev.new_null_tree()
    right = JjRev(RevType.LOCAL)
  elseif rev_arg:match("%.%.%.") then
    local r2 = self:normalize_rev_arg(rev_arg:match("%.%.%.(.+)") or "@")
    left, right = self:symmetric_diff_revs(rev_arg)
    if left and right and r2 == "@" then
      -- In JJ, '@' is the mutable working-copy commit. Keep the right side as
      -- LOCAL so refresh reflects latest filesystem content even when commit
      -- identifiers are stable across edits.
      right = JjRev(RevType.LOCAL)
    end
  elseif self:is_rev_arg_range(rev_arg) then
    local r1 = self:normalize_rev_arg(rev_arg:match("^(.-)%.%.") or "@")
    local r2 = self:normalize_rev_arg(rev_arg:match("%.%.(.-)$") or "@")

    if r1 == "" then
      r1 = "@"
    end
    if r2 == "" then
      r2 = "@"
    end

    local h1 = self:resolve_rev_arg(r1)
    local h2 = self:resolve_rev_arg(r2)

    if not (h1 and h2) then
      return
    end

    left = JjRev(RevType.COMMIT, h1)
    right = JjRev(RevType.COMMIT, h2)
  else
    local hash = self:resolve_rev_arg(self:normalize_rev_arg(rev_arg))
    if not hash then
      return
    end

    left = JjRev(RevType.COMMIT, hash)
    right = JjRev(RevType.LOCAL)
  end

  if opt.cached then
    utils.warn("The '--cached/--staged' option is not supported for Jujutsu. Ignoring.")
  end

  if opt.imply_local then
    utils.warn("The '--imply-local' option is not supported for Jujutsu. Ignoring.")
  end

  return left, right
end

---@param rev_arg string?
---@param left Rev
---@param right Rev
---@return Rev? new_left
---@return Rev? new_right
function JjAdapter:refresh_revs(rev_arg, left, right)
  -- Keep bookmark state current between refreshes.
  self._bookmark_map = nil

  local new_left, new_right = self:parse_revs(rev_arg, {})
  if not (new_left and new_right) then
    return nil, nil
  end

  if
    new_left.type == left.type
    and new_right.type == right.type
    and new_left:object_name() == left:object_name()
    and new_right:object_name() == right:object_name()
  then
    return nil, nil
  end

  return new_left, new_right
end

---@param left Rev
---@param right Rev
---@return boolean
function JjAdapter:force_entry_refresh_on_noop(left, right)
  return self:has_local(left, right)
end

---Jj may rewrite working-copy files when revisions change, so reload the
---buffer from disk when it is reused.
---@param bufnr integer
function JjAdapter:on_local_buffer_reused(bufnr)
  local api = vim.api

  if not api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  if not vim.bo[bufnr].modified then
    pcall(vim.api.nvim_command, ("checktime %d"):format(bufnr))
  end
end

---@param left Rev
---@param right Rev
---@return string[]
function JjAdapter:rev_to_args(left, right)
  assert(
    not (left.type == RevType.LOCAL and right.type == RevType.LOCAL),
    "InvalidArgument :: Can't diff LOCAL against LOCAL!"
  )

  if left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    return { "--from", left.commit, "--to", right.commit }
  elseif right.type == RevType.LOCAL and left.type == RevType.COMMIT then
    return { "--from", left.commit }
  elseif left.type == RevType.LOCAL and right.type == RevType.COMMIT then
    return { "--to", right.commit }
  end

  error(fmt("InvalidArgument :: Unsupported rev range: '%s..%s'!", left, right))
end

---@param argo ArgObject
---@return {left: Rev, right: Rev, options: DiffViewOptions}?
function JjAdapter:diffview_options(argo)
  local rev_arg = argo.args[1]

  local left, right = self:parse_revs(rev_arg, {
    cached = argo:get_flag({ "cached", "staged" }),
    imply_local = argo:get_flag("imply-local"),
  })

  if not (left and right) then
    return
  end

  logger:fmt_debug("Parsed revs: left = %s, right = %s", left, right)

  local options = {
    show_untracked = arg_parser.ambiguous_bool(
      argo:get_flag({ "u", "untracked-files" }, { plain = true }),
      nil,
      { "all", "normal", "true" },
      { "no", "false" }
    ),
    selected_file = argo:get_flag("selected-file", { no_empty = true, expand = true })
      or (vim.bo.buftype == "" and pl:vim_expand("%:p"))
      or nil,
  }

  return { left = left, right = right, options = options }
end

---@param path_args string[]?
---@param lflags? string[] # Ignored; jj has no `-L` line-trace mode.
---@diagnostic disable-next-line: unused-local
function JjAdapter:is_single_file(path_args, lflags)
  if path_args and self.ctx.toplevel then
    return #path_args == 1
      and not pl:is_dir(path_args[1])
      and #self:list_files_at_head(path_args) < 2
  end
  return true
end

---@override
---@param path_args string[]
---@param log_options JjLogOptions
---@return vcs.adapter.HistoryScope
function JjAdapter:history_scope(path_args, log_options) ---@diagnostic disable-line: unused-local
  -- jj has no `-L` line-trace mode (`file_history_options` rejects `range`),
  -- so the scope question reduces to "is this a single-file pathspec?".
  if not (path_args and #path_args == 1 and self.ctx.toplevel) then
    return { single_file = false }
  end
  if pl:is_dir(path_args[1]) then
    return { single_file = false }
  end
  -- See `GitAdapter:history_scope` for why we resolve through `jj file list`
  -- instead of using `path_args[1]` raw. We diverge from git on `#out == 0`:
  -- git uses `path = path_args[1]` as a `--follow` rename anchor, but jj has
  -- no `--follow` and callers consume `scope.path` as a literal post-filter
  -- against `f.target().path()`. Returning a non-canonical `path_args[1]`
  -- (`./foo.txt`, `glob:*`, ...) there would empty otherwise-valid history.
  local out = self:list_files_at_head(path_args)
  if #out == 1 then
    return { single_file = true, path = out[1] }
  end
  if #out == 0 then
    -- Still single-file (matches `is_single_file`'s `< 2`), but the path
    -- isn't tracked at `@` so we can't canonicalise it. Omit `path` and let
    -- callers fall back to `compute_fh_scope_args`, which handles both
    -- literal and non-literal shapes.
    return { single_file = true }
  end
  return { single_file = false }
end

---Resolve `path_args` to workspace-relative paths used by `parse_fh_data`'s
---`in_scope` post-filter. The per-path canonicalise handles literal paths
---(absolute or cwd-relative). Non-literal jj pathspecs (e.g. `glob:*.lua`)
---can't be canonicalised that way, so we ask jj to list the matching files
---at `@` and use that as the scope set. When jj returns nothing (a deleted
---path or a pathspec matching no current file), we drop the post-filter
---rather than silently emptying the history `jj log` already found.
---
---Literal paths are routed through `pl:absolute` then `pl:relative` so a
---`./foo.txt`, a bare `foo.txt` issued from a subdir of the workspace, and an
---absolute `/repo/foo.txt` all collapse to the same workspace-relative form
---that `f.target().path()` emits. Without that, the `in_scope` post-filter
---would reject every file and the history would come back empty.
---@param path_args string[]
---@return string[]
function JjAdapter:compute_fh_scope_args(path_args)
  local toplevel = self.ctx.toplevel
  for _, p in ipairs(path_args) do
    if is_non_literal_pathspec(p) then
      local out = self:list_files_at_head(path_args)
      return #out > 0 and out or {}
    end
  end
  return vim.tbl_map(function(p)
    if p == "." or p == "" then
      return p
    end
    return pl:relative(pl:absolute(p), toplevel)
  end, path_args) --[[@as string[] ]]
end

---@param range? { [1]: integer, [2]: integer }
---@param paths string[]
---@param argo ArgObject
---@return JjLogOptions?
function JjAdapter:file_history_options(range, paths, argo)
  if range then
    utils.err("Line ranges are not supported for jj!")
    return
  end

  local rel_paths = vim.tbl_map(function(v)
    return v == "." and "." or pl:relative(v, ".")
  end, paths) --[[@as string[] ]]

  local log_flag_names = {
    { "revisions", "r" },
    { "limit", "n" },
    { "reversed", "R" },
  }

  ---@type JjLogOptions
  ---@diagnostic disable-next-line: missing-fields
  local log_options = {}
  for _, names in ipairs(log_flag_names) do
    local key = names[1]:gsub("%-", "_")
    local v = argo:get_flag(names, {
      expect_string = type(config.log_option_defaults[self.config_key][key]) ~= "boolean",
    })
    log_options[key] = v
  end

  log_options.path_args = paths

  local ok, opt_description, parse_err = self:file_history_dry_run(log_options)

  if not ok then
    if parse_err then
      utils.err(parse_err)
      return
    end

    local msg = "No jj history for the target(s) given the current options! Targets: %s\n"
      .. "Current options: [ %s ]"

    if #rel_paths == 0 then
      utils.info(fmt(msg, "':(top)'", opt_description))
    else
      local msg_paths = vim.tbl_map(utils.str_quote, rel_paths)
      utils.info(fmt(msg, table.concat(msg_paths, ", "), opt_description))
    end

    return
  end

  return log_options
end

---@class JjAdapter.PreparedLogOpts
---@field revisions? string
---@field path_args string[]
---@field flags string[]

---@class JjAdapter.FHState
---@field path_args string[]
---@field scope_args string[] # Workspace-relative form of `path_args`, used by `parse_fh_data` to filter the per-commit file list.
---@field log_options JjLogOptions
---@field prepared_log_opts JjAdapter.PreparedLogOpts
---@field layout_opt vcs.adapter.LayoutOpt
---@field single_file boolean

---@param log_options JjLogOptions
---@param single_file boolean
---@return JjAdapter.PreparedLogOpts
function JjAdapter:prepare_fh_options(log_options, single_file) ---@diagnostic disable-line: unused-local
  local o = log_options
  return {
    revisions = o.revisions,
    path_args = log_options.path_args,
    flags = utils.vec_join(
      o.limit and { "--limit=" .. o.limit } or nil,
      o.reversed and { "--reversed" } or nil
    ),
  }
end

---@param log_opt JjLogOptions
---@return boolean ok, string description, string? err # Actionable error when a
---path argument is not valid fileset syntax (as opposed to an empty history).
function JjAdapter:file_history_dry_run(log_opt)
  local single_file = self:is_single_file(log_opt.path_args)
  local log_options = config.get_log_options(single_file, log_opt, self.config_key) --[[@as JjLogOptions ]]

  local options = vim.tbl_map(function(v)
    return vim.fn.shellescape(v)
  end, self:prepare_fh_options(log_options, single_file).flags) --[[@as vector ]]

  local description = utils.vec_join(
    fmt("Top-level path: '%s'", pl:vim_fnamemodify(self.ctx.toplevel, ":~")),
    log_options.revisions and fmt("Revisions: '%s'", log_options.revisions) or nil,
    fmt("Flags: %s", table.concat(options, " "))
  )

  -- Probe for at least one matching commit by re-running with limit=1 and a
  -- minimal template. `--no-graph` keeps the output one line per commit.
  log_options = utils.tbl_clone(log_options) --[[@as JjLogOptions ]]
  log_options.limit = 1
  options = self:prepare_fh_options(log_options, single_file).flags

  local cmd = utils.vec_join(
    "log",
    "--no-graph",
    "-T",
    'commit_id ++ "\n"',
    log_options.revisions and { "-r", log_options.revisions } or nil,
    options,
    "--",
    quote_path_args(log_options.path_args, self.ctx.toplevel)
  )

  local out, code, stderr = self:exec_sync(cmd, {
    cwd = self.ctx.toplevel,
    log_opt = { label = "JjAdapter:file_history_dry_run()" },
  })

  if code == 0 and #out > 0 then
    return true, table.concat(description, ", ")
  end

  logger:fmt_debug("[JjAdapter:file_history_dry_run] Dry run failed.")

  -- A fileset parse failure (as opposed to an empty history) means a path
  -- argument was not valid fileset syntax. When it looks like a literal path
  -- that merely contains fileset metacharacters, point the user at the `file:`
  -- pattern instead of the misleading "no history" message.
  if
    code ~= 0
    and stderr
    and table.concat(stderr, "\n"):find("Failed to parse fileset", 1, true)
  then
    for _, p in ipairs(log_options.path_args) do
      if is_ambiguous_literal_path(p) then
        return false,
          table.concat(description, ", "),
          fmt(
            "Could not parse %s as a jj fileset. If this is a literal path, "
              .. "prefix it with `file:` to match it literally; see "
              .. "`:h :DiffviewFileHistory` for quoting paths that contain "
              .. "`(`, `)`, or spaces.",
            utils.str_quote(p)
          )
      end
    end
  end

  return false, table.concat(description, ", ")
end

---Template fed to `jj log -T ...` by the file-history worker.
---
---Each commit produces exactly one line terminated by `\n`. Fields within a
---commit are separated by `\x01` (ASCII SOH). The final field is the file
---list, where individual file entries are separated by `\x1e` (ASCII RS)
---and each entry's `<status, path>` pair is separated by `\x1f` (ASCII US).
---
---Choosing a one-line-per-commit format -- rather than the line-per-field
---layout used by the hg adapter -- sidesteps two problems unique to jj:
---  1. Fields like `author.email()` can be legitimately empty, which
---     collides with the diffview job runner's habit of dropping empty
---     lines (and dispatching phantom empties at chunk boundaries when a
---     chunk ends on a `\n`).
---  2. Files-per-commit is variable, so a fixed line-index parse would
---     drift; here it's a single trailing field.
---
---Three distinct control chars (`\x01`, `\x1e`, `\x1f`) are needed because
---the file-list field contains nested separators: if the outer field
---separator and the inner `<status, path>` separator were the same byte, a
---single top-level split would shred each file entry into two fields.
---
---Field order, by index:
---  1. commit_id (full hash)
---  2. change_id
---  3. parent commit_ids (space-separated; empty for the root commit)
---  4. author email
---  5. author timestamp (unix epoch, UTC)
---  6. author timestamp offset (e.g. `+0200`, `-0500`)
---  7. relative date (e.g. `2 minutes ago`)
---  8. ref names (comma-separated local bookmarks + tags)
---  9. subject (first line of description)
---  10. files blob (`\x1e`-separated entries, each `<status>\x1f<path>`)
local FH_TEMPLATE = table.concat({
  [[ commit_id ++ "\x01" ]],
  [[ ++ change_id ++ "\x01" ]],
  [[ ++ parents.map(|p| p.commit_id()).join(" ") ++ "\x01" ]],
  [[ ++ author.email() ++ "\x01" ]],
  [[ ++ author.timestamp().format("%s") ++ "\x01" ]],
  [[ ++ author.timestamp().format("%z") ++ "\x01" ]],
  [[ ++ author.timestamp().ago() ++ "\x01" ]],
  [[ ++ separate(", ", local_bookmarks, tags) ++ "\x01" ]],
  [[ ++ description.first_line() ++ "\x01" ]],
  [[ ++ diff.files().map(|f| f.status_char() ++ "\x1f" ++ f.target().path()).join("\x1e") ++ "\n" ]],
}, "")

---Parse one line of jj log output (a single `\x01`-separated commit record)
---into the table shape that `parse_fh_data` consumes.
---@param line string
---@return table?
local function structure_fh_data(line)
  local fields = vim.split(line, "\x01", { plain = true })
  local commit_id = fields[1]
  if not commit_id or commit_id == "" then
    return nil
  end
  -- The root commit's hash is all zeros and has no description, parents, or
  -- diff entries. Skip it: it doesn't belong in the file-history list.
  if commit_id == JjRev.NULL_TREE_SHA then
    return nil
  end

  -- Strip empty and null-tree parent slots: empty appears when the parents
  -- field rendered to `""` (no parents on the root commit); null-tree
  -- appears when jj surfaces the synthetic zero-hash root as a parent.
  local function clean_parent(p)
    if not p or p == "" or p == JjRev.NULL_TREE_SHA then
      return nil
    end
    return p
  end

  local parents = utils.str_split(fields[3] or "")
  local left_hash = clean_parent(parents[1])
  local merge_hash = clean_parent(parents[2])

  -- The trailing field is a `\x1e`-separated list of `status\x1fpath` pairs.
  local namestat = {}
  local files_blob = fields[10] or ""
  if files_blob ~= "" then
    for _, entry in ipairs(vim.split(files_blob, "\x1e", { plain = true })) do
      -- Reuse the line format the old per-line parser expected so
      -- `parse_fh_data` doesn't need to change shape: `"<status> <path>"`.
      local sep = entry:find("\x1f", 1, true)
      if sep then
        local status = entry:sub(1, sep - 1)
        local path = entry:sub(sep + 1)
        if status ~= "" and path ~= "" then
          namestat[#namestat + 1] = status .. " " .. path
        end
      end
    end
  end

  return {
    right_hash = commit_id,
    left_hash = left_hash,
    merge_hash = merge_hash,
    author = fields[4] or "",
    time = tonumber(fields[5] or "0") or 0,
    time_offset = fields[6] or "",
    rel_date = fields[7] or "",
    ref_names = fields[8] or "",
    subject = fields[9] or "",
    namestat = namestat,
  }
end

---@param state JjAdapter.FHState
---@return AsyncListStream
function JjAdapter:stream_fh_data(state)
  ---@type AsyncListStream
  local stream
  ---@type diffview.Job
  local job

  local function on_stdout(_, line)
    if line == "" then
      -- Skip the empty trailing element vim.split produces after the final
      -- newline of a chunk.
      return
    end
    local log_data = structure_fh_data(line)
    if log_data then
      stream:push({ JobStatus.PROGRESS, log_data })
    end
  end

  stream = AsyncListStream({
    ---@param shutdown? SignalConsumer
    on_close = function(shutdown)
      if shutdown and shutdown:check() then
        if job:is_running() then
          logger:warn("Received shutdown signal. Killing file history job...")
          job:kill(64)
        else
          logger:warn("Received shutdown signal, but job is not running.")
        end

        stream:push({ JobStatus.KILLED })
        return
      end

      if job.code ~= 0 then
        stream:push({
          JobStatus.ERROR,
          nil,
          table.concat(job.stderr or {}, "\n"),
        })
      else
        stream:push({ JobStatus.SUCCESS })
      end
    end,
  })

  local prepared = state.prepared_log_opts
  job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "log",
      "--no-graph",
      "-T",
      FH_TEMPLATE,
      prepared.revisions and { "-r", prepared.revisions } or nil,
      prepared.flags,
      "--",
      quote_path_args(prepared.path_args, self.ctx.toplevel)
    ),
    cwd = self.ctx.toplevel,
    log_opt = { label = "JjAdapter:stream_fh_data()" },
    on_stdout = on_stdout,
    on_exit = utils.hard_bind(stream.close, stream),
  })
  job:start()

  return stream
end

---@param self JjAdapter
---@param out_stream AsyncListStream
---@param opt vcs.adapter.FileHistoryWorkerSpec
JjAdapter.file_history_worker = async.void(function(self, out_stream, opt)
  -- Use `history_scope` rather than bare `is_single_file` so that a
  -- single-file scope resolved from a non-literal pathspec (e.g. `glob:*.lua`,
  -- `file:foo`) is canonicalised to its concrete workspace-relative path.
  -- `parse_fh_data`'s `in_scope` matches files literally, so without this
  -- the post-filter would drop every file and the history would come back
  -- empty.
  local log_opt = opt.log_opt.single_file --[[@as JjLogOptions ]]
  local scope = self:history_scope(log_opt.path_args, log_opt)
  local single_file = scope.single_file

  -- When `history_scope` resolved a concrete workspace-relative path (from
  -- `jj file list`), use it for both the `jj log` pathspec and the scope
  -- filter. Otherwise fall through to the raw `path_args` for the query and
  -- `compute_fh_scope_args` for the filter (which handles literal and
  -- non-literal shapes, but would mis-resolve an already-canonical path if
  -- the user's cwd isn't the workspace toplevel).
  local path_args = scope.path and { scope.path } or log_opt.path_args

  local log_options = config.get_log_options(
    single_file,
    single_file and opt.log_opt.single_file or opt.log_opt.multi_file,
    "jj"
  ) --[[@as JjLogOptions ]]
  log_options.path_args = path_args

  -- Precompute the workspace-relative scope here, before the per-commit loop
  -- enters a fast event context. `pl:vim_expand` calls Vimscript's `expand()`
  -- which errors out in a fast context, so doing this once up front (instead
  -- of per commit inside `parse_fh_data`) both saves work and keeps the
  -- post-filter callable from the stream listener.
  local scope_args = scope.path and { scope.path } or self:compute_fh_scope_args(path_args)

  ---@type JjAdapter.FHState
  local state = {
    path_args = path_args,
    scope_args = scope_args,
    log_options = log_options,
    prepared_log_opts = self:prepare_fh_options(log_options, single_file),
    layout_opt = opt.layout_opt,
    single_file = single_file,
  }

  logger:info(
    "[FileHistory] Updating with options:",
    vim.inspect(state.prepared_log_opts, { newline = " ", indent = "" })
  )

  local in_stream = self:stream_fh_data(state)

  ---@param shutdown? SignalConsumer
  out_stream:on_close(function(shutdown)
    if shutdown then
      in_stream:close(shutdown)
    end
  end)

  local last_wait = uv.hrtime()
  local interval = (1000 / 15) * 1E6

  for _, item in in_stream:iter() do
    ---@type JobStatus, table?, string?
    local status, new_data, msg = unpack(item, 1, 3)

    -- Yield periodically so the editor stays responsive.
    local now = uv.hrtime()
    if now - last_wait > interval then
      last_wait = now
      await(async.schedule_now())
    end

    if status == JobStatus.KILLED then
      logger:warn("File history processing was killed.")
      out_stream:push({ status })
      out_stream:close()
      return
    elseif status == JobStatus.ERROR then
      out_stream:push({ status, nil, msg })
      out_stream:close()
      return
    elseif status == JobStatus.SUCCESS then
      out_stream:push({ status })
      out_stream:close()
      return
    elseif status ~= JobStatus.PROGRESS then
      error("Unexpected state!")
    end

    assert(new_data, "No data received from scheduler!")

    local commit = Commit({
      hash = new_data.right_hash,
      author = new_data.author,
      time = tonumber(new_data.time),
      time_offset = new_data.time_offset,
      rel_date = new_data.rel_date,
      ref_names = new_data.ref_names,
      subject = new_data.subject,
    })

    local ok, entry = self:parse_fh_data(new_data, commit, state)

    if ok then
      out_stream:push({ JobStatus.PROGRESS, entry })
    end
  end
end)

---@param data table
---@param commit JjCommit
---@param state JjAdapter.FHState
---@return boolean success
---@return LogEntry|string ret
function JjAdapter:parse_fh_data(data, commit, state)
  local files = {}
  -- jj's `diff.files()` template ignores the CLI pathspec, so the per-commit
  -- file list contains every file the commit changed. Re-apply the path
  -- scope (precomputed by `file_history_worker` in workspace-relative form)
  -- so single-file/scoped history doesn't drag in unrelated files from
  -- commits that happen to touch the requested path.
  local scope_args = state.scope_args or {}

  ---@param path string
  ---@return boolean
  local function in_scope(path)
    if #scope_args == 0 then
      return true
    end
    for _, p in ipairs(scope_args) do
      if p == "." or p == "" then
        return true
      end
      local trimmed = p:gsub("/+$", "")
      if path == trimmed or vim.startswith(path, trimmed .. "/") then
        return true
      end
    end
    return false
  end

  -- `--pin-local` is rejected upstream for jj (see `lib.file_history`), so we
  -- always diff each commit against its parent. The pin-local code paths
  -- mirroring the git/hg adapters are deferred until `build_local_log_entry`
  -- lands for jj.
  for _, line in ipairs(data.namestat) do
    local status, path = line:match("^(%S)%s+(.+)$")
    if status and path and in_scope(path) then
      -- TODO: surface rename source. jj exposes `f.source().path()` on
      -- TreeDiffEntry; threading it into the template + parser is a follow-up.
      local oldname = nil

      local rev_a = data.left_hash and JjRev(RevType.COMMIT, data.left_hash)
        or JjRev.new_null_tree()
      local rev_b = JjRev(RevType.COMMIT, data.right_hash)

      table.insert(
        files,
        self:build_pin_local_file_entry({
          layout_class = state.layout_opt.default_layout or Diff2Hor,
          layout_opt = state.layout_opt,
          path = path,
          oldpath = oldname,
          status = status,
          stats = nil,
          commit = commit,
          rev_a = rev_a,
          rev_b = rev_b,
          single_file = state.single_file,
        })
      )
    end
  end

  if files[1] then
    return true,
      LogEntry({
        path_args = state.path_args,
        commit = commit,
        files = files,
        single_file = state.single_file,
      })
  end

  if state.path_args[1] then
    logger:warn("[JjAdapter:parse_fh_data] Encountered commit with no file data:", data)
    return false, "Found no relevant file data with given path args!"
  end

  -- Commit had no file changes (e.g. empty commit). Return a null entry so
  -- the file-history panel still surfaces it.
  return true,
    LogEntry({
      path_args = state.path_args,
      commit = commit,
      single_file = state.single_file,
      nulled = true,
      files = { FileEntry.new_null_entry(self) },
    })
end

JjAdapter.flags = {
  ---@type FlagOption[]
  switches = {
    FlagOption("-R", "--reversed", "Show revisions oldest-first"),
  },
  ---@type FlagOption[]
  options = {
    FlagOption("=r", "--revisions=", "Revset", { prompt_label = "(Revset)" }),
    FlagOption("=n", "--limit=", "Limit the number of revisions"),
  },
}

-- Add reverse lookups so the option panel can look up a FlagOption by its
-- `key` slug. Mirrors the pattern used by the hg adapter.
for _, list in pairs(JjAdapter.flags) do
  for i, option in ipairs(list) do
    list[i] = option
    list[option.key] = option
  end
end

---@param opt? VCSAdapter.show_untracked.Opt
---@return boolean
function JjAdapter:show_untracked(opt)
  return false
end

---@param self JjAdapter
---@param left Rev
---@param right Rev
---@param args string[]
---@param kind vcs.FileKind
---@param opt vcs.adapter.LayoutOpt
---@param callback function
JjAdapter.tracked_files = async.wrap(function(self, left, right, args, kind, opt, callback)
  local job = Job({
    command = self:bin(),
    args = utils.vec_join(self:args(), "diff", "--summary", args),
    cwd = self.ctx.toplevel,
    retry = 2,
    log_opt = { label = "JjAdapter:tracked_files()" },
  })

  local ok = await(job)

  if not ok or job.code ~= 0 then
    callback(job.stderr or {}, nil)
    return
  end

  local files = {}

  for _, line in ipairs(job.stdout) do
    local status, path = line:match("^(%u)%s+(.*)$")

    if status and path then
      local oldpath

      if status == "R" or status == "C" then
        local from_path, to_path = path:match("^(.-)%s+=>%s+(.-)$")
        oldpath = from_path
        path = to_path or path
      end

      files[#files + 1] = FileEntry.with_layout(opt.default_layout, {
        adapter = self,
        path = path,
        oldpath = oldpath,
        status = status,
        stats = {},
        kind = kind,
        revs = {
          a = left,
          b = right,
        },
      })
    end
  end

  callback(nil, files, {})
end)

---@param self JjAdapter
---@param left Rev
---@param right Rev
---@param opt vcs.adapter.LayoutOpt
---@param callback function
JjAdapter.untracked_files = async.wrap(function(self, left, right, opt, callback)
  callback(nil, {})
end)

---@param self JjAdapter
---@param path string
---@param rev? Rev
---@param callback fun(stderr: string[]?, stdout: string[]?)
JjAdapter.show = async.wrap(function(self, path, rev, callback)
  if not rev or rev:object_name() == self.Rev.NULL_TREE_SHA then
    callback(nil, {})
    return
  end

  local job
  job = Job({
    command = self:bin(),
    args = self:get_show_args(path, rev),
    cwd = self.ctx.toplevel,
    retry = 2,
    fail_cond = Job.FAIL_COND.on_empty,
    log_opt = { label = "JjAdapter:show()" },
    on_exit = async.void(function(_, ok, err)
      if not ok or job.code ~= 0 then
        local out = job.stderr and job.stderr[1] or ""
        if out:match("No such path") then
          callback(nil, {})
        else
          callback(utils.vec_join(err, job.stderr), nil)
        end
        return
      end

      callback(nil, job.stdout)
    end),
  })
  vcs_utils.queue_sync_job(job)
end)

---@param path string
---@param rev Rev
---@return boolean
function JjAdapter:is_binary(path, rev)
  return false
end

---Emit a warning at most once per adapter instance for a given key. The file
---panel batches stage/unstage by retrying file-by-file when a batch fails, so
---an unconditional `utils.warn` would fire N+1 times for a selection of N
---files. Keying lets us coalesce all "no staging in jj" surfaces into a single
---visible message per session.
---@param key string
---@param msg string
function JjAdapter:_warn_once(key, msg)
  self._warned = self._warned or {}
  if self._warned[key] then
    return
  end
  self._warned[key] = true
  utils.warn(msg)
end

---@param path string
---@param kind vcs.FileKind
---@param commit string?
---@param callback fun(ok: boolean, undo?: string)
JjAdapter.file_restore = async.wrap(function(self, path, kind, commit, callback)
  if kind == "staged" then
    self:_warn_once(
      "no_staging",
      "Jujutsu has no staging index; staging-related operations are not supported."
    )
    callback(false)
    return
  end

  -- `jj restore --from <commit> -- <path>` rewrites the working copy from the
  -- source commit. When `commit` is nil this defaults to `@-` (the parent),
  -- which matches "discard local changes" semantics.
  local from = commit or "@-"
  local abs_path = pl:join(self.ctx.toplevel, path)
  local _, code, stderr = self:exec_sync(
    { "restore", "--from", from, "--", fileset_exact(path) },
    { cwd = self.ctx.toplevel }
  )

  if code ~= 0 then
    utils.err(
      utils.vec_join(
        fmt("Failed to restore %s from %s!", utils.str_quote(path), utils.str_quote(from)),
        "Jujutsu output:",
        stderr
      )
    )
    callback(false)
    return
  end

  -- Refresh any open buffer for the restored file so its contents are picked
  -- up from disk instead of staying stale.
  await(async.scheduler())
  local bn = utils.find_file_buffer(abs_path)
  if bn then
    vim.cmd(fmt("checktime %d", bn))
  end

  callback(true, ":!jj op undo")
end)

-- The staging methods below are deliberate no-ops: jj has no staging index, so
-- there is nothing to do. We return `true` (rather than `false`) because the
-- diff-view staging listeners surface a "Failed to stage/unstage" error on a
-- `false` return, and the user has already been told via `_warn_once` that the
-- operation is unsupported. A `true` return signals "request handled" without
-- piling a misleading error on top of the warning.

---@param file vcs.File
---@return boolean
function JjAdapter:stage_index_file(file) ---@diagnostic disable-line: unused-local
  self:_warn_once(
    "no_staging",
    "Jujutsu has no staging index; staging-related operations are not supported."
  )
  return true
end

---@param paths string[]?
---@return boolean
function JjAdapter:reset_files(paths) ---@diagnostic disable-line: unused-local
  self:_warn_once(
    "no_staging",
    "Jujutsu has no staging index; staging-related operations are not supported."
  )
  return true
end

---@param paths string[]
---@return boolean
function JjAdapter:add_files(paths) ---@diagnostic disable-line: unused-local
  self:_warn_once(
    "no_staging",
    "Jujutsu has no staging index; staging-related operations are not supported."
  )
  return true
end

---@param arg_lead string
---@param opt? RevCompletionSpec
---@return string[]
function JjAdapter:rev_candidates(arg_lead, opt)
  opt = vim.tbl_extend("keep", opt or {}, { accept_range = false }) --[[@as RevCompletionSpec ]]
  logger:lvl(1):debug("[completion] Revision candidates requested.")

  local ret = { "@", "@-", "root()" }
  local bookmarks = self:exec_sync(
    { "bookmark", "list", "-a", "-T", [[name ++ "\n"]] },
    { cwd = self.ctx.toplevel, silent = true }
  )

  local tags = self:exec_sync(
    { "tag", "list", "-T", [[name ++ "\n"]] },
    { cwd = self.ctx.toplevel, silent = true }
  )

  ret = utils.vec_join(ret, bookmarks, tags)

  local seen = {}
  ret = vim.tbl_filter(function(v)
    if not v or v == "" or seen[v] then
      return false
    end
    seen[v] = true
    return true
  end, ret)

  if opt.accept_range then
    local _, range_end = utils.str_match(arg_lead, {
      "^(%.%.%.?)()$",
      "^(%.%.%.?)()[^.]",
      "[^.](%.%.%.?)()$",
      "[^.](%.%.%.?)()[^.]",
    })

    if range_end then
      local range_lead = arg_lead:sub(1, range_end - 1)
      ret = vim.tbl_map(function(v)
        return range_lead .. v
      end, ret)
    end
  end

  return ret
end

function JjAdapter:init_completion()
  self.comp.open:put({ "u", "untracked-files" }, { "true", "normal", "all", "false", "no" })
  self.comp.open:put({ "C" }, function(_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "dir")
  end)
  self.comp.open:put({ "selected-file" }, function(_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "file")
  end)

  self.comp.file_history:put({ "--revisions", "-r" }, function(_, arg_lead)
    return self:rev_candidates(arg_lead, { accept_range = true })
  end)

  self.comp.file_history:put({ "--reversed", "-R" })
  self.comp.file_history:put({ "--limit", "-n" }, {})
end

M.JjAdapter = JjAdapter
-- Internals exposed for unit testing only. Do not consume from outside the
-- adapter; the shape is unstable.
M._test = {
  structure_fh_data = structure_fh_data,
  FH_TEMPLATE = FH_TEMPLATE,
  is_non_literal_pathspec = is_non_literal_pathspec,
  is_ambiguous_literal_path = is_ambiguous_literal_path,
  quote_path_args = quote_path_args,
}
return M
