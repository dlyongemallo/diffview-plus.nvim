local async = require("diffview.async")
local File = require("diffview.vcs.file").File
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local config = require("diffview.config")
local test_utils = require("diffview.tests.helpers")

local function run(cmd, cwd, env)
  local res = vim.system(cmd, { cwd = cwd, env = env, text = true }):wait()
  assert.equals(0, res.code, (table.concat(cmd, " ") .. "\n" .. (res.stderr or "")))
  return vim.trim(res.stdout or "")
end

local function make_dir()
  local d = assert(vim.fn.tempname())
  assert.equals(1, vim.fn.mkdir(d, "p"))
  return assert(vim.uv.fs_realpath(d))
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

--- Build a snapshot-style layout where the git dir and work tree diverge, the
--- way snapshot tooling sets one up: a `project` repo with its own history, and
--- a separate snapshot git dir initialized with `GIT_DIR` / `GIT_WORK_TREE` (so
--- `git init` records `core.worktree`, pointing the store's work tree back at
--- `project`). Objects are shared via `objects/info/alternates`, and snapshots
--- are trees written with `write-tree`, so the store has no commits and its
--- `HEAD` is unborn. Each tree is reachable only from the store; running git
--- from `project` cannot see it.
local function make_snapshot_repo()
  local project = make_dir()
  run({ "git", "init", "-q" }, project)
  run({ "git", "config", "user.name", "Diffview Test" }, project)
  run({ "git", "config", "user.email", "diffview@test.local" }, project)
  write_file(project .. "/tracked.txt", "line1\n")
  run({ "git", "add", "tracked.txt" }, project)
  run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "P1" }, project)

  -- The store dir itself is the git dir; `GIT_WORK_TREE` makes init record
  -- `core.worktree`, so `--show-toplevel` from the store reports `project`.
  local store = make_dir()
  run({ "git", "init", "-q" }, project, { GIT_DIR = store, GIT_WORK_TREE = project })

  -- Share the project's object database, as snapshot tooling does.
  local common = run({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, project)
  assert.equals(1, vim.fn.mkdir(store .. "/objects/info", "p"))
  write_file(store .. "/objects/info/alternates", common .. "/objects\n")

  -- Each snapshot is a tree written from the work tree (no commit).
  local function snapshot()
    run({ "git", "--git-dir", store, "--work-tree", project, "add", "--all", "--", "." }, project)
    return run({ "git", "--git-dir", store, "--work-tree", project, "write-tree" }, project)
  end

  write_file(project .. "/tracked.txt", "line1\nline2-A\n")
  local tree_a = snapshot()
  write_file(project .. "/tracked.txt", "line1\nline2-A\nline3-B\n")
  local tree_b = snapshot()

  -- A further local edit so a COMMIT..LOCAL diff against tree B is non-empty.
  write_file(project .. "/tracked.txt", "line1\nline2-A\nline3-B\nline4-local\n")

  return {
    project = project,
    store = store,
    tree_a = tree_a,
    tree_b = tree_b,
    cleanup = function()
      pcall(vim.fn.delete, store, "rf")
      pcall(vim.fn.delete, project, "rf")
    end,
  }
end

describe("diffview.vcs.adapters.git -C snapshot (divergent git dir / work tree)", function()
  it(
    "pins the snapshot git dir and resolves a HEAD-less tree snapshot",
    test_utils.async_test(function()
      local env = make_snapshot_repo()

      local ok, err = pcall(function()
        -- `core.worktree` makes the reported toplevel the project, not the `-C`
        -- dir, so the git dir and work tree genuinely diverge.
        local terr, toplevel = GitAdapter.find_toplevel({ env.store })
        assert.is_nil(terr)
        assert.equals(env.project, toplevel)

        local aerr, adapter = GitAdapter.create(toplevel, {}, env.store)
        assert.is_nil(aerr)
        assert.equals(env.project, adapter.ctx.toplevel)
        assert.equals(env.store, adapter.ctx.dir)
        assert.same(
          { "--git-dir=" .. env.store, "--work-tree=" .. env.project },
          adapter.ctx.git_override
        )

        -- The store has no commits, so `parse_revs` must resolve the tree-hash
        -- snapshot for a single-rev (COMMIT..LOCAL) diff without a `HEAD`.
        assert.is_nil(adapter:head_rev())
        local left, right = adapter:parse_revs(env.tree_b, {})
        assert.equals(RevType.COMMIT, left.type)
        assert.equals(env.tree_b, left.commit)
        assert.equals(RevType.LOCAL, right.type)

        -- The COMMIT side reads the snapshot content through the store git dir.
        local serr, data = async.await(adapter:show("tracked.txt", left))
        assert.is_nil(serr)
        assert.same({ "line1", "line2-A", "line3-B" }, data)
      end)

      vim.schedule(env.cleanup)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "resolves a tree-hash range across two snapshots",
    test_utils.async_test(function()
      local env = make_snapshot_repo()

      local ok, err = pcall(function()
        local aerr, adapter = GitAdapter.create(env.project, {}, env.store)
        assert.is_nil(aerr)

        local left, right = adapter:parse_revs(env.tree_a .. ".." .. env.tree_b, {})
        assert.equals(RevType.COMMIT, left.type)
        assert.equals(env.tree_a, left.commit)
        assert.equals(RevType.COMMIT, right.type)
        assert.equals(env.tree_b, right.commit)

        -- Both endpoints resolve to their own snapshot content via the store.
        local _, data_a = async.await(adapter:show("tracked.txt", left))
        local _, data_b = async.await(adapter:show("tracked.txt", right))
        assert.same({ "line1", "line2-A" }, data_a)
        assert.same({ "line1", "line2-A", "line3-B" }, data_b)
      end)

      vim.schedule(env.cleanup)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "opens the real work-tree file on the LOCAL side without a binary false-positive",
    test_utils.async_test(function()
      local env = make_snapshot_repo()

      local aerr, adapter = GitAdapter.create(env.project, {}, env.store)
      assert.is_nil(aerr)

      local file = File({
        adapter = adapter,
        path = "tracked.txt",
        kind = "working",
        rev = GitRev(RevType.LOCAL),
      })

      local ok, err = pcall(function()
        -- No tracked-file probe needed: with the work tree pinned, the binary
        -- detector finds the tracked text file from the work-tree cwd.
        assert.False(adapter:is_binary("tracked.txt", GitRev(RevType.LOCAL)))

        local bufnr = async.await(file:create_buffer())
        assert.False(file.binary)
        assert.True(bufnr ~= File._get_null_buffer())
        assert.same(
          { "line1", "line2-A", "line3-B", "line4-local" },
          vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        )
      end)

      vim.schedule(function()
        if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
          pcall(vim.api.nvim_buf_delete, file.bufnr, { force = true })
        end
        env.cleanup()
      end)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it("leaves an ordinary `-C` repo's command prefix untouched", function()
    local repo = make_dir()
    run({ "git", "init", "-q" }, repo)
    run({ "git", "config", "user.name", "Diffview Test" }, repo)
    run({ "git", "config", "user.email", "diffview@test.local" }, repo)
    write_file(repo .. "/a.txt", "x\n")
    run({ "git", "add", "a.txt" }, repo)
    run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" }, repo)

    local ok, err = pcall(function()
      -- `-C` points at the repo's own toplevel, so there is no divergence.
      local aerr, adapter = GitAdapter.create(repo, {}, repo)
      assert.is_nil(aerr)
      assert.is_nil(adapter.ctx.git_override)
      assert.equals(repo .. "/.git", adapter.ctx.dir)
      assert.same(config.get_config().git_cmd, adapter:get_command())
    end)

    pcall(vim.fn.delete, repo, "rf")

    if not ok then
      error(err)
    end
  end)
end)
