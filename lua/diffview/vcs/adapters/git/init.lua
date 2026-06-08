local AsyncListStream = require("diffview.stream").AsyncListStream
local Commit = require("diffview.vcs.adapters.git.commit").GitCommit
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local FileEntry = require("diffview.scene.file_entry").FileEntry
local FlagOption = require("diffview.vcs.flag_option").FlagOption
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local Job = require("diffview.job").Job
local JobStatus = require("diffview.vcs.utils").JobStatus
local LogEntry = require("diffview.vcs.log_entry").LogEntry
local MultiJob = require("diffview.multi_job").MultiJob
local RevType = require("diffview.vcs.rev").RevType
local VCSAdapter = require("diffview.vcs.adapter").VCSAdapter
local arg_parser = require("diffview.arg_parser")
local async = require("diffview.async")
local config = require("diffview.config")
local git_parser = require("diffview.vcs.adapters.git.parser")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")
local utils = require("diffview.utils")
local vcs_utils = require("diffview.vcs.utils")

local api = vim.api
local await, pawait = async.await, async.pawait
local fmt = string.format
local logger = DiffviewGlobal.logger
local pl = lazy.access(utils, "path") --[[@as PathLib ]]
local uv = vim.uv

local M = {}

---@class GitAdapter : VCSAdapter
---@operator call : GitAdapter
local GitAdapter = oop.create_class("GitAdapter", VCSAdapter)

GitAdapter.Rev = GitRev
GitAdapter.config_key = "git"
GitAdapter.bootstrap = {
  done = false,
  ok = false,
  version = {},
  target_version = {
    major = 2,
    minor = 31,
    patch = 0,
  },
}

-- stylua: ignore start
GitAdapter.COMMIT_PRETTY_FMT = (
  "%H %P"      -- Commit hash followed by parent hashes
  .. "%n%an"   -- Author name
  .. "%n%at"   -- Author date: UNIX timestamp
  .. "%n%ai"   -- Author date: ISO (gives us timezone)
  .. "%n%ar"   -- Author date: relative
  .. "%n..%D"  -- Ref names
  .. "%n..%gd" -- Reflog selectors
  .. "%n..%s"  -- Subject
  -- The leading dots here are only used for padding to ensure those lines
  -- won't ever be completely empty. This way the lines will be
  -- distinguishable from other empty lines outputted by Git.
)
-- stylua: ignore end

---@return string, string
function GitAdapter.pathspec_split(pathspec)
  local magic = utils.str_match(pathspec, {
    "^:[/!^]+:?",
    "^:%b()",
    "^:",
  }) or ""
  local pattern = pathspec:sub(1 + #magic, -1)
  return magic or "", pattern or ""
end

function GitAdapter.pathspec_expand(toplevel, cwd, pathspec)
  local magic, pattern = GitAdapter.pathspec_split(pathspec)
  if not pl:is_abs(pattern) then
    pattern = pl:join(pl:relative(cwd, toplevel), pattern)
  end
  return magic .. pl:convert(pattern)
end

function GitAdapter.pathspec_modify(pathspec, mods)
  local magic, pattern = GitAdapter.pathspec_split(pathspec)
  return magic .. pl:vim_fnamemodify(pattern, mods)
end

function GitAdapter.run_bootstrap()
  local git_cmd = config.get_config().git_cmd
  local bs = GitAdapter.bootstrap
  local err = VCSAdapter.bootstrap_preamble(bs, git_cmd, "GitAdapter", "git_cmd")
  if not err then
    return
  end

  local out = utils.job(utils.flatten({ git_cmd, "version" }))
  bs.version_string = out[1] and out[1]:match("git version (%S+)") or nil

  if not bs.version_string then
    return err("Could not get Git version!")
  end

  -- Parse version string
  local v, target = bs.version, bs.target_version
  bs.target_version_string = fmt("%d.%d.%d", target.major, target.minor, target.patch)
  local parts = vim.split(bs.version_string, "%.")
  v.major = tonumber(parts[1])
  v.minor = tonumber(parts[2]) or 0
  v.patch = tonumber(parts[3]) or 0

  local version_ok = vcs_utils.check_semver(v, target)

  if not version_ok then
    return err(
      string.format(
        "Git version is outdated! Some functionality might not work as expected, "
          .. "or not at all! Current: %s, wanted: %s",
        bs.version_string,
        bs.target_version_string
      )
    )
  end

  bs.ok = true
end

---@param path_args string[] # Raw path args
---@param cpath string? # Cwd path given by the `-C` flag option
---@return string[] path_args # Resolved path args
---@return string[] top_indicators # Top-level indicators
function GitAdapter.get_repo_paths(path_args, cpath)
  local paths = {}
  local top_indicators = {}

  for _, path_arg in ipairs(path_args) do
    for _, path in
      ipairs(pl:vim_expand(path_arg, false, true) --[[@as string[] ]])
    do
      local magic, pattern = GitAdapter.pathspec_split(path)
      pattern = pl:readlink(pattern) or pattern
      table.insert(paths, magic .. pattern)
    end
  end

  for _, path in ipairs(paths) do
    if GitAdapter.pathspec_split(path) == "" then
      table.insert(top_indicators, pl:absolute(path, cpath))
      break
    end
  end

  VCSAdapter.append_implicit_indicators(top_indicators, cpath)

  return paths, top_indicators
end

---Extract the working-tree path from a git `-L` spec. Each spec is shaped
---`<line-spec>:<path>`, where `<line-spec>` is one of `<start>,<end>`,
---`:<funcname>`, or `:<regex>:`. We take the suffix after the last `:` to
---match git's own parsing (`strrchr(spec, ':')` in `line-log.c`); paths
---containing `:` are ambiguous to git itself. Returns nil when the spec
---is malformed or has no path so callers can downgrade safely.
---@param spec string
---@return string?
local function l_spec_path(spec)
  local path = spec:match(".*:(.*)")
  if path == nil or path == "" then
    return nil
  end
  return path
end

local has_cygpath ---@type boolean?
---@type table<string, string>
local cygpath_cache = {}

---Convert MSYS2/Cygwin Unix-style paths to Windows paths when running on
---native Windows with a Cygwin-based git. Without this, paths like
---`/c/Users/...` returned by Cygwin git are unusable by Neovim.
---See: https://www.msys2.org/docs/git/
---@param path string?
---@return string?
local function normalize_cygwin_path(path)
  if not path or vim.fn.has("win32") ~= 1 or path:sub(1, 1) ~= "/" then
    return path
  end

  if cygpath_cache[path] then
    return cygpath_cache[path]
  end

  if has_cygpath == nil then
    has_cygpath = vim.fn.executable("cygpath") == 1
  end

  if has_cygpath then
    local result = vim.trim(vim.fn.system({ "cygpath", "--absolute", "--windows", path }))
    if vim.v.shell_error ~= 0 or result == "" then
      return path
    end
    cygpath_cache[path] = result
    return result
  end

  return path
end

---Get the git toplevel directory from a path to file or directory
---@param path string
---@return string?
local function get_toplevel(path)
  local out, code = utils.job(
    utils.flatten({
      config.get_config().git_cmd,
      { "rev-parse", "--path-format=absolute", "--show-toplevel" },
    }),
    path
  )
  if code ~= 0 then
    return nil
  end
  return normalize_cygwin_path(out[1] and vim.trim(out[1]))
end

---@param top_indicators string[] A list of paths that might indicate what working tree we are in.
---@return string? err
---@return string toplevel # as an absolute path
function GitAdapter.find_toplevel(top_indicators)
  return VCSAdapter.find_toplevel_with(top_indicators, get_toplevel, "git")
end

---@param toplevel string
---@param path_args string[]
---@param cpath string?
---@return string? err
---@return GitAdapter
function GitAdapter.create(toplevel, path_args, cpath)
  local err
  local adapter = GitAdapter({
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
    err = "Could not find the Git directory!"
  elseif not pl:is_dir(adapter.ctx.dir) then
    err = "The Git directory is not readable: " .. adapter.ctx.dir
  end

  return err, adapter
end

---@param opt vcs.adapter.VCSAdapter.Opt
function GitAdapter:init(opt)
  opt = opt or {}
  self:super(opt)

  local cwd = opt.cpath or uv.cwd()

  self.ctx = {
    toplevel = opt.toplevel,
    dir = self:get_dir(opt.toplevel),
    path_args = vim.tbl_map(function(pathspec)
      return GitAdapter.pathspec_expand(opt.toplevel, cwd, pathspec)
    end, opt.path_args or {}) --[[@as string[] ]],
  }

  self:init_completion()
end

function GitAdapter:get_command()
  return config.get_config().git_cmd
end

---@param path string
---@param rev Rev?
function GitAdapter:get_show_args(path, rev)
  return utils.vec_join(
    self:args(),
    "show",
    "--no-show-signature",
    fmt("%s:%s", rev and rev:object_name() or "", path)
  )
end

function GitAdapter:get_log_args(args)
  return utils.vec_join("log", "--no-show-signature", "--first-parent", "--stat", args)
end

function GitAdapter:get_dir(path)
  local out, code = self:exec_sync({ "rev-parse", "--path-format=absolute", "--git-dir" }, path)
  if code ~= 0 then
    return nil
  end
  return normalize_cygwin_path(out[1] and vim.trim(out[1]))
end

---Verify that a given git rev is valid.
---@param rev_arg string
---@return boolean ok, string[] output
function GitAdapter:verify_rev_arg(rev_arg)
  local out, code = self:exec_sync({ "rev-parse", "--revs-only", rev_arg }, {
    log_opt = { label = "GitAdapter:verify_rev_arg()" },
    cwd = self.ctx.toplevel,
  })
  return code == 0 and (out[2] ~= nil or out[1] and out[1] ~= ""), out
end

---@return vcs.MergeContext?
function GitAdapter:get_merge_context()
  local their_head

  for _, name in ipairs({ "MERGE_HEAD", "REBASE_HEAD", "REVERT_HEAD", "CHERRY_PICK_HEAD" }) do
    if pl:readable(pl:join(self.ctx.dir, name)) then
      their_head = name
      break
    end
  end

  if not their_head then
    -- We were unable to find THEIR head. Merge could be a result of an applied
    -- stash (or something else?). Either way, we can't proceed.
    return
  end

  local ret = {}
  local out, code = self:exec_sync(
    { "show", "-s", "--no-show-signature", "--pretty=format:%H%n%D", "HEAD", "--" },
    self.ctx.toplevel
  )

  ret.ours = code ~= 0 and {} or {
    hash = out[1],
    ref_names = out[2],
  }

  out, code = self:exec_sync(
    { "show", "-s", "--no-show-signature", "--pretty=format:%H%n%D", their_head, "--" },
    self.ctx.toplevel
  )

  ret.theirs = code ~= 0 and {} or {
    hash = out[1],
    ref_names = out[2],
  }

  out, code = self:exec_sync({ "merge-base", "HEAD", their_head }, self.ctx.toplevel)
  if code ~= 0 then
    -- merge-base can fail during --root rebases for initial commits.
    -- Use the canonical empty tree SHA as the base.
    ret.base = { hash = self.Rev.NULL_TREE_SHA, ref_names = nil }
  else
    ret.base = {
      hash = out[1],
      ref_names = self:exec_sync(
        { "show", "-s", "--no-show-signature", "--pretty=format:%D", out[1] },
        self.ctx.toplevel
      )[1],
    }
  end

  return ret
end

---@class GitAdapter.PreparedLogOpts
---@field rev_range string
---@field base Rev
---@field path_args string[]
---@field flags string[]

---@param log_options GitLogOptions
---@param single_file boolean
---@return GitAdapter.PreparedLogOpts
function GitAdapter:prepare_fh_options(log_options, single_file)
  local o = log_options
  local line_trace = vim.tbl_map(function(v)
    if not v:match("^-L") then
      return "-L" .. v
    end
    return v
  end, o.L or {})

  local rev_range, base

  if log_options.rev_range then
    local ok, _ = self:verify_rev_arg(log_options.rev_range)

    if not ok then
      utils.warn(fmt("Bad range revision, ignoring: %s", utils.str_quote(log_options.rev_range)))
    else
      rev_range = log_options.rev_range
    end
  end

  if log_options.base then
    if log_options.base == "LOCAL" then
      base = GitRev(RevType.LOCAL)
    else
      local ok, out = self:verify_rev_arg(log_options.base)

      if not ok then
        utils.warn(fmt("Bad base revision, ignoring: %s", utils.str_quote(log_options.base)))
      else
        base = GitRev(RevType.COMMIT, out[1])
      end
    end
  end

  return {
    rev_range = rev_range,
    base = base,
    path_args = log_options.path_args,
    flags = utils.vec_join(
      line_trace,
      (o.follow and single_file) and { "--follow" } or nil,
      o.first_parent and { "--first-parent" } or nil,
      o.show_pulls and { "--show-pulls" } or nil,
      o.reflog and { "--reflog" } or nil,
      o.walk_reflogs and { "--walk-reflogs" } or nil,
      o.all and { "--all" } or nil,
      o.merges and { "--merges" } or nil,
      o.no_merges and { "--no-merges" } or nil,
      o.reverse and { "--reverse" } or nil,
      o.cherry_pick and { "--cherry-pick" } or nil,
      o.left_only and { "--left-only" } or nil,
      o.right_only and { "--right-only" } or nil,
      o.max_count and { "-n" .. o.max_count } or nil,
      o.diff_merges and { "--diff-merges=" .. o.diff_merges } or nil,
      o.author and { "-E", "--author=" .. o.author } or nil,
      o.grep and { "-E", "--grep=" .. o.grep } or nil,
      o.G and { "-E", "-G" .. o.G } or nil,
      o.S and { "-S" .. o.S, "--pickaxe-regex" } or nil,
      o.after and { "--after=" .. o.after } or nil,
      o.before and { "--before=" .. o.before } or nil
    ),
  }
end

-- The stat data may appear intertwined, like:
--
-- :100644 100644 5755178b18 cb8f8ce44d M  src/nvim/eval/typval.c
-- :100644 100644 84e4067f9d 767fd706b3 M  src/nvim/eval/typval.h
-- :100644 100644 5231ec0841 4e521b14f7 M  src/nvim/strings.c
-- 22      0       src/nvim/eval/typval.c
-- 0       4       src/nvim/eval/typval.h
-- 25      12      src/nvim/strings.c
-- :100644 100644 ea6555f005 2fd0aed601 M  runtime/syntax/checkhealth.vim
-- 1       1       runtime/syntax/checkhealth.vim

local structure_stat_data = git_parser.structure_stat_data
local structure_fh_data = git_parser.structure_fh_data

---@param state GitAdapter.FHState
function GitAdapter:stream_fh_data(state)
  ---@type diffview.Job, AsyncListStream
  local job, stream
  ---@type string[]?
  local data

  local function on_stdout(_, line)
    if line == "\0" then
      if data then
        local log_data = structure_fh_data(data)
        stream:push({ JobStatus.PROGRESS, log_data })
      end

      data = {}
    else
      data[#data + 1] = line
    end
  end

  stream = AsyncListStream({
    ---@param shutdown? SignalConsumer Shutdown signal
    on_close = function(shutdown)
      if shutdown and shutdown:check() then
        if job:is_running() then
          logger:warn("Received shutdown signal. Killing file history jobs...")
          job:kill(64)
        else
          logger:warn("Received shutdown signal, but no jobs are running. Nothing to do.")
        end

        stream:push({ JobStatus.KILLED })
        return
      end

      local ok, err = job:is_success()
      if job:is_done() and ok and job.code == 0 then
        on_stdout(nil, "\0")
      end

      if not ok then
        stream:push({
          JobStatus.ERROR,
          nil,
          table.concat(utils.vec_join(err, job.stderr), "\n"),
        })
      else
        stream:push({ JobStatus.SUCCESS })
      end
    end,
  })

  job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "-P",
      "-c",
      "gc.auto=0",
      "-c",
      "core.quotePath=false",
      "log",
      "--no-show-signature",
      "--pretty=format:%x00%n" .. GitAdapter.COMMIT_PRETTY_FMT,
      (function()
        local t = config.get_config().rename_threshold
        return t and ("-M" .. t .. "%") or nil
      end)(),
      "--numstat",
      "--raw",
      state.prepared_log_opts.flags,
      state.prepared_log_opts.rev_range,
      "--",
      state.path_args
    ),
    cwd = self.ctx.toplevel,
    log_opt = { label = "GitAdapter:incremental_fh_data()" },
    on_stdout = on_stdout,
    on_exit = utils.hard_bind(stream.close, stream),
  })

  job:start()

  return stream
end

---@param state GitAdapter.FHState
function GitAdapter:stream_line_trace_data(state)
  ---@type diffview.Job, AsyncListStream
  local job, stream
  ---@type string[]?
  local data

  local function on_stdout(_, line)
    if line == "\0" then
      if data then
        local log_data = structure_fh_data(data, true)
        stream:push({ JobStatus.PROGRESS, log_data })
      end

      data = {}
    else
      data[#data + 1] = line
    end
  end

  stream = AsyncListStream({
    ---@param kill? boolean Shutdown signal
    on_close = function(kill)
      if kill then
        if job:is_running() then
          logger:warn("Received shutdown signal. Killing file history jobs...")
          job:kill(64)
        else
          logger:warn("Received shutdown signal, but no jobs are running. Nothing to do.")
        end

        stream:push({ JobStatus.KILLED })
        return
      end

      local ok, err = job:is_success()
      if job:is_done() and ok and job.code == 0 then
        on_stdout(nil, "\0")
      end

      if not ok then
        stream:push({
          JobStatus.ERROR,
          nil,
          table.concat(utils.vec_join(err, job.stderr), "\n"),
        })
      else
        stream:push({ JobStatus.SUCCESS })
      end
    end,
  })

  job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "-P",
      "-c",
      "gc.auto=0",
      "-c",
      "core.quotePath=false",
      "log",
      "--no-show-signature",
      "--color=never",
      "--no-ext-diff",
      "--pretty=format:%x00%n" .. GitAdapter.COMMIT_PRETTY_FMT,
      state.prepared_log_opts.flags,
      state.prepared_log_opts.rev_range,
      "--"
    ),
    cwd = self.ctx.toplevel,
    log_opt = { label = "GitAdapter:incremental_line_trace_data()" },
    on_stdout = on_stdout,
    on_exit = utils.hard_bind(stream.close, stream),
  })

  job:start()

  return stream
