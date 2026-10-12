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

describe("diffview.vcs.adapters.git GitAdapter:worktree_list", function()
  it(
    "returns the main worktree for a plain repo",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local adapter = make_adapter(repo)

      local ok, err = pcall(function()
        local entries = adapter:worktree_list()
        assert.is_not_nil(entries)
        assert.equals(1, #entries)

        local e = entries[1]
        assert.equals(repo, e.path)
        assert.is_false(e.is_bare)
        assert.is_false(e.is_detached)
        -- `init.txt` was committed on the default branch; branch name varies
        -- across git versions (`master` vs `main`), so just assert it is set
        -- and matches whatever HEAD points at.
        assert.is_string(e.branch)
        local head_branch = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo)
        assert.equals(head_branch, e.branch)
      end)

      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "lists an added linked worktree alongside the main one",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local adapter = make_adapter(repo)

      -- `git worktree add` wants a sibling path; put it next to `repo`
      -- rather than inside it so cleanup is straightforward.
      local linked = repo .. "-wt"

      local ok, err = pcall(function()
        run({ "git", "worktree", "add", "-b", "feature/x", linked }, repo)

        local entries = adapter:worktree_list()
        assert.is_not_nil(entries)
        assert.equals(2, #entries)

        local by_path = {}
        for _, e in ipairs(entries) do
          by_path[e.path] = e
        end

        assert.is_not_nil(by_path[repo])
        assert.is_not_nil(by_path[linked])
        assert.equals("feature/x", by_path[linked].branch)
        assert.equals("refs/heads/feature/x", by_path[linked].ref)
      end)

      -- Remove the linked worktree before deleting the main repo so git
      -- does not leave a dangling admin dir behind.
      pcall(run, { "git", "worktree", "remove", "--force", linked }, repo)
      test_utils.cleanup_repo(repo)
      pcall(vim.fn.delete, linked, "rf")
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )
end)

describe("diffview.vcs.adapters.git GitAdapter:resolve_default_base", function()
  it(
    "falls back to origin/<default> when origin/HEAD is absent",
    test_utils.async_test(function()
      local upstream = test_utils.make_repo()
      local clone = vim.fn.tempname()

      local ok, err = pcall(function()
        run({ "git", "clone", "-q", upstream, clone })
        -- Drop `origin/HEAD` but keep `origin/<default>`, so the next
        -- candidate in the precedence list is what should win.
        run({ "git", "symbolic-ref", "--delete", "refs/remotes/origin/HEAD" }, clone)

        local adapter = make_adapter(clone)
        local head_branch = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, clone)
        local base = adapter:resolve_default_base()
        assert.equals("origin/" .. head_branch, base)
      end)

      test_utils.cleanup_repo(clone)
      test_utils.cleanup_repo(upstream)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "returns the local default branch when no remote exists",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()
      local adapter = make_adapter(repo)

      local ok, err = pcall(function()
        local head_branch = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo)
        local base = adapter:resolve_default_base()
        -- `make_repo` only ever leaves `main` or `master` behind, both of
        -- which the resolver's priority list covers.
        assert.equals(head_branch, base)
      end)

      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "returns nil when no conventional default branch is reachable",
    test_utils.async_test(function()
      local repo = test_utils.make_repo()

      local ok, err = pcall(function()
        -- Move the only ref off `main`/`master` so none of the resolver's
        -- candidates can resolve to a commit.
        run({ "git", "branch", "-m", "feature/only" }, repo)

        local adapter = make_adapter(repo)
        local base = adapter:resolve_default_base()
        assert.is_nil(base)
      end)

      test_utils.cleanup_repo(repo)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "resolves `origin/HEAD` to its target branch name rather than returning the symbolic ref",
    test_utils.async_test(function()
      local upstream = test_utils.make_repo()
      local clone = vim.fn.tempname()

      local ok, err = pcall(function()
        run({ "git", "clone", "-q", upstream, clone })
        -- `git clone` seeds `refs/remotes/origin/HEAD` to track upstream's
        -- default branch; the resolver should surface the resolved target
        -- (`origin/<default>`), not the symbolic `origin/HEAD` itself, so
        -- that callers see the actual branch they are comparing against.
        local default_branch = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, upstream)

        local adapter = make_adapter(clone)
        local base = adapter:resolve_default_base()
        assert.equals("origin/" .. default_branch, base)
      end)

      test_utils.cleanup_repo(clone)
      test_utils.cleanup_repo(upstream)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "falls back to `origin/<fallback>` when `refs/remotes/origin/HEAD` is unset",
    test_utils.async_test(function()
      local upstream = test_utils.make_repo()
      local clone = vim.fn.tempname()

      local ok, err = pcall(function()
        run({ "git", "clone", "-q", upstream, clone })
        -- Drop the symbolic ref so the resolver cannot read `origin`'s
        -- default dynamically and must consult the branch fallbacks.
        run({ "git", "symbolic-ref", "--delete", "refs/remotes/origin/HEAD" }, clone)

        local adapter = make_adapter(clone)
        local default_branch = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, upstream)
        local base = adapter:resolve_default_base()
        assert.equals("origin/" .. default_branch, base)
      end)

      test_utils.cleanup_repo(clone)
      test_utils.cleanup_repo(upstream)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "prefers `upstream` over `origin` for the fork-and-PR workflow",
    test_utils.async_test(function()
      -- Set up two "canonical" repos: the user's fork (what `origin` will
      -- point at from their clone) and the real upstream project. Give
      -- them divergent default-branch tips so a wrong resolver choice
      -- shows up as a different rev-parse SHA, not just a different name.
      local upstream = test_utils.make_repo()
      local fork = test_utils.make_repo()
      local clone = vim.fn.tempname()

      local ok, err = pcall(function()
        local upstream_branch = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, upstream)
        -- Advance both repos' default branches by one commit each, so
        -- `upstream/<branch>` and `origin/<branch>` resolve to distinct
        -- commits post-clone. Without this the test cannot distinguish
        -- "resolver picked upstream" from "resolver picked origin".
        local u_file = upstream .. "/u.txt"
        local f = assert(io.open(u_file, "w"))
        f:write("u\n")
        f:close()
        run({ "git", "add", "u.txt" }, upstream)
        run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "u" }, upstream)
        local upstream_sha = run({ "git", "rev-parse", "HEAD" }, upstream)

        local f_file = fork .. "/f.txt"
        local ff = assert(io.open(f_file, "w"))
        ff:write("f\n")
        ff:close()
        run({ "git", "add", "f.txt" }, fork)
        run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "f" }, fork)

        -- Clone from the fork (so `origin` points there), then add
        -- `upstream` as a second remote and fetch it so the local
        -- `refs/remotes/upstream/*` refs exist.
        run({ "git", "clone", "-q", fork, clone })
        run({ "git", "remote", "add", "upstream", upstream }, clone)
        run({ "git", "fetch", "-q", "upstream" }, clone)

        local adapter = make_adapter(clone)
        local base = adapter:resolve_default_base()
        assert.equals("upstream/" .. upstream_branch, base)
        -- Guard against a false positive where the resolver returned the
        -- right name but it secretly points at origin's tip: assert the
        -- resolved SHA matches upstream, not the fork.
        local base_sha = run({ "git", "rev-parse", base }, clone)
        assert.equals(upstream_sha, base_sha)
      end)

      test_utils.cleanup_repo(clone)
      test_utils.cleanup_repo(upstream)
      test_utils.cleanup_repo(fork)
      async.await(async.scheduler())

      if not ok then
        error(err)
      end
    end)
  )
end)
