local Job = require("diffview.job").Job
local async = require("diffview.async")
local lazy = require("diffview.lazy")
local utils = require("diffview.utils")
local vcs_utils = require("diffview.vcs.utils")

local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule

local await = async.await
local fmt = string.format
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

local M = {}

---Maximum pointer `size` (bytes) the module will smudge in-process.
---Smudging pulls the full LFS object into memory and feeds it to
---`vim.diff`, which blocks nvim's main thread; a multi-GB object would
---freeze or OOM the editor. Oversized pointers fall back to the raw
---pointer bytes with a warning.
M.MAX_SMUDGE_BYTES = 2 * 1024 * 1024

---Extract the `size` field (in bytes) from a git-LFS pointer. Returns nil
---when the pointer is malformed or has no size line.
---@param pointer string[]
---@return integer?
function M.parse_size(pointer)
  if type(pointer) ~= "table" then
    return nil
  end
  for _, line in ipairs(pointer) do
    local sz = line:match("^size (%d+)$")
    if sz then
      return tonumber(sz)
    end
  end
  return nil
end

---Does `pointer` declare a `size` above `M.MAX_SMUDGE_BYTES`? Pointers
---without a parseable size are treated as safe: we have no positive
---evidence they are oversized, and a bogus pointer that fails smudge
---surfaces separately via the "error" status.
---@param pointer string[]
---@return boolean
local function pointer_too_large(pointer)
  if M.MAX_SMUDGE_BYTES <= 0 then
    return false
  end
  local sz = M.parse_size(pointer)
  return sz ~= nil and sz > M.MAX_SMUDGE_BYTES
end

---Does `lines` look like a git LFS pointer file? Deliberately
---under-specified (version header plus an `oid sha256:` line) to stay
---cheap and avoid false positives on real content.
---@param lines string[]?
---@return boolean
function M.is_pointer(lines)
  if type(lines) ~= "table" then
    return false
  end
  local n = #lines
  if n < 2 or n > 10 then
    return false
  end
  if not lines[1]:match("^version https://git%-lfs%.github%.com/spec/v%d+$") then
    return false
  end
  for i = 2, n do
    if lines[i]:match("^oid sha256:%x+$") then
      return true
    end
  end
  return false
end

---Pipe `pointer` through `git lfs smudge -- <path>` and return the smudged
---content as a list of lines. On failure (`git-lfs` missing, filter error,
---etc.), `err` is populated and `stdout` is nil; callers typically fall
---back to the pointer bytes unchanged.
---@param adapter GitAdapter
---@param path string
---@param pointer string[]
---@param callback fun(stderr: string[]?, stdout: string[]?)
M.smudge = async.wrap(function(adapter, path, pointer, callback)
  local job
  job = Job({
    command = adapter:bin(),
    args = utils.vec_join(adapter:args(), "lfs", "smudge", "--", path),
    cwd = adapter.ctx.toplevel,
    -- `GIT_LFS_SKIP_SMUDGE=1` in nvim's environment turns `git lfs smudge`
    -- into a pointer passthrough, which leaves the UI showing pointer
    -- bytes even though the user explicitly asked to smudge. Override it
    -- for this call while preserving the rest of the environment.
    env = vim.tbl_extend("force", vim.uv.os_environ(), { GIT_LFS_SKIP_SMUDGE = "0" }),
    writer = pointer,
    fail_cond = Job.FAIL_COND.non_zero,
    log_opt = { label = "git.lfs.smudge()" },
    -- `on_exit` fires in libuv's fast event context; `async.void` hops
    -- onto nvim's scheduler so any downstream API call doesn't raise
    -- `E5560`.
    on_exit = async.void(function(_, ok)
      if not ok or job.code ~= 0 then
        local stderr = job.stderr or {}
        callback({
          fmt(
            "`git lfs smudge` failed for %s (code=%s): %s",
            path,
            tostring(job.code),
            table.concat(stderr, "\n")
          ),
        }, nil)
        return
      end
      callback(nil, job.stdout)
    end),
  })
  await(vcs_utils.queue_sync_job(job))
end)