end

---@override
---@param path_args string[]
---@param log_options GitLogOptions
---@return vcs.adapter.HistoryScope
function GitAdapter:history_scope(path_args, log_options)
  local lflags = log_options and log_options.L or {}
  if #lflags > 0 then
    -- Line-trace history: each `L` spec is `<line-spec>:<path>`. The
    -- working-tree path lives there, not in `path_args` (which is empty
    -- in `-L` mode). A malformed spec (no `:`, empty path) downgrades
    -- the whole scope to multi-file rather than seeding `pinned_path`
    -- with nil/empty downstream.
    local first_path = l_spec_path(lflags[1])
    if not first_path then
      return { single_file = false }
    end
    for i = 2, #lflags do
      if l_spec_path(lflags[i]) ~= first_path then
        return { single_file = false }
      end
    end
    return { single_file = true, path = first_path }
  end

  if not (path_args and #path_args == 1 and self.ctx.toplevel) then
    return { single_file = false }
  end
  if pl:is_dir(path_args[1]) then
    return { single_file = false }
  end
  -- Resolve the pathspec to the actual tracked file. `path_args[1]` may
  -- be a glob / magic pathspec (`*.lua`, `:(glob)**/*.lua`, ...) rather
  -- than a literal path; using it raw as `pinned_path` would key the
  -- pin_local cache by the pathspec instead of the matched filename and
  -- the RHS would try to open a LOCAL file named after the pattern. The
  -- ls-files call canonicalises to git's relative emission, so absolute
  -- and relative spellings of the same file also share a cache key.
  local out = self:exec_sync(
    utils.vec_join("-c", "core.quotePath=false", "ls-files", "--", path_args),
    self.ctx.toplevel
  )
  if #out == 1 then
    return { single_file = true, path = out[1] }
  end
  if #out == 0 then
    -- Match `is_single_file`'s `< 2` semantics: a single-pathspec history
    -- whose path isn't tracked today (deleted, renamed away, etc.) is still
    -- single-file and may have history. Fall back to the literal pathspec
    -- as the rename anchor; a magic pathspec that resolves to nothing also
    -- has empty history, so the approximation is harmless there.
    return { single_file = true, path = path_args[1] }
  end
  return { single_file = false }
end

---@param path_args string[]
---@param lflags? string[]
---@return boolean
function GitAdapter:is_single_file(path_args, lflags)
  if lflags and #lflags > 0 then
    local seen = {}
    for i, v in ipairs(lflags) do
      local path = l_spec_path(v)
      if not path then
        -- Malformed L spec: fall back to multi-file rather than indexing
        -- `seen` with nil (which would error).
        return false
      end
      if i > 1 and not seen[path] then
        return false
      end
      seen[path] = true
    end
  elseif path_args and self.ctx.toplevel then
    return #path_args == 1
      and not pl:is_dir(path_args[1])
      and #self:exec_sync(
          utils.vec_join("-c", "core.quotePath=false", "ls-files", "--", path_args),
          self.ctx.toplevel
        )
        < 2
  end

  return true
