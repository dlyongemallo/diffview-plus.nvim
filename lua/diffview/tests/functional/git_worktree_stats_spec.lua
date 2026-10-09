local async = require("diffview.async")
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local test_utils = require("diffview.tests.helpers")

local run = test_utils.run

local function make_adapter(repo)
  return GitAdapter({
    toplevel = repo,
    cpath = repo,
    path_args = {},
  })
end

describe("diffview.vcs.adapters.git GitAdapter:worktree_stats", function()
  it(
    "reports all zeros for a clean repo at HEAD",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local adapter = make_adapter(repo)

      local ok, err = pcall(function()
        local s = adapter:worktree_stats()
        assert.equals(0, s.ahead)
        assert.equals(0, s.behind)
        assert.equals(0, s.changed_files)
        assert.equals(0, s.insertions)
        assert.equals(0, s.deletions)
        assert.equals(0, s.staged)
        assert.equals(0, s.unstaged)
        assert.equals(0, s.untracked)
      end)

      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "reports ahead/behind and diff totals against the resolved base",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local linked = repo .. "-wt"

      local ok, err = pcall(function()
        -- Branch off, add one commit with a two-line insertion so the diff
        -- stat has a predictable shape.
        run({ "git", "worktree", "add", "-b", "feature/x", linked }, repo)
        local path = linked .. "/added.txt"
        local f = assert(io.open(path, "w"))
        f:write("one\ntwo\n")
        f:close()
        test_utils.commit(linked, "add file")

        local adapter = make_adapter(linked)
        local s = adapter:worktree_stats()
        -- Base defaults to the main/master of the repo (origin absent).
        assert.is_not_nil(s.base)
        assert.equals(1, s.ahead)
        assert.equals(0, s.behind)
        assert.equals(1, s.changed_files)
        assert.equals(2, s.insertions)
        assert.equals(0, s.deletions)
        assert.equals(0, s.staged)
        assert.equals(0, s.unstaged)
        assert.equals(0, s.untracked)
      end)

      pcall(run, { "git", "worktree", "remove", "--force", linked }, repo)
      test_utils.cleanup_repo(repo)
      pcall(vim.fn.delete, linked, "rf")
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "distinguishes staged, unstaged, and untracked changes",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local adapter = make_adapter(repo)

      local ok, err = pcall(function()
        -- Staged: modify tracked file, add to index.
        local tracked = repo .. "/init.txt"
        local f = assert(io.open(tracked, "w"))
        f:write("changed\n")
        f:close()
        run({ "git", "add", "init.txt" }, repo)

        -- Unstaged: modify after staging; v1 reports MM.
        f = assert(io.open(tracked, "w"))
        f:write("changed again\n")
        f:close()

        -- Untracked: a brand-new file.
        local new = repo .. "/new.txt"
        f = assert(io.open(new, "w"))
        f:write("x\n")
        f:close()

        local s = adapter:worktree_stats()
        assert.equals(1, s.staged)
        assert.equals(1, s.unstaged)
        assert.equals(1, s.untracked)
      end)

      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "skips branch probes when no base can be resolved",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()

      local ok, err = pcall(function()
        -- Move the only ref off main/master so `resolve_default_base` returns nil.
        run({ "git", "branch", "-m", "feature/only" }, repo)

        local adapter = make_adapter(repo)
        local s = adapter:worktree_stats()
        assert.is_nil(s.base)
        assert.equals(0, s.ahead)
        assert.equals(0, s.behind)
        assert.equals(0, s.changed_files)
      end)

      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )
end)
