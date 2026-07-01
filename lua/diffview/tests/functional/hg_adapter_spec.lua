local async = require("diffview.async")
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local HgAdapter = require("diffview.vcs.adapters.hg").HgAdapter
local RevType = require("diffview.vcs.rev").RevType
local helpers = require("diffview.tests.helpers")

local await = async.await
local eq = helpers.eq
local run = helpers.run

local function hg_available()
  return vim.fn.executable("hg") == 1
end

local function create_hg_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")

  run({ "hg", "init" }, repo)

  return {
    dir = repo,
    hg = function(args)
      local cmd = { "hg" }
      vim.list_extend(cmd, args)
      return run(cmd, repo)
    end,
    write = function(relpath, content)
      local dir = vim.fn.fnamemodify(repo .. "/" .. relpath, ":h")
      vim.fn.mkdir(dir, "p")
      local f = assert(io.open(repo .. "/" .. relpath, "w"))
      f:write(content)
      f:close()
    end,
    adapter = function()
      HgAdapter.bootstrap.done = true
      HgAdapter.bootstrap.ok = true
      return HgAdapter({
        toplevel = repo,
        path_args = {},
      })
    end,
    cleanup = function()
      pcall(vim.fn.delete, repo, "rf")
    end,
  }
end

describe("diffview.vcs.adapters.hg", function()
  -- ------------------------------------------------------------------
  -- Unit tests (no Mercurial installation needed)
  -- ------------------------------------------------------------------
  describe("HgRev", function()
    local HgRev = require("diffview.vcs.adapters.hg.rev").HgRev

    it("object_name returns the commit hash for COMMIT revs", function()
      local rev = HgRev(RevType.COMMIT, "abc123")
      eq("abc123", rev:object_name())
    end)

    it("new_null_tree creates a null rev", function()
      local rev = HgRev.new_null_tree()
      eq(HgRev.NULL_TREE_SHA, rev:object_name())
    end)
  end)

  describe("get_show_args", function()
    it("uses --rev flag to separate revision from path", function()
      local adapter = HgAdapter({ toplevel = "/tmp", path_args = {} })
      local HgRev = require("diffview.vcs.adapters.hg.rev").HgRev
      local rev = HgRev(RevType.COMMIT, "abc123")
      local args = adapter:get_show_args("src/main.lua", rev)

      -- Should produce: { "cat", "--rev", "abc123", "--", "src/main.lua" }
      assert.is_true(vim.tbl_contains(args, "cat"))
      assert.is_true(vim.tbl_contains(args, "--rev"))
      assert.is_true(vim.tbl_contains(args, "abc123"))
      assert.is_true(vim.tbl_contains(args, "src/main.lua"))

      -- The path must not have a revision appended to it.
      for _, arg in ipairs(args) do
        if arg == "src/main.lua" then
          assert.is_nil(arg:match("#"), "path should not contain revision specifier")
        end
      end
    end)
  end)

  describe("get_log_args", function()
    it("prepends user-configured global flags from `hg_cmd`", function()
      local adapter = HgAdapter({ toplevel = "/tmp", path_args = {} })
      adapter.get_command = function(_)
        return { "hg", "-R", "/some/path" }
      end
      local args = adapter:get_log_args({ "abc123" })

      -- `-R /some/path` must come before `log` so hg honours the flag.
      local log_idx
      for i, arg in ipairs(args) do
        if arg == "log" then
          log_idx = i
          break
        end
      end
      assert.is_not_nil(log_idx, "get_log_args must include the `log` subcommand")
      eq("-R", args[log_idx - 2])
      eq("/some/path", args[log_idx - 1])
    end)
  end)

  -- ------------------------------------------------------------------
  -- Integration tests: require hg
  -- ------------------------------------------------------------------
  describe("tracked_files", function()
    local repo

    before_each(function()
      if not hg_available() then
        pending("hg not installed")
        return
      end
      repo = create_hg_repo()
    end)

    after_each(function()
      if repo then
        repo.cleanup()
      end
    end)

    it(
      "lists modified, added, and removed files",
      helpers.async_test(function()
        if not hg_available() then
          pending("hg not installed")
          return
        end

        -- Initial commit.
        repo.write("src/main.lua", 'print("v1")\n')
        repo.write("src/utils.lua", "local M = {}\nreturn M\n")
        repo.hg({ "add", "src/main.lua", "src/utils.lua" })
        repo.hg({ "commit", "-m", "initial", "-u", "test <test@test.com>" })

        -- Working copy changes: modify, remove, add.
        repo.write("src/main.lua", 'print("v2")\n')
        repo.hg({ "remove", "src/utils.lua" })
        repo.write("src/new.lua", "new\n")
        repo.hg({ "add", "src/new.lua" })

        local adapter = repo.adapter()
        local HgRev = adapter.Rev
        local left = HgRev(RevType.COMMIT, "tip")
        local right = HgRev(RevType.LOCAL)

        local err, files = await(
          adapter:tracked_files(
            left,
            right,
            {},
            "working",
            { default_layout = Diff2, merge_layout = Diff2 }
          )
        )

        assert.is_nil(err)

        local by_name = {}
        for _, file in ipairs(files) do
          local name = file.path:match("[^/]+$")
          by_name[name] = file
        end

        assert.is_not_nil(by_name["main.lua"], "main.lua should appear (modified)")
        assert.equals("M", by_name["main.lua"].status)

        assert.is_not_nil(by_name["new.lua"], "new.lua should appear (added)")
        assert.equals("A", by_name["new.lua"].status)

        assert.is_not_nil(by_name["utils.lua"], "utils.lua should appear (removed)")
        assert.equals("R", by_name["utils.lua"].status)
      end)
    )

    it(
      "shows file content at a revision without errors",
      helpers.async_test(function()
        if not hg_available() then
          pending("hg not installed")
          return
        end

        repo.write("hello.txt", "hello world\n")
        repo.hg({ "add", "hello.txt" })
        repo.hg({ "commit", "-m", "add hello", "-u", "test <test@test.com>" })

        local adapter = repo.adapter()
        local HgRev = adapter.Rev
        local rev = HgRev(RevType.COMMIT, "tip")

        local err, content = await(adapter:show("hello.txt", rev))

        assert.is_nil(err)
        assert.is_not_nil(content)
        assert.equals("hello world", vim.trim(table.concat(content, "\n")))
      end)
    )

    it(
      "paths do not contain revision specifiers",
      helpers.async_test(function()
        if not hg_available() then
          pending("hg not installed")
          return
        end

        repo.write("file.lua", "content\n")
        repo.hg({ "add", "file.lua" })
        repo.hg({ "commit", "-m", "add file", "-u", "test <test@test.com>" })
        repo.write("file.lua", "updated\n")

        local adapter = repo.adapter()
        local HgRev = adapter.Rev
        local left = HgRev(RevType.COMMIT, "tip")
        local right = HgRev(RevType.LOCAL)

        local err, files = await(
          adapter:tracked_files(
            left,
            right,
            {},
            "working",
            { default_layout = Diff2, merge_layout = Diff2 }
          )
        )

        assert.is_nil(err)
        assert.is_true(#files > 0)

        for _, file in ipairs(files) do
          -- Mercurial paths should never contain revision specifiers.
          assert.is_nil(file.path:match("#%d+"), ("path %q contains #rev"):format(file.path))
          assert.is_nil(file.path:match("@%d+"), ("path %q contains @rev"):format(file.path))
        end
      end)
    )
  end)

  describe("parse_fh_data pin_local", function()
    -- Construct an HgAdapter without invoking `hg`. parse_fh_data only
    -- shells out via state.layout_opt.default_layout, which we control,
    -- so a tempdir toplevel and stubbed bootstrap state are sufficient.
    local function make_adapter()
      local repo = vim.fn.tempname()
      vim.fn.mkdir(repo, "p")

      HgAdapter.bootstrap.done = true
      HgAdapter.bootstrap.ok = true

      return HgAdapter({ toplevel = repo, path_args = {} }), repo
    end

    -- Mercurial's parse_fh_data iterates `#numstat - 1` times, so the
    -- numstat array carries a sentinel trailing entry. Status character
    -- comes from the first character of the matching `namestat[i]`.
    local function setup_state_and_data(layout_opt)
      local state = {
        path_args = { "foo.txt" },
        log_options = {},
        prepared_log_opts = { base = nil },
        layout_opt = layout_opt,
        single_file = true,
      }

      local data = {
        left_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        right_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        namestat = { "M foo.txt" },
        numstat = { "foo.txt | 2 +-", "" },
      }

      local commit = {}

      return state, data, commit
    end

    it("uses commit-side rev for b when pin_local is unset", function()
      local adapter, repo = make_adapter()

      local state, data, commit = setup_state_and_data({
        default_layout = Diff2,
      })

      local success, log_entry = adapter:parse_fh_data(data, commit, state)
      assert.True(success)
      ---@cast log_entry LogEntry

      local b_rev = log_entry.files[1].layout.b.file.rev
      assert.equals(RevType.COMMIT, b_rev.type)
      assert.equals(data.right_hash, b_rev.commit)

      pcall(vim.fn.delete, repo, "rf")
    end)

    it("sets revs.b to LOCAL when state.layout_opt.pin_local is true", function()
      local adapter, repo = make_adapter()

      local state, data, commit = setup_state_and_data({
        default_layout = Diff2,
        pin_local = true,
      })

      local success, log_entry = adapter:parse_fh_data(data, commit, state)
      assert.True(success)
      ---@cast log_entry LogEntry

      local b_file = log_entry.files[1].layout.b.file
      assert.equals(RevType.LOCAL, b_file.rev.type)
      assert.equals("foo.txt", b_file.path)

      -- pin_local diffs each changeset against the working tree, so the
      -- a-side reads from this changeset (not its parent).
      local a_rev = log_entry.files[1].layout.a.file.rev
      assert.equals(RevType.COMMIT, a_rev.type)
      assert.equals(data.right_hash, a_rev.commit)

      pcall(vim.fn.delete, repo, "rf")
    end)

    it("reuses the layout_opt.pinned_b_file_for File for the b-side", function()
      local adapter, repo = make_adapter()

      -- See `git_adapter_spec`'s mirror test for the rationale: the adapter
      -- looks up the b-side `vcs.File` through the view's cache (resolved
      -- via `pinned_path` when set), so identity is preserved across every
      -- entry the view will ever build.
      local shared = { path = "shared.txt", rev = adapter.Rev(RevType.LOCAL) }
      local lookups = {}
      local state, data, commit = setup_state_and_data({
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
      assert.same({ "renamed/foo.txt" }, lookups)

      pcall(vim.fn.delete, repo, "rf")
    end)
  end)

  describe("file_exists_at_rev", function()
    local repo

    before_each(function()
      if not hg_available() then
        pending("hg not installed")
        return
      end
      repo = create_hg_repo()
    end)

    after_each(function()
      if repo then
        repo.cleanup()
      end
    end)

    it("returns true for files tracked at the revision", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("kept.txt", "v1\n")
      repo.hg({ "add", "kept.txt" })
      repo.hg({ "commit", "-m", "init", "-u", "test <test@test.com>" })

      local adapter = repo.adapter()
      assert.is_true(adapter:file_exists_at_rev("kept.txt", "tip"))
    end)

    it("returns false for paths absent at the revision", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("kept.txt", "v1\n")
      repo.hg({ "add", "kept.txt" })
      repo.hg({ "commit", "-m", "init", "-u", "test <test@test.com>" })

      local adapter = repo.adapter()
      assert.is_false(adapter:file_exists_at_rev("never_added.txt", "tip"))
    end)

    -- Regression: an earlier commit's resolver fell through to status="M"
    -- for hg because `HgAdapter` didn't implement the probe, so navigating
    -- to a commit before the pinned file was added tried to `hg cat` a
    -- missing file and the diff buffer creation failed. The probe now lets
    -- the resolver mark the overlay status="D" and null the a-side.
    it("returns false for paths added in a later revision", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("first.txt", "v1\n")
      repo.hg({ "add", "first.txt" })
      repo.hg({ "commit", "-m", "first", "-u", "test <test@test.com>" })

      local first_rev = repo.hg({ "log", "--template={node}", "--rev", "tip" })

      repo.write("later.txt", "added later\n")
      repo.hg({ "add", "later.txt" })
      repo.hg({ "commit", "-m", "second", "-u", "test <test@test.com>" })

      local adapter = repo.adapter()
      -- `later.txt` exists at tip but not at the first commit.
      assert.is_true(adapter:file_exists_at_rev("later.txt", "tip"))
      assert.is_false(adapter:file_exists_at_rev("later.txt", first_rev))
    end)
  end)

  -- See `git_adapter_spec`'s `history_scope` block for the rationale: the
  -- scope is the single source of truth for "single-file?" + "which path?",
  -- and must agree with `is_single_file()`'s `<2` semantics so `pin_local`
  -- seeds `pinned_path` even for histories of removed/missing files.
  describe("history_scope", function()
    local repo

    before_each(function()
      if not hg_available() then
        pending("hg not installed")
        return
      end
      repo = create_hg_repo()
    end)

    after_each(function()
      if repo then
        repo.cleanup()
      end
    end)

    it("recognises a single tracked file pathspec", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("init.txt", "v1\n")
      repo.hg({ "add", "init.txt" })
      repo.hg({ "commit", "-m", "init", "-u", "test <test@test.com>" })

      local adapter = repo.adapter()
      local scope = adapter:history_scope({ "init.txt" }, {})
      assert.equals(true, scope.single_file)
      assert.equals("init.txt", scope.path)
    end)

    it("treats a single pathspec with zero matches as single-file with the literal path", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("init.txt", "v1\n")
      repo.hg({ "add", "init.txt" })
      repo.hg({ "commit", "-m", "init", "-u", "test <test@test.com>" })

      local adapter = repo.adapter()
      local scope = adapter:history_scope({ "deleted.txt" }, {})
      assert.equals(true, scope.single_file)
      assert.equals("deleted.txt", scope.path)
    end)

    it("downgrades a single-directory pathspec to multi-file", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      vim.fn.mkdir(repo.dir .. "/sub", "p")
      local adapter = repo.adapter()
      local scope = adapter:history_scope({ repo.dir .. "/sub" }, {})
      assert.equals(false, scope.single_file)
      assert.is_nil(scope.path)
    end)

    it("returns multi-file for an empty path_args", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      local adapter = repo.adapter()
      local scope = adapter:history_scope({}, {})
      assert.equals(false, scope.single_file)
    end)
  end)

  describe("build_local_log_entry", function()
    local repo

    before_each(function()
      if not hg_available() then
        pending("hg not installed")
        return
      end
      repo = create_hg_repo()
    end)

    after_each(function()
      if repo then
        repo.cleanup()
      end
    end)

    it("returns nil on a clean working tree", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("init.txt", "init\n")
      repo.hg({ "add", "init.txt" })
      repo.hg({ "commit", "-m", "init", "-u", "test <test@test.com>" })

      local adapter = repo.adapter()
      local log_entry = adapter:build_local_log_entry({
        path_args = {},
        layout_opt = { default_layout = Diff2 },
        single_file = false,
      })

      assert.is_nil(log_entry)
    end)

    it("builds a synthetic LogEntry with revs.b = LOCAL when the tree is dirty", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("init.txt", "init\n")
      repo.hg({ "add", "init.txt" })
      repo.hg({ "commit", "-m", "init", "-u", "test <test@test.com>" })

      repo.write("init.txt", "changed\n")

      local adapter = repo.adapter()
      local log_entry = adapter:build_local_log_entry({
        path_args = {},
        layout_opt = { default_layout = Diff2 },
        single_file = false,
      })

      assert.is_not_nil(log_entry)
      ---@cast log_entry LogEntry
      assert.is_nil(log_entry.commit.hash)
      assert.equals("Working tree", log_entry.commit.subject)
      -- The synthetic commit must populate `iso_date` (and the
      -- `time_offset` fallback that feeds it). `render.lua` concatenates
      -- `iso_date` into the panel header when `date_format = "iso"` (and in
      -- the `auto` branch for older commits), so a nil here would abort the
      -- file-history panel render. The synth is constructed via the
      -- adapter's `Commit` alias (`HgCommit`), whose `init` derives
      -- `iso_date` from `time` regardless of whether `time_offset` was
      -- provided.
      assert.is_string(log_entry.commit.iso_date)
      assert.equals(0, log_entry.commit.time_offset)
      assert.equals(1, #log_entry.files)

      local file = log_entry.files[1]
      assert.equals("init.txt", file.path)
      assert.equals("M", file.status)
      assert.equals(RevType.LOCAL, file.revs.b.type)
      assert.equals(RevType.COMMIT, file.revs.a.type)
    end)

    it("builds entries for multiple modified paths", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("foo.txt", "foo\n")
      repo.write("bar.txt", "bar\n")
      repo.hg({ "add", "foo.txt", "bar.txt" })
      repo.hg({ "commit", "-m", "init", "-u", "test <test@test.com>" })

      repo.write("foo.txt", "foo changed\n")
      repo.write("bar.txt", "bar changed\n")

      local adapter = repo.adapter()
      local log_entry = adapter:build_local_log_entry({
        path_args = { "foo.txt", "bar.txt" },
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
      assert.is_true(paths["foo.txt"])
      assert.is_true(paths["bar.txt"])
    end)

    it("includes missing (`!`) and removed (`R`) files normalized to `D`", function()
      if not hg_available() then
        pending("hg not installed")
        return
      end

      repo.write("modified.txt", "m\n")
      repo.write("missing.txt", "m\n")
      repo.write("removed.txt", "r\n")
      repo.hg({ "add", "modified.txt", "missing.txt", "removed.txt" })
      repo.hg({ "commit", "-m", "init", "-u", "test <test@test.com>" })

      repo.write("modified.txt", "changed\n")
      -- `!` (missing): file removed from disk without `hg rm`.
      os.remove(repo.dir .. "/missing.txt")
      -- `R` (removed): tracked-and-removed via `hg rm`.
      repo.hg({ "rm", "removed.txt" })

      local adapter = repo.adapter()
      local log_entry = adapter:build_local_log_entry({
        path_args = {},
        layout_opt = { default_layout = Diff2 },
        single_file = false,
      })

      assert.is_not_nil(log_entry)
      ---@cast log_entry LogEntry
      local by_name = {}
      for _, file in ipairs(log_entry.files) do
        by_name[file.path] = file
      end

      assert.equals("M", by_name["modified.txt"].status)
      assert.is_not_nil(by_name["missing.txt"], "missing.txt should appear (deleted)")
      assert.equals("D", by_name["missing.txt"].status)
      assert.is_not_nil(by_name["removed.txt"], "removed.txt should appear (removed)")
      assert.equals("D", by_name["removed.txt"].status)
    end)
  end)
end)