end

---@param log_opt GitLogOptions
---@return boolean ok, string description
function GitAdapter:file_history_dry_run(log_opt)
  local single_file = self:is_single_file(log_opt.path_args, log_opt.L)
  local log_options = config.get_log_options(single_file, log_opt, "git") --[[@as GitLogOptions ]]

  local options = vim.tbl_map(function(v)
    return vim.fn.shellescape(v)
  end, self:prepare_fh_options(log_options, single_file).flags) --[[@as vector ]]

  local description = utils.vec_join(
    fmt("Top-level path: '%s'", pl:vim_fnamemodify(self.ctx.toplevel, ":~")),
    log_options.rev_range and fmt("Revision range: '%s'", log_options.rev_range) or nil,
    fmt("Flags: %s", table.concat(options, " "))
  )

  log_options = utils.tbl_clone(log_options) --[[@as GitLogOptions ]]
  log_options.max_count = 1
  options = self:prepare_fh_options(log_options, single_file).flags

  local context = "GitAdapter:file_history_dry_run()"
  local cmd

  if #log_options.L > 0 then
    -- cmd = utils.vec_join("-P", "log", log_options.rev_range, "--no-ext-diff", "--color=never", "--pretty=format:%H", "-s", options, "--")
    -- NOTE: Running the dry-run for line tracing is slow. Just skip for now.
    return true, table.concat(description, ", ")
  else
    cmd = utils.vec_join(
      "log",
      "--no-show-signature",
      "--pretty=format:%H",
      "--name-status",
      options,
      log_options.rev_range,
      "--",
      log_options.path_args
    )
  end

  local out, code = self:exec_sync(cmd, {
    cwd = self.ctx.toplevel,
    log_opt = { label = context },
  })

  local ok = code == 0 and #out > 0

  if not ok then
    logger:fmt_debug("[%s] Dry run failed.", context)
  end

  return ok, table.concat(description, ", ")
end

---@param range? { [1]: integer, [2]: integer }
---@param paths string[]
---@param argo ArgObject
function GitAdapter:file_history_options(range, paths, argo)
  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile

  logger:fmt_debug("Found git top-level: %s", utils.str_quote(self.ctx.toplevel))

  local rel_paths = vim.tbl_map(function(v)
    return v == "." and "." or pl:relative(v, ".")
  end, paths) --[[@as string[] ]]

  local range_arg = argo:get_flag("range", { no_empty = true }) --[[@as string? ]]
  if range_arg then
    local ok = self:verify_rev_arg(range_arg)
    if not ok then
      utils.err(fmt("Bad revision: %s", utils.str_quote(range_arg)))
      return
    end

    logger:fmt_debug("Verified range rev: %s", range_arg)
  end

  local log_flag_names = {
    { "follow" },
    { "first-parent" },
    { "show-pulls" },
    { "reflog" },
    { "walk-reflogs", "g" },
    { "all" },
    { "merges" },
    { "no-merges" },
    { "reverse" },
    { "cherry-pick" },
    { "left-only" },
    { "right-only" },
    { "max-count", "n" },
    { "L" },
    { "diff-merges" },
    { "author" },
    { "grep" },
    { "base" },
    { "G" },
    { "S" },
    { "after", "since" },
    { "before", "until" },
  }

  ---@diagnostic disable-next-line: missing-fields
  local log_options = { rev_range = range_arg } --[[@as GitLogOptions ]]
  for _, names in ipairs(log_flag_names) do
    local key, _ = names[1]:gsub("%-", "_")
    local v = argo:get_flag(names, {
      expect_string = type(config.log_option_defaults[self.config_key][key]) ~= "boolean",
      expect_list = names[1] == "L",
    })
    ---@diagnostic disable-next-line: assign-type-mismatch
    log_options[key] = v
  end

  if range then
    paths, rel_paths = {}, {}
    log_options.L = {
      fmt("%d,%d:%s", range[1], range[2], pl:relative(pl:absolute(cfile), self.ctx.toplevel)),
    }
  end

  if log_options.L and next(log_options.L) then
    log_options.follow = false -- '--follow' is not compatible with '-L'
  end

  log_options.path_args = paths

  local ok, opt_description = self:file_history_dry_run(log_options)

  if not ok then
    local msg = "No git history for the target(s) given the current options! Targets: %s\n"
      .. "Current options: [ %s ]"

    if #rel_paths == 0 then
      utils.info(fmt(msg, "':(top)'", opt_description))
    else
      local msg_paths = vim.tbl_map(utils.str_quote, rel_paths)
      utils.info(fmt(msg, table.concat(msg_paths, ", "), opt_description))
    end

    return
  end

  if not self.ctx.dir then
    utils.err(
      fmt("Failed to find the git dir for the repository: %s", utils.str_quote(self.ctx.toplevel))
    )
    return
  end

  return log_options
end

---Collect the set of commit hashes reachable from any remote-tracking ref,
---restricted to commits affecting `path_args`. Used by the file history view
---to colour pushed vs unpushed commits accurately (i.e. not only at the tip
---of a remote branch). Returns an empty set if the repository has no
---remote-tracking refs, or `nil` if the command fails.
---
---Note: this is broader than lazygit's "pushed" check. Lazygit asks whether
---the commit is reachable from the current branch's configured upstream
---(`@{u}`); we ask whether it's reachable from any `refs/remotes/*/*`. In
---a fork-and-upstream workflow that gap is visible: a commit on
---`refs/remotes/upstream/<branch>` but not yet on your fork's branch tip
---is "pushed" here but "unpushed" in lazygit. The broader check stays
---branch-independent (so it works for repo-wide history and detached HEAD)
---and surfaces "already on `origin/main`" as a useful signal.
---@param path_args string[]
---@return table<string, true>?
function GitAdapter:fh_compute_pushed_set(path_args)
  local out, code = self:exec_sync(utils.vec_join("rev-list", "--remotes", "--", path_args), {
    cwd = self.ctx.toplevel,
    log_opt = { label = "GitAdapter:fh_compute_pushed_set()" },
  })

  if code ~= 0 then
    return nil
  end

  local set = {}
  for _, sha in ipairs(out) do
    if #sha > 0 then
      set[sha] = true
    end
  end
  return set
end

---When `--follow` traces a single-file history through a rename, the streamed
---commits include those that touched the file under previous names. The
---initial pushed set is computed for the current path only (via
---`git rev-list --remotes -- <path>`, which has no `--follow` equivalent), so
---it cannot recognise pre-rename commits as pushed. This method extends
---`state.pushed_set` with hashes that touched `path` and are reachable from
---a remote-tracking ref. Idempotent per path: a second call with the same
---path is a no-op.
---@param state GitAdapter.FHState
---@param path string Path the file had before the detected rename.
function GitAdapter:fh_extend_pushed_set(state, path)
  if not state.pushed_set or not state.pushed_paths_seen then
    return
  end
  if state.pushed_paths_seen[path] then
    return
  end
  state.pushed_paths_seen[path] = true

  local extra = self:fh_compute_pushed_set({ path })
  if not extra then
    return
  end
  for sha in pairs(extra) do
    state.pushed_set[sha] = true
  end
end

---Find local and remote-tracking refs that name a "main" branch. Used by the
---file history view to colour commits reachable from trunk distinctly. Names
---hard-coded to the conventional set (`main`, `master`); matching remote-
---tracking refs (e.g. `refs/remotes/origin/main`) are included too so commits
---that are merged on the remote but not yet pulled locally still count.
---@return string[]
function GitAdapter:_find_main_branch_refs()
  local out, code = self:exec_sync({
    "for-each-ref",
    "--format=%(refname)",
    "refs/heads/main",
    "refs/heads/master",
    "refs/remotes/*/main",
    "refs/remotes/*/master",
  }, {
    cwd = self.ctx.toplevel,
    log_opt = { label = "GitAdapter:_find_main_branch_refs()" },
  })

  if code ~= 0 then
    return {}
  end

  local refs = {}
  for _, line in ipairs(out) do
    if #line > 0 then
      table.insert(refs, line)
    end
  end
  return refs
end

---Collect the set of commit hashes reachable from any "main" branch ref (see
---`_find_main_branch_refs`), restricted to commits affecting `path_args`.
---Used by the file history view to colour commits that have landed on trunk
---distinctly from commits that are merely pushed. Returns an empty set if no
---main branch refs exist, or `nil` if the command fails.
---@param main_refs string[] Refs to traverse from, e.g. as returned by `_find_main_branch_refs`.
---@param path_args string[]
---@return table<string, true>?
function GitAdapter:fh_compute_merged_set(main_refs, path_args)
  if #main_refs == 0 then
    return {}
  end

  local out, code = self:exec_sync(utils.vec_join("rev-list", main_refs, "--", path_args), {
    cwd = self.ctx.toplevel,
    log_opt = { label = "GitAdapter:fh_compute_merged_set()" },
  })

  if code ~= 0 then
    return nil
  end

  local set = {}
  for _, sha in ipairs(out) do
    if #sha > 0 then
      set[sha] = true
    end
  end
  return set
end

---Counterpart to `fh_extend_pushed_set` for the merged set: when a `--follow`
---rename is detected, top up the merged set with commits that touched the
---file under its previous name and are reachable from a main branch ref.
---@param state GitAdapter.FHState
---@param path string Path the file had before the detected rename.
function GitAdapter:fh_extend_merged_set(state, path)
  if not state.merged_set or not state.merged_paths_seen or not state.main_refs then
    return
  end
  if state.merged_paths_seen[path] then
    return
  end
  state.merged_paths_seen[path] = true

  local extra = self:fh_compute_merged_set(state.main_refs, { path })
  if not extra then
    return
  end
  for sha in pairs(extra) do
    state.merged_set[sha] = true
  end
end

---@class GitAdapter.FHState
---@field path_args string[]
---@field log_options GitLogOptions
---@field prepared_log_opts GitAdapter.PreparedLogOpts
---@field layout_opt vcs.adapter.LayoutOpt
---@field single_file boolean
---@field old_path string?
---@field pushed_set? table<string, true> Hashes of commits reachable from any remote-tracking ref. Absent if not computed (e.g. `subject_highlight = "plain"`).
---@field pushed_paths_seen? table<string, true> Paths already queried while building `pushed_set`. Used to keep the rename extension (`fh_extend_pushed_set`) idempotent.
---@field main_refs? string[] Refs (local and remote-tracking) that name a "main" branch, resolved once at worker start. Only set in `merge_aware` mode.
---@field merged_set? table<string, true> Hashes of commits reachable from any main branch ref. Absent unless `subject_highlight = "merge_aware"`.
---@field merged_paths_seen? table<string, true> Paths already queried while building `merged_set`; idempotency mirror of `pushed_paths_seen`.

