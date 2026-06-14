local async = require("diffview.async")
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local Job = require("diffview.job").Job
local RevType = require("diffview.vcs.rev").RevType
local test_utils = require("diffview.tests.helpers")

local run = test_utils.run

--- Create a temporary git repo with one commit and an adapter for it.
local function make_repo_and_adapter()
  local repo = test_utils.make_repo()

  local adapter = GitAdapter({
    toplevel = repo,
    cpath = repo,
    path_args = {},
  })

  return repo, adapter
end

describe("diffview.vcs.adapters.git", function()
  describe("get_show_args", function()
    it(
      "includes --no-show-signature",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local head = run({ "git", "rev-parse", "HEAD" }, repo)
          local rev = GitRev(RevType.COMMIT, head)
          local args = adapter:get_show_args("init.txt", rev)

          local found = false
          for _, arg in ipairs(args) do
            if arg == "--no-show-signature" then
              found = true
              break
            end
          end

          assert.True(found, "get_show_args must include --no-show-signature")
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

    it(
      "includes --no-show-signature when rev is nil",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local args = adapter:get_show_args("init.txt", nil)

          local found = false
          for _, arg in ipairs(args) do
            if arg == "--no-show-signature" then
              found = true
              break
            end
          end

          assert.True(found, "get_show_args must include --no-show-signature even with nil rev")
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
  end)

  describe("get_log_args", function()
    it(
      "includes --no-show-signature",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local args = adapter:get_log_args({})

          local found = false
          for _, arg in ipairs(args) do
            if arg == "--no-show-signature" then
              found = true
              break
            end
          end

          assert.True(found, "get_log_args must include --no-show-signature")
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
  end)

  describe("show_untracked", function()
    it(
      "returns true when left is STAGE and right is LOCAL",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local left = GitRev(RevType.STAGE, 0)
          local right = GitRev(RevType.LOCAL)
          local result = adapter:show_untracked({ revs = { left = left, right = right } })
          assert.is_true(result)
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

    it(
      "returns false when left is COMMIT and right is LOCAL",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local head = run({ "git", "rev-parse", "HEAD" }, repo)
          local left = GitRev(RevType.COMMIT, head)
          local right = GitRev(RevType.LOCAL)
          local result = adapter:show_untracked({ revs = { left = left, right = right } })
          assert.is_false(result)
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

    it(
      "returns false when user config show_untracked is false (STAGE vs LOCAL)",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local left = GitRev(RevType.STAGE, 0)
          local right = GitRev(RevType.LOCAL)
          local result = adapter:show_untracked({
            revs = { left = left, right = right },
            dv_opt = { show_untracked = false },
          })
          assert.is_false(result)
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
  end)

  it(
    "handles LOCAL..COMMIT binary stats without crashing",
    test_utils.async_test(function()
      local repo = vim.fn.tempname()
      assert.equals(1, vim.fn.mkdir(repo, "p"))

      local ok, err = pcall(function()
        run({ "git", "init", "-q" }, repo)
        run({ "git", "config", "user.name", "Diffview Test" }, repo)
        run({ "git", "config", "user.email", "diffview@test.local" }, repo)

        local path = repo .. "/bin.dat"
        local f = assert(io.open(path, "wb"))
        f:write(string.char(0, 1, 2, 3))
        f:close()

        run({ "git", "add", "bin.dat" }, repo)
        run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" }, repo)

        f = assert(io.open(path, "wb"))
        f:write(string.char(0, 1, 9, 3))
        f:close()

        local adapter = GitAdapter({
          toplevel = repo,
          cpath = repo,
          path_args = {},
        })

        local head = run({ "git", "rev-parse", "HEAD" }, repo)
        local left = GitRev(RevType.LOCAL)
        local right = GitRev(RevType.COMMIT, head)
        local args = adapter:rev_to_args(left, right)

        local tracked_err, files = async.await(
          adapter:tracked_files(
            left,
            right,
            args,
            "working",
            { default_layout = Diff2, merge_layout = Diff2 }
          )
        )

        assert.is_nil(tracked_err)
        assert.is_true(#files > 0)

        local found = false
        for _, file in ipairs(files) do
          if file.path == "bin.dat" then
            found = true
            assert.is_nil(file.stats)
          end
        end

        assert.True(found)
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

  describe("merge-base failure during rebase --root", function()
    it(
      "falls back to NULL_TREE_SHA when merge-base fails",
      test_utils.async_test(function()
        -- Simulate an initial-commit rebase scenario where merge-base has no
        -- common ancestor.  We create two independent repos and graft an orphan
        -- branch so that "git merge-base" exits non-zero.
        local repo = vim.fn.tempname()
        assert.equals(1, vim.fn.mkdir(repo, "p"))

        local ok, err = pcall(function()
          run({ "git", "init", "-q" }, repo)
          run({ "git", "config", "user.name", "Diffview Test" }, repo)
          run({ "git", "config", "user.email", "diffview@test.local" }, repo)

          -- Create a commit on the default branch.
          local path = repo .. "/a.txt"
          local f = assert(io.open(path, "w"))
          f:write("a\n")
          f:close()
          run({ "git", "add", "a.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "first" }, repo)
          local main_sha = run({ "git", "rev-parse", "HEAD" }, repo)

          -- Create an orphan branch with an unrelated history.  Remove tracked
          -- files so the index is clean for the orphan commit.
          run({ "git", "checkout", "--orphan", "orphan" }, repo)
          run({ "git", "rm", "-rf", "." }, repo)
          local p2 = repo .. "/b.txt"
          f = assert(io.open(p2, "w"))
          f:write("b\n")
          f:close()
          run({ "git", "add", "b.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "orphan" }, repo)
          local orphan_sha = run({ "git", "rev-parse", "HEAD" }, repo)

          -- Confirm that merge-base between the two disjoint roots fails.
          local mb_result = vim
            .system({ "git", "merge-base", main_sha, orphan_sha }, { cwd = repo, text = true })
            :wait()
          assert.is_not.equal(0, mb_result.code, "merge-base should fail for disjoint histories")

          -- Verify that NULL_TREE_SHA is the expected fallback constant.
          assert.equals(
            "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
            GitRev.NULL_TREE_SHA,
            "NULL_TREE_SHA must be the canonical git empty tree"
          )

          -- Verify that a null-tree rev can be constructed from the constant.
          local null_rev = GitRev.new_null_tree()
          assert.equals(RevType.COMMIT, null_rev.type)
          assert.equals(GitRev.NULL_TREE_SHA, null_rev:object_name())
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
  end)

  describe("--merge-base option in parse_revs", function()
    it(
      "uses merge-base when the flag is set",
      test_utils.async_test(function()
        local repo = vim.fn.tempname()
        assert.equals(1, vim.fn.mkdir(repo, "p"))

        local ok, err = pcall(function()
          run({ "git", "init", "-q" }, repo)
          run({ "git", "config", "user.name", "Diffview Test" }, repo)
          run({ "git", "config", "user.email", "diffview@test.local" }, repo)

          -- Create two commits on the default branch.
          local path = repo .. "/a.txt"
          local f = assert(io.open(path, "w"))
          f:write("a\n")
          f:close()
          run({ "git", "add", "a.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base" }, repo)
          local base_sha = run({ "git", "rev-parse", "HEAD" }, repo)

          -- Create a feature branch diverging from base.
          run({ "git", "checkout", "-b", "feature" }, repo)
          f = assert(io.open(path, "w"))
          f:write("a-feature\n")
          f:close()
          run({ "git", "add", "a.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "feature" }, repo)
          local feature_sha = run({ "git", "rev-parse", "HEAD" }, repo)

          -- Advance the default branch so HEAD diverges from the feature branch.
          run({ "git", "checkout", "-" }, repo)
          f = assert(io.open(path, "w"))
          f:write("a-main\n")
          f:close()
          run({ "git", "add", "a.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "main-advance" }, repo)

          local adapter = GitAdapter({
            toplevel = repo,
            cpath = repo,
            path_args = {},
          })

          -- Without merge_base, parse_revs should use the ref directly.
          local left_plain, right_plain = adapter:parse_revs(feature_sha, {})
          assert.is_not_nil(left_plain)
          assert.equals(feature_sha, left_plain:object_name())
          assert.equals(RevType.LOCAL, right_plain.type)

          -- With merge_base, parse_revs should resolve to the merge-base of HEAD
          -- and the given ref, which is base_sha.
          local left_mb, right_mb = adapter:parse_revs(feature_sha, { merge_base = true })
          assert.is_not_nil(left_mb)
          assert.equals(base_sha, left_mb:object_name())
          assert.equals(RevType.LOCAL, right_mb.type)
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

    it(
      "falls back to the ref when merge-base fails",
      test_utils.async_test(function()
        local repo = vim.fn.tempname()
        assert.equals(1, vim.fn.mkdir(repo, "p"))

        local ok, err = pcall(function()
          run({ "git", "init", "-q" }, repo)
          run({ "git", "config", "user.name", "Diffview Test" }, repo)
          run({ "git", "config", "user.email", "diffview@test.local" }, repo)

          -- Create a commit on the default branch and record its name.
          local default_branch = run({ "git", "branch", "--show-current" }, repo)
          local path = repo .. "/a.txt"
          local f = assert(io.open(path, "w"))
          f:write("a\n")
          f:close()
          run({ "git", "add", "a.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "first" }, repo)

          -- Create an orphan branch with disjoint history.  Remove tracked files
          -- so the index is clean for the orphan commit.
          run({ "git", "checkout", "--orphan", "orphan" }, repo)
          run({ "git", "rm", "-rf", "." }, repo)
          local p2 = repo .. "/b.txt"
          f = assert(io.open(p2, "w"))
          f:write("b\n")
          f:close()
          run({ "git", "add", "b.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "orphan" }, repo)
          local orphan_sha = run({ "git", "rev-parse", "HEAD" }, repo)

          -- Switch back to the default branch.
          run({ "git", "checkout", default_branch }, repo)

          local adapter = GitAdapter({
            toplevel = repo,
            cpath = repo,
            path_args = {},
          })

          -- With merge_base=true but disjoint histories, parse_revs should fall
          -- back to using the ref itself.
          local left, right = adapter:parse_revs(orphan_sha, { merge_base = true })
          assert.is_not_nil(left)
          assert.equals(orphan_sha, left:object_name())
          assert.equals(RevType.LOCAL, right.type)
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
  end)

  describe("GIT_OPTIONAL_LOCKS in job environment", function()
    it("includes GIT_OPTIONAL_LOCKS=0 when env is provided", function()
      local job = Job({
        command = "echo",
        args = { "test" },
        env = { FOO = "bar" },
      })

      local found = false
      for _, entry in ipairs(job.env) do
        if entry == "GIT_OPTIONAL_LOCKS=0" then
          found = true
          break
        end
      end

      assert.True(found, "Job env must include GIT_OPTIONAL_LOCKS=0")
    end)

    it("includes GIT_OPTIONAL_LOCKS=0 when env is defaulted from os_environ", function()
      local job = Job({
        command = "echo",
        args = { "test" },
      })

      local found = false
      for _, entry in ipairs(job.env) do
        if entry == "GIT_OPTIONAL_LOCKS=0" then
          found = true
          break
        end
      end

      assert.True(found, "Job env must include GIT_OPTIONAL_LOCKS=0 even with default env")
    end)

    it("preserves other env vars alongside GIT_OPTIONAL_LOCKS", function()
      local job = Job({
        command = "echo",
        args = { "test" },
        env = { MY_VAR = "hello" },
      })

      local found_locks = false
      local found_custom = false
      for _, entry in ipairs(job.env) do
        if entry == "GIT_OPTIONAL_LOCKS=0" then
          found_locks = true
        end
        if entry == "MY_VAR=hello" then
          found_custom = true
        end
      end

      assert.True(found_locks, "GIT_OPTIONAL_LOCKS=0 must be present")
      assert.True(found_custom, "Custom env var must also be present")
    end)
  end)

  describe("parse_fh_data pin_local", function()
    -- Build a (state, data, commit) triple that exercises a single-file
    -- modification commit. The namestat/numstat strings mirror what
    -- `git log --raw --numstat` emits for `:100644 100644 <a> <b> M\tfoo.txt`.
    local function setup_state_and_data(adapter, layout_opt)
      local state = {
        path_args = { "foo.txt" },
        log_options = { L = {} },
        prepared_log_opts = { base = nil },
        layout_opt = layout_opt,
        single_file = true,
      }

      local data = {
        left_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        right_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        namestat = { ":100644 100644 aaaaaaa bbbbbbb M\tfoo.txt" },
        numstat = { "1\t1\tfoo.txt" },
      }

      -- A bare table is enough; parse_fh_data only forwards `commit` into
      -- the LogEntry it produces, never reads any field.
      local commit = {}

      return state, data, commit
    end

    it(
      "uses commit-side rev for b when pin_local is unset",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local state, data, commit = setup_state_and_data(adapter, {
            default_layout = Diff2,
          })

          local success, log_entry = adapter:parse_fh_data(data, commit, state)
          assert.True(success)
          ---@cast log_entry LogEntry

          local b_rev = log_entry.files[1].layout.b.file.rev
          assert.equals(RevType.COMMIT, b_rev.type)
          assert.equals(data.right_hash, b_rev.commit)
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

    it(
      "sets revs.b to LOCAL when state.layout_opt.pin_local is true",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local state, data, commit = setup_state_and_data(adapter, {
            default_layout = Diff2,
            pin_local = true,
          })

          local success, log_entry = adapter:parse_fh_data(data, commit, state)
          assert.True(success)
          ---@cast log_entry LogEntry

          local b_file = log_entry.files[1].layout.b.file
          assert.equals(RevType.LOCAL, b_file.rev.type)
          -- Without `pinned_path` the b-side falls back to the entry path,
          -- which is still the working-tree file in the no-rename case.
          assert.equals("foo.txt", b_file.path)

          -- pin_local diffs each commit against the working tree, so the
          -- a-side reads from this commit (not its parent).
          local a_rev = log_entry.files[1].layout.a.file.rev
          assert.equals(RevType.COMMIT, a_rev.type)
          assert.equals(data.right_hash, a_rev.commit)
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

    it(
      "reuses the layout_opt.pinned_b_file_for File for the b-side",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Stand-in for the view's pin_local cache: hand out a single
          -- distinguishable `vcs.File`-like instance regardless of path so
          -- we can assert it's the b-side that the FileEntry ended up with.
          -- Identity equality is what `Diff2*Pinned.shared_symbols` and
          -- the view's destruction path rely on.
          local shared = { path = "shared.txt", rev = adapter.Rev(RevType.LOCAL) }
          local lookups = {}
          local state, data, commit = setup_state_and_data(adapter, {
            default_layout = Diff2,
            pin_local = true,
            pinned_path = "renamed/foo.txt",
            pinned_b_file_for = function(path)
              table.insert(lookups, path)
              return shared
            end,
          })

          local success, log_entry = adapter:parse_fh_data(data, commit, state)
          assert.True(success)
          ---@cast log_entry LogEntry

          assert.equals(shared, log_entry.files[1].layout.b.file)
          -- Adapter resolves the path through pinned_path (when set) before
          -- asking the view for the File, so the view's cache stays keyed
          -- by working-tree paths.
          assert.same({ "renamed/foo.txt" }, lookups)
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

    -- In multi-file pin_local (`state.single_file = false`), `pinned_path`
    -- tracks the cursor's last file row -- not a per-entry rename anchor --
    -- so it must NOT route every entry's b-side to that one path. Each file
    -- must resolve its own working-tree File, otherwise switching rows in
    -- multi-file history would diff a different file's commit-side contents
    -- against the previously cursored working-tree file.
    it(
      "ignores layout_opt.pinned_path in multi-file mode (uses each entry's name)",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local lookups = {}
          local state = {
            path_args = { "alpha.txt", "beta.txt" },
            log_options = { L = {} },
            prepared_log_opts = { base = nil },
            layout_opt = {
              default_layout = Diff2,
              pin_local = true,
              pinned_path = "alpha.txt",
              pinned_b_file_for = function(path)
                table.insert(lookups, path)
                return { path = path, rev = adapter.Rev(RevType.LOCAL) }
              end,
            },
            single_file = false,
          }
          local data = {
            left_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            right_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            namestat = {
              ":100644 100644 aaaaaaa bbbbbbb M\talpha.txt",
              ":100644 100644 ccccccc ddddddd M\tbeta.txt",
            },
            numstat = { "1\t1\talpha.txt", "2\t2\tbeta.txt" },
          }

          local success, log_entry = adapter:parse_fh_data(data, {}, state)
          assert.True(success)
          ---@cast log_entry LogEntry

          assert.equals(2, #log_entry.files)
          -- Lookups happen in entry order; the universal pinned_path would
          -- have produced { "alpha.txt", "alpha.txt" } -- both routed to
          -- alpha's working-tree file. The fix uses each entry's name.
          assert.same({ "alpha.txt", "beta.txt" }, lookups)
          assert.equals("alpha.txt", log_entry.files[1].layout.b.file.path)
          assert.equals("beta.txt", log_entry.files[2].layout.b.file.path)
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
  end)

  describe("build_local_log_entry", function()
    it(
      "returns nil on a clean working tree",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local log_entry = adapter:build_local_log_entry({
            path_args = {},
            layout_opt = { default_layout = Diff2 },
            single_file = false,
          })

          assert.is_nil(log_entry)
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

    it(
      "builds a synthetic LogEntry with revs.b = LOCAL when the tree is dirty",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Modify the init file so `git diff --name-status HEAD` reports it.
          local f = assert(io.open(repo .. "/init.txt", "w"))
          f:write("changed\n")
          f:close()

          local log_entry = adapter:build_local_log_entry({
            path_args = {},
            layout_opt = { default_layout = Diff2 },
            single_file = false,
          })

          assert.is_not_nil(log_entry)
          ---@cast log_entry LogEntry
          assert.is_nil(log_entry.commit.hash)
          assert.equals("Working tree", log_entry.commit.subject)
          assert.equals("now", log_entry.commit.rel_date)
          -- The synthetic commit must populate `iso_date` (and the
          -- `time_offset` fallback that feeds it). `render.lua` concatenates
          -- `iso_date` into the panel header when `date_format = "iso"` (and
          -- in the `auto` branch for older commits), so a nil here would
          -- abort the file-history panel render. The synth is constructed
          -- via the adapter's `Commit` alias (`GitCommit`/`HgCommit`), whose
          -- `init` derives `iso_date` from `time` regardless of whether
          -- `time_offset` was provided.
          assert.is_string(log_entry.commit.iso_date)
          assert.equals(0, log_entry.commit.time_offset)
          assert.equals(1, #log_entry.files)

          local file = log_entry.files[1]
          assert.equals("init.txt", file.path)
          assert.equals("M", file.status)
          assert.equals(RevType.LOCAL, file.revs.b.type)
          assert.equals(RevType.COMMIT, file.revs.a.type)
          -- Without this flag, the pinned `Diff2` layout's `should_null`
          -- would invert the standard semantics for revs.a (treating it as
          -- the commit being browsed) and mishandle added/deleted files in
          -- the synthetic entry. See `Diff2HorPinned.should_null`.
          assert.is_true(file.revs.a.pin_local_synthetic)
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

    -- The synth's b-side cache key must match `parse_fh_data`'s key in
    -- single-file mode (`layout_opt.pinned_path`), otherwise an absolute
    -- or non-canonical pathspec produces different `vcs.File` instances
    -- for the synth and the streamed entries, breaking pinned-buffer reuse.
    it(
      "keys b-side by layout_opt.pinned_path in single-file mode",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local f = assert(io.open(repo .. "/init.txt", "w"))
          f:write("changed\n")
          f:close()

          local lookups = {}
          local shared = { path = "shared.txt", rev = adapter.Rev(RevType.LOCAL) }
          local log_entry = adapter:build_local_log_entry({
            path_args = { "init.txt" },
            -- pinned_path is the user's working-tree spelling; entry.name
            -- here is git's emitted relative name. Use a deliberately
            -- different value so the test catches the mismatch.
            layout_opt = {
              default_layout = Diff2,
              pin_local = true,
              pinned_path = repo .. "/init.txt",
              pinned_b_file_for = function(path)
                table.insert(lookups, path)
                return shared
              end,
            },
            single_file = true,
          })

          assert.is_not_nil(log_entry)
          ---@cast log_entry LogEntry
          -- The cache key matches what `parse_fh_data` would use for real
          -- entries in single-file mode; both feed the same `vcs.File`.
          assert.same({ repo .. "/init.txt" }, lookups)
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

    it(
      "respects path_args, omitting unmodified paths",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Add a second tracked file, then modify only `init.txt`.
          local g = assert(io.open(repo .. "/other.txt", "w"))
          g:write("other\n")
          g:close()
          run({ "git", "add", "other.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "add other" }, repo)

          local f = assert(io.open(repo .. "/init.txt", "w"))
          f:write("changed\n")
          f:close()

          -- Pass only `other.txt` as path_args; `init.txt` should be ignored.
          local log_entry = adapter:build_local_log_entry({
            path_args = { "other.txt" },
            layout_opt = { default_layout = Diff2 },
            single_file = true,
          })

          assert.is_nil(log_entry, "expected nil for clean path filter")
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

    it(
      "builds entries for multiple modified paths",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local g = assert(io.open(repo .. "/other.txt", "w"))
          g:write("other\n")
          g:close()
          run({ "git", "add", "other.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "add other" }, repo)

          for _, name in ipairs({ "init.txt", "other.txt" }) do
            local f = assert(io.open(repo .. "/" .. name, "w"))
            f:write("changed\n")
            f:close()
          end

          local log_entry = adapter:build_local_log_entry({
            path_args = { "init.txt", "other.txt" },
            layout_opt = { default_layout = Diff2 },
            single_file = false,
          })

          assert.is_not_nil(log_entry)
          ---@cast log_entry LogEntry
          assert.equals(2, #log_entry.files)
          assert.is_false(log_entry.single_file)

          local paths = {}
          for _, file in ipairs(log_entry.files) do
            paths[file.path] = true
            assert.equals(RevType.LOCAL, file.revs.b.type)
          end
          assert.is_true(paths["init.txt"])
          assert.is_true(paths["other.txt"])
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

    -- A single directory pathspec produces a multi-file history (the
    -- streaming adapter uses `is_single_file` to decide); the synthetic
    -- entry must follow the same rule, otherwise `panel.single_file`
    -- gets set to `true` from the synth and the rest of the panel
    -- (folding, navigation, header rendering) is rendered in the wrong
    -- mode.
    it(
      "marks single_file=false for a single-directory pathspec",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          assert.equals(1, vim.fn.mkdir(repo .. "/sub", "p"))
          local g = assert(io.open(repo .. "/sub/a.txt", "w"))
          g:write("a\n")
          g:close()
          local h = assert(io.open(repo .. "/sub/b.txt", "w"))
          h:write("b\n")
          h:close()
          run({ "git", "add", "sub" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "add sub" }, repo)

          for _, name in ipairs({ "sub/a.txt", "sub/b.txt" }) do
            local f = assert(io.open(repo .. "/" .. name, "w"))
            f:write("changed\n")
            f:close()
          end

          -- Use the absolute path so the directory check inside
          -- `build_local_log_entry` doesn't depend on the test runner's
          -- cwd (real callers usually invoke from the repo root, where a
          -- relative pathspec would also resolve).
          local log_entry = adapter:build_local_log_entry({
            path_args = { repo .. "/sub" },
            layout_opt = { default_layout = Diff2 },
            single_file = false,
          })

          assert.is_not_nil(log_entry)
          ---@cast log_entry LogEntry
          -- `#path_args == 1` would have wrongly returned `true` here
          -- because the pathspec is a single argument; the directory
          -- check downgrades to multi-file.
          assert.is_false(log_entry.single_file)
          assert.equals(2, #log_entry.files)
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
  end)

  -- `history_scope` is the single source of truth for "is this history
  -- single-file, and if so, which path?". Three call sites consult it
  -- (pin_local's `pinned_path` seed, the synthetic entry's `single_file`
  -- field, and the synth's `git diff` path filter) so each scope question
  -- now has one answer instead of three near-duplicates.
  describe("history_scope", function()
    it(
      "recognises a single file pathspec",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          local scope = adapter:history_scope({ "init.txt" }, {})
          assert.equals(true, scope.single_file)
          assert.equals("init.txt", scope.path)
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

    it(
      "downgrades a single-directory pathspec to multi-file",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          assert.equals(1, vim.fn.mkdir(repo .. "/sub", "p"))
          local scope = adapter:history_scope({ repo .. "/sub" }, {})
          assert.equals(false, scope.single_file)
          assert.is_nil(scope.path)
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

    -- Line-trace history: the path lives in the L spec, not in
    -- `path_args` (which is empty in `-L` mode). Without this branch,
    -- `pin_local`'s rename anchor would fall back to each commit's
    -- `entry.path_new` and stop following the working-tree path.
    it(
      "extracts the path from a single -L spec",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          local scope = adapter:history_scope(
            {},
            { L = { "10,20:src/foo.lua" } } --[[@as GitLogOptions ]]
          )
          assert.equals(true, scope.single_file)
          assert.equals("src/foo.lua", scope.path)
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

    it(
      "downgrades multiple -L specs targeting different paths",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          local scope = adapter:history_scope({}, {
            L = { ":sym:src/a.lua", ":sym:src/b.lua" },
          } --[[@as GitLogOptions ]])
          assert.equals(false, scope.single_file)
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

    -- A malformed L spec (no `:`, or empty path after the last `:`) used
    -- to fall through and return `{ single_file = true, path = nil }`,
    -- which then seeded `pinned_path` with nil and broke downstream
    -- cache-key resolution. The scope must downgrade to multi-file so
    -- pin_local doesn't try to anchor on a missing path.
    it(
      "downgrades a malformed -L spec to multi-file",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          local no_colon = adapter:history_scope({}, { L = { "garbage" } } --[[@as GitLogOptions ]])
          assert.equals(false, no_colon.single_file)
          assert.is_nil(no_colon.path)

          local empty_path = adapter:history_scope(
            {},
            { L = { "10,20:" } } --[[@as GitLogOptions ]]
          )
          assert.equals(false, empty_path.single_file)
          assert.is_nil(empty_path.path)
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

    -- Pathspec resolution: a single argument like `*.txt` or
    -- `:(glob)**/*.txt` isn't a literal path, so using it raw as
    -- `pinned_path` would key the pin_local cache by the pattern and
    -- the RHS would try to open a LOCAL file named after the pattern.
    -- `history_scope` resolves through `git ls-files` to git's emitted
    -- relative name when exactly one tracked file matches.
    it(
      "resolves a glob pathspec to the matched file when exactly one matches",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          local scope = adapter:history_scope({ "*.txt" }, {})
          -- `init.txt` is the only tracked file in `make_repo_and_adapter`.
          assert.equals(true, scope.single_file)
          assert.equals("init.txt", scope.path)
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

    it(
      "downgrades a glob pathspec that matches multiple files",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          -- Add a second tracked file so `*.txt` matches both.
          local f = assert(io.open(repo .. "/other.txt", "w"))
          f:write("other\n")
          f:close()
          run({ "git", "add", "other.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "add other" }, repo)

          local scope = adapter:history_scope({ "*.txt" }, {})
          assert.equals(false, scope.single_file)
          assert.is_nil(scope.path)
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

    -- A single-pathspec history whose path isn't tracked today (deleted /
    -- renamed away / never added) is still single-file: `is_single_file()`
    -- returns true for `<2` matches, so `history_scope` must agree or
    -- pin_local stops seeding `pinned_path` for valid single-path
    -- histories of removed files.
    it(
      "treats a single pathspec with zero matches as single-file with the literal path",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          local scope = adapter:history_scope({ "deleted.txt" }, {})
          assert.equals(true, scope.single_file)
          assert.equals("deleted.txt", scope.path)
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

    -- An absolute path canonicalises through `ls-files` to git's
    -- emitted relative spelling. Both spellings then key the pin_local
    -- cache the same way, so the synth and streamed entries share one
    -- view-owned `vcs.File`.
    it(
      "canonicalises absolute paths to git's relative emission",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          local scope = adapter:history_scope({ repo .. "/init.txt" }, {})
          assert.equals(true, scope.single_file)
          assert.equals("init.txt", scope.path)
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

    it(
      "returns multi-file for an empty path_args (no -L)",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()
        local ok, err = pcall(function()
          local scope = adapter:history_scope({}, {})
          assert.equals(false, scope.single_file)
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
  end)

  describe("fh_compute_pushed_set", function()
    it(
      "marks ancestors of a remote-tracking ref as pushed, not only the tip",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Build a small linear history of three commits.
          local hashes = {}
          for i = 1, 3 do
            local p = ("%s/f%d.txt"):format(repo, i)
            local f = assert(io.open(p, "w"))
            f:write(("file %d\n"):format(i))
            f:close()
            run({ "git", "add", ("f%d.txt"):format(i) }, repo)
            run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c" .. i }, repo)
            hashes[i] = run({ "git", "rev-parse", "HEAD" }, repo)
          end

          -- Simulate a remote-tracking ref pinned at the second commit, so the
          -- third commit is local-only while the first two are "pushed".
          run({ "git", "update-ref", "refs/remotes/origin/main", hashes[2] }, repo)

          local set = adapter:fh_compute_pushed_set({})
          assert.is_not_nil(set, "fh_compute_pushed_set should not return nil on success")
          assert.True(set[hashes[1]], "first commit must be in the pushed set")
          assert.True(set[hashes[2]], "second commit (the remote tip) must be in the pushed set")
          assert.is_nil(set[hashes[3]], "third commit must NOT be in the pushed set")
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

    it(
      "returns an empty set in a repository with no remote-tracking refs",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local set = adapter:fh_compute_pushed_set({})
          assert.is_not_nil(set)
          assert.is_nil(next(set), "set must be empty when no refs/remotes/ exist")
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
  end)

  -- `--follow` walks a single-file history through renames, so the streamed
  -- commits include those that touched the file under previous names. The
  -- initial `fh_compute_pushed_set` query only knows about the current path,
  -- so `fh_extend_pushed_set` is the on-demand top-up for the old name.
  describe("fh_extend_pushed_set", function()
    it(
      "adds hashes that touched the pre-rename path to the existing set",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Build a small history that renames a file:
          --   c1: create  original.txt
          --   c2: modify  original.txt
          --   c3: rename  original.txt -> renamed.txt
          --   c4: modify  renamed.txt  (local-only)
          local original = repo .. "/original.txt"
          local f = assert(io.open(original, "w"))
          f:write("v1\n")
          f:close()
          run({ "git", "add", "original.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c1" }, repo)
          local c1 = run({ "git", "rev-parse", "HEAD" }, repo)

          f = assert(io.open(original, "w"))
          f:write("v2\n")
          f:close()
          run({ "git", "add", "original.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c2" }, repo)
          local c2 = run({ "git", "rev-parse", "HEAD" }, repo)

          run({ "git", "mv", "original.txt", "renamed.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c3" }, repo)
          local c3 = run({ "git", "rev-parse", "HEAD" }, repo)

          -- Pin the remote-tracking ref at c3 so c1..c3 are "pushed".
          run({ "git", "update-ref", "refs/remotes/origin/main", c3 }, repo)

          f = assert(io.open(repo .. "/renamed.txt", "w"))
          f:write("v3\n")
          f:close()
          run({ "git", "add", "renamed.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c4" }, repo)
          local c4 = run({ "git", "rev-parse", "HEAD" }, repo)

          -- Mirror the worker's setup: initial query is for the current path
          -- only, so c1 and c2 (which touched the old name only) must be
          -- missing from the initial set.
          local state = {
            pushed_set = adapter:fh_compute_pushed_set({ "renamed.txt" }),
            pushed_paths_seen = { ["renamed.txt"] = true },
          }
          assert.is_not_nil(state.pushed_set)
          assert.True(state.pushed_set[c3], "rename commit must be in initial set")
          assert.is_nil(state.pushed_set[c2], "pre-rename c2 must be absent initially")
          assert.is_nil(state.pushed_set[c1], "pre-rename c1 must be absent initially")
          assert.is_nil(state.pushed_set[c4], "local-only c4 must never be present")

          adapter:fh_extend_pushed_set(state, "original.txt")

          assert.True(state.pushed_set[c1], "c1 must be in the extended set")
          assert.True(state.pushed_set[c2], "c2 must be in the extended set")
          assert.True(state.pushed_set[c3], "c3 must still be in the set")
          assert.is_nil(state.pushed_set[c4], "c4 must remain absent (local-only)")
          assert.True(state.pushed_paths_seen["original.txt"])
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

    it(
      "is idempotent: a second call with the same path does not rerun rev-list",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        -- Install the call counter outside the `pcall` so we can restore the
        -- original method in a guaranteed cleanup step, even if an assertion
        -- inside the body throws.
        local calls = 0
        local real = adapter.fh_compute_pushed_set
        adapter.fh_compute_pushed_set = function(self, path_args)
          calls = calls + 1
          return real(self, path_args)
        end

        local ok, err = pcall(function()
          local state = {
            pushed_set = {},
            pushed_paths_seen = {},
          }

          adapter:fh_extend_pushed_set(state, "original.txt")
          assert.equals(1, calls)
          assert.True(state.pushed_paths_seen["original.txt"])

          adapter:fh_extend_pushed_set(state, "original.txt")
          assert.equals(1, calls, "second call must not invoke fh_compute_pushed_set")
        end)

        adapter.fh_compute_pushed_set = real

        vim.schedule(function()
          pcall(vim.fn.delete, repo, "rf")
        end)
        async.await(async.scheduler())

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "is a no-op when the pushed set was never computed",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Mirrors `subject_highlight ~= "ref_aware"`: the worker skips the
          -- initial query and leaves both fields nil. The extension must not
          -- materialise a set in that case.
          local state = {}

          adapter:fh_extend_pushed_set(state, "original.txt")

          assert.is_nil(state.pushed_set)
          assert.is_nil(state.pushed_paths_seen)
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
  end)

  describe("_find_main_branch_refs", function()
    it(
      "returns an empty list when no main/master refs exist",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- The branch from `git init` may be `main` or `master` depending on
          -- the user's `init.defaultBranch`. Rename it out of the way so we
          -- can assert "no main refs" deterministically.
          run({ "git", "branch", "-m", "feature" }, repo)

          local refs = adapter:_find_main_branch_refs()
          assert.equals(0, #refs)
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

    it(
      "finds local main/master and remote-tracking variants",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Force a stable starting state: rename whatever the default
          -- branch is so it doesn't get picked up by accident, then set up
          -- exactly the refs we want to assert against.
          run({ "git", "branch", "-m", "scratch" }, repo)
          local head = run({ "git", "rev-parse", "HEAD" }, repo)
          run({ "git", "update-ref", "refs/heads/main", head }, repo)
          run({ "git", "update-ref", "refs/remotes/origin/master", head }, repo)

          local refs = adapter:_find_main_branch_refs()
          table.sort(refs)
          assert.equals(2, #refs)
          assert.equals("refs/heads/main", refs[1])
          assert.equals("refs/remotes/origin/master", refs[2])
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
  end)

  describe("fh_compute_merged_set", function()
    it(
      "marks ancestors of a main branch ref as merged, not only the tip",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Build a small linear history of three commits, then pin a "main"
          -- ref at the second so the third is unmerged.
          local hashes = {}
          for i = 1, 3 do
            local p = ("%s/f%d.txt"):format(repo, i)
            local f = assert(io.open(p, "w"))
            f:write(("file %d\n"):format(i))
            f:close()
            run({ "git", "add", ("f%d.txt"):format(i) }, repo)
            run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c" .. i }, repo)
            hashes[i] = run({ "git", "rev-parse", "HEAD" }, repo)
          end

          run({ "git", "update-ref", "refs/heads/main", hashes[2] }, repo)

          local set = adapter:fh_compute_merged_set({ "refs/heads/main" }, {})
          assert.is_not_nil(set, "fh_compute_merged_set must not return nil on success")
          assert.True(set[hashes[1]], "first commit must be in the merged set")
          assert.True(set[hashes[2]], "second commit (the main tip) must be in the merged set")
          assert.is_nil(set[hashes[3]], "third commit must NOT be in the merged set")
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

    it(
      "returns an empty set when no main refs are supplied",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          local set = adapter:fh_compute_merged_set({}, {})
          assert.is_not_nil(set)
          assert.is_nil(next(set), "set must be empty when there are no main refs to walk")
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
  end)

  -- Mirrors `fh_extend_pushed_set`: when `--follow` (or line-trace) walks past
  -- a rename, the initial merged-set query missed the old name; the extension
  -- backfills it.
  describe("fh_extend_merged_set", function()
    it(
      "adds hashes that touched the pre-rename path to the existing set",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Same rename scaffold as the pushed-set test, but pin `main` (not
          -- a remote ref) at c3 so c1..c3 count as "merged".
          local original = repo .. "/original.txt"
          local f = assert(io.open(original, "w"))
          f:write("v1\n")
          f:close()
          run({ "git", "add", "original.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c1" }, repo)
          local c1 = run({ "git", "rev-parse", "HEAD" }, repo)

          f = assert(io.open(original, "w"))
          f:write("v2\n")
          f:close()
          run({ "git", "add", "original.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c2" }, repo)
          local c2 = run({ "git", "rev-parse", "HEAD" }, repo)

          run({ "git", "mv", "original.txt", "renamed.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c3" }, repo)
          local c3 = run({ "git", "rev-parse", "HEAD" }, repo)

          f = assert(io.open(repo .. "/renamed.txt", "w"))
          f:write("v3\n")
          f:close()
          run({ "git", "add", "renamed.txt" }, repo)
          run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "c4" }, repo)
          local c4 = run({ "git", "rev-parse", "HEAD" }, repo)

          -- Pin `refs/heads/main` at c3 AFTER c4 is committed: if the default
          -- branch (per `init.defaultBranch`) is `main`, an earlier `update-ref`
          -- would be silently advanced when the next commit lands on HEAD.
          run({ "git", "update-ref", "refs/heads/main", c3 }, repo)

          local main_refs = { "refs/heads/main" }
          local state = {
            main_refs = main_refs,
            merged_set = adapter:fh_compute_merged_set(main_refs, { "renamed.txt" }),
            merged_paths_seen = { ["renamed.txt"] = true },
          }
          assert.is_not_nil(state.merged_set)
          assert.True(state.merged_set[c3], "rename commit must be in initial set")
          assert.is_nil(state.merged_set[c2], "pre-rename c2 must be absent initially")
          assert.is_nil(state.merged_set[c1], "pre-rename c1 must be absent initially")
          assert.is_nil(state.merged_set[c4], "local-only c4 must never be present")

          adapter:fh_extend_merged_set(state, "original.txt")

          assert.True(state.merged_set[c1], "c1 must be in the extended set")
          assert.True(state.merged_set[c2], "c2 must be in the extended set")
          assert.True(state.merged_set[c3], "c3 must still be in the set")
          assert.is_nil(state.merged_set[c4], "c4 must remain absent (local-only)")
          assert.True(state.merged_paths_seen["original.txt"])
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

    it(
      "is idempotent: a second call with the same path does not rerun rev-list",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local calls = 0
        local real = adapter.fh_compute_merged_set
        adapter.fh_compute_merged_set = function(self, main_refs, path_args)
          calls = calls + 1
          return real(self, main_refs, path_args)
        end

        local ok, err = pcall(function()
          local state = {
            main_refs = { "refs/heads/main" },
            merged_set = {},
            merged_paths_seen = {},
          }

          adapter:fh_extend_merged_set(state, "original.txt")
          assert.equals(1, calls)
          assert.True(state.merged_paths_seen["original.txt"])

          adapter:fh_extend_merged_set(state, "original.txt")
          assert.equals(1, calls, "second call must not invoke fh_compute_merged_set")
        end)

        adapter.fh_compute_merged_set = real

        vim.schedule(function()
          pcall(vim.fn.delete, repo, "rf")
        end)
        async.await(async.scheduler())

        if not ok then
          error(err)
        end
      end)
    )

    it(
      "is a no-op when the merged set was never computed",
      test_utils.async_test(function()
        local repo, adapter = make_repo_and_adapter()

        local ok, err = pcall(function()
          -- Mirrors `subject_highlight ~= "merge_aware"`: the worker skips the
          -- initial query and leaves the fields nil. The extension must not
          -- materialise a set in that case.
          local state = {}

          adapter:fh_extend_merged_set(state, "original.txt")

          assert.is_nil(state.merged_set)
          assert.is_nil(state.merged_paths_seen)
          assert.is_nil(state.main_refs)
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
  end)
end)