---Generate the LFS pointer for the working-tree bytes at `abs_path`.
---Uses `git lfs pointer --file=<abs>`, which streams through the file
---to compute the SHA256 without buffering it in memory, so this is
---cheap even for multi-GB LFS objects. The command prefixes its output
---with a `Git LFS pointer for <abs>` header and a blank line; strip
---everything up to and including that blank line.
---
---Pairing the LOCAL side with a working-tree pointer (rather than the
---staged `:<path>` blob) keeps unstaged edits visible as a pointer-level
---diff and handles LFS files that are not yet in the index at all.
---@param adapter GitAdapter
---@param abs_path string
---@param callback fun(stderr: string[]?, stdout: string[]?)
M.working_tree_pointer = async.wrap(function(adapter, abs_path, callback)
  local job
  job = Job({
    command = adapter:bin(),
    args = utils.vec_join(adapter:args(), "lfs", "pointer", "--file=" .. abs_path),
    cwd = adapter.ctx.toplevel,
    fail_cond = Job.FAIL_COND.non_zero,
    log_opt = { label = "git.lfs.working_tree_pointer()" },
    on_exit = async.void(function(_, ok)
      if not ok or job.code ~= 0 then
        callback(job.stderr or { "git lfs pointer failed" }, nil)
        return
      end
      local out = job.stdout
      for i, line in ipairs(out) do
        if line == "" then
          callback(nil, utils.vec_slice(out, i + 1))
          return
        end
      end
      -- No header found: treat the whole output as the pointer.
      callback(nil, out)
    end),
  })
  await(vcs_utils.queue_sync_job(job))
end)

---Return the subset of `paths` whose `filter` attribute is `lfs` according
---to the index's `.gitattributes` (`--cached`). On error, returns an empty
---table; callers degrade to the raw `--numstat` values rather than failing.
---@param adapter GitAdapter
---@param paths string[]
---@param callback fun(lfs_set: table<string, true>)
M.filter_lfs_paths = async.wrap(function(adapter, paths, callback)
  if #paths == 0 then
    callback({})
    return
  end
  local job
  job = Job({
    command = adapter:bin(),
    args = utils.vec_join(adapter:args(), "check-attr", "--cached", "-z", "filter", "--", paths),
    cwd = adapter.ctx.toplevel,
    fail_cond = Job.FAIL_COND.non_zero,
    log_opt = { label = "git.lfs.filter_lfs_paths()" },
    on_exit = async.void(function(_, ok)
      if not ok then
        callback({})
        return
      end
      -- `-z` output is NUL-separated with no newlines; join with "" to
      -- stitch across any chunk boundaries without introducing stray \n.
      local data = table.concat(job.stdout, "")
      local fields = vim.split(data, "\0", { plain = true })
      local out = {}
      -- Records are three fields: path, attr, value.
      for i = 1, #fields - 2, 3 do
        if fields[i + 1] == "filter" and fields[i + 2] == "lfs" then
          out[fields[i]] = true
        end
      end
      callback(out)
    end),
  })
  await(vcs_utils.queue_sync_job(job))
end)

---Single-path LFS tracking check wrapping `filter_lfs_paths`.
---@param adapter GitAdapter
---@param path string
---@param callback fun(tracked: boolean)
M.is_tracked = async.wrap(function(adapter, path, callback)
  local set = await(M.filter_lfs_paths(adapter, { path }))
  callback(set[path] == true)
end)

---Session cache for `is_tracked`, keyed by `(toplevel, path)`. Fills once
---per path per nvim session; invalidation is coarse (quit nvim) because
---`.gitattributes` rarely changes mid-session.
---@type table<string, table<string, boolean>>
M._tracked_cache = {}

---Cached variant of `is_tracked`. Skips the `git check-attr` subprocess
---when the same `(toplevel, path)` was resolved earlier in the session.
---@param adapter GitAdapter
---@param path string
---@param callback fun(tracked: boolean)
M.cached_is_tracked = async.wrap(function(adapter, path, callback)
  local toplevel = adapter.ctx.toplevel
  local by_path = M._tracked_cache[toplevel]
  if by_path and by_path[path] ~= nil then
    callback(by_path[path])
    return
  end
  local tracked = await(M.is_tracked(adapter, path))
  by_path = M._tracked_cache[toplevel] or {}
  by_path[path] = tracked
  M._tracked_cache[toplevel] = by_path
  callback(tracked)
end)

---@alias git.lfs.FetchStatus "ok"|"absent"|"error"|"too-large"