---@param self GitAdapter
---@param out_stream AsyncListStream
---@param opt vcs.adapter.FileHistoryWorkerSpec
GitAdapter.file_history_worker = async.void(function(self, out_stream, opt)
  local single_file =
    self:is_single_file(opt.log_opt.single_file.path_args, opt.log_opt.single_file.L)

  local log_options = config.get_log_options(
    single_file,
    single_file and opt.log_opt.single_file or opt.log_opt.multi_file,
    "git"
  ) --[[@as GitLogOptions ]]

  local is_trace = #log_options.L > 0

  ---@type GitAdapter.FHState
  local state = {
    path_args = opt.log_opt.single_file.path_args,
    log_options = log_options,
    prepared_log_opts = self:prepare_fh_options(log_options, single_file),
    layout_opt = opt.layout_opt,
    single_file = single_file,
  }

  -- Precompute the pushed set so render can colour each commit by reachability
  -- from a remote ref, not only by `%D` decoration at remote tips. Skipped
  -- when ref-aware colouring is off so we don't pay for a git call we won't use.
  -- In `-L` (line-trace) mode `state.path_args` is empty: the traced file lives
  -- in the L spec instead. `history_scope` extracts it so we restrict the
  -- `git rev-list --remotes` query rather than scanning every commit reachable
  -- from any remote ref. Multi-file `-L` (different paths across specs) is
  -- non-single-file: skip the precompute since a path-less query would defeat
  -- the requested scope.
  -- For repo-wide history (no path args) we still precompute via
  -- `git rev-list --remotes --`, traversing every commit reachable from any
  -- remote ref. This is cheap on typical repos; users on pathologically large
  -- repos can opt out with `subject_highlight = "plain"`.
  -- `pushed_paths_seen` lets `fh_extend_pushed_set` (called from the parse
  -- functions when a `--follow` rename is detected) avoid requerying paths
  -- already covered by the initial computation.
  -- `merge_aware` adds a third state for commits reachable from a "main"
  -- branch (see `_find_main_branch_refs`). It needs both the pushed and
  -- merged sets, so it implies the `ref_aware` precompute too.
  local subj_hl = config.get_config().file_history_panel.subject_highlight
  if subj_hl == "ref_aware" or subj_hl == "merge_aware" then
    local pushed_paths
    if is_trace then
      local scope = self:history_scope(state.path_args, log_options)
      pushed_paths = scope.single_file and { scope.path } or nil
    else
      pushed_paths = state.path_args
    end

    if pushed_paths then
      state.pushed_set = self:fh_compute_pushed_set(pushed_paths)
      if state.pushed_set then
        state.pushed_paths_seen = {}
        for _, p in ipairs(pushed_paths) do
          state.pushed_paths_seen[p] = true
        end
      end

      if subj_hl == "merge_aware" then
        state.main_refs = self:_find_main_branch_refs()
        state.merged_set = self:fh_compute_merged_set(state.main_refs, pushed_paths)
        if state.merged_set then
          state.merged_paths_seen = {}
          for _, p in ipairs(pushed_paths) do
            state.merged_paths_seen[p] = true
          end
        end
      end
    end
  end

  logger:info(
    "[FileHistory] Updating with options:",
    vim.inspect(state.prepared_log_opts, { newline = " ", indent = "" })
  )

  ---@type AsyncListStream
  local in_stream

  if is_trace then
    in_stream = self:stream_line_trace_data(state)
  else
    in_stream = self:stream_fh_data(state)
  end

  ---@param shutdown? SignalConsumer
  out_stream:on_close(function(shutdown)
    if shutdown then
      in_stream:close(shutdown)
    end
  end)

  local last_wait = uv.hrtime()
  local interval = (1000 / 15) * 1E6

  for _, item in in_stream:iter() do
    ---@type JobStatus, GitAdapter.LogData?, string?
    local status, new_data, msg = unpack(item, 1, 3)

    -- Make sure to yield to the scheduler periodically to keep the editor
    -- responsive.
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

    -- Status is PROGRESS
    assert(new_data, "No data received from scheduler!")

    if not new_data.valid then
      -- Sometimes git fails to provide stat data for a commit. This seems to
      -- happen with commits that have a large number of changes. Merge commits
      -- will also often be missing status data depending on the value of
      -- `--diff-merges`. Attempt recovery here by retrying entries that have
      -- data deemed invalid.

      local err
      local rev_arg = new_data.right_hash
      local is_merge = new_data.merge_hash ~= nil

      if is_trace and is_merge then
        goto continue
      end

      logger:fmt_warn("Received malformed or insufficient data for '%s'! Retrying...", rev_arg)
      logger:debug(new_data)
      err, new_data = await(self:fh_retry_commit(rev_arg, state, {
        is_merge = is_merge,
        retry_count = not is_merge and 2,
        keep_diff = is_trace,
      }))

      if err then
        if err.name == "job_fail" then
          logger:error(err.msg)
          out_stream:push({ JobStatus.ERROR, nil, err.msg })
          out_stream:close()
          return
        elseif err.name == "bad_data" then
          logger:warn(err.msg)
          utils.warn(
            fmt(
              "Encountered malformed data while parsing commit '%s'!"
                .. " This commit will be missing from the displayed history."
                .. " Call :DiffviewRefresh to try again. See :DiffviewLog for details.",
              rev_arg:sub(1, 10)
            ),
            true
          )
          -- Skip commit
          goto continue
        end
      end
    end

    local commit = Commit({
      hash = new_data.right_hash,
      author = new_data.author,
      time = tonumber(new_data.time),
      time_offset = new_data.time_offset,
      rel_date = new_data.rel_date,
      ref_names = new_data.ref_names,
      reflog_selector = new_data.reflog_selector,
      subject = new_data.subject,
      diff = new_data.diff,
    })

    ---@type boolean, (LogEntry|string)?
    local ok, entry

    if is_trace then
      ok, entry = self:parse_fh_line_trace_data(new_data, commit, state)
    else
      ok, entry = self:parse_fh_data(new_data, commit, state)
    end

    -- Some commits might not have file data. In that case we simply ignore it,
    -- as the fh panel doesn't support such entries at the moment.
    if ok then
      out_stream:push({ JobStatus.PROGRESS, entry })
    end

    ::continue::
  end
end)

---@class GitAdapter.fh_retry_commit.Opt
---@field is_merge boolean
---@field retry_count integer
---@field keep_diff boolean

---@param self GitAdapter
---@param rev_arg string
---@param state GitAdapter.FHState
---@param opt GitAdapter.fh_retry_commit.Opt
---@param callback fun(err?: { name: string, msg: string }, data?: GitAdapter.LogData)
GitAdapter.fh_retry_commit = async.wrap(function(self, rev_arg, state, opt, callback)
  opt = opt or {}

  local job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "-P",
      "-c",
      "gc.auto=0",
      "-c",
      "core.quotePath=false",
      "show",
      "--no-show-signature",
      "--pretty=format:" .. GitAdapter.COMMIT_PRETTY_FMT,
      "--numstat",
      "--raw",
      "--diff-merges=" .. state.log_options.diff_merges,
      (state.single_file and state.log_options.follow) and "--follow" or nil,
      rev_arg,
      "--",
      state.old_path or state.path_args
    ),
    cwd = self.ctx.toplevel,
    fail_cond = Job.FAIL_COND.on_empty,
    log_opt = { label = "GitAdapter:fh_retry_commit()" },
  })

  local err, data

  for _ = 1, opt.retry_count or 1 do
    _, err = await(job:start())

    if not err and job.code == 0 then
      data = structure_fh_data(job.stdout, opt.keep_diff)
      if data.valid then
        break
      end
    end

    await(async.timeout(10))
  end

  if not data or not (job:is_success()) then
    callback({
      name = "job_fail",
      msg = table.concat(utils.vec_join(err, job.stderr), "\n"),
    })
    return
  end

  if not data.valid then
    callback({
      name = "bad_data",
      msg = fmt(
        "Malformed data or imbalance in stat data for commit '%s'! Raw data: \n%s",
        rev_arg,
        table.concat(job.stdout, "\n")
      ),
    })
    return
  end

  callback(nil, data)
end)

-- Example data:
--
-- om: old file mode
-- nm: new file mode
-- oo: old object hash
-- no: new object hash
-- s: status symbol
-- p: path relative to top-level
--
-- om      nm     oo         no         s  p
-- :100644 100644 cb1f4d26fb 5c05b8faf7 M  src/nvim/eval.c
-- :100644 000000 f21eb2c128 0000000000 D  test/old/testdir/test_python2.vim
-- :000000 100644 0000000000 2471670dc6 A  .github/workflows/issue-open-check.yml
-- :000000 000000 0000000000 0000000000 U file6
-- :100644 100644 f645fca5cb f645fca5cb R100       .github/scripts/unstale.js      .github/scripts/remove_response_label.js
-- :100644 100644 18279d160e 09a7cab0c6 R091       scripts/genvimvim.lua   src/nvim/generators/gen_vimvim.lua
-- :100644 100644 000abcd123 0001234567 C68 file1 file2
--
-- There's also an extended format for combined diff merge commits where we get
-- the file mode and object hash for all parents as well as the resulting
-- commit. Here the number of colons in the prefix determines the number of
-- parents:
--
-- ::100644 100644 100644 d473044 d473044 af22f11 MM       lua/diffview/actions.lua
--
-- More info: `:Man git-diff | call search("RAW OUTPUT FORMAT")`
--
-- Numstat data:
--
-- 1       1       src/nvim/eval.c
-- 0       195     test/old/testdir/test_python2.vim
-- 34      0       .github/workflows/issue-open-check.yml
-- 0       0       .github/scripts/{unstale.js => remove_response_label.js}
-- 2       12      scripts/genvimvim.lua => src/nvim/generators/gen_vimvim.lua
-- -       -       .github/media/screenshot_1.png

