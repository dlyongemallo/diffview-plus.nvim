local async = require("diffview.async")
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local Diff4 = require("diffview.scene.layouts.diff_4").Diff4
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local test_utils = require("diffview.tests.helpers")

local run = test_utils.system

local function setup_repo(case_name)
  local repo = test_utils.init_repo()
  local base_branch = vim.trim(run({ "git", "symbolic-ref", "--short", "HEAD" }, repo).stdout or "")

  if case_name == "modify_modify" then
    local path = repo .. "/conflict.txt"
    local f = assert(io.open(path, "w"))
    f:write("base\n")
    f:close()

    run({ "git", "add", "conflict.txt" }, repo)
    run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base" }, repo)

    run({ "git", "checkout", "-q", "-b", "side" }, repo)
    f = assert(io.open(path, "w"))
    f:write("side\n")
    f:close()
    run({ "git", "add", "conflict.txt" }, repo)
    run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "side" }, repo)

    run({ "git", "checkout", "-q", base_branch }, repo)
    f = assert(io.open(path, "w"))
    f:write("main\n")
    f:close()
    run({ "git", "add", "conflict.txt" }, repo)
    run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "main" }, repo)

    local merge = run({ "git", "merge", "--no-edit", "side" }, repo, { allow_nonzero = true })
    assert.is_true(merge.code ~= 0)

    return repo, "conflict.txt"
  elseif case_name == "modify_delete" then
    local path = repo .. "/delete_conflict.txt"
    local f = assert(io.open(path, "w"))
    f:write("base\n")
    f:close()

    run({ "git", "add", "delete_conflict.txt" }, repo)
    run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base" }, repo)

    run({ "git", "checkout", "-q", "-b", "side" }, repo)
    run({ "git", "rm", "-q", "delete_conflict.txt" }, repo)
    run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "delete" }, repo)

    run({ "git", "checkout", "-q", base_branch }, repo)
    f = assert(io.open(path, "w"))
    f:write("main edit\n")
    f:close()
    run({ "git", "add", "delete_conflict.txt" }, repo)
    run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "modify" }, repo)

    local merge = run({ "git", "merge", "--no-edit", "side" }, repo, { allow_nonzero = true })
    assert.is_true(merge.code ~= 0)

    return repo, "delete_conflict.txt"
  end

  error("unknown case")
end

describe("diffview.vcs.adapters.git merge conflict matrix", function()
  for _, case_name in ipairs({ "modify_modify", "modify_delete" }) do
    it(
      "opens conflict stages safely for " .. case_name,
      test_utils.async_test(function()
        local repo, conflict_path = setup_repo(case_name)

        local ok, err = pcall(function()
          local adapter = GitAdapter({
            toplevel = repo,
            cpath = repo,
            path_args = {},
          })

          local left = GitRev(RevType.STAGE, 0)
          local right = GitRev(RevType.LOCAL)
          local args = adapter:rev_to_args(left, right)

          local tracked_err, _, conflicts = async.await(
            adapter:tracked_files(
              left,
              right,
              args,
              "working",
              { default_layout = Diff2, merge_layout = Diff4 }
            )
          )

          assert.is_nil(tracked_err)
          assert.is_true(#conflicts > 0)

          local target
          for _, entry in ipairs(conflicts) do
            if entry.path == conflict_path then
              target = entry
              break
            end
          end

          assert.is_not_nil(target)

          -- Ensure all merge panes can be materialized without crashing,
          -- including missing stages for modify/delete style conflicts.
          for _, sym in ipairs({ "a", "b", "c", "d" }) do
            local file = target.layout[sym].file
            local bufnr = async.await(file:create_buffer())
            assert.is_true(type(bufnr) == "number")
          end
        end)

        vim.schedule(function()
          pcall(vim.fn.delete, repo, "rf")
        end)
        async.await(async.scheduler())

        if not ok then
          error(err)
        end
      end)
    )
  end
end)