---Return the byte size of the blob at `rev:path` via `git cat-file -s`,
---which does not buffer the object, so it is cheap even for multi-GB
---blobs. Returns nil on lookup failure (object missing, bad rev, etc.);
---callers degrade to the existing error paths rather than failing.
---@param adapter GitAdapter
---@param path string
---@param rev Rev
---@param callback fun(size: integer?)
local blob_size = async.wrap(function(adapter, path, rev, callback)
  local spec = fmt("%s:%s", rev:object_name() or "", path)
  local job
  job = Job({
    command = adapter:bin(),
    args = utils.vec_join(adapter:args(), "cat-file", "-s", spec),
    cwd = adapter.ctx.toplevel,
    fail_cond = Job.FAIL_COND.non_zero,
    log_opt = { label = "git.lfs.blob_size()" },
    on_exit = async.void(function(_, ok)
      if not ok or job.code ~= 0 then
        callback(nil)
        return
      end
      local line = (job.stdout or {})[1]
      callback(line and tonumber(line) or nil)
    end),
  })
  await(vcs_utils.queue_sync_job(job))
end)

---`git show` stderr lines that mean "path doesn't exist at rev", as
---opposed to an operational error. Matched case-insensitively.
local absence_patterns = {
  "does not exist",
  "exists on disk",
  "Not a valid object name",
}

---@param stderr string[]?
---@return boolean
local function stderr_signals_absence(stderr)
  if type(stderr) ~= "table" then
    return false
  end
  for _, line in ipairs(stderr) do
    for _, pat in ipairs(absence_patterns) do
      if line:find(pat) then
        return true
      end
    end
  end
  return false
end

---Fetch the smudged content of `path` at `rev`.
---
---Returns a status tag alongside the lines:
---  * `"ok"`: lines carry fully smudged content.
---  * `"absent"`: `path@rev` has no bytes (null tree, LOCAL file gone
---    from disk, or git-reported "path doesn't exist in rev").
---  * `"error"`: an operational failure (smudge crash, bad object).
---  * `"too-large"`: pointer declares a `size` above `M.MAX_SMUDGE_BYTES`;
---    lines carry the raw pointer so callers can still display it.
---@param adapter GitAdapter
---@param path string
---@param rev Rev
---@param callback fun(status: git.lfs.FetchStatus, lines: string[]?)
local fetch_smudged_lines = async.wrap(function(adapter, path, rev, callback)
  if rev.type == RevType.LOCAL then
    -- Hop onto nvim's scheduler so `vim.fn.readfile` doesn't raise
    -- `E5560` when resumed from a prior job's exit callback.
    await(async.scheduler())
    local abs = pl:absolute(path, adapter.ctx.toplevel)
    -- Gate on file size before loading. A normal `git lfs install`
    -- checkout leaves the full smudged object in the working tree, so
    -- an unguarded `vim.fn.readfile` would pull a multi-GB file into a
    -- Lua list of lines and later feed it to `vim.diff`, freezing nvim.
    -- The pointer-size check only covers raw-pointer-on-disk, which is
    -- the exceptional branch.
    local stat = pl:stat(abs)
    if stat and M.MAX_SMUDGE_BYTES > 0 and stat.size > M.MAX_SMUDGE_BYTES then
      callback("too-large", nil)
      return
    end
    local ok, lines = pcall(vim.fn.readfile, abs)
    if not ok then
      callback("absent", nil)
      return
    end
    if M.is_pointer(lines) then
      if pointer_too_large(lines) then
        callback("too-large", lines)
        return
      end
      local serr, smudged = await(M.smudge(adapter, path, lines))
      if serr or not smudged then
        callback("error", nil)
        return
      end
      callback("ok", smudged)
      return
    end
    callback("ok", lines)
    return
  end

  -- Pre-size via `git cat-file -s` so a historical non-pointer blob that
  -- was later migrated to LFS can't bypass `MAX_SMUDGE_BYTES`: `adapter:show`
  -- would buffer the whole object into memory and feed it to `vim.diff`.
  -- Pointer blobs are tiny (~140 bytes), so this check never short-circuits
  -- the pointer path. On lookup failure (nil size), fall through so the
  -- existing `absent`/`error` classification handles it.
  if M.MAX_SMUDGE_BYTES > 0 then
    local size = await(blob_size(adapter, path, rev))
    if size and size > M.MAX_SMUDGE_BYTES then
      callback("too-large", nil)
      return
    end
  end

  local err, data = await(adapter:show(path, rev))
  if err then
    callback(stderr_signals_absence(err) and "absent" or "error", nil)
    return
  end
  if not data then
    callback("absent", nil)
    return
  end
  if not M.is_pointer(data) then
    callback("ok", data)
    return
  end
  if pointer_too_large(data) then
    callback("too-large", data)
    return
  end
  local serr, smudged = await(M.smudge(adapter, path, data))
  if serr or not smudged then
    callback("error", nil)
    return
  end
  callback("ok", smudged)
end)