---@param data GitAdapter.LogData
---@param commit GitCommit
---@param state GitAdapter.FHState
---@return boolean success
---@return LogEntry|string ret
function GitAdapter:parse_fh_data(data, commit, state)
  local files = {}
  local pin_local = state.layout_opt.pin_local == true

  for i = 1, #data.numstat do
    local entry = git_parser.parse_namestat_entry(data.namestat[i], data.numstat[i])

    if entry.oldname and state.single_file then
      state.old_path = entry.oldname
      -- `--follow` walks past this rename into commits that touched the file
      -- under its previous name. Those commits aren't in the initial pushed
      -- set (computed for the current path only), so extend the set now.
      self:fh_extend_pushed_set(state, entry.oldname)
      self:fh_extend_merged_set(state, entry.oldname)
    end

    local rev_a, rev_b
    if pin_local then
      -- pin_local diffs each commit against the working tree, so the a-side
      -- reads from this commit (not its parent) and the b-side from LOCAL.
      -- This matches the synthetic top-of-history "Working tree" entry
      -- (HEAD vs LOCAL) and the documented "diff each commit against your
      -- live file" behaviour.
      rev_a = GitRev(RevType.COMMIT, data.right_hash)
      rev_b = self.Rev(RevType.LOCAL)
    else
      rev_a = data.left_hash and GitRev(RevType.COMMIT, data.left_hash) or GitRev.new_null_tree()
      rev_b = state.prepared_log_opts.base or GitRev(RevType.COMMIT, data.right_hash)
    end

    table.insert(
      files,
      self:build_pin_local_file_entry({
        layout_class = state.layout_opt.default_layout or Diff2Hor,
        layout_opt = state.layout_opt,
        path = entry.name,
        -- In pin_local mode revs.a is the commit itself, so the parent's
        -- old name doesn't apply; entry.name lives in this commit's tree.
        oldpath = (not pin_local) and entry.oldname or nil,
        status = entry.status,
        stats = entry.stats,
        commit = commit,
        rev_a = rev_a,
        rev_b = rev_b,
        single_file = state.single_file,
      })
    )
  end

  -- `nil` signals "pushed set not computed" so LogEntry falls back to the
  -- decoration-based check; explicit `false` means "not in the computed set".
  local is_pushed
  if state.pushed_set then
    is_pushed = state.pushed_set[commit.hash] == true
  end
  -- `is_merged` has no decoration-based fallback, so we just pass `nil`
  -- when the set wasn't computed and let `LogEntry` default it to false.
  local is_merged
  if state.merged_set then
    is_merged = state.merged_set[commit.hash] == true
  end

  if files[1] then
    return true,
      LogEntry({
        path_args = state.path_args,
        commit = commit,
        files = files,
        single_file = state.single_file,
        is_pushed = is_pushed,
        is_merged = is_merged,
      })
  end

  if state.path_args[1] then
    -- If path args are provided we never want to show empty log entries.
    logger:warn("[GitAdapter:parse_fh_data()] Encountered commit with no file data:", data)
    return false, "Found no relevant file data with given path args!"
  end

  -- Commit is likely identical to it's parent. Return an empty log entry.
  return true,
    LogEntry.new_null_entry(self, {
      path_args = state.path_args,
      commit = commit,
      single_file = state.single_file,
      is_pushed = is_pushed,
      is_merged = is_merged,
    })
end

---@param data GitAdapter.LogData
---@param commit GitCommit
---@param state GitAdapter.FHState
---@return boolean success
---@return LogEntry|string ret
function GitAdapter:parse_fh_line_trace_data(data, commit, state)
  local files = {}
  local pin_local = state.layout_opt.pin_local == true

  for _, entry in ipairs(data.diff) do
    local oldpath = entry.path_old ~= entry.path_new and entry.path_old or nil

    if state.single_file and oldpath then
      state.old_path = oldpath
      -- Line-trace mode follows renames at the line level (without `--follow`)
      -- and so streams pre-rename commits too. The initial pushed set lacks
      -- those because it was queried with the current path only.
      self:fh_extend_pushed_set(state, oldpath)
      self:fh_extend_merged_set(state, oldpath)
    end

    local rev_a, rev_b
    if pin_local then
      -- See `parse_fh_data` for the rationale: pin_local diffs each commit
      -- against the working tree, so a-side reads from this commit.
      rev_a = GitRev(RevType.COMMIT, data.right_hash)
      rev_b = self.Rev(RevType.LOCAL)
    else
      rev_a = data.left_hash and GitRev(RevType.COMMIT, data.left_hash) or GitRev.new_null_tree()
      rev_b = state.prepared_log_opts.base or GitRev(RevType.COMMIT, data.right_hash)
    end

    -- Line-trace is single-file by construction, so the helper's
    -- `single_file = true` resolves the b-side cache key through
    -- `pinned_path` (the rename anchor) -- mirroring `parse_fh_data`.
    -- `entry.path_new` is typed `string?` upstream; the line-trace
    -- pipeline only emits entries with a real path, so casting here is
    -- safe.
    table.insert(
      files,
      self:build_pin_local_file_entry({
        layout_class = state.layout_opt.default_layout or Diff2Hor,
        layout_opt = state.layout_opt,
        path = entry.path_new --[[@as string ]],
        oldpath = (not pin_local) and oldpath or nil,
        commit = commit,
        rev_a = rev_a,
        rev_b = rev_b,
        single_file = true,
      })
    )
  end

  local is_pushed
  if state.pushed_set then
    is_pushed = state.pushed_set[commit.hash] == true
  end
  local is_merged
  if state.merged_set then
    is_merged = state.merged_set[commit.hash] == true
  end

  if files[1] then
    return true,
      LogEntry({
        path_args = state.path_args,
        commit = commit,
        files = files,
        single_file = state.single_file,
        is_pushed = is_pushed,
        is_merged = is_merged,
      })
  end

  logger:debug("[GitAdapter:parse_fh_data] Encountered commit with no file data:", data)

  return false, "Missing file data!"
end

---@override
---@param opt { path_args: string[], layout_opt: vcs.adapter.LayoutOpt, single_file: boolean }
---@return LogEntry?
function GitAdapter:build_local_log_entry(opt)
  local path_args = opt.path_args or {}
  local layout_opt = opt.layout_opt

  local head = self:head_rev()
  if not head then
    return nil
  end

  -- Mark this rev as the synthetic entry's a-side. The pinned layout's
  -- `should_null` inverts the standard semantics for the normal pin_local
  -- case (where revs.a is the commit being browsed, so `A` means present
  -- and `D` means absent on the a-side). Here revs.a is HEAD and the
  -- statuses come from `diff HEAD` (parent-perspective), so the standard
  -- `Diff2.should_null` applies; the flag tells the override to defer.
  head.pin_local_synthetic = true

  -- `--raw --numstat HEAD` mirrors the format `parse_fh_data` already
  -- consumes, so namestat parsing can reuse `git_parser.parse_namestat_entry`.
  -- `core.quotePath=false` matches the streamed file-history invocations so
  -- non-ASCII (or otherwise C-quotable) paths arrive as raw bytes here too;
  -- without it the synthetic entry's path would not match the pinned-path
  -- cache that's keyed on the streamed (unquoted) path.
  local args = utils.vec_join(
    { "-c", "core.quotePath=false", "diff", "--raw", "--numstat", "HEAD", "--" },
    path_args
  )
  local out, code = self:exec_sync(args, self.ctx.toplevel)
  if code ~= 0 or not out then
    return nil
  end

  local namestat, numstat = git_parser.structure_stat_data(out, 1)
  if #namestat == 0 then
    return nil
  end

  local user_out = self:exec_sync(
    { "config", "user.name" },
    { cwd = self.ctx.toplevel, silent = true }
  )
  local author = (user_out and user_out[1] and vim.trim(user_out[1])) or ""
  if author == "" then
    author = "Working tree"
  end

  -- `Commit` here is `GitCommit` (see the alias at the top of this file),
  -- whose `init` derives `iso_date` from `time` and defaults `time_offset`
  -- to 0. Both fields are required by `render.lua` when the panel's
  -- `date_format` is `iso` (and in the `auto` branch for older commits);
  -- a nil `iso_date` would abort the panel render, so we rely on the
  -- subclass init populating them rather than passing them explicitly.
  local commit = Commit({
    hash = nil,
    author = author,
    time = os.time(),
    rel_date = "now",
    subject = "Working tree",
    ref_names = nil,
  })

  local layout_class = layout_opt.default_layout or Diff2Hor
  local files = {}

  for i = 1, #namestat do
    local entry = git_parser.parse_namestat_entry(namestat[i], numstat[i] or "0\t0\t")

    -- Synthetic working-tree entry. `oldpath` IS retained: revs.a is HEAD
    -- (parent of the working tree), so the rename detected by
    -- `git diff HEAD` is meaningful for reading the file at HEAD.
    table.insert(
      files,
      self:build_pin_local_file_entry({
        layout_class = layout_class,
        layout_opt = layout_opt,
        path = entry.name,
        oldpath = entry.oldname,
        status = entry.status,
        stats = entry.stats,
        commit = commit,
        rev_a = head,
        rev_b = self.Rev(RevType.LOCAL),
        single_file = opt.single_file,
      })
    )
  end

  return LogEntry({
    path_args = path_args,
    commit = commit,
    files = files,
    -- Mirror the scope decision the caller already made via
    -- `history_scope`. Recomputing from `#path_args == 1` here would
    -- mismark single-arg multi-file pathspecs (e.g. `*.txt` matching
    -- multiple files) as single-file, which would force the whole
    -- panel into single-file mode because the synth is prepended.
    single_file = opt.single_file,
  })
end

---@param argo ArgObject
function GitAdapter:diffview_options(argo)
  local rev_arg = argo.args[1]

  local left, right = self:parse_revs(rev_arg, {
    cached = argo:get_flag({ "cached", "staged" }),
    imply_local = argo:get_flag("imply-local"),
    merge_base = argo:get_flag("merge-base"),
  })

  if not (left and right) then
    return
  end

  logger:fmt_debug("Parsed revs: left = %s, right = %s", left, right)

  ---@type DiffViewOptions
  local options = {
    show_untracked = arg_parser.ambiguous_bool(
      argo:get_flag({ "u", "untracked-files" }, { plain = true }),
      nil,
      { "all", "normal", "true" },
      { "no", "false" }
    ),
    selected_file = (
      argo:get_flag("selected-file", { no_empty = true, expand = true })
      or (vim.bo.buftype == "" and pl:vim_expand("%:p"))
      or nil
    ) --[[@as string? ]],
    selected_row = tonumber(argo:get_flag("selected-row", { no_empty = true })),
  }

  return { left = left, right = right, options = options }
end

---@return Rev?
function GitAdapter:head_rev()
  local out, code = self:exec_sync(
    { "rev-parse", "HEAD", "--" },
    { cwd = self.ctx.toplevel, retry = 2, fail_on_empty = true }
  )

  if code ~= 0 then
    return
  end

  local s = vim.trim(out[1]):gsub("^%^", "")

  return GitRev(RevType.COMMIT, s, true)
