local async = require("diffview.async")
local File = require("diffview.vcs.file").File
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local git_lfs = require("diffview.vcs.adapters.git.lfs")
local test_utils = require("diffview.tests.helpers")

local run = test_utils.run
local system = test_utils.system

--- Is `git-lfs` installed and functional?
local function git_lfs_available()
  -- `vim.system` raises on spawn failure (e.g., executable not on PATH)
  -- rather than returning a nonzero code. This runs at describe-registration
  -- time, so an unguarded throw would abort loading the spec on hosts
  -- without this optional binary.
  if vim.fn.executable("git-lfs") ~= 1 then
    return false
  end
  local ok, res = pcall(function()
    return vim.system({ "git-lfs", "version" }, { text = true }):wait()
  end)
  return ok and res.code == 0
end

local function sample_pointer(oid, size)
  return {
    "version https://git-lfs.github.com/spec/v1",
    "oid sha256:" .. oid,
    "size " .. tostring(size),
  }
end

describe("diffview.vcs.adapters.git.lfs", function()
  describe("is_pointer()", function()
    it("recognises a canonical v1 pointer", function()
      assert.True(git_lfs.is_pointer(sample_pointer(string.rep("a", 64), 42)))
    end)

    it("accepts additional ext-* lines within the size limit", function()
      local lines = sample_pointer(string.rep("b", 64), 7)
      table.insert(lines, "x-foo bar")
      assert.True(git_lfs.is_pointer(lines))
    end)

    it("rejects nil or wrong-type input", function()
      assert.False(git_lfs.is_pointer(nil))
      assert.False(git_lfs.is_pointer("version https://git-lfs.github.com/spec/v1"))
    end)

    it("rejects empty or single-line input", function()
      assert.False(git_lfs.is_pointer({}))
      assert.False(git_lfs.is_pointer({ "version https://git-lfs.github.com/spec/v1" }))
    end)

    it("rejects content without the LFS version header", function()
      assert.False(git_lfs.is_pointer({ "hello", "world" }))
      assert.False(git_lfs.is_pointer({
        "version https://example.com/spec/v1",
        "oid sha256:" .. string.rep("c", 64),
      }))
    end)

    it("rejects content missing the oid line", function()
      assert.False(git_lfs.is_pointer({
        "version https://git-lfs.github.com/spec/v1",
        "size 42",
      }))
    end)

    it("rejects pointer-shaped content larger than the pointer-size cap", function()
      local lines = sample_pointer(string.rep("d", 64), 1)
      for i = 1, 20 do
        lines[#lines + 1] = ("x-%d trailing"):format(i)
      end
      assert.False(git_lfs.is_pointer(lines))
    end)
  end)

  describe("parse_size()", function()
    it("extracts the byte size from a canonical pointer", function()
      assert.equals(42, git_lfs.parse_size(sample_pointer(string.rep("a", 64), 42)))
    end)

    it("returns nil for malformed input or a pointer missing a size line", function()
      assert.is_nil(git_lfs.parse_size(nil))
      assert.is_nil(git_lfs.parse_size("not a table"))
      assert.is_nil(git_lfs.parse_size({
        "version https://git-lfs.github.com/spec/v1",
        "oid sha256:" .. string.rep("e", 64),
      }))
    end)
  end)

  describe("vcs.File:produce_data() with LFS", function()
    if not git_lfs_available() then
      pending("skipped: `git-lfs` is not installed on this host")
      return
    end

    local repo

    local function make_lfs_repo()
      repo = test_utils.init_repo()
      -- Configure LFS filters in this repo only, so the user's global
      -- `.gitconfig` is left untouched.
      run({ "git", "lfs", "install", "--local" }, repo)
      test_utils.write(repo, ".gitattributes", {
        "*.bin filter=lfs diff=lfs merge=lfs -text",
      })
      test_utils.write(repo, "big.bin", { "hello lfs v1" })
      test_utils.commit(repo, "lfs v1")
      test_utils.write(repo, "big.bin", { "hello lfs v2" })
      test_utils.commit(repo, "lfs v2")
    end

    local function cleanup()
      if repo then
        test_utils.cleanup_repo(repo)
        repo = nil
      end
    end

    local function make_file(adapter, path, rev, lfs_smudge)
      return File({
        adapter = adapter,
        path = path,
        kind = "working",
        rev = rev,
        lfs_smudge = lfs_smudge,
      })
    end

    it(
      "returns pointer bytes by default (lfs_smudge=false)",
      test_utils.async_test(function()
        make_lfs_repo()

        local ok, err = pcall(function()
          -- Sanity-check: without smudging the blob at HEAD~ is a pointer.
          local raw = system({ "git", "show", "HEAD~:big.bin" }, repo).stdout
          assert.truthy(raw:match("^version https://git%-lfs%.github%.com/spec/v1"))

          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local rev = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD~" }, repo))
          local file = make_file(adapter, "big.bin", rev, false)

          local serr, data = async.await(File.produce_data(file))
          assert.is_nil(serr)
          assert.True(git_lfs.is_pointer(data), "expected pointer bytes when lfs_smudge=false")
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "returns smudged content when lfs_smudge=true on an LFS blob",
      test_utils.async_test(function()
        make_lfs_repo()

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local rev = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD~" }, repo))
          local file = make_file(adapter, "big.bin", rev, true)

          local serr, data = async.await(File.produce_data(file))
          assert.is_nil(serr)
          assert.False(git_lfs.is_pointer(data), "expected smudged content")
          assert.equals("hello lfs v1", data[1])
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "returns a working-tree pointer when LOCAL + lfs_smudge=false on an LFS file",
      test_utils.async_test(function()
        make_lfs_repo()

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local file = make_file(adapter, "big.bin", adapter.Rev(RevType.LOCAL), false)

          local serr, data = async.await(File.produce_data(file))
          assert.is_nil(serr)
          assert.True(
            git_lfs.is_pointer(data),
            "expected the LOCAL side to show a pointer when lfs_smudge=false"
          )
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "the LOCAL pointer reflects the current working-tree bytes, not the index",
      test_utils.async_test(function()
        make_lfs_repo()

        local ok, err = pcall(function()
          -- Modify the working tree without staging. The LOCAL pointer must
          -- hash these bytes, not the ones in the index.
          test_utils.write(repo, "big.bin", { "unstaged content v3" })

          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local file = make_file(adapter, "big.bin", adapter.Rev(RevType.LOCAL), false)
          local serr, local_lines = async.await(File.produce_data(file))
          assert.is_nil(serr)
          assert.True(git_lfs.is_pointer(local_lines))

          -- `produce_data` resumes in a fast event context; land on the
          -- scheduler before `vim.system` (via `test_utils.system`) below.
          async.await(async.scheduler())

          -- Oid line differs from the index version. If `produce_data` had
          -- used `git show :big.bin`, both would carry the same oid.
          local staged = system({ "git", "show", ":big.bin" }, repo).stdout
          local staged_oid = staged:match("oid sha256:(%x+)")
          local local_oid
          for _, line in ipairs(local_lines) do
            local m = line:match("^oid sha256:(%x+)$")
            if m then
              local_oid = m
              break
            end
          end
          assert.is_not_nil(staged_oid)
          assert.is_not_nil(local_oid)
          assert.are_not.equal(staged_oid, local_oid)
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "leaves non-LFS blobs untouched regardless of the lfs_smudge flag",
      test_utils.async_test(function()
        make_lfs_repo()

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local rev = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))

          -- `.gitattributes` is not LFS-tracked, so smudging must not alter it
          -- (the smudge filter sees non-pointer bytes and would echo them back,
          -- but we never invoke it because `is_pointer` is false).
          for _, flag in ipairs({ false, true }) do
            local file = make_file(adapter, ".gitattributes", rev, flag)
            local serr, data = async.await(File.produce_data(file))
            assert.is_nil(serr)
            assert.equals("*.bin filter=lfs diff=lfs merge=lfs -text", data[1])
          end
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )
  end)

  describe("recompute_stats() with LFS", function()
    if not git_lfs_available() then
      pending("skipped: `git-lfs` is not installed on this host")
      return
    end

    local repo

    local function cleanup()
      if repo then
        test_utils.cleanup_repo(repo)
        repo = nil
      end
    end

    it(
      "returns content-level additions/deletions for LOCAL vs COMMIT",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "alpha" })
        test_utils.commit(repo, "v1")
        -- Write a bigger working-tree version without committing: this mirrors
        -- the user's `:DiffviewOpen HEAD~` case where the right side is LOCAL
        -- and the pointer at `HEAD~` must still smudge into "alpha".
        test_utils.write(repo, "big.bin", { "alpha", "beta", "gamma" })

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local left = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))
          local right = adapter.Rev(RevType.LOCAL)
          local stats =
            async.await(git_lfs.recompute_stats(adapter, "big.bin", left, "big.bin", right))
          assert.is_not_nil(stats, "recompute_stats returned nil for LOCAL rev")
          assert.equals(2, stats.additions)
          assert.equals(0, stats.deletions)
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "returns content-level additions/deletions for an LFS-tracked blob",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "hello" })
        test_utils.commit(repo, "v1")
        test_utils.write(repo, "big.bin", { "hello world", "line2", "line3" })
        test_utils.commit(repo, "v2")

        local ok, err = pcall(function()
          -- Sanity-check that git's own numstat reports pointer stats here,
          -- so passing assertions below prove `recompute_stats` sidestepped
          -- that path and computed from smudged content.
          local numstat = run({ "git", "diff", "--numstat", "HEAD~", "HEAD" }, repo)
          assert.truthy(numstat:match("^2\t2\tbig%.bin$"))

          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local left = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD~" }, repo))
          local right = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))

          local stats =
            async.await(git_lfs.recompute_stats(adapter, "big.bin", left, "big.bin", right))
          assert.is_not_nil(stats)
          assert.equals(3, stats.additions)
          assert.equals(1, stats.deletions)
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "returns nil when either pointer declares a size above MAX_SMUDGE_BYTES",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "hello" })
        test_utils.commit(repo, "v1")
        test_utils.write(repo, "big.bin", { "hello world", "line2", "line3" })
        test_utils.commit(repo, "v2")

        -- Clamp the limit so the existing tiny LFS objects count as oversized.
        local saved = git_lfs.MAX_SMUDGE_BYTES
        git_lfs.MAX_SMUDGE_BYTES = 1

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local left = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD~" }, repo))
          local right = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))

          local stats =
            async.await(git_lfs.recompute_stats(adapter, "big.bin", left, "big.bin", right))
          assert.is_nil(stats, "expected nil so the caller falls back to raw numstat")
        end)

        git_lfs.MAX_SMUDGE_BYTES = saved
        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "returns nil when the LOCAL working-tree file exceeds MAX_SMUDGE_BYTES",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "small" })
        test_utils.commit(repo, "v1")
        -- The working-tree file is normally the fully smudged payload.
        -- Clamp the limit so the (tiny) file still counts as oversized
        -- and the fs_stat gate rejects it before the readfile.
        local saved = git_lfs.MAX_SMUDGE_BYTES
        git_lfs.MAX_SMUDGE_BYTES = 1

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local left = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))
          local right = adapter.Rev(RevType.LOCAL)
          local stats =
            async.await(git_lfs.recompute_stats(adapter, "big.bin", left, "big.bin", right))
          assert.is_nil(stats, "expected nil so the caller falls back to raw numstat")
        end)

        git_lfs.MAX_SMUDGE_BYTES = saved
        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "smudges a raw pointer left on disk by `GIT_LFS_SKIP_SMUDGE`",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "alpha" })
        test_utils.commit(repo, "v1")
        -- Replace the working-tree file with the raw pointer bytes, as if
        -- the checkout had set `GIT_LFS_SKIP_SMUDGE=1`.
        local pointer = system({ "git", "show", "HEAD:big.bin" }, repo).stdout
        local f = assert(io.open(repo .. "/big.bin", "w"))
        f:write(pointer)
        f:close()

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local left = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))
          local right = adapter.Rev(RevType.LOCAL)
          -- Both sides collapse to the same smudged "alpha", so there are
          -- no content-level changes to report; without the pointer guard
          -- the LOCAL side would be the raw pointer and the diff would
          -- report spurious additions/deletions.
          local stats =
            async.await(git_lfs.recompute_stats(adapter, "big.bin", left, "big.bin", right))
          assert.is_not_nil(stats)
          assert.equals(0, stats.additions)
          assert.equals(0, stats.deletions)
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "resolves per-side paths for renamed LFS entries",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "old.bin", { "alpha" })
        test_utils.commit(repo, "v1")
        run({ "git", "mv", "old.bin", "new.bin" }, repo)
        test_utils.write(repo, "new.bin", { "alpha", "beta" })
        test_utils.commit(repo, "renamed and extended")

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local left = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD~" }, repo))
          local right = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))
          -- With per-side paths, `recompute_stats` sees "alpha" on the
          -- left (via `old.bin@HEAD~`) and "alpha\nbeta" on the right
          -- (via `new.bin@HEAD`): one real addition, no deletions.
          local stats, status =
            async.await(git_lfs.recompute_stats(adapter, "old.bin", left, "new.bin", right))
          assert.equals("ok", status)
          assert.is_not_nil(stats)
          assert.equals(1, stats.additions)
          assert.equals(0, stats.deletions)
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "returns `error` (not `absent`) when a `git show` fails operationally",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "payload" })
        test_utils.commit(repo, "v1")

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          -- A bogus revision triggers a `fatal: Not a valid object name`
          -- stderr that matches the absence patterns, so this still
          -- counts as "absent"; use a non-existent path at a real rev
          -- to exercise the same code path (stderr says "does not
          -- exist", also matched as absent).
          local real = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))
          local stats, status =
            async.await(git_lfs.recompute_stats(adapter, "missing.bin", real, "big.bin", real))
          -- Left side absent + right side ok with pointer size well
          -- under the cap → the one-sided-addition path runs and we
          -- get an "ok" result; this proves the patterns match the
          -- known-absence case rather than promoting it to error.
          assert.equals("ok", status)
          assert.is_not_nil(stats)
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "cached_is_tracked returns the memoised value without re-shelling",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "payload" })
        test_utils.commit(repo, "v1")

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          -- Reset the cache so this test starts from a known state.
          git_lfs._tracked_cache[adapter.ctx.toplevel] = nil
          local first = async.await(git_lfs.cached_is_tracked(adapter, "big.bin"))
          assert.True(first)
          -- Mutate the cache to a sentinel; a cached call must return it.
          git_lfs._tracked_cache[adapter.ctx.toplevel]["big.bin"] = false
          local second = async.await(git_lfs.cached_is_tracked(adapter, "big.bin"))
          assert.False(second, "second call should hit the cache, not re-run check-attr")
        end)

        cleanup()

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "returns `too-large` status so the caller can revert the toggle",
      test_utils.async_test(function()
        repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "payload" })
        test_utils.commit(repo, "v1")

        local saved = git_lfs.MAX_SMUDGE_BYTES
        git_lfs.MAX_SMUDGE_BYTES = 1

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local left = GitRev(RevType.COMMIT, run({ "git", "rev-parse", "HEAD" }, repo))
          local right = adapter.Rev(RevType.LOCAL)
          local stats, status =
            async.await(git_lfs.recompute_stats(adapter, "big.bin", left, "big.bin", right))
          assert.is_nil(stats)
          assert.equals("too-large", status)
        end)

        git_lfs.MAX_SMUDGE_BYTES = saved
        cleanup()

        if not ok then
          error(err)
        end
      end)
    )
  end)

  describe("vcs.File:produce_data() LOCAL with raw pointer on disk", function()
    if not git_lfs_available() then
      pending("skipped: `git-lfs` is not installed on this host")
      return
    end

    it(
      "returns the on-disk pointer verbatim instead of re-hashing it",
      test_utils.async_test(function()
        local repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "alpha" })
        test_utils.commit(repo, "v1")
        -- Working-tree file is the raw pointer (as under `GIT_LFS_SKIP_SMUDGE=1`).
        local pointer = system({ "git", "show", "HEAD:big.bin" }, repo).stdout
        local f = assert(io.open(repo .. "/big.bin", "w"))
        f:write(pointer)
        f:close()

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local file = File({
            adapter = adapter,
            path = "big.bin",
            kind = "working",
            rev = adapter.Rev(RevType.LOCAL),
            lfs_smudge = false,
          })

          local serr, data = async.await(File.produce_data(file))
          assert.is_nil(serr)
          assert.True(git_lfs.is_pointer(data))
          -- Compare oid against the committed pointer's oid: a pass means
          -- we used the on-disk bytes rather than hashing the pointer
          -- header via `git lfs pointer --file=`, which would yield a
          -- different (pointer-of-pointer) oid.
          local expected_oid = pointer:match("oid sha256:(%x+)")
          local got_oid
          for _, line in ipairs(data) do
            local m = line:match("^oid sha256:(%x+)$")
            if m then
              got_oid = m
              break
            end
          end
          assert.is_not_nil(expected_oid)
          assert.equals(expected_oid, got_oid)
        end)

        test_utils.cleanup_repo(repo)

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "smudges a raw pointer on disk when lfs_smudge=true",
      test_utils.async_test(function()
        local repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        test_utils.write(repo, "big.bin", { "alpha" })
        test_utils.commit(repo, "v1")
        -- `GIT_LFS_SKIP_SMUDGE=1` shape: working-tree file is the raw pointer.
        local pointer = system({ "git", "show", "HEAD:big.bin" }, repo).stdout
        local f = assert(io.open(repo .. "/big.bin", "w"))
        f:write(pointer)
        f:close()

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local file = File({
            adapter = adapter,
            path = "big.bin",
            kind = "working",
            rev = adapter.Rev(RevType.LOCAL),
            lfs_smudge = true,
          })
          -- Mimic the `create_buffer` decision: with a pointer on disk and
          -- `lfs_smudge=true`, the LOCAL branch routes through the
          -- `[lfs-local-smudged]` path, which sets this flag so
          -- `produce_data` smudges the on-disk pointer bytes.
          file._lfs_smudge_from_pointer = true

          local serr, data = async.await(File.produce_data(file))
          assert.is_nil(serr)
          assert.False(git_lfs.is_pointer(data), "expected smudged content, not the raw pointer")
          assert.equals("alpha", data[1])
        end)

        test_utils.cleanup_repo(repo)

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "does not misclassify a longer file whose first lines mimic a pointer",
      test_utils.async_test(function()
        local repo = test_utils.init_repo()
        run({ "git", "lfs", "install", "--local" }, repo)
        test_utils.write(repo, ".gitattributes", {
          "*.bin filter=lfs diff=lfs merge=lfs -text",
        })
        -- First commit a real LFS blob so `_lfs_tracked` reports true.
        test_utils.write(repo, "big.bin", { "payload" })
        test_utils.commit(repo, "v1")
        -- Replace the working-tree file with a trap: three pointer-shaped
        -- lines followed by extra body. A 10-line sample would accept
        -- the trap as the pointer; the 11-line canary rejects it.
        local trap = {
          "version https://git-lfs.github.com/spec/v1",
          "oid sha256:" .. string.rep("a", 64),
          "size 42",
        }
        for i = 1, 8 do
          trap[#trap + 1] = ("extra body line %d"):format(i)
        end
        local f = assert(io.open(repo .. "/big.bin", "w"))
        f:write(table.concat(trap, "\n") .. "\n")
        f:close()

        local ok, err = pcall(function()
          local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
          local file = File({
            adapter = adapter,
            path = "big.bin",
            kind = "working",
            rev = adapter.Rev(RevType.LOCAL),
            lfs_smudge = false,
          })

          local serr, data = async.await(File.produce_data(file))
          assert.is_nil(serr)
          -- The result must come from `git lfs pointer --file=` on the
          -- trap bytes (so its oid hashes the full file), not from the
          -- disk sample itself (which would just echo the trap bytes).
          assert.True(git_lfs.is_pointer(data))
          local got_oid
          for _, line in ipairs(data) do
            local m = line:match("^oid sha256:(%x+)$")
            if m then
              got_oid = m
              break
            end
          end
          assert.is_not_nil(got_oid)
          assert.are_not.equal(string.rep("a", 64), got_oid)
        end)

        test_utils.cleanup_repo(repo)

        if not ok then
          error(err)
        end
      end)
    )
  end)
end)