---@alias git.lfs.RecomputeStatus "ok"|"error"|"too-large"|"empty"|"binary"

---Scan a bounded prefix of `lines` for a NUL byte, matching
---`vcs.File._lines_look_binary`. Inlined here to avoid pulling the
---`vcs.file` module into the LFS adapter and risking a require cycle.
---@param lines string[]
---@return boolean
local function lines_look_binary(lines)
  local budget = 8192
  for _, line in ipairs(lines) do
    if type(line) == "string" then
      if line:find("\0", 1, true) then
        return true
      end
      budget = budget - #line
      if budget <= 0 then
        return false
      end
    end
  end
  return false
end

---Recompute additions/deletions by diffing smudged content on both sides
---via `vim.diff`. Takes per-side paths so renamed entries (old-path on
---left, new-path on right) resolve correctly. The companion status is:
---  * `"ok"`: stats are populated.
---  * `"error"`: a smudge or `show` call failed operationally.
---  * `"too-large"`: at least one side's pointer declares a size above
---    `M.MAX_SMUDGE_BYTES`.
---  * `"empty"`: both sides absent (null tree vs null tree, etc.).
---  * `"binary"`: at least one side's smudged bytes contain NUL. Feeding
---    binary content to `vim.diff` yields line counts proportional to
---    stray `0x0a` bytes, which is meaningless; callers hold the raw
---    numstat (same handling as `"too-large"`).
---Callers that drive a UI toggle use the status to decide whether to
---keep the raw numstat (and whether to revert a flipped state).
---@param adapter GitAdapter
---@param path_a string
---@param left Rev
---@param path_b string
---@param right Rev
---@param callback fun(stats: GitStats?, status: git.lfs.RecomputeStatus)
M.recompute_stats = async.wrap(function(adapter, path_a, left, path_b, right, callback)
  local a_status, a_lines = await(fetch_smudged_lines(adapter, path_a, left))
  local b_status, b_lines = await(fetch_smudged_lines(adapter, path_b, right))
  -- Operational failures and oversized LFS objects: we have no meaningful
  -- line count to publish. Leave the caller's raw numstat in place.
  if a_status == "error" or b_status == "error" then
    callback(nil, "error")
    return
  end
  if a_status == "too-large" or b_status == "too-large" then
    callback(nil, "too-large")
    return
  end
  if a_status == "absent" and b_status == "absent" then
    callback(nil, "empty")
    return
  end
  -- Treat an absent-on-one-side as empty so the diff reports the real
  -- line count for a true addition or deletion.
  a_lines = a_lines or {}
  b_lines = b_lines or {}

  -- Short-circuit on binary content: `vim.diff` would count stray `0x0a`
  -- bytes as line breaks and emit a nonsense add/del count, which the UI
  -- would then present alongside two null-rendered sides.
  if lines_look_binary(a_lines) or lines_look_binary(b_lines) then
    callback(nil, "binary")
    return
  end

  -- `table.concat({}, "\n") .. "\n"` renders as `"\n"` (one empty line),
  -- which `vim.diff` counts as content. Serialize `{}` as `""` so an
  -- empty side counts as zero lines.
  local function join(lines)
    return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
  end
  local a = join(a_lines)
  local b = join(b_lines)
  ---@diagnostic disable-next-line: deprecated
  local hunks = vim.diff(a, b, { result_type = "indices" })
  if type(hunks) ~= "table" then
    callback(nil, "error")
    return
  end

  local additions, deletions = 0, 0
  for _, h in ipairs(hunks) do
    deletions = deletions + h[2]
    additions = additions + h[4]
  end
  callback({ additions = additions, deletions = deletions }, "ok")
end)

return M