end

---Get the current branch name.
---@return string? branch_name The branch name, or nil if detached HEAD.
function GitAdapter:get_branch_name()
  local out, code = self:exec_sync(
    { "symbolic-ref", "--short", "HEAD" },
    { cwd = self.ctx.toplevel, silent = true }
  )

  if code == 0 and out[1] then
    return vim.trim(out[1])
  end

  return nil
end

---Get the default branch name (main, master, etc.).
---@return string? branch_name The default branch name.
function GitAdapter:get_default_branch()
  -- Try to get from origin/HEAD symbolic reference.
  local out, code = self:exec_sync(
    { "symbolic-ref", "refs/remotes/origin/HEAD" },
    { cwd = self.ctx.toplevel, silent = true }
  )

  if code == 0 and out[1] then
    local ref = vim.trim(out[1])
    -- Extract branch name from "refs/remotes/origin/main".
    local branch = ref:match("refs/remotes/origin/(.+)$")
    if branch then
      return branch
    end
  end

  -- Fall back to checking if main or master exist.
  for _, branch in ipairs({ "main", "master" }) do
    local _, code_check = self:exec_sync(
      { "rev-parse", "--verify", branch },
      { cwd = self.ctx.toplevel, silent = true }
    )
    if code_check == 0 then
      return branch
    end
  end

  return nil
end

---Get the remote URL for origin.
---@param remote? string The remote name (default: "origin").
---@return string? url The remote URL.
function GitAdapter:get_remote_url(remote)
  remote = remote or "origin"
  local out, code = self:exec_sync(
    { "remote", "get-url", remote },
    { cwd = self.ctx.toplevel, silent = true }
  )

  if code == 0 and out[1] then
    return vim.trim(out[1])
  end

  return nil
end

---Construct a web URL for viewing a commit in the browser.
---Supports GitHub, GitLab, and Bitbucket.
---@param commit_hash string The commit hash.
---@return string? url The web URL, or nil if the hosting service is not recognized.
function GitAdapter:get_commit_url(commit_hash)
  local remote_url = self:get_remote_url()
  if not remote_url then
    return nil
  end

  -- Normalize the URL to extract host and repo path.
  local host, repo

  -- Handle SSH URLs: git@github.com:user/repo.git
  local ssh_host, ssh_repo = remote_url:match("^git@([^:]+):(.+)$")
  if ssh_host and ssh_repo then
    host = ssh_host
    repo = ssh_repo
  else
    -- Handle HTTPS URLs: https://github.com/user/repo.git
    local https_host, https_repo = remote_url:match("^https?://([^/]+)/(.+)$")
    if https_host and https_repo then
      host = https_host
      repo = https_repo
    end
  end

  if not host or not repo then
    return nil
  end

  -- Remove .git suffix if present.
  repo = repo:gsub("%.git$", "")

  -- Construct URL based on hosting service.
  if host:match("github") then
    return fmt("https://%s/%s/commit/%s", host, repo, commit_hash)
  elseif host:match("gitlab") then
    return fmt("https://%s/%s/-/commit/%s", host, repo, commit_hash)
  elseif host:match("bitbucket") then
    return fmt("https://%s/%s/commits/%s", host, repo, commit_hash)
  else
    -- Generic format (works for many Git hosting services).
    return fmt("https://%s/%s/commit/%s", host, repo, commit_hash)
  end
end

---@param path string
---@param rev_arg string?
---@return string?
function GitAdapter:file_blob_hash(path, rev_arg)
  local out, code = self:exec_sync({
    "rev-parse",
    "--revs-only",
    fmt("%s:%s", rev_arg or "", path),
  }, {
    cwd = self.ctx.toplevel,
    retry = 2,
    fail_on_empty = true,
  })

  if code ~= 0 then
    return
  end

  return vim.trim(out[1])
end

---@param path string
---@param rev_arg string
---@return boolean
function GitAdapter:file_exists_at_rev(path, rev_arg)
  local blob = self:file_blob_hash(path, rev_arg)
  return blob ~= nil and blob ~= ""
end

---Parse two endpoint, commit revs from a symmetric difference notated rev arg.
---@param rev_arg string
---@return Rev? left The left rev.
---@return Rev? right The right rev.
function GitAdapter:symmetric_diff_revs(rev_arg)
  local r1 = rev_arg:match("(.+)%.%.%.") or "HEAD"
  local r2 = rev_arg:match("%.%.%.(.+)") or "HEAD"
  local out, code, stderr

  local function err()
    utils.err(utils.vec_join(fmt("Failed to parse rev '%s'!", rev_arg), "Git output: ", stderr))
  end

  out, code, stderr = self:exec_sync(
    { "merge-base", r1, r2 },
    { cwd = self.ctx.toplevel, fail_on_empty = true, retry = 2 }
  )
  if code ~= 0 then
    return err()
  end
  local left_hash = out[1]:gsub("^%^", "")

  out, code, stderr = self:exec_sync(
    { "rev-parse", "--revs-only", r2 },
    { cwd = self.ctx.toplevel, fail_on_empty = true, retry = 2 }
  )
  if code ~= 0 then
    return err()
  end
  local right_hash = out[1]:gsub("^%^", "")

  return GitRev(RevType.COMMIT, left_hash), GitRev(RevType.COMMIT, right_hash)
end

---Determine whether a rev arg is a range.
---@param rev_arg string
---@return boolean
function GitAdapter:is_rev_arg_range(rev_arg)
  return utils.str_match(rev_arg, {
    "^%.%.%.?$",
    "^%.%.%.?[^.]",
    "[^.]%.%.%.?$",
    "[^.]%.%.%.?[^.]",
    "^.-%^@",
    "^.-%^!",
    "^.-%^%-%d?",
  }) ~= nil
end

---Parse a given rev arg.
---@param rev_arg string?
---@param opt table
---@return Rev? left
---@return Rev? right
function GitAdapter:parse_revs(rev_arg, opt)
  ---@type Rev?
  local left
  ---@type Rev?
  local right

  local head = self:head_rev()
  ---@cast head Rev

  if not rev_arg then
    if opt.cached then
      left = head or GitRev.new_null_tree()
      right = GitRev(RevType.STAGE, 0)
    else
      left = GitRev(RevType.STAGE, 0)
      right = GitRev(RevType.LOCAL)
    end
  elseif rev_arg:match("%.%.%.") then
    left, right = self:symmetric_diff_revs(rev_arg)
    if not (left or right) then
      return
    elseif opt.imply_local then
      ---@cast left Rev
      ---@cast right Rev
      left, right = self:imply_local(left, right, head)
    end
  else
    local rev_strings, code, stderr = self:exec_sync(
      { "rev-parse", "--revs-only", rev_arg },
      { cwd = self.ctx.toplevel, fail_on_empty = true, retry = 2 }
    )
    if code ~= 0 then
      utils.err(
        utils.vec_join(
          fmt("Failed to parse rev %s!", utils.str_quote(rev_arg)),
          "Git output: ",
          stderr
        )
      )
      return
    elseif #rev_strings == 0 then
      utils.err("Bad revision: " .. utils.str_quote(rev_arg))
      return
    end

    local is_range = self:is_rev_arg_range(rev_arg)

    if is_range then
      local right_hash = rev_strings[1]:gsub("^%^", "")
      right = GitRev(RevType.COMMIT, right_hash)
      if #rev_strings > 1 then
        local left_hash = rev_strings[2]:gsub("^%^", "")
        left = GitRev(RevType.COMMIT, left_hash)
      else
        left = GitRev.new_null_tree()
      end

      if opt.imply_local then
        left, right = self:imply_local(left, right, head)
      end
    else
      local hash = rev_strings[1]:gsub("^%^", "")
      if opt.cached then
        left = GitRev(RevType.COMMIT, hash)
        right = GitRev(RevType.STAGE, 0)
      else
        -- When comparing a single ref with working tree, optionally use merge-base.
        if opt.merge_base then
          local merge_base_out, merge_base_code = self:exec_sync(
            { "merge-base", "HEAD", hash },
            { cwd = self.ctx.toplevel, fail_on_empty = true, retry = 2 }
          )
          if merge_base_code == 0 and #merge_base_out > 0 then
            left = GitRev(RevType.COMMIT, merge_base_out[1])
          else
            -- Fallback to the ref itself if merge-base fails.
            left = GitRev(RevType.COMMIT, hash)
          end
        else
          left = GitRev(RevType.COMMIT, hash)
        end
        right = GitRev(RevType.LOCAL)
      end
    end
  end

  return left, right
end

---@param left Rev
---@param right Rev
---@param head Rev
---@return Rev, Rev
function GitAdapter:imply_local(left, right, head)
  -- Special case when they both point to head: change only the right side in
  -- order to still get a meaningful rev range.
  if left.commit == head.commit and right.commit == head.commit then
    return left, GitRev(RevType.LOCAL)
  end

  if left.commit == head.commit then
    left = GitRev(RevType.LOCAL)
  end
  if right.commit == head.commit then
    right = GitRev(RevType.LOCAL)
  end

  return left, right
end

---Convert revs to git rev args.
---@param left Rev
---@param right Rev
---@return string[]
function GitAdapter:rev_to_args(left, right)
  assert(
    not (left.type == RevType.LOCAL and right.type == RevType.LOCAL),
    "InvalidArgument :: Can't diff LOCAL against LOCAL!"
  )

  if left.type == RevType.COMMIT and right.type == RevType.COMMIT then
    return { left.commit .. ".." .. right.commit }
  elseif left.type == RevType.COMMIT and right.type == RevType.STAGE then
    return { "--cached", left.commit }
  elseif right.type == RevType.LOCAL then
    if left.type == RevType.STAGE then
      return {}
    elseif left.type == RevType.COMMIT then
      return { left.commit }
    end
  elseif left.type == RevType.LOCAL then
    -- WARN: these require special handling when creating the diff file list.
    -- I.e. the stats for 'additions' and 'deletions' need to be swapped.
    if right.type == RevType.STAGE then
      return { "--cached" }
    elseif right.type == RevType.COMMIT then
      return { right.commit }
    end
  end

  error(fmt("InvalidArgument :: Unsupported rev range: '%s..%s'!", left, right))
end

