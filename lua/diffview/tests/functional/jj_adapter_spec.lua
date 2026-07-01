local helpers = require("diffview.tests.helpers")
local utils = require("diffview.utils")

local eq = helpers.eq

describe("diffview.vcs.adapters.jj", function()
  local JjAdapter = require("diffview.vcs.adapters.jj").JjAdapter
  local RevType = require("diffview.vcs.rev").RevType
  local arg_parser = require("diffview.arg_parser")

  ---@return JjAdapter
  local function new_adapter()
    local old_get_dir = JjAdapter.get_dir
    JjAdapter.get_dir = function(_)
      return "/tmp/.jj"
    end

    local adapter = JjAdapter({
      toplevel = "/tmp",
      path_args = {},
      cpath = nil,
    })

    JjAdapter.get_dir = old_get_dir

    adapter._rev_map = {
      ["@"] = "head_hash",
      ["@-"] = "parent_hash",
      ["root()"] = "root_hash",
      ["main"] = "main_hash",
      ["master"] = "master_hash",
      ["feature"] = "feature_hash",
    }

    adapter.resolve_rev_arg = function(_, rev)
      return adapter._rev_map[rev]
    end

    adapter.head_rev = function(_)
      return adapter.Rev(RevType.COMMIT, adapter._rev_map["@"] or "head_hash", true)
    end

    adapter.symmetric_diff_revs = function(_, _)
      return adapter.Rev(RevType.COMMIT, "merge_base_hash"),
        adapter.Rev(RevType.COMMIT, adapter._rev_map["@"])
    end

    adapter.has_bookmark = function(_, _)
      return true
    end

    return adapter
  end

  describe("parse_revs()", function()
    it("defaults to HEAD..LOCAL when no rev is provided", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs(nil, {})

      eq(RevType.COMMIT, left.type)
      eq("parent_hash", left.commit)
      eq(RevType.LOCAL, right.type)
    end)

    it("parses single rev as COMMIT..LOCAL", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs("main", {})

      eq(RevType.COMMIT, left.type)
      eq("main_hash", left.commit)
      eq(RevType.LOCAL, right.type)
    end)

    it("falls back from main to master when main bookmark is absent", function()
      local adapter = new_adapter()
      adapter.has_bookmark = function(_, name)
        return name == "master"
      end

      local left, right = adapter:parse_revs("main", {})

      eq(RevType.COMMIT, left.type)
      eq("master_hash", left.commit)
      eq(RevType.LOCAL, right.type)
    end)

    it("parses double-dot range as COMMIT..COMMIT", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs("main..feature", {})

      eq(RevType.COMMIT, left.type)
      eq("main_hash", left.commit)
      eq(RevType.COMMIT, right.type)
      eq("feature_hash", right.commit)
    end)

    it("parses triple-dot range through symmetric merge-base resolution", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs("main...@", {})

      eq(RevType.COMMIT, left.type)
      eq("merge_base_hash", left.commit)
      eq(RevType.LOCAL, right.type)
    end)
  end)

  describe("diffview_options()", function()
    it("accepts --selected-file and resolves rev args", function()
      local adapter = new_adapter()
      local argo = arg_parser.parse({ "main", "--selected-file=lua/diffview/init.lua" })
      local opt = adapter:diffview_options(argo)

      eq("main_hash", opt.left.commit)
      eq(RevType.LOCAL, opt.right.type)
      eq("lua/diffview/init.lua", opt.options.selected_file)
    end)
  end)

  describe("refresh_revs()", function()
    it("re-resolves symbolic revs", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs("main", {})

      adapter._rev_map["main"] = "next_main_hash"

      local new_left, new_right = adapter:refresh_revs("main", left, right)
      eq("next_main_hash", new_left.commit)
      eq(RevType.LOCAL, new_right.type)
    end)

    it("updates default baseline when parent changes", function()
      local adapter = new_adapter()
      local left, right = adapter:parse_revs(nil, {})

      adapter._rev_map["@-"] = "next_parent_hash"

      local new_left, new_right = adapter:refresh_revs(nil, left, right)
      eq("next_parent_hash", new_left.commit)
      eq(RevType.LOCAL, new_right.type)
    end)
  end)

  describe("force_entry_refresh_on_noop()", function()
    it("returns true for ranges that include LOCAL", function()
      local adapter = new_adapter()
      local ok = adapter:force_entry_refresh_on_noop(
        adapter.Rev(RevType.COMMIT, "left_hash"),
        adapter.Rev(RevType.LOCAL)
      )

      eq(true, ok)
    end)

    it("returns false for commit-to-commit ranges", function()
      local adapter = new_adapter()
      local ok = adapter:force_entry_refresh_on_noop(
        adapter.Rev(RevType.COMMIT, "left_hash"),
        adapter.Rev(RevType.COMMIT, "right_hash")
      )

      eq(false, ok)
    end)
  end)

  describe("on_local_buffer_reused()", function()
    it("calls checktime on an unmodified buffer", function()
      local adapter = new_adapter()
      local bufnr = vim.api.nvim_create_buf(true, false)

      -- checktime requires a file on disk; write a temp file so the buffer
      -- has a real name and checktime doesn't error.
      local tmpfile = vim.fn.tempname()
      vim.fn.writefile({ "hello" }, tmpfile)
      vim.api.nvim_buf_set_name(bufnr, tmpfile)
      vim.fn.bufload(bufnr)

      -- Should not error.
      assert.has_no.errors(function()
        adapter:on_local_buffer_reused(bufnr)
      end)

      -- Buffer should still be loaded and valid.
      assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
      assert.is_true(vim.api.nvim_buf_is_loaded(bufnr))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      vim.fn.delete(tmpfile)
    end)
  end)

  describe("rev_to_args()", function()
    it("returns --from/--to for commit ranges", function()
      local adapter = new_adapter()
      local args = adapter:rev_to_args(
        adapter.Rev(RevType.COMMIT, "left_hash"),
        adapter.Rev(RevType.COMMIT, "right_hash")
      )

      eq({ "--from", "left_hash", "--to", "right_hash" }, args)
    end)

    it("returns --from for commit..LOCAL", function()
      local adapter = new_adapter()
      local args =
        adapter:rev_to_args(adapter.Rev(RevType.COMMIT, "left_hash"), adapter.Rev(RevType.LOCAL))

      eq({ "--from", "left_hash" }, args)
    end)
  end)

  describe("get_show_args()", function()
    it("wraps the path in an exact-file fileset pattern", function()
      local adapter = new_adapter()
      local args = adapter:get_show_args("src/main.lua", adapter.Rev(RevType.COMMIT, "abc123"))

      eq({ "file", "show", "-r", "abc123", "--", 'file:"src/main.lua"' }, args)
    end)

    it("escapes fileset metacharacters so jj matches the path literally", function()
      local adapter = new_adapter()
      -- Svelte route groups use parentheses, which are fileset operators in jj.
      local args = adapter:get_show_args(
        "frontend/src/routes/(test)/View.svelte",
        adapter.Rev(RevType.COMMIT, "abc123")
      )

      eq('file:"frontend/src/routes/(test)/View.svelte"', args[#args])
    end)

    it("uses the exact-file kind so glob symbols match literally", function()
      local adapter = new_adapter()
      -- The `file:` kind disables glob expansion, so `[1]` is not a character
      -- class and the bracketed filename resolves to itself.
      local args = adapter:get_show_args("a[1].txt", adapter.Rev(RevType.COMMIT, "abc123"))

      eq('file:"a[1].txt"', args[#args])
    end)

    it("backslash-escapes embedded quotes and backslashes", function()
      local adapter = new_adapter()
      local args = adapter:get_show_args([[a"b\c.txt]], adapter.Rev(RevType.COMMIT, "abc123"))

      eq([[file:"a\"b\\c.txt"]], args[#args])
    end)
  end)

  describe("get_log_args()", function()
    it("returns just `log` when no args are given", function()
      local adapter = new_adapter()

      eq({ "log" }, adapter:get_log_args({}))
    end)

    it("wraps a single revset in `-r` so `jj log` reads it as a revision", function()
      local adapter = new_adapter()

      eq({ "log", "-r", "abc123" }, adapter:get_log_args({ "abc123" }))
    end)

    it("wraps an `a..b` range revset in `-r`", function()
      local adapter = new_adapter()

      eq({ "log", "-r", "abc123..def456" }, adapter:get_log_args({ "abc123..def456" }))
    end)

    it("wraps each revset when given multiple positional args", function()
      local adapter = new_adapter()

      eq({ "log", "-r", "abc", "-r", "def" }, adapter:get_log_args({ "abc", "def" }))
    end)

    it("mixes flags and revsets without re-wrapping flags", function()
      local adapter = new_adapter()

      eq({ "log", "-n10", "-r", "abc123" }, adapter:get_log_args({ "-n10", "abc123" }))
    end)

    it("prepends user-configured global flags from `jj_cmd`", function()
      local adapter = new_adapter()
      adapter.get_command = function(_)
        return { "jj", "--repository", "/some/path" }
      end

      eq(
        { "--repository", "/some/path", "log", "-r", "abc123" },
        adapter:get_log_args({ "abc123" })
      )
    end)
  end)

  describe("_warn_once()", function()
    local orig_warn

    before_each(function()
      orig_warn = utils.warn
    end)

    after_each(function()
      utils.warn = orig_warn
    end)

    it("warns only once per key across repeated calls", function()
      local adapter = new_adapter()
      local count = 0
      utils.warn = function()
        count = count + 1
      end

      adapter:_warn_once("k", "msg")
      adapter:_warn_once("k", "msg")
      adapter:_warn_once("k", "msg")

      eq(1, count)
    end)

    it("warns independently for distinct keys", function()
      local adapter = new_adapter()
      local count = 0
      utils.warn = function()
        count = count + 1
      end

      adapter:_warn_once("a", "msg-a")
      adapter:_warn_once("b", "msg-b")
      adapter:_warn_once("a", "msg-a")

      eq(2, count)
    end)

    it("isolates warn state per adapter instance", function()
      local a = new_adapter()
      local b = new_adapter()
      local count = 0
      utils.warn = function()
        count = count + 1
      end

      a:_warn_once("k", "msg")
      b:_warn_once("k", "msg")

      eq(2, count)
    end)
  end)

  describe("staging no-ops", function()
    local orig_warn

    before_each(function()
      orig_warn = utils.warn
      utils.warn = function() end
    end)

    after_each(function()
      utils.warn = orig_warn
    end)

    it("add_files returns true to suppress listener error", function()
      local adapter = new_adapter()
      assert.True(adapter:add_files({ "file.txt" }))
    end)

    it("reset_files returns true to suppress listener error", function()
      local adapter = new_adapter()
      assert.True(adapter:reset_files({ "file.txt" }))
    end)

    it("stage_index_file returns true to suppress listener error", function()
      local adapter = new_adapter()
      assert.True(adapter:stage_index_file({}))
    end)

    it("coalesces warnings across all staging surfaces", function()
      local adapter = new_adapter()
      local count = 0
      utils.warn = function()
        count = count + 1
      end

      adapter:add_files({ "a" })
      adapter:reset_files({ "a" })
      adapter:stage_index_file({})
      adapter:add_files({ "b" })

      eq(1, count)
    end)
  end)

  describe("file_restore()", function()
    local async = require("diffview.async")
    local await = async.await

    local orig_warn, orig_err

    before_each(function()
      orig_warn = utils.warn
      orig_err = utils.err
      utils.warn = function() end
      utils.err = function() end
    end)

    after_each(function()
      utils.warn = orig_warn
      utils.err = orig_err
    end)

    it(
      "warns and returns failure for kind == 'staged'",
      helpers.async_test(function()
        local adapter = new_adapter()
        local warned = 0
        utils.warn = function()
          warned = warned + 1
        end
        local exec_called = false
        adapter.exec_sync = function()
          exec_called = true
        end

        local ok, undo = await(adapter:file_restore("file.txt", "staged", nil))

        eq(false, ok)
        assert.is_nil(undo)
        eq(1, warned)
        assert.False(exec_called)
      end)
    )

    it(
      "invokes `jj restore --from @- -- <path>` when commit is nil",
      helpers.async_test(function()
        local adapter = new_adapter()
        local captured_args
        adapter.exec_sync = function(_, args)
          captured_args = args
          return {}, 0, {}
        end

        local ok, undo = await(adapter:file_restore("src/main.lua", "working", nil))

        eq(true, ok)
        eq(":!jj op undo", undo)
        eq({ "restore", "--from", "@-", "--", 'file:"src/main.lua"' }, captured_args)
      end)
    )

    it(
      "uses the explicit commit when provided",
      helpers.async_test(function()
        local adapter = new_adapter()
        local captured_args
        adapter.exec_sync = function(_, args)
          captured_args = args
          return {}, 0, {}
        end

        local ok = await(adapter:file_restore("src/main.lua", "working", "abcdef"))

        eq(true, ok)
        eq({ "restore", "--from", "abcdef", "--", 'file:"src/main.lua"' }, captured_args)
      end)
    )

    it(
      "reports failure and surfaces stderr when jj exits non-zero",
      helpers.async_test(function()
        local adapter = new_adapter()
        local err_msg
        utils.err = function(msg)
          err_msg = msg
        end
        adapter.exec_sync = function()
          return {}, 1, { "boom" }
        end

        local ok, undo = await(adapter:file_restore("src/main.lua", "working", nil))

        eq(false, ok)
        assert.is_nil(undo)
        assert.is_not_nil(err_msg)
      end)
    )
  end)

  -- ------------------------------------------------------------------
  -- Integration tests: require jj
  -- ------------------------------------------------------------------
  describe("integration", function()
    local async = require("diffview.async")
    local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
    local await = async.await

    local function jj_available()
      return vim.fn.executable("jj") == 1
    end

    local function run(cmd, cwd)
      local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
      assert.equals(0, res.code, (table.concat(cmd, " ") .. "\n" .. (res.stderr or "")))
      return vim.trim(res.stdout or "")
    end

    local function create_jj_repo()
      local repo = vim.fn.tempname()
      vim.fn.mkdir(repo, "p")

      run({ "jj", "git", "init" }, repo)
      run({ "jj", "config", "set", "--repo", "user.name", "Test" }, repo)
      run({ "jj", "config", "set", "--repo", "user.email", "test@test.com" }, repo)

      return {
        dir = repo,
        jj = function(args)
          local cmd = { "jj" }
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
        read = function(relpath)
          local f = assert(io.open(repo .. "/" .. relpath, "r"))
          local content = f:read("*a")
          f:close()
          return content
        end,
        adapter = function()
          JjAdapter.bootstrap.done = true
          JjAdapter.bootstrap.ok = true
          return JjAdapter({
            toplevel = repo,
            path_args = {},
          })
        end,
        cleanup = function()
          pcall(vim.fn.delete, repo, "rf")
        end,
      }
    end

    local repo
    local saved_bootstrap

    before_each(function()
      if not jj_available() then
        pending("jj not installed")
        return
      end
      saved_bootstrap = vim.deepcopy(JjAdapter.bootstrap)
      repo = create_jj_repo()
    end)

    after_each(function()
      if repo then
        repo.cleanup()
        repo = nil
      end
      if saved_bootstrap then
        JjAdapter.bootstrap = saved_bootstrap
        saved_bootstrap = nil
      end
    end)

    describe("tracked_files", function()
      it(
        "lists modified, added, and deleted files",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          -- Initial commit with two files.
          repo.write("src/main.lua", 'print("v1")\n')
          repo.write("src/utils.lua", "local M = {}\nreturn M\n")
          repo.jj({ "describe", "-m", "initial" })
          repo.jj({ "new" })

          -- Modify one, delete one, add one.
          repo.write("src/main.lua", 'print("v2")\n')
          os.remove(repo.dir .. "/src/utils.lua")
          repo.write("src/new.lua", "new\n")

          local adapter = repo.adapter()
          local left = adapter.Rev(
            RevType.COMMIT,
            run({ "jj", "show", "-T", "commit_id", "@-", "--no-patch" }, repo.dir)
          )
          local right = adapter.Rev(RevType.LOCAL)
          local args = adapter:rev_to_args(left, right)

          local err, files = await(
            adapter:tracked_files(
              left,
              right,
              args,
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

          assert.is_not_nil(by_name["utils.lua"], "utils.lua should appear (deleted)")
          assert.equals("D", by_name["utils.lua"].status)
        end)
      )

      it(
        "shows file content at a revision without errors",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("hello.txt", "hello world\n")
          repo.jj({ "describe", "-m", "add hello" })

          local adapter = repo.adapter()
          local commit_id = run({ "jj", "show", "-T", "commit_id", "@", "--no-patch" }, repo.dir)
          local rev = adapter.Rev(RevType.COMMIT, commit_id)

          local err, content = await(adapter:show("hello.txt", rev))

          assert.is_nil(err)
          assert.is_not_nil(content)
          assert.equals("hello world", vim.trim(table.concat(content, "\n")))
        end)
      )

      it(
        "shows file content for a path containing fileset metacharacters",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          -- Svelte route groups embed parentheses in the path, which jj reads
          -- as fileset operators unless the path is quoted (regression test
          -- for the "Failed to parse fileset" error on `:DiffviewOpen`).
          local path = "frontend/src/routes/(test)/View.svelte"
          repo.write(path, "<svelte/>\n")
          repo.jj({ "describe", "-m", "add svelte route group" })

          local adapter = repo.adapter()
          local commit_id = run({ "jj", "show", "-T", "commit_id", "@", "--no-patch" }, repo.dir)
          local rev = adapter.Rev(RevType.COMMIT, commit_id)

          local err, content = await(adapter:show(path, rev))

          assert.is_nil(err)
          assert.is_not_nil(content)
          assert.equals("<svelte/>", vim.trim(table.concat(content, "\n")))
        end)
      )

      it(
        "shows the exact file when a glob-collision sibling exists",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          -- `a[1].txt` would be a glob character class matching `a1.txt` under
          -- jj's default pattern kind. The exact-file (`file:`) kind must pin
          -- the lookup to the literally-named file, not its glob sibling.
          repo.write("a[1].txt", "BRACKET\n")
          repo.write("a1.txt", "GLOBBED\n")
          repo.jj({ "describe", "-m", "add glob-collision files" })

          local adapter = repo.adapter()
          local commit_id = run({ "jj", "show", "-T", "commit_id", "@", "--no-patch" }, repo.dir)
          local rev = adapter.Rev(RevType.COMMIT, commit_id)

          local err, content = await(adapter:show("a[1].txt", rev))

          assert.is_nil(err)
          assert.is_not_nil(content)
          assert.equals("BRACKET", vim.trim(table.concat(content, "\n")))
        end)
      )

      it(
        "paths do not contain revision specifiers",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("file.lua", "content\n")
          repo.jj({ "describe", "-m", "add file" })
          repo.jj({ "new" })
          repo.write("file.lua", "updated\n")

          local adapter = repo.adapter()
          local left = adapter.Rev(
            RevType.COMMIT,
            run({ "jj", "show", "-T", "commit_id", "@-", "--no-patch" }, repo.dir)
          )
          local right = adapter.Rev(RevType.LOCAL)
          local args = adapter:rev_to_args(left, right)

          local err, files = await(
            adapter:tracked_files(
              left,
              right,
              args,
              "working",
              { default_layout = Diff2, merge_layout = Diff2 }
            )
          )

          assert.is_nil(err)
          assert.is_true(#files > 0)

          for _, file in ipairs(files) do
            -- Jujutsu paths should never contain revision specifiers.
            assert.is_nil(file.path:match("@"), ("path %q contains @"):format(file.path))
            assert.is_nil(file.path:match("#%d+"), ("path %q contains #rev"):format(file.path))
          end
        end)
      )
    end)

    describe("merge conflict detection", function()
      -- Build a 2-parent merge with a conflicting file. Returns the change
      -- ids of the base, ours, and theirs commits.
      local function make_conflict(filename)
        filename = filename or "file.txt"
        repo.write(filename, "line1\n")
        repo.jj({ "describe", "-m", "initial" })
        local base = repo.jj({ "log", "-r", "@", "--no-graph", "-T", "change_id.short()" })

        repo.jj({ "new", "-m", "left" })
        repo.write(filename, "left\n")
        local ours = repo.jj({ "log", "-r", "@", "--no-graph", "-T", "change_id.short()" })

        repo.jj({ "new", base, "-m", "right" })
        repo.write(filename, "right\n")
        local theirs = repo.jj({ "log", "-r", "@", "--no-graph", "-T", "change_id.short()" })

        repo.jj({ "new", ours, theirs, "-m", "merge" })

        return base, ours, theirs
      end

      it(
        "detects a 2-sided conflict and returns commit ids for OURS/THEIRS/BASE",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          make_conflict()
          local adapter = repo.adapter()

          local err, ctx = await(adapter:_query_merge_context())
          assert.is_nil(err)
          assert.is_not_nil(ctx)
          assert.same({ "file.txt" }, ctx.paths)
          -- Commit ids are full 40-char hex.
          assert.equals(40, #ctx.ours)
          assert.equals(40, #ctx.theirs)
          assert.equals(40, ctx.base and #ctx.base or 0)
          assert.not_equals(ctx.ours, ctx.theirs)
        end)
      )

      it(
        "returns nil when the working copy has no conflicts",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("file.txt", "clean\n")
          repo.jj({ "describe", "-m", "clean" })

          local adapter = repo.adapter()
          local err, ctx = await(adapter:_query_merge_context())
          assert.is_nil(err)
          assert.is_nil(ctx)
        end)
      )

      it(
        "routes conflicting paths into the conflicts bucket with the merge layout",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          make_conflict()

          local adapter = repo.adapter()
          local left = adapter.Rev(RevType.COMMIT, adapter.Rev.NULL_TREE_SHA)
          local right = adapter.Rev(RevType.LOCAL)
          local args = adapter:rev_to_args(left, right)

          local Diff3Hor = require("diffview.scene.layouts.diff_3_hor").Diff3Hor
          local err, files, conflicts = await(
            adapter:tracked_files(
              left,
              right,
              args,
              "working",
              { default_layout = Diff2, merge_layout = Diff3Hor }
            )
          )

          assert.is_nil(err)
          for _, f in ipairs(files) do
            assert.not_equals("file.txt", f.path)
          end
          assert.equals(1, #conflicts)
          assert.equals("file.txt", conflicts[1].path)
          assert.equals("U", conflicts[1].status)
          assert.equals("conflicting", conflicts[1].kind)
        end)
      )

      it(
        "populates `get_merge_context` after `tracked_files` from the cache",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          make_conflict()

          local adapter = repo.adapter()
          -- Nothing runs before tracked_files, so the cache is unset.
          assert.is_nil(adapter:get_merge_context())

          local left = adapter.Rev(RevType.COMMIT, adapter.Rev.NULL_TREE_SHA)
          local right = adapter.Rev(RevType.LOCAL)
          local args = adapter:rev_to_args(left, right)
          local Diff3Hor = require("diffview.scene.layouts.diff_3_hor").Diff3Hor

          await(
            adapter:tracked_files(
              left,
              right,
              args,
              "working",
              { default_layout = Diff2, merge_layout = Diff3Hor }
            )
          )

          local ctx = adapter:get_merge_context()
          assert.is_not_nil(ctx)
          assert.equals(40, #ctx.ours.hash)
          assert.equals(40, #ctx.theirs.hash)
          assert.equals(40, #ctx.base.hash)
        end)
      )

      it(
        "get_merge_context returns nil when there is no conflict",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("file.txt", "clean\n")
          repo.jj({ "describe", "-m", "clean" })

          local adapter = repo.adapter()
          local left = adapter.Rev(RevType.COMMIT, adapter.Rev.NULL_TREE_SHA)
          local right = adapter.Rev(RevType.LOCAL)
          local args = adapter:rev_to_args(left, right)

          await(
            adapter:tracked_files(
              left,
              right,
              args,
              "working",
              { default_layout = Diff2, merge_layout = Diff2 }
            )
          )

          assert.is_nil(adapter:get_merge_context())
        end)
      )

      it(
        "does not inject working-copy conflicts into a commit-range diff (right != LOCAL)",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          make_conflict()

          local adapter = repo.adapter()
          -- Both endpoints are commits, not LOCAL: this simulates
          -- `:DiffviewOpen v1.0..v1.1` where the working copy `@` isn't the
          -- right endpoint.
          local left = adapter.Rev(RevType.COMMIT, adapter.Rev.NULL_TREE_SHA)
          local right = adapter.Rev(RevType.COMMIT, adapter.Rev.NULL_TREE_SHA)
          local Diff3Hor = require("diffview.scene.layouts.diff_3_hor").Diff3Hor

          local err, _, conflicts = await(
            adapter:tracked_files(
              left,
              right,
              {},
              "working",
              { default_layout = Diff2, merge_layout = Diff3Hor }
            )
          )

          assert.is_nil(err)
          assert.equals(0, #conflicts)
          assert.is_nil(adapter:get_merge_context())
        end)
      )

      it(
        "excludes conflicts outside the requested `path_args` scope",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          make_conflict("bar/file.txt")

          local adapter = repo.adapter()
          adapter.ctx.path_args = { "foo" }
          local left = adapter.Rev(RevType.COMMIT, adapter.Rev.NULL_TREE_SHA)
          local right = adapter.Rev(RevType.LOCAL)
          local args = adapter:rev_to_args(left, right)
          local Diff3Hor = require("diffview.scene.layouts.diff_3_hor").Diff3Hor

          local err, _, conflicts = await(
            adapter:tracked_files(
              left,
              right,
              args,
              "working",
              { default_layout = Diff2, merge_layout = Diff3Hor }
            )
          )

          assert.is_nil(err)
          assert.equals(0, #conflicts)
        end)
      )

      it(
        "sets `revs.d` to a null-tree Rev rather than nil, so 4-way layouts have a valid BASE pane",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          make_conflict()

          local adapter = repo.adapter()
          -- Force the null-tree branch: pretend fork_point returned nothing.
          local orig_query = adapter._query_merge_context
          adapter._query_merge_context = function(self, callback)
            return orig_query(self, function(err, ctx)
              if ctx then
                ctx.base = nil
              end
              callback(err, ctx)
            end)
          end

          local left = adapter.Rev(RevType.COMMIT, adapter.Rev.NULL_TREE_SHA)
          local right = adapter.Rev(RevType.LOCAL)
          local args = adapter:rev_to_args(left, right)
          local Diff4Mixed = require("diffview.scene.layouts.diff_4_mixed").Diff4Mixed

          local err, _, conflicts = await(
            adapter:tracked_files(
              left,
              right,
              args,
              "working",
              { default_layout = Diff2, merge_layout = Diff4Mixed }
            )
          )

          assert.is_nil(err)
          assert.equals(1, #conflicts)
          local entry = conflicts[1]
          local d_rev = entry.layout.d.file.rev
          assert.is_not_nil(d_rev, "revs.d must not be nil (would crash Diff4 on layout open)")
          assert.equals(adapter.Rev.NULL_TREE_SHA, d_rev:object_name())
        end)
      )
    end)

    describe("file_history_worker", function()
      it(
        "streams one entry per commit",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("a.txt", "alpha\n")
          repo.jj({ "describe", "-m", "add a" })
          repo.jj({ "new" })
          repo.write("b.txt", "beta\n")
          repo.jj({ "describe", "-m", "add b" })

          local adapter = repo.adapter()
          local AsyncListStream = require("diffview.stream").AsyncListStream
          local JobStatus = require("diffview.vcs.utils").JobStatus

          local stream = AsyncListStream()
          adapter:file_history_worker(stream, {
            log_opt = {
              single_file = { path_args = {}, revisions = "::@" },
              multi_file = { path_args = {}, revisions = "::@" },
            },
            layout_opt = { default_layout = Diff2, merge_layout = Diff2 },
          })

          local entries = {}
          local statuses = {}
          for _, item in stream:iter() do
            local status, log_entry = unpack(item, 1, 2)
            statuses[#statuses + 1] = status
            if status == JobStatus.PROGRESS and log_entry then
              entries[#entries + 1] = log_entry
            end
          end

          assert.equals(JobStatus.SUCCESS, statuses[#statuses])
          -- Expect at least the two described commits ("add a" and the
          -- working-copy "add b"); the `>=` tolerates extra entries from
          -- repo initialization.
          assert.is_true(#entries >= 2)

          -- Build a path -> status map from the most recent entry.
          local subjects = {}
          for _, e in ipairs(entries) do
            subjects[e.commit.subject] = true
          end
          assert.is_true(subjects["add a"], "missing 'add a' in entries")
          assert.is_true(subjects["add b"], "missing 'add b' in entries")
        end)
      )

      it(
        "canonicalises a glob pathspec to the matched file",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("only.txt", "alpha\n")
          repo.jj({ "describe", "-m", "add only" })

          local adapter = repo.adapter()
          local AsyncListStream = require("diffview.stream").AsyncListStream
          local JobStatus = require("diffview.vcs.utils").JobStatus

          -- A `glob:*.txt` pathspec resolves to a single tracked file. Before
          -- the canonicalisation fix, `parse_fh_data`'s post-filter would
          -- compare each file in the commit against the literal `"glob:*.txt"`
          -- and drop everything, returning an empty history.
          local stream = AsyncListStream()
          adapter:file_history_worker(stream, {
            log_opt = {
              single_file = { path_args = { "glob:*.txt" }, revisions = "::@" },
              multi_file = { path_args = { "glob:*.txt" }, revisions = "::@" },
            },
            layout_opt = { default_layout = Diff2, merge_layout = Diff2 },
          })

          local entries = {}
          for _, item in stream:iter() do
            local status, log_entry = unpack(item, 1, 2)
            if status == JobStatus.PROGRESS and log_entry then
              entries[#entries + 1] = log_entry
            end
          end

          local found_only_txt = false
          for _, e in ipairs(entries) do
            for _, f in ipairs(e.files) do
              if f.path == "only.txt" then
                found_only_txt = true
              end
            end
          end
          assert.is_true(found_only_txt, "glob pathspec dropped the matched file from history")
        end)
      )

      it(
        "canonicalises a multi-file glob pathspec",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("a.txt", "alpha\n")
          repo.write("b.txt", "beta\n")
          repo.write("c.md", "gamma\n")
          repo.jj({ "describe", "-m", "add multiple files" })

          local adapter = repo.adapter()
          local AsyncListStream = require("diffview.stream").AsyncListStream
          local JobStatus = require("diffview.vcs.utils").JobStatus

          -- A `glob:*.txt` pathspec resolves to multiple files (`a.txt` and
          -- `b.txt`), forcing multi-file mode. Before the fix, the post-filter
          -- would compare files against the literal `"glob:*.txt"` and drop
          -- every entry; the `.md` file should be excluded but the two `.txt`
          -- files must appear.
          local stream = AsyncListStream()
          adapter:file_history_worker(stream, {
            log_opt = {
              single_file = { path_args = { "glob:*.txt" }, revisions = "::@" },
              multi_file = { path_args = { "glob:*.txt" }, revisions = "::@" },
            },
            layout_opt = { default_layout = Diff2, merge_layout = Diff2 },
          })

          local seen_paths = {}
          for _, item in stream:iter() do
            local status, log_entry = unpack(item, 1, 2)
            if status == JobStatus.PROGRESS and log_entry then
              for _, f in ipairs(log_entry.files) do
                seen_paths[f.path] = true
              end
            end
          end

          assert.is_true(seen_paths["a.txt"], "expected a.txt in history")
          assert.is_true(seen_paths["b.txt"], "expected b.txt in history")
          assert.is_nil(seen_paths["c.md"], "c.md should have been filtered out")
        end)
      )

      it(
        "builds history for a literal path containing fileset metacharacters",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          -- A Svelte route group path embeds parentheses, which jj parses as
          -- fileset operators. `:DiffviewFileHistory <path>` must quote the
          -- path so `jj log`/`jj file list` match it literally instead of
          -- failing with "Failed to parse fileset".
          local path = "frontend/src/routes/(test)/View.svelte"
          repo.write(path, "<svelte/>\n")
          repo.jj({ "describe", "-m", "add svelte route group" })

          local adapter = repo.adapter()
          local AsyncListStream = require("diffview.stream").AsyncListStream
          local JobStatus = require("diffview.vcs.utils").JobStatus

          local stream = AsyncListStream()
          adapter:file_history_worker(stream, {
            log_opt = {
              single_file = { path_args = { path }, revisions = "::@" },
              multi_file = { path_args = { path }, revisions = "::@" },
            },
            layout_opt = { default_layout = Diff2, merge_layout = Diff2 },
          })

          local statuses = {}
          local found = false
          for _, item in stream:iter() do
            local status, log_entry = unpack(item, 1, 2)
            statuses[#statuses + 1] = status
            if status == JobStatus.PROGRESS and log_entry then
              for _, f in ipairs(log_entry.files) do
                if f.path == path then
                  found = true
                end
              end
            end
          end

          assert.equals(JobStatus.SUCCESS, statuses[#statuses])
          assert.is_true(found, "history dropped the parenthesised path")
        end)
      )

      it(
        "populates per-file and per-commit stats from `diff.stat()`",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("a.txt", "alpha\nbeta\ngamma\n")
          repo.jj({ "describe", "-m", "seed a" })
          repo.jj({ "new" })
          repo.write("a.txt", "alpha\nGAMMA\ndelta\n")
          repo.write("b.txt", "first\nsecond\n")
          repo.jj({ "describe", "-m", "edit a, add b" })

          local adapter = repo.adapter()
          local AsyncListStream = require("diffview.stream").AsyncListStream
          local JobStatus = require("diffview.vcs.utils").JobStatus

          local stream = AsyncListStream()
          adapter:file_history_worker(stream, {
            log_opt = {
              single_file = { path_args = {}, revisions = "::@" },
              multi_file = { path_args = {}, revisions = "::@" },
            },
            layout_opt = { default_layout = Diff2, merge_layout = Diff2 },
          })

          local by_subject = {}
          for _, item in stream:iter() do
            local status, log_entry = unpack(item, 1, 2)
            if status == JobStatus.PROGRESS and log_entry then
              by_subject[log_entry.commit.subject] = log_entry
            end
          end

          local edit = by_subject["edit a, add b"]
          assert.is_not_nil(edit, "missing 'edit a, add b' in entries")

          local by_path = {}
          for _, f in ipairs(edit.files) do
            by_path[f.path] = f
          end

          -- `a.txt` rewrites lines 2-3: 2 additions, 2 deletions.
          assert.is_not_nil(by_path["a.txt"], "missing a.txt in 'edit a, add b'")
          assert.same({ additions = 2, deletions = 2 }, by_path["a.txt"].stats)

          -- `b.txt` is brand new: 2 additions, 0 deletions.
          assert.is_not_nil(by_path["b.txt"], "missing b.txt in 'edit a, add b'")
          assert.same({ additions = 2, deletions = 0 }, by_path["b.txt"].stats)

          -- The per-commit stat is the sum of its files.
          assert.same({ additions = 4, deletions = 2 }, edit.stats)
        end)
      )

      it(
        "tracks the literal glob-character file, not its glob sibling",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          -- `a[1].txt` would glob-match `a1.txt` under jj's default kind. With
          -- the on-disk path resolved to the literal `cwd:` kind, history must
          -- follow only `a[1].txt` and never the sibling `a1.txt`.
          repo.write("a1.txt", "sibling\n")
          repo.jj({ "describe", "-m", "add a1" })
          repo.jj({ "new" })
          repo.write("a[1].txt", "bracket\n")
          repo.jj({ "describe", "-m", "add bracket" })

          local adapter = repo.adapter()
          local AsyncListStream = require("diffview.stream").AsyncListStream
          local JobStatus = require("diffview.vcs.utils").JobStatus

          local stream = AsyncListStream()
          adapter:file_history_worker(stream, {
            log_opt = {
              single_file = { path_args = { "a[1].txt" }, revisions = "::@" },
              multi_file = { path_args = { "a[1].txt" }, revisions = "::@" },
            },
            layout_opt = { default_layout = Diff2, merge_layout = Diff2 },
          })

          local seen_paths = {}
          for _, item in stream:iter() do
            local status, log_entry = unpack(item, 1, 2)
            if status == JobStatus.PROGRESS and log_entry then
              for _, f in ipairs(log_entry.files) do
                seen_paths[f.path] = true
              end
            end
          end

          assert.is_true(seen_paths["a[1].txt"], "expected the literal a[1].txt in history")
          assert.is_nil(seen_paths["a1.txt"], "glob sibling a1.txt must not appear")
        end)
      )
    end)

    describe("fh_compute_pushed_set", function()
      local function init_bare_remote()
        local remote = vim.fn.tempname()
        vim.fn.mkdir(remote, "p")
        run({ "git", "init", "--bare" }, remote)
        return remote
      end

      local function head_commit_id()
        return repo.jj({ "log", "--no-graph", "-T", "commit_id", "-r", "@" })
      end

      local function push_main_to(remote)
        repo.jj({ "bookmark", "create", "main", "-r", "@" })
        repo.jj({ "git", "remote", "add", "origin", remote })
        repo.jj({ "git", "push", "--remote", "origin", "--bookmark", "main", "--allow-new" })
      end

      it(
        "marks ancestors of a pushed remote bookmark as pushed and leaves newer commits unpushed",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          local remote = init_bare_remote()

          -- Build a small linear history, bookmark the second commit, push it,
          -- then add a third commit that's strictly newer than the bookmark.
          repo.write("a.txt", "alpha\n")
          repo.jj({ "describe", "-m", "first" })
          local first = head_commit_id()

          repo.jj({ "new", "-m", "second" })
          repo.write("a.txt", "beta\n")
          local second = head_commit_id()

          push_main_to(remote)

          repo.jj({ "new", "-m", "third" })
          repo.write("a.txt", "gamma\n")
          local third = head_commit_id()

          local adapter = repo.adapter()
          local set = adapter:fh_compute_pushed_set({})
          assert.is_not_nil(set)

          assert.is_true(set[first], "first commit should be reachable from remote_bookmarks()")
          assert.is_true(set[second], "second commit (the bookmark target) should be pushed")
          assert.is_nil(set[third], "third commit is past the bookmark and should not be pushed")

          pcall(vim.fn.delete, remote, "rf")
        end)
      )

      it(
        "returns an empty set when the repo has no remotes",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("a.txt", "alpha\n")
          repo.jj({ "describe", "-m", "only" })

          local adapter = repo.adapter()
          local set = adapter:fh_compute_pushed_set({})
          assert.is_not_nil(set)
          assert.same({}, set)
        end)
      )

      it(
        "restricts the set to commits touching the given path scope",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          local remote = init_bare_remote()

          -- Two pushed commits, each touching a different file. Scoping to
          -- only one of those paths must drop the unrelated commit.
          repo.write("kept.txt", "k\n")
          repo.jj({ "describe", "-m", "touch kept" })
          local kept_sha = head_commit_id()

          repo.jj({ "new", "-m", "touch other" })
          repo.write("other.txt", "o\n")
          local other_sha = head_commit_id()

          push_main_to(remote)

          local adapter = repo.adapter()
          local set = adapter:fh_compute_pushed_set({ "kept.txt" })
          assert.is_not_nil(set)
          assert.is_true(set[kept_sha], "kept.txt's commit should appear in the path-scoped set")
          assert.is_nil(set[other_sha], "other.txt's commit must not appear in the kept.txt scope")

          pcall(vim.fn.delete, remote, "rf")
        end)
      )
    end)

    describe("file_history_dry_run", function()
      it(
        "returns a `file:` hint when a literal path can't parse as a fileset",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          -- `(app)` is a fileset operator and `[id]` keeps the path unquoted, so
          -- jj fails to parse it. The path does not exist on disk, so it cannot
          -- be resolved literally; the dry run should surface an actionable hint
          -- rather than the misleading "no history" message.
          repo.write("readme.md", "x\n")
          repo.jj({ "describe", "-m", "init" })

          local adapter = repo.adapter()
          local ok, _, err =
            adapter:file_history_dry_run({ path_args = { "src/routes/(app)/[id]/page.svelte" } })

          assert.is_false(ok)
          assert.is_not_nil(err)
          assert.is_truthy(err:find("file:", 1, true), "hint should mention the file: prefix")
        end)
      )

      it(
        "does not add the hint for a plain path with genuinely no history",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("present.txt", "x\n")
          repo.jj({ "describe", "-m", "add present" })

          local adapter = repo.adapter()
          -- A well-formed path that simply isn't tracked: empty history, but not
          -- a parse error, so no `file:` hint.
          local ok, _, err = adapter:file_history_dry_run({ path_args = { "absent.txt" } })

          assert.is_false(ok)
          assert.is_nil(err)
        end)
      )

      it(
        "succeeds for an existing path that mixes glob and operator characters",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          -- The bare path would fail fileset parsing, but because it exists on
          -- disk it resolves to the literal `cwd:` kind, so the dry run finds
          -- history with no parse error and no `file:` hint.
          local path = "src/routes/(app)/[id]/page.svelte"
          repo.write(path, "<svelte/>\n")
          repo.jj({ "describe", "-m", "add route" })

          local adapter = repo.adapter()
          local ok, _, err = adapter:file_history_dry_run({ path_args = { path } })

          assert.is_true(ok)
          assert.is_nil(err)
        end)
      )
    end)

    describe("file_restore", function()
      it(
        "restores a modified working-copy file from @-",
        helpers.async_test(function()
          if not jj_available() then
            pending("jj not installed")
            return
          end

          repo.write("src/main.lua", 'print("v1")\n')
          repo.jj({ "describe", "-m", "initial" })
          repo.jj({ "new" })
          repo.write("src/main.lua", 'print("v2")\n')

          local adapter = repo.adapter()
          local ok, undo = await(adapter:file_restore("src/main.lua", "working", nil))

          eq(true, ok)
          eq(":!jj op undo", undo)
          eq('print("v1")\n', repo.read("src/main.lua"))
        end)
      )
    end)
  end)
  describe("structure_fh_data", function()
    local structure_fh_data = require("diffview.vcs.adapters.jj")._test.structure_fh_data
    local JjRev = require("diffview.vcs.adapters.jj.rev").JjRev

    local SOH = "\x01" -- outer field separator
    local US = "\x1f" -- status/path separator within a file entry
    local RS = "\x1e" -- between file entries

    local function build_line(fields)
      return table.concat(fields, SOH)
    end

    it("parses a full commit record", function()
      local files = table.concat({
        "M" .. US .. "a.txt" .. US .. "3" .. US .. "1",
        "A" .. US .. "b.txt" .. US .. "5" .. US .. "0",
      }, RS)
      local data = structure_fh_data(build_line({
        "deadbeef",
        "qpzqyx",
        "cafebabe",
        "alice@example.com",
        "1700000000",
        "+0200",
        "5 minutes ago",
        "main",
        "feat: add b",
        files,
      }))

      assert.is_not_nil(data)
      assert.equals("deadbeef", data.right_hash)
      assert.equals("cafebabe", data.left_hash)
      assert.is_nil(data.merge_hash)
      assert.equals("alice@example.com", data.author)
      assert.equals(1700000000, data.time)
      assert.equals("+0200", data.time_offset)
      assert.equals("5 minutes ago", data.rel_date)
      assert.equals("main", data.ref_names)
      assert.equals("feat: add b", data.subject)
      eq({
        { status = "M", path = "a.txt", stats = { additions = 3, deletions = 1 } },
        { status = "A", path = "b.txt", stats = { additions = 5, deletions = 0 } },
      }, data.namestat)
    end)

    it("returns nil for the root commit (null-tree hash)", function()
      local line = build_line({
        JjRev.NULL_TREE_SHA,
        "zzzz",
        "",
        "",
        "0",
        "+0000",
        "56 years ago",
        "",
        "",
        "",
      })
      assert.is_nil(structure_fh_data(line))
    end)

    it("drops a null-tree parent so the entry is treated as a root-child", function()
      local line = build_line({
        "abc123",
        "qpzqyx",
        JjRev.NULL_TREE_SHA, -- parent is the synthetic root
        "",
        "1700000000",
        "+0000",
        "",
        "",
        "init",
        "",
      })
      local data = structure_fh_data(line)
      assert.is_nil(data.left_hash)
    end)

    it("tolerates empty optional fields without shifting downstream slots", function()
      -- Empty author email and empty bookmarks/subject -- the case that broke
      -- the previous line-per-field parser.
      local line = build_line({
        "abc",
        "xyz",
        "parent",
        "", -- no author email
        "1700000000",
        "+0000",
        "",
        "", -- no ref names
        "", -- no subject
        "M" .. US .. "f.txt" .. US .. "2" .. US .. "4",
      })
      local data = structure_fh_data(line)
      assert.equals("abc", data.right_hash)
      assert.equals("", data.author)
      assert.equals(1700000000, data.time)
      assert.equals("", data.ref_names)
      assert.equals("", data.subject)
      eq(
        { { status = "M", path = "f.txt", stats = { additions = 2, deletions = 4 } } },
        data.namestat
      )
    end)

    it("yields an empty namestat when the commit has no diff", function()
      local data = structure_fh_data(build_line({
        "abc",
        "xyz",
        "parent",
        "",
        "1700000000",
        "+0000",
        "",
        "",
        "empty commit",
        "",
      }))
      eq({}, data.namestat)
    end)

    it("splits multiple file entries on the RS separator", function()
      -- The middle entry covers jj's binary-file shape: `lines_added()` and
      -- `lines_removed()` both render as integer `0`, with no sentinel. The
      -- parser collapses `(0, 0)` to `stats = nil` so binary (and pure-rename
      -- or mode-only) changes don't surface a misleading "0, 0" in the panel,
      -- matching the git adapter's `- -` numstat handling.
      local files = table.concat({
        "A" .. US .. "x" .. US .. "1" .. US .. "0",
        "M" .. US .. "y" .. US .. "0" .. US .. "0",
        "D" .. US .. "z" .. US .. "0" .. US .. "7",
      }, RS)
      local data = structure_fh_data(build_line({
        "abc",
        "xyz",
        "parent",
        "",
        "1700000000",
        "+0000",
        "",
        "",
        "multi",
        files,
      }))
      eq({
        { status = "A", path = "x", stats = { additions = 1, deletions = 0 } },
        { status = "M", path = "y" },
        { status = "D", path = "z", stats = { additions = 0, deletions = 7 } },
      }, data.namestat)
    end)
  end)

  describe("parse_fh_data", function()
    local Diff2 = require("diffview.scene.layouts.diff_2").Diff2

    local saved_bootstrap

    before_each(function()
      saved_bootstrap = vim.deepcopy(JjAdapter.bootstrap)
    end)

    after_each(function()
      if saved_bootstrap then
        JjAdapter.bootstrap = saved_bootstrap
        saved_bootstrap = nil
      end
    end)

    -- Construct a JjAdapter without invoking `jj`. parse_fh_data only needs
    -- a toplevel and stubbed bootstrap state to assemble file entries from
    -- the supplied data table.
    local function make_adapter()
      local repo = vim.fn.tempname()
      vim.fn.mkdir(repo, "p")

      JjAdapter.bootstrap.done = true
      JjAdapter.bootstrap.ok = true

      return JjAdapter({ toplevel = repo, path_args = {} }), repo
    end

    it("matches a file against workspace-relative scope_args", function()
      local adapter, repo = make_adapter()

      local state = {
        -- `path_args` retains the user-supplied form (absolute here); the
        -- post-filter now consumes `scope_args`, which `file_history_worker`
        -- has already resolved to workspace-relative form.
        path_args = { repo .. "/foo.txt" },
        scope_args = { "foo.txt" },
        log_options = {},
        prepared_log_opts = {},
        layout_opt = { default_layout = Diff2 },
        single_file = true,
      }

      local data = {
        left_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        right_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        namestat = {
          { status = "M", path = "foo.txt", stats = { additions = 3, deletions = 1 } },
        },
      }

      local success, log_entry = adapter:parse_fh_data(data, {}, state)
      assert.True(success)
      ---@cast log_entry LogEntry

      assert.equals(1, #log_entry.files)
      assert.equals("foo.txt", log_entry.files[1].path)
      assert.same({ additions = 3, deletions = 1 }, log_entry.files[1].stats)
      assert.same({ additions = 3, deletions = 1 }, log_entry.stats)

      pcall(vim.fn.delete, repo, "rf")
    end)

    it("filters out files outside the scope_args set", function()
      local adapter, repo = make_adapter()

      local state = {
        path_args = { repo .. "/keep.txt" },
        scope_args = { "keep.txt" },
        log_options = {},
        prepared_log_opts = {},
        layout_opt = { default_layout = Diff2 },
        single_file = true,
      }

      local data = {
        left_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        right_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        namestat = {
          { status = "M", path = "unrelated.txt", stats = { additions = 1, deletions = 0 } },
        },
      }

      local success, msg = adapter:parse_fh_data(data, {}, state)
      assert.False(success)
      assert.equals("Found no relevant file data with given path args!", msg)

      pcall(vim.fn.delete, repo, "rf")
    end)

    it("marks the commit as pushed when its hash is in `state.pushed_set`", function()
      local adapter, repo = make_adapter()

      local pushed_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      local state = {
        path_args = { repo .. "/foo.txt" },
        scope_args = { "foo.txt" },
        log_options = {},
        prepared_log_opts = {},
        layout_opt = { default_layout = Diff2 },
        single_file = true,
        pushed_set = { [pushed_hash] = true },
      }

      local data = {
        left_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        right_hash = pushed_hash,
        namestat = {
          { status = "M", path = "foo.txt", stats = { additions = 1, deletions = 0 } },
        },
      }

      local success, log_entry = adapter:parse_fh_data(data, { hash = pushed_hash }, state)
      assert.True(success)
      ---@cast log_entry LogEntry
      assert.True(log_entry.is_pushed)

      pcall(vim.fn.delete, repo, "rf")
    end)

    it("marks the commit as not pushed when its hash is absent from `state.pushed_set`", function()
      local adapter, repo = make_adapter()

      local local_hash = "cccccccccccccccccccccccccccccccccccccccc"
      local state = {
        path_args = { repo .. "/foo.txt" },
        scope_args = { "foo.txt" },
        log_options = {},
        prepared_log_opts = {},
        layout_opt = { default_layout = Diff2 },
        single_file = true,
        pushed_set = {},
      }

      local data = {
        left_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        right_hash = local_hash,
        namestat = {
          { status = "M", path = "foo.txt", stats = { additions = 1, deletions = 0 } },
        },
      }

      local success, log_entry = adapter:parse_fh_data(data, { hash = local_hash }, state)
      assert.True(success)
      ---@cast log_entry LogEntry
      assert.False(log_entry.is_pushed)

      pcall(vim.fn.delete, repo, "rf")
    end)
  end)

  describe("history_scope", function()
    local saved_bootstrap

    before_each(function()
      saved_bootstrap = vim.deepcopy(JjAdapter.bootstrap)
    end)

    after_each(function()
      if saved_bootstrap then
        JjAdapter.bootstrap = saved_bootstrap
        saved_bootstrap = nil
      end
    end)

    it("returns single_file for a real tracked file in a jj repo", function()
      local jj_available = vim.fn.executable("jj") == 1
      if not jj_available then
        pending("jj not installed")
        return
      end

      local repo_dir = vim.fn.tempname()
      vim.fn.mkdir(repo_dir, "p")
      vim.system({ "jj", "git", "init" }, { cwd = repo_dir }):wait()
      vim.system({ "jj", "config", "set", "--repo", "user.name", "T" }, { cwd = repo_dir }):wait()
      vim
        .system({ "jj", "config", "set", "--repo", "user.email", "t@t" }, { cwd = repo_dir })
        :wait()
      local f = assert(io.open(repo_dir .. "/foo.txt", "w"))
      f:write("hello\n")
      f:close()
      vim.system({ "jj", "describe", "-m", "add" }, { cwd = repo_dir }):wait()

      JjAdapter.bootstrap.done = true
      JjAdapter.bootstrap.ok = true
      local adapter = JjAdapter({ toplevel = repo_dir, path_args = {} })
      local scope = adapter:history_scope({ repo_dir .. "/foo.txt" }, {})
      assert.is_true(scope.single_file)

      vim.fn.delete(repo_dir, "rf")
    end)

    it("returns multi_file for an empty path_args", function()
      local jj_available = vim.fn.executable("jj") == 1
      if not jj_available then
        pending("jj not installed")
        return
      end

      local repo_dir = vim.fn.tempname()
      vim.fn.mkdir(repo_dir, "p")
      vim.system({ "jj", "git", "init" }, { cwd = repo_dir }):wait()

      JjAdapter.bootstrap.done = true
      JjAdapter.bootstrap.ok = true
      local adapter = JjAdapter({ toplevel = repo_dir, path_args = {} })
      local scope = adapter:history_scope({}, {})
      assert.is_false(scope.single_file)

      vim.fn.delete(repo_dir, "rf")
    end)

    it("returns multi_file for a directory pathspec", function()
      local jj_available = vim.fn.executable("jj") == 1
      if not jj_available then
        pending("jj not installed")
        return
      end

      local repo_dir = vim.fn.tempname()
      vim.fn.mkdir(repo_dir .. "/sub", "p")
      vim.system({ "jj", "git", "init" }, { cwd = repo_dir }):wait()

      JjAdapter.bootstrap.done = true
      JjAdapter.bootstrap.ok = true
      local adapter = JjAdapter({ toplevel = repo_dir, path_args = {} })
      local scope = adapter:history_scope({ repo_dir .. "/sub" }, {})
      assert.is_false(scope.single_file)

      vim.fn.delete(repo_dir, "rf")
    end)
  end)

  describe("is_non_literal_pathspec", function()
    local is_non_literal_pathspec =
      require("diffview.vcs.adapters.jj")._test.is_non_literal_pathspec

    it("treats `.` and the empty string as literal", function()
      assert.is_false(is_non_literal_pathspec("."))
      assert.is_false(is_non_literal_pathspec(""))
    end)

    it("flags known jj fileset kind prefixes", function()
      assert.is_true(is_non_literal_pathspec("glob:*.lua"))
      assert.is_true(is_non_literal_pathspec("root:foo"))
      assert.is_true(is_non_literal_pathspec("cwd:foo"))
      assert.is_true(is_non_literal_pathspec("cwd-glob:**/*.lua"))
      assert.is_true(is_non_literal_pathspec("file:foo.txt"))
      assert.is_true(is_non_literal_pathspec("root-file:foo.txt"))
      assert.is_true(is_non_literal_pathspec("root-glob:**/*.lua"))
      assert.is_true(is_non_literal_pathspec("prefix-glob:*.d"))
    end)

    it("flags the case-insensitive `-i` glob variants", function()
      assert.is_true(is_non_literal_pathspec("glob-i:*.TXT"))
      assert.is_true(is_non_literal_pathspec("cwd-glob-i:*.TXT"))
      assert.is_true(is_non_literal_pathspec("root-glob-i:*.TXT"))
    end)

    it("flags shell glob metacharacters", function()
      assert.is_true(is_non_literal_pathspec("*.lua"))
      assert.is_true(is_non_literal_pathspec("src/?.lua"))
      assert.is_true(is_non_literal_pathspec("[abc].lua"))
    end)

    it("keeps Windows drive letters literal", function()
      assert.is_false(is_non_literal_pathspec("C:/foo.txt"))
      assert.is_false(is_non_literal_pathspec("D:\\bar.txt"))
    end)

    it("keeps a literal filename with a colon literal", function()
      -- A colon is legal in a Unix filename. Only jj's recognised kinds are
      -- non-literal, so an unknown `<word>:` prefix (a real filename, or `jj
      -- file-list:` which is not a fileset kind) must stay literal and get
      -- quoted rather than parsed by jj as an invalid pattern kind.
      assert.is_false(is_non_literal_pathspec("foo:bar.txt"))
      assert.is_false(is_non_literal_pathspec("src/foo:bar.txt"))
      assert.is_false(is_non_literal_pathspec("2024:01:01.log"))
      assert.is_false(is_non_literal_pathspec("file-list:paths.txt"))
    end)

    it("keeps bare relative and absolute paths literal", function()
      assert.is_false(is_non_literal_pathspec("foo.txt"))
      assert.is_false(is_non_literal_pathspec("src/foo.txt"))
      assert.is_false(is_non_literal_pathspec("/abs/foo.txt"))
      assert.is_false(is_non_literal_pathspec("./foo.txt"))
    end)
  end)

  describe("quote_path_args", function()
    local quote_path_args = require("diffview.vcs.adapters.jj")._test.quote_path_args

    it("quotes a literal path so fileset metacharacters match literally", function()
      eq(
        { '"frontend/src/routes/(test)/View.svelte"' },
        quote_path_args({
          "frontend/src/routes/(test)/View.svelte",
        })
      )
    end)

    it("leaves non-literal pathspecs untouched so filesets keep working", function()
      eq(
        { "glob:*.lua", "root:foo", "*.lua" },
        quote_path_args({
          "glob:*.lua",
          "root:foo",
          "*.lua",
        })
      )
    end)

    it("quotes a literal filename containing a colon", function()
      -- `foo:bar.txt` is a valid Unix filename, not a jj `<kind>:` pathspec, so
      -- it must be quoted; left bare, jj would reject `foo:` as a pattern kind.
      eq({ '"foo:bar.txt"' }, quote_path_args({ "foo:bar.txt" }))
    end)

    it("leaves the `.` and empty sentinels untouched", function()
      eq({ ".", "" }, quote_path_args({ ".", "" }))
    end)

    it("quotes only the literal members of a mixed list", function()
      eq(
        { '"src/(a)/x.lua"', "glob:*.lua" },
        quote_path_args({
          "src/(a)/x.lua",
          "glob:*.lua",
        })
      )
    end)

    it("matches a glob-character path literally when it exists on disk", function()
      local top = vim.fn.tempname()
      vim.fn.mkdir(top .. "/src/routes/(app)/[id]", "p")
      local f = assert(io.open(top .. "/src/routes/(app)/[id]/page.svelte", "w"))
      f:write("x")
      f:close()
      local g = assert(io.open(top .. "/a[1].txt", "w"))
      g:write("x")
      g:close()

      -- Existing paths with glob metacharacters resolve to the non-globbing
      -- `cwd:` kind so jj matches them literally instead of as a glob.
      eq({ 'cwd:"a[1].txt"' }, quote_path_args({ "a[1].txt" }, top))
      eq(
        { 'cwd:"src/routes/(app)/[id]/page.svelte"' },
        quote_path_args({ "src/routes/(app)/[id]/page.svelte" }, top)
      )

      vim.fn.delete(top, "rf")
    end)

    it("leaves a glob as a glob when no file matches it on disk", function()
      local top = vim.fn.tempname()
      vim.fn.mkdir(top, "p")

      -- An intentional glob, and a glob-character path that names nothing on
      -- disk, are both left bare for jj to expand.
      eq({ "*.lua" }, quote_path_args({ "*.lua" }, top))
      eq({ "missing[1].txt" }, quote_path_args({ "missing[1].txt" }, top))

      vim.fn.delete(top, "rf")
    end)
  end)

  describe("is_ambiguous_literal_path", function()
    local is_ambiguous_literal_path =
      require("diffview.vcs.adapters.jj")._test.is_ambiguous_literal_path

    it("flags an unquoted glob-char path that also has a fileset operator", function()
      -- A SvelteKit route: `[id]` keeps it unquoted, `(app)` then breaks jj's
      -- fileset parser. This is the shape that needs an explicit `file:`.
      assert.is_true(is_ambiguous_literal_path("src/routes/(app)/[id]/page.svelte"))
      assert.is_true(is_ambiguous_literal_path("a b[1].txt"))
    end)

    it("does not flag a glob-char path with no fileset operator", function()
      -- `a[1].txt` is left unquoted but parses (it just globs a sibling); it is
      -- not a hard parse error, so it is out of scope here.
      assert.is_false(is_ambiguous_literal_path("a[1].txt"))
      assert.is_false(is_ambiguous_literal_path("*.lua"))
    end)

    it("does not flag an operator-only path (it is auto-quoted)", function()
      assert.is_false(is_ambiguous_literal_path("(app)/page.svelte"))
      assert.is_false(is_ambiguous_literal_path("src/foo.txt"))
    end)

    it("does not flag an explicit fileset kind prefix", function()
      assert.is_false(is_ambiguous_literal_path("glob:(app)/*.svelte"))
    end)
  end)
end)
