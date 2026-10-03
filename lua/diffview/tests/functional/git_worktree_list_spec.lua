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