---@param self GitAdapter
---@param path string
---@param kind vcs.FileKind
---@param commit string?
---@param callback fun(ok: boolean, undo?: string)
GitAdapter.file_restore = async.wrap(function(self, path, kind, commit, callback)
  local out, code
  local abs_path = pl:join(self.ctx.toplevel, path)
  local rel_path = pl:vim_fnamemodify(abs_path, ":~")

  -- Check if file exists in history
  _, code = self:exec_sync(
    { "cat-file", "-e", fmt("%s:%s", commit or (kind == "staged" and "HEAD") or "", path) },
    self.ctx.toplevel
  )
  local exists_git = code == 0
  local exists_local = pl:readable(abs_path)

  if exists_local then
    -- Write file blob into db
    out, code = self:exec_sync({ "hash-object", "-w", "--", path }, self.ctx.toplevel)
    if code ~= 0 then
      utils.err(
        "Failed to write file blob into the object database. Aborting file restoration.",
        true
      )
      callback(false)
      return
    end
  end

  local undo
  if exists_local then
    undo = fmt(":sp %s | %%!git show %s", vim.fn.fnameescape(rel_path), out[1]:sub(1, 11))
  else
    undo = fmt(":!git rm %s", vim.fn.fnameescape(path))
  end

  -- Revert file
  if not exists_git then
    local bn = utils.find_file_buffer(abs_path)
    if bn then
      await(async.scheduler())
      local ok, err = utils.remove_buffer(false, bn)
      if not ok then
        utils.err({
          fmt("Failed to delete buffer '%d'! Aborting file restoration. Error message:", bn),
          err,
        }, true)
        callback(false)
        return
      end
    end

    if kind == "working" or kind == "conflicting" then
      -- File is untracked and has no history: delete it from fs.
      local ok, err = pawait(pl.unlink, pl, abs_path)
      if not ok then
        utils.err({
          fmt("Failed to delete file '%s'! Aborting file restoration. Error message:", abs_path),
          err,
        }, true)
        callback(false)
        return
      end
    else
      -- File only exists in index
      out, code = self:exec_sync({ "rm", "-f", "--", path }, self.ctx.toplevel)
    end
  else
    -- File exists in history: checkout
    out, code = self:exec_sync(
      utils.vec_join("checkout", commit or (kind == "staged" and "HEAD" or nil), "--", path),
      self.ctx.toplevel
    )

    await(async.scheduler())
    local bn = utils.find_file_buffer(abs_path)
    if bn then
      vim.cmd(fmt("checktime %d", bn))
    end
  end

  callback(true, undo)
end)

---@param file vcs.File
function GitAdapter:stage_index_file(file)
  local out, code, err
  local temp = vim.fn.tempname()

  local ok, ret = pcall(function()
    api.nvim_exec_autocmds("BufWritePre", {
      pattern = api.nvim_buf_get_name(file.bufnr),
    })

    vim.cmd("silent noautocmd keepalt '[,']write " .. temp)

    out, code = self:exec_sync(
      { "--literal-pathspecs", "hash-object", "-w", "--", pl:convert(temp) },
      self.ctx.toplevel
    )

    if code ~= 0 then
      utils.err("Failed to write file blob into the object database. Aborting.")
      return false
    end

    local blob_hash = out[1]

    out, code = self:exec_sync(
      { "-c", "core.quotePath=false", "ls-files", "--stage", file.path },
      self.ctx.toplevel
    )
    local old_mode = out[1]:match("^(%d+)")

    if not old_mode then
      old_mode = vim.fn.executable(file.absolute_path) == 1 and "100755" or "100644"
    end

    out, code, err = self:exec_sync({ "update-index", "--index-info" }, {
      cwd = self.ctx.toplevel,
      writer = fmt("%s %s %d\t%s", old_mode, blob_hash, file.rev.stage, file.path),
    })

    if code ~= 0 then
      utils.err(utils.vec_join("Failed to update index!", err))
      return false
    end

    file.blob_hash = blob_hash
    vim.bo[file.bufnr].modified = false
    api.nvim_exec_autocmds("BufWritePost", {
      pattern = api.nvim_buf_get_name(file.bufnr),
    })
  end)

  vim.fn.delete(temp)
  if not ok then
    error(ret)
  end

  return ret
end

function GitAdapter:reset_files(paths)
  local _, code = self:exec_sync(utils.vec_join("reset", "--", paths), self.ctx.toplevel)
  return code == 0
end

function GitAdapter:add_files(paths)
  local _, code = self:exec_sync(utils.vec_join("add", "--", paths), self.ctx.toplevel)
  return code == 0
end

---Check whether untracked files should be listed.
---@param opt? VCSAdapter.show_untracked.Opt
---@return boolean
function GitAdapter:show_untracked(opt)
  opt = opt or {}

  if opt.revs then
    -- Show untracked files only when comparing index (STAGE) vs working tree (LOCAL).
    -- Don't show untracked when comparing a commit to working tree.
    if not (opt.revs.left.type == RevType.STAGE and opt.revs.right.type == RevType.LOCAL) then
      return false
    end
  end

  -- Check the user provided flag options
  if opt.dv_opt then
    if type(opt.dv_opt.show_untracked) == "boolean" and not opt.dv_opt.show_untracked then
      return false
    end
  end

  -- Fall back to checking git config
  local out = self:exec_sync(
    { "config", "status.showUntrackedFiles" },
    { cwd = self.ctx.toplevel, silent = true }
  )

  return vim.trim(out[1] or "") ~= "no"
end

