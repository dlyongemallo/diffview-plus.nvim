local worktree = require("diffview.vcs.adapters.git.worktree")

describe("diffview.vcs.adapters.git.worktree", function()
  describe("parse_worktree_list", function()
    it("returns an empty list for empty input", function()
      assert.same({}, worktree.parse_worktree_list(""))
      assert.same({}, worktree.parse_worktree_list({}))
    end)

    it("parses a single normal worktree", function()
      local out = table.concat({
        "worktree /home/me/repo",
        "HEAD abc1234def5678abc1234def5678abc1234def56",
        "branch refs/heads/main",
        "",
      }, "\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals(1, #entries)

      local e = entries[1]
      assert.equals("/home/me/repo", e.path)
      assert.equals("abc1234def5678abc1234def5678abc1234def56", e.head)
      assert.equals("main", e.branch)
      assert.equals("refs/heads/main", e.ref)
      assert.is_false(e.is_bare)
      assert.is_false(e.is_detached)
      assert.is_false(e.is_locked)
      assert.is_false(e.is_prunable)
    end)

    it("parses bare, branched, and detached worktrees together", function()
      local out = table.concat({
        "worktree /repo/.bare",
        "bare",
        "",
        "worktree /repo/feature",
        "HEAD 1111111111111111111111111111111111111111",
        "branch refs/heads/feature/foo",
        "",
        "worktree /repo/detached",
        "HEAD 2222222222222222222222222222222222222222",
        "detached",
        "",
      }, "\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals(3, #entries)

      assert.is_true(entries[1].is_bare)
      assert.is_nil(entries[1].head)
      assert.is_nil(entries[1].branch)

      assert.equals("feature/foo", entries[2].branch)
      assert.equals("refs/heads/feature/foo", entries[2].ref)
      assert.is_false(entries[2].is_detached)

      assert.is_true(entries[3].is_detached)
      assert.is_nil(entries[3].branch)
      assert.is_nil(entries[3].ref)
    end)

    it("captures locked/prunable flags with and without reasons", function()
      local out = table.concat({
        "worktree /repo/a",
        "HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "branch refs/heads/a",
        "locked",
        "",
        "worktree /repo/b",
        "HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "branch refs/heads/b",
        "locked user said so",
        "",
        "worktree /repo/c",
        "HEAD cccccccccccccccccccccccccccccccccccccccc",
        "branch refs/heads/c",
        "prunable gitdir file points to non-existent location",
        "",
      }, "\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals(3, #entries)

      assert.is_true(entries[1].is_locked)
      assert.is_nil(entries[1].lock_reason)

      assert.is_true(entries[2].is_locked)
      assert.equals("user said so", entries[2].lock_reason)

      assert.is_true(entries[3].is_prunable)
      assert.equals("gitdir file points to non-existent location", entries[3].prune_reason)
    end)

    it("tolerates a missing trailing blank line", function()
      local out = table.concat({
        "worktree /repo/a",
        "HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "branch refs/heads/a",
      }, "\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals(1, #entries)
      assert.equals("/repo/a", entries[1].path)
    end)

    it("preserves spaces in worktree paths and lock reasons", function()
      local out = table.concat({
        "worktree /home/me/some project/wt one",
        "HEAD 3333333333333333333333333333333333333333",
        "branch refs/heads/feature/with spaces",
        "locked reason with  multiple   spaces",
        "",
      }, "\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals(1, #entries)
      assert.equals("/home/me/some project/wt one", entries[1].path)
      assert.equals("feature/with spaces", entries[1].branch)
      assert.equals("reason with  multiple   spaces", entries[1].lock_reason)
    end)

    it("tolerates CRLF line endings", function()
      local out = table.concat({
        "worktree /repo/a",
        "HEAD 4444444444444444444444444444444444444444",
        "branch refs/heads/a",
        "",
      }, "\r\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals(1, #entries)
      assert.equals("/repo/a", entries[1].path)
      assert.equals("a", entries[1].branch)
    end)

    it("accepts input as a pre-split array of lines", function()
      local entries = worktree.parse_worktree_list({
        "worktree /repo/a",
        "HEAD 5555555555555555555555555555555555555555",
        "branch refs/heads/a",
        "",
      })
      assert.equals(1, #entries)
      assert.equals("/repo/a", entries[1].path)
    end)

    it("ignores unknown attributes for forward compatibility", function()
      local out = table.concat({
        "worktree /repo/a",
        "HEAD 6666666666666666666666666666666666666666",
        "branch refs/heads/a",
        "someday-new-flag",
        "someday-new-key with value",
        "",
      }, "\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals(1, #entries)
      assert.equals("/repo/a", entries[1].path)
      assert.equals("a", entries[1].branch)
    end)

    it("skips attribute lines that appear before any worktree line", function()
      local out = table.concat({
        "HEAD 7777777777777777777777777777777777777777",
        "branch refs/heads/orphan",
        "",
        "worktree /repo/a",
        "HEAD 8888888888888888888888888888888888888888",
        "branch refs/heads/a",
        "",
      }, "\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals(1, #entries)
      assert.equals("/repo/a", entries[1].path)
    end)

    it("strips refs/heads/ but leaves other ref namespaces intact", function()
      -- Git's porcelain always uses `refs/heads/...` for `branch`, but be
      -- defensive: if git ever emits something else, expose the full ref
      -- via `ref` and leave `branch` unmodified rather than mangling it.
      local out = table.concat({
        "worktree /repo/a",
        "HEAD 9999999999999999999999999999999999999999",
        "branch refs/tags/v1.0",
        "",
      }, "\n")

      local entries = worktree.parse_worktree_list(out)
      assert.equals("refs/tags/v1.0", entries[1].ref)
      assert.equals("refs/tags/v1.0", entries[1].branch)
    end)
  end)
end)