GitAdapter.tracked_files = async.wrap(function(self, left, right, args, kind, opt, callback)
  ---@type FileEntry[]
  local files = {}
  ---@type FileEntry[]
  local conflicts = {}
  local log_opt = { label = "GitAdapter:tracked_files()" }
  local rename_threshold = config.get_config().rename_threshold
  local rename_flag = rename_threshold and ("-M" .. rename_threshold .. "%") or nil

  local namestat_job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "diff",
      "-z",
      rename_flag,
      "--ignore-submodules",
      "--name-status",
      args
    ),
    cwd = self.ctx.toplevel,
    log_opt = log_opt,
  })
  local numstat_job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "diff",
      "-z",
      rename_flag,
      "--ignore-submodules",
      "--numstat",
      args
    ),
    cwd = self.ctx.toplevel,
    log_opt = log_opt,
  })

  local max_attempts = 3
  local namestat_entries
  local numstat_entries
  local numstat_count

  for attempt = 1, max_attempts do
    local multi_job = MultiJob({ namestat_job, numstat_job }, { retry = 2 })

    local ok, err = await(multi_job)

    if not ok then
      callback(utils.vec_join(err, namestat_job.stderr, numstat_job.stderr), nil)
      return
    end

    -- Both jobs use `-z` for NUL-delimited output, which is safe for
    -- filenames containing tabs or newlines.  Reassemble stdout into a
    -- single string and split on NUL.
    local namestat_fields =
      vim.split(table.concat(namestat_job.stdout, "\n"), "\0", { plain = true })
    local numstat_fields = vim.split(table.concat(numstat_job.stdout, "\n"), "\0", { plain = true })

    -- Parse NUL-delimited --name-status: status\0name[\0oldname]\0...
    namestat_entries = {}
    local ni = 1
    while ni <= #namestat_fields do
      local field = namestat_fields[ni]
      if field == "" then
        ni = ni + 1
      else
        local status = field:sub(1, 1):gsub("%s", " ")
        local name = namestat_fields[ni + 1]
        local oldname

        if status == "R" or status == "C" then
          -- Renames and copies have an extra field: old\0new.
          oldname = name
          name = namestat_fields[ni + 2]
          ni = ni + 3
        else
          ni = ni + 2
        end

        table.insert(namestat_entries, { status = status, name = name, oldname = oldname })
      end
    end

    -- Parse NUL-delimited --numstat output.
    -- Non-rename: "add\tdel\tpath\0" -> after split: "add\tdel\tpath"
    -- Rename:     "add\tdel\t\0old\0new\0" -> after split: "add\tdel\t", "old", "new"
    numstat_entries = {}
    numstat_count = 0
    local si = 1
    while si <= #numstat_fields do
      local field = numstat_fields[si]
      if field == "" then
        si = si + 1
      else
        local add_s, del_s, path = field:match("^([%d-]+)\t([%d-]+)\t(.*)")
        if not add_s then
          -- Malformed record; skip.
          si = si + 1
        else
          local additions = tonumber(add_s)
          local deletions = tonumber(del_s)

          if path == "" then
            -- Rename: the old and new paths follow as separate NUL fields.
            si = si + 3
          else
            si = si + 1
          end

          -- Binary files have `-` for both additions and deletions, so
          -- tonumber returns nil.  Use explicit indexing because
          -- table.insert(t, nil) is a no-op in Lua.
          numstat_count = numstat_count + 1
          numstat_entries[numstat_count] = (additions and deletions)
              and { additions = additions, deletions = deletions }
            or nil
        end
      end
    end

    if #namestat_entries == numstat_count then
      break
    end

    -- Imbalance detected; retry unless we have exhausted all attempts.
    if attempt == max_attempts then
      local msg = (
        "Imbalance in diff data: name-status has %d entries, numstat has %d. "
        .. "This may indicate malformed or truncated git output and can be intermittent. "
        .. "kind=%s"
      ):format(#namestat_entries, numstat_count, tostring(kind))
      callback({ msg }, nil)
      return
    end
  end

  local data = {}
  local conflict_map = {}

  for i, entry in ipairs(namestat_entries) do
    local stats = numstat_entries[i]

    if not (entry.status == "U" and kind == "staged") then
      table.insert(data, {
        status = entry.status,
        name = entry.name,
        oldname = entry.oldname,
        stats = stats,
      })
    end

    if entry.status == "U" then
      conflict_map[entry.name] = data[#data]
    end
  end

  if kind == "working" and next(conflict_map) then
    data = vim.tbl_filter(function(v)
      return not conflict_map[v.name]
    end, data)

    for _, v in pairs(conflict_map) do
      table.insert(
        conflicts,
        FileEntry.with_layout(opt.merge_layout, {
          adapter = self,
          path = v.name,
          oldpath = v.oldname,
          status = "U",
          kind = "conflicting",
          revs = {
            a = self.Rev(RevType.STAGE, 2), -- ours
            b = self.Rev(RevType.LOCAL), -- local
            c = self.Rev(RevType.STAGE, 3), -- theirs
            d = self.Rev(RevType.STAGE, 1), -- base
          },
        })
      )
    end
  end

  for _, v in ipairs(data) do
    local file = FileEntry.with_layout(opt.default_layout, {
      adapter = self,
      path = v.name,
      oldpath = v.oldname,
      status = v.status,
      stats = v.stats,
      kind = kind,
      revs = {
        a = left,
        b = right,
      },
    })

    if left and left.type == RevType.LOCAL and file.stats then
      -- Special handling is required here. The rev range `LOCAL..{REV}` can't be
      -- expressed in Git's rev syntax, but logically it should be the same as
      -- just `{REV}`, but with the diff stats swapped (as we want the diff from
      -- the perspective of LOCAL).
      file.stats.additions, file.stats.deletions = file.stats.deletions, file.stats.additions
    end

    table.insert(files, file)
  end

  callback(nil, files, conflicts)
end)

GitAdapter.untracked_files = async.wrap(function(self, left, right, opt, callback)
  local job = Job({
    command = self:bin(),
    args = utils.vec_join(
      self:args(),
      "-c",
      "core.quotePath=false",
      "ls-files",
      "--others",
      "--exclude-standard"
    ),
    cwd = self.ctx.toplevel,
    log_opt = { label = "GitAdapter:untracked_files()" },
  })

  local ok = await(job)

  if not ok then
    callback(job.stderr or {}, nil)
    return
  end

  local files = {}
  for _, s in ipairs(job.stdout) do
    table.insert(
      files,
      FileEntry.with_layout(opt.default_layout, {
        adapter = self,
        path = s,
        status = "?",
        kind = "working",
        revs = {
          a = left,
          b = right,
        },
      })
    )
  end

  callback(nil, files)
end)

---Convert revs to string representation.
---@param left Rev
---@param right Rev
---@return string|nil
function GitAdapter:rev_to_pretty_string(left, right)
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
function GitAdapter:has_local(left, right)
  return left.type == RevType.LOCAL or right.type == RevType.LOCAL
end

---Strange trick to check if a file is binary using only git.
---@param path string
---@param rev Rev
---@return boolean -- True if the file was binary for the given rev, or it didn't exist.
function GitAdapter:is_binary(path, rev)
  if rev.type == RevType.STAGE and rev.stage > 0 then
    return false
  end

  local cmd = {
    "-c",
    "submodule.recurse=false",
    "-c",
    "core.quotePath=false",
    "grep",
    "-I",
    "--name-only",
    "-e",
    ".",
  }
  if rev.type == RevType.LOCAL then
    cmd[#cmd + 1] = "--untracked"
    cmd[#cmd + 1] = "--no-exclude-standard"
  elseif rev.type == RevType.STAGE then
    cmd[#cmd + 1] = "--cached"
  else
    cmd[#cmd + 1] = rev.commit
  end

  utils.vec_push(cmd, "--", path)

  local _, code = self:exec_sync(cmd, { cwd = self.ctx.toplevel, silent = true })
  return code ~= 0
end

GitAdapter.flags = {
  ---@type FlagOption[]
  switches = {
    FlagOption("-f", "--follow", "Follow renames (only for single file)"),
    FlagOption("-p", "--first-parent", "Follow only the first parent upon seeing a merge commit"),
    FlagOption(
      "-s",
      "--show-pulls",
      "Show merge commits the first introduced a change to a branch"
    ),
    FlagOption("-R", "--reflog", "Include all reachable objects mentioned by reflogs"),
    FlagOption("-g", "--walk-reflogs", "Walk reflogs instead of the commit ancestry chain"),
    FlagOption("-a", "--all", "Include all refs"),
    FlagOption("-m", "--merges", "List only merge commits"),
    FlagOption("-n", "--no-merges", "List no merge commits"),
    FlagOption("-r", "--reverse", "List commits in reverse order"),
    FlagOption("-cp", "--cherry-pick", "Omit commits that introduce the same change as another"),
    FlagOption("-lo", "--left-only", "List only the commits on the left side of a symmetric diff"),
    FlagOption(
      "-ro",
      "--right-only",
      "List only the commits on the right side of a symmetric diff"
    ),
  },
  ---@type FlagOption[]
  options = {
    FlagOption("=r", "++rev-range=", "Show only commits in the specified revision range", {
      ---@param panel FHOptionPanel
      completion = function(panel)
        local view = panel.parent.parent

        ---@param ctx CmdLineContext
        return function(ctx)
          return view.adapter:rev_candidates(ctx.arg_lead, { accept_range = true })
        end
      end,
    }),
    FlagOption("=b", "++base=", "Set the base revision", {
      ---@param panel FHOptionPanel
      completion = function(panel)
        local view = panel.parent.parent

        ---@param ctx CmdLineContext
        return function(ctx)
          return utils.vec_join("LOCAL", view.adapter:rev_candidates(ctx.arg_lead))
        end
      end,
    }),
    FlagOption("=n", "--max-count=", "Limit the number of commits"),
    FlagOption("=L", "-L", "Trace line evolution", {
      expect_list = true,
      prompt_label = "(Accepts multiple values)",
      -- prompt_fmt = "${label} ",
      completion = function(_)
        ---@param ctx CmdLineContext
        return function(ctx)
          return GitAdapter.line_trace_candidates(ctx.arg_lead)
        end
      end,
    }),
    FlagOption("=d", "--diff-merges=", "Determines how merge commits are treated", {
      select = {
        "",
        "off",
        "on",
        "first-parent",
        "separate",
        "combined",
        "dense-combined",
        "remerge",
      },
    }),
    FlagOption("=a", "--author=", "List only commits from a given author", {
      prompt_label = "(Extended regular expression)",
    }),
    FlagOption("=g", "--grep=", "Filter commit messages", {
      prompt_label = "(Extended regular expression)",
    }),
    FlagOption("=G", "-G", "Search changes", {
      prompt_label = "(Extended regular expression)",
    }),
    FlagOption("=S", "-S", "Search occurrences", {
      prompt_label = "(Extended regular expression)",
    }),
    FlagOption("=A", "--after=", "List only commits after a certain date", {
      prompt_label = "(YYYY-mm-dd, YYYY-mm-dd HH:mm:ss)",
    }),
    FlagOption("=B", "--before=", "List only commits before a certain date", {
      prompt_label = "(YYYY-mm-dd, YYYY-mm-dd HH:mm:ss)",
    }),
    FlagOption("--", "--", "Limit to files", {
      key = "path_args",
      expect_list = true,
      prompt_label = "(Path arguments)",
      prompt_fmt = "${label}${flag_name} ",
      value_fmt = "${value}",
      display_fmt = "${flag_name} ${values}",
      ---@param panel FHOptionPanel
      completion = function(panel)
        local view = panel.parent.parent

        ---@param ctx CmdLineContext
        return function(ctx)
          return view.adapter:path_candidates(ctx.arg_lead)
        end
      end,
    }),
  },
}

-- Add reverse lookups
for _, list in pairs(GitAdapter.flags) do
  for i, option in ipairs(list) do
    list[i] = option
    list[option.key] = option
  end
end

-- Completion

function GitAdapter:path_candidates(arg_lead)
  local magic, pattern = GitAdapter.pathspec_split(arg_lead)

  return vim.tbl_map(function(v)
    return magic .. v
  end, vim.fn.getcompletion(pattern, "file", false))
end

---Get completion candidates for git revisions.
---@param arg_lead string
---@param opt? RevCompletionSpec
function GitAdapter:rev_candidates(arg_lead, opt)
  opt = vim.tbl_extend("keep", opt or {}, { accept_range = false }) --[[@as RevCompletionSpec ]]
  logger:lvl(1):debug("[completion] Revision candidates requested.")

  -- stylua: ignore start
  local targets = {
    "HEAD", "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD",
    "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"
  }
  -- stylua: ignore end

  local heads = vim.tbl_filter(
    function(name)
      return vim.tbl_contains(targets, name)
    end,
    vim.tbl_map(function(v)
      return pl:basename(v)
    end, vim.fn.glob(self.ctx.dir .. "/*", false, true))
  )
  local revs = self:exec_sync(
    { "rev-parse", "--symbolic", "--branches", "--tags", "--remotes" },
    { cwd = self.ctx.toplevel, silent = true }
  )
  local stashes = self:exec_sync(
    { "stash", "list", "--pretty=format:%gd" },
    { cwd = self.ctx.toplevel, silent = true }
  )

  local ret = utils.vec_join(heads, revs, stashes)

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

---Completion for the git-log `-L` flag.
---@param arg_lead string
---@return string[]?
function GitAdapter.line_trace_candidates(arg_lead)
  local range_end = arg_lead:match(".*:()")

  if not range_end then
    return
  else
    local lead = arg_lead:sub(1, range_end - 1)
    local path_lead = arg_lead:sub(range_end)

    return vim.tbl_map(function(v)
      return lead .. v
    end, vim.fn.getcompletion(path_lead, "file"))
  end
end

function GitAdapter:init_completion()
  self.comp.open:put({ "u", "untracked-files" }, { "true", "normal", "all", "false", "no" })
  self.comp.open:put({ "cached", "staged" })
  self.comp.open:put({ "imply-local" })
  self.comp.open:put({ "merge-base" })
  self.comp.open:put({ "C" }, function(_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "dir")
  end)
  self.comp.open:put({ "selected-file" }, function(_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "file")
  end)
  self.comp.open:put({ "selected-row" })

  self.comp.file_history:put({ "base" }, function(_, arg_lead)
    return utils.vec_join("LOCAL", self:rev_candidates(arg_lead))
  end)
  self.comp.file_history:put({ "range" }, function(_, arg_lead)
    return self:rev_candidates(arg_lead, { accept_range = true })
  end)
  self.comp.file_history:put({ "C" }, function(_, arg_lead)
    return vim.fn.getcompletion(arg_lead, "dir")
  end)
  self.comp.file_history:put({ "--follow" })
  self.comp.file_history:put({ "--pin-local" })
  self.comp.file_history:put({ "--first-parent" })
  self.comp.file_history:put({ "--show-pulls" })
  self.comp.file_history:put({ "--reflog" })
  self.comp.file_history:put({ "--walk-reflogs", "-g" })
  self.comp.file_history:put({ "--all" })
  self.comp.file_history:put({ "--merges" })
  self.comp.file_history:put({ "--no-merges" })
  self.comp.file_history:put({ "--reverse" })
  self.comp.file_history:put({ "--cherry-pick" })
  self.comp.file_history:put({ "--left-only" })
  self.comp.file_history:put({ "--right-only" })
  self.comp.file_history:put({ "--max-count", "-n" }, {})
  self.comp.file_history:put({ "-L" }, function(_, arg_lead)
    return GitAdapter.line_trace_candidates(arg_lead)
  end)
  self.comp.file_history:put({ "--diff-merges" }, {
    "off",
    "on",
    "first-parent",
    "separate",
    "combined",
    "dense-combined",
    "remerge",
  })
  self.comp.file_history:put({ "--author" }, {})
  self.comp.file_history:put({ "--grep" }, {})
  self.comp.file_history:put({ "-G" }, {})
  self.comp.file_history:put({ "-S" }, {})
  self.comp.file_history:put({ "--after", "--since" }, {})
  self.comp.file_history:put({ "--before", "--until" }, {})
end

M.GitAdapter = GitAdapter
return M
