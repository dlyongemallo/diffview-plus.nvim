local async = require("diffview.async")
local config = require("diffview.config")
local control = require("diffview.control")
local File = require("diffview.vcs.file").File
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local helpers = require("diffview.tests.helpers")

local Signal = control.Signal

describe("diffview.vcs.file", function()
  it("uses the null buffer when a conflict stage blob is missing", function()
    local show_called = false

    local adapter = {
      ctx = {
        toplevel = vim.uv.cwd(),
        dir = vim.uv.cwd(),
      },
      file_blob_hash = function(_, _, rev_arg)
        assert.equals(":2", rev_arg)
        return nil
      end,
      is_binary = function()
        return false
      end,
      show = function(_, _, _, callback)
        show_called = true
        callback(nil, { "unexpected" })
      end,
    }

    local file = File({
      adapter = adapter,
      path = "README.md",
      kind = "conflicting",
      rev = GitRev(RevType.STAGE, 2),
    })

    local bufnr = async.await(file:create_buffer())

    assert.equals(File._get_null_buffer(), bufnr)
    assert.False(show_called)
  end)

  it("adopts a stale `diffview://null` in a tab's only window without raising E444", function()
    -- Regression: `_get_null_buffer` used to call `utils.wipe_named_buffer`
    -- when `nvim_buf_set_name` collided with an existing `diffview://null`
    -- buffer. `wipe_named_buffer` closes every window showing that buffer,
    -- which throws E444 when the stale buffer occupies the only window in
    -- the current tabpage. The function now adopts the existing buffer.
    local null_buf = File._get_null_buffer()

    -- Stage the scenario: a fresh tab whose only window displays the null
    -- buffer, mimicking a stale `diffview://null` from a previous session.
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_buf(null_buf)

    -- Drop the cached singleton so `_get_null_buffer` re-runs the
    -- adoption path against the still-named buffer.
    File.NULL_FILE.bufnr = nil

    local ok, adopted = pcall(File._get_null_buffer)

    assert.is_true(ok)
    assert.equals(null_buf, adopted)
    assert.is_true(vim.api.nvim_tabpage_is_valid(tab))

    if vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
    end
  end)

  it("does not probe binary-ness for a nulled file", function()
    -- A deleted file's gone `LOCAL` path makes `is_binary` false-positive; a
    -- nulled side must not be probed (its result is unused).
    local is_binary_called = false

    local adapter = {
      ctx = {
        toplevel = vim.uv.cwd(),
        dir = vim.uv.cwd(),
      },
      is_binary = function()
        is_binary_called = true
        return true -- simulate the deleted-working-tree-path false positive
      end,
    }

    local file = File({
      adapter = adapter,
      path = "deleted.txt",
      kind = "working",
      rev = GitRev(RevType.LOCAL),
      nulled = true,
    })

    local bufnr = async.await(file:create_buffer())

    assert.False(is_binary_called)
    assert.is_not_true(file.binary)
    assert.equals(File._get_null_buffer(), bufnr)
  end)

  it(
    "bails out of create_buffer if deactivated before produce_data",
    helpers.async_test(function()
      local show_called = false

      local adapter = {
        ctx = {
          toplevel = vim.uv.cwd(),
          dir = vim.uv.cwd(),
        },
        is_binary = function()
          return false
        end,
        show = async.wrap(function(_, _, _, callback)
          show_called = true
          callback(nil, { "some data" })
        end),
      }

      local file = File({
        adapter = adapter,
        path = "README.md",
        kind = "working",
        rev = GitRev(RevType.COMMIT, "abc1234"),
      })

      -- Deactivate the file before create_buffer runs.
      file.active = false

      local ok, err = async.pawait(file.create_buffer, file)

      assert.False(ok)
      assert.is_string(err)
      assert.is_not_nil(err:find(File.CANCELLED, 1, true))
      -- produce_data (and thus show) should never have been called.
      assert.False(show_called)
      assert.is_nil(file.bufnr)
    end)
  )

  it(
    "bails out of create_buffer if deactivated during produce_data",
    helpers.async_test(function()
      local yield_signal = Signal("yield")
      local produce_data_started = Signal("produce_data_started")
      local show_called = false

      local adapter = {
        ctx = {
          toplevel = vim.uv.cwd(),
          dir = vim.uv.cwd(),
        },
        is_binary = function()
          return false
        end,
        show = async.wrap(function(_, _, _, callback)
          show_called = true
          produce_data_started:send()
          async.await(yield_signal)
          callback(nil, { "some data" })
        end),
      }

      local file = File({
        adapter = adapter,
        path = "README.md",
        kind = "working",
        rev = GitRev(RevType.COMMIT, "abc1234"),
      })

      -- Capture results from the thread so we can assert outside it.
      -- Assertions inside async.void coroutines fail silently.
      local thread_ok, thread_err

      local create_buffer_thread = async.void(function()
        thread_ok, thread_err = async.pawait(file.create_buffer, file)
      end)

      create_buffer_thread()

      -- Wait for produce_data to start, confirming the show job was invoked.
      async.await(produce_data_started)
      assert.is_not_nil(file.bufnr)
      assert.is_true(vim.api.nvim_buf_is_valid(file.bufnr))
      local pre_cancel_bufnr = file.bufnr

      -- Deactivate the file while produce_data is yielded, then resume it.
      file.active = false
      yield_signal:send()

      -- Let the thread finish.
      async.await(async.scheduler())

      -- The pre-allocated buffer should have been cleaned up.
      assert.is_true(show_called)
      assert.False(thread_ok)
      assert.is_string(thread_err)
      assert.is_not_nil(thread_err:find(File.CANCELLED, 1, true))
      assert.is_nil(file.bufnr)
      assert.is_false(vim.api.nvim_buf_is_valid(pre_cancel_bufnr))
    end)
  )

  describe("diffview:// buffer guards", function()
    local file_counter = 0
    local created_files = {}

    ---Create a File with a COMMIT rev whose create_buffer succeeds.
    ---Uses a unique path each time so buffers are not reused across tests.
    ---@return vcs.File
    local function make_commit_file()
      file_counter = file_counter + 1

      local adapter = {
        ctx = {
          toplevel = vim.uv.cwd(),
          dir = vim.uv.cwd(),
        },
        is_binary = function()
          return false
        end,
        show = async.wrap(function(_, _, _, callback)
          callback(nil, { "line1", "line2" })
        end),
      }

      local file = File({
        adapter = adapter,
        path = "test_guard_" .. file_counter .. ".txt",
        kind = "working",
        rev = GitRev(RevType.COMMIT, "abc1234"),
      })
      table.insert(created_files, file)
      return file
    end

    after_each(function()
      for _, file in ipairs(created_files) do
        File.safe_delete_buf(file.bufnr)
      end
      created_files = {}
    end)

    it(
      "sets autoformat=false on diffview:// buffers",
      helpers.async_test(function()
        local file = make_commit_file()
        async.await(file:create_buffer())

        assert.is_not_nil(file.bufnr)
        assert.is_false(vim.b[file.bufnr].autoformat)
      end)
    )

    it(
      "registers an LspAttach autocmd on diffview:// buffers",
      helpers.async_test(function()
        local file = make_commit_file()
        async.await(file:create_buffer())

        assert.is_not_nil(file.bufnr)
        local aus = vim.api.nvim_get_autocmds({ event = "LspAttach", buffer = file.bufnr })
        assert.is_true(#aus > 0)
      end)
    )

    it(
      "sets buftype=acwrite on stage-0 diffview:// buffers",
      helpers.async_test(function()
        file_counter = file_counter + 1

        local adapter = {
          ctx = {
            toplevel = vim.uv.cwd(),
            dir = vim.uv.cwd(),
          },
          is_binary = function()
            return false
          end,
          show = async.wrap(function(_, _, _, callback)
            callback(nil, { "line1", "line2" })
          end),
          file_blob_hash = function()
            return "abcdef1234"
          end,
        }

        local file = File({
          adapter = adapter,
          path = "test_guard_" .. file_counter .. ".c",
          kind = "working",
          rev = GitRev(RevType.STAGE, 0),
        })
        table.insert(created_files, file)

        async.await(file:create_buffer())

        assert.is_not_nil(file.bufnr)
        -- Stage-0 buffers write via BufWriteCmd, so buftype must be "acwrite"
        -- rather than "" to prevent LSP clients and plugins (e.g. LazyVim)
        -- from treating them as normal files.
        assert.equals("acwrite", vim.bo[file.bufnr].buftype)
        assert.is_true(vim.bo[file.bufnr].modifiable)
      end)
    )

    describe("large_file_threshold", function()
      local original_config

      before_each(function()
        original_config = vim.deepcopy(config.get_config())
      end)

      after_each(function()
        if original_config then
          config.setup(original_config)
          original_config = nil
        end
      end)

      it(
        "sets diffview_disable_ts flag when buffer exceeds threshold",
        helpers.async_test(function()
          config.setup({ large_file_threshold = 5 })

          local lines = {}
          for i = 1, 10 do
            lines[i] = "line " .. i
          end

          file_counter = file_counter + 1
          local adapter = {
            ctx = {
              toplevel = vim.uv.cwd(),
              dir = vim.uv.cwd(),
            },
            is_binary = function()
              return false
            end,
            show = async.wrap(function(_, _, _, callback)
              callback(nil, lines)
            end),
          }

          local file = File({
            adapter = adapter,
            path = "test_large_" .. file_counter .. ".txt",
            kind = "working",
            rev = GitRev(RevType.COMMIT, "abc1234"),
          })
          table.insert(created_files, file)
          async.await(file:create_buffer())

          assert.is_not_nil(file.bufnr)
          assert.is_true(vim.b[file.bufnr].diffview_disable_ts)
        end)
      )

      it(
        "does not set diffview_disable_ts flag when buffer is under threshold",
        helpers.async_test(function()
          config.setup({ large_file_threshold = 100 })

          file_counter = file_counter + 1
          local adapter = {
            ctx = {
              toplevel = vim.uv.cwd(),
              dir = vim.uv.cwd(),
            },
            is_binary = function()
              return false
            end,
            show = async.wrap(function(_, _, _, callback)
              callback(nil, { "line1", "line2" })
            end),
          }

          local file = File({
            adapter = adapter,
            path = "test_small_" .. file_counter .. ".txt",
            kind = "working",
            rev = GitRev(RevType.COMMIT, "abc1234"),
          })
          table.insert(created_files, file)
          async.await(file:create_buffer())

          assert.is_not_nil(file.bufnr)
          assert.is_nil(vim.b[file.bufnr].diffview_disable_ts)
        end)
      )
    end)
  end)

  -- `is_valid()` must require `loaded`, not just a `bufnr`, so that a
  -- concurrent caller arriving mid-load doesn't proceed with an empty
  -- placeholder buffer. Concurrent callers on the same File instance
  -- await the in-flight load via `_loading` and share its outcome.
  describe("loaded flag and concurrent create_buffer coordination", function()
    it("starts with loaded=false; flips to true after content is populated", function()
      local file = File({
        adapter = {
          ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
          is_binary = function()
            return false
          end,
          show = async.wrap(function(_, _, _, callback)
            callback(nil, { "content" })
          end),
        },
        path = "loaded_initial.txt",
        kind = "working",
        rev = GitRev(RevType.COMMIT, "abc1234"),
      })

      assert.is_false(file.loaded)
      assert.is_false(file:is_valid())

      async.await(file:create_buffer())
      assert.is_true(file.loaded)
      assert.is_true(file:is_valid())

      File.safe_delete_buf(file.bufnr)
    end)

    it("NULL_FILE is loaded so callers checking is_valid() accept it", function()
      assert.is_true(File.NULL_FILE.loaded)
    end)

    it(
      "concurrent caller waits for the in-flight create_buffer and gets the same bufnr",
      helpers.async_test(function()
        local yield_signal = Signal("yield_concurrent")
        local produce_data_started = Signal("produce_data_started_concurrent")
        local show_call_count = 0

        local adapter = {
          ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
          is_binary = function()
            return false
          end,
          show = async.wrap(function(_, _, _, callback)
            show_call_count = show_call_count + 1
            produce_data_started:send()
            async.await(yield_signal)
            callback(nil, { "concurrent_line1", "concurrent_line2" })
          end),
        }

        local file = File({
          adapter = adapter,
          path = "concurrent_load.txt",
          kind = "working",
          rev = GitRev(RevType.COMMIT, "abc1234"),
        })

        -- First caller starts the load. It will yield inside `show`.
        local first_bufnr, second_bufnr
        local first_done, second_done = false, false
        local first_thread = async.void(function()
          first_bufnr = async.await(file:create_buffer())
          first_done = true
        end)
        first_thread()

        -- Wait until the first caller is mid-load: bufnr created, content
        -- not yet populated. `is_valid()` must report false here.
        async.await(produce_data_started)
        local mid_load_bufnr = file.bufnr
        assert.is_not_nil(mid_load_bufnr)
        assert.is_true(vim.api.nvim_buf_is_valid(mid_load_bufnr))
        assert.is_false(file.loaded)
        assert.is_false(file:is_valid()) -- the load-not-done guard
        assert.is_not_nil(file._loading)

        -- Second caller starts mid-load. It should see `_loading` and
        -- await rather than racing through.
        local second_thread = async.void(function()
          second_bufnr = async.await(file:create_buffer())
          second_done = true
        end)
        second_thread()
        async.await(async.scheduler())
        assert.is_false(second_done) -- still waiting on the in-flight load
        assert.equals(1, show_call_count) -- and didn't restart the show job

        -- Release the in-flight load. Both callers settle with the same bufnr.
        yield_signal:send()
        vim.wait(2000, function()
          return first_done and second_done
        end, 5)

        assert.is_true(first_done)
        assert.is_true(second_done)
        assert.equals(mid_load_bufnr, first_bufnr)
        assert.equals(mid_load_bufnr, second_bufnr)
        assert.is_true(file.loaded)
        assert.equals(1, show_call_count) -- exactly one git show, shared

        File.safe_delete_buf(file.bufnr)
      end)
    )

    it(
      "concurrent caller propagates cancellation when the in-flight load is cancelled",
      helpers.async_test(function()
        local yield_signal = Signal("yield_cancel")
        local produce_data_started = Signal("produce_data_started_cancel")

        local adapter = {
          ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
          is_binary = function()
            return false
          end,
          show = async.wrap(function(_, _, _, callback)
            produce_data_started:send()
            async.await(yield_signal)
            callback(nil, { "cancel_line" })
          end),
        }

        local file = File({
          adapter = adapter,
          path = "concurrent_cancel.txt",
          kind = "working",
          rev = GitRev(RevType.COMMIT, "abc1234"),
        })

        local first_ok, first_err
        local first_thread = async.void(function()
          first_ok, first_err = async.pawait(file.create_buffer, file)
        end)
        first_thread()

        async.await(produce_data_started)

        -- Concurrent caller arrives mid-load.
        local second_ok, second_err
        local second_thread = async.void(function()
          second_ok, second_err = async.pawait(file.create_buffer, file)
        end)
        second_thread()
        async.await(async.scheduler())

        -- Cancel the in-flight load by deactivating the file, then let
        -- the yielded `show` resume so the first caller hits the
        -- post-produce_data cancellation branch.
        file.active = false
        yield_signal:send()

        vim.wait(2000, function()
          return first_ok ~= nil and second_ok ~= nil
        end, 5)

        assert.is_false(first_ok)
        assert.is_string(first_err)
        assert.is_not_nil(first_err:find(File.CANCELLED, 1, true))

        -- The second caller must also see the failure, not return a
        -- half-built bufnr.
        assert.is_false(second_ok)
        assert.is_string(second_err)
        assert.is_not_nil(second_err:find(File.CANCELLED, 1, true))
        assert.is_false(file.loaded)
      end)
    )

    it(
      "waiter receives the in-flight load's original error message",
      helpers.async_test(function()
        local yield_signal = Signal("yield_err")
        local produce_data_started = Signal("produce_data_started_err")
        local distinctive_err = "produce_data exploded: something specific"

        local adapter = {
          ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
          is_binary = function()
            return false
          end,
          show = async.wrap(function(_, _, _, callback)
            produce_data_started:send()
            async.await(yield_signal)
            callback({ distinctive_err })
          end),
        }

        local file = File({
          adapter = adapter,
          path = "concurrent_err.txt",
          kind = "working",
          rev = GitRev(RevType.COMMIT, "abc1234"),
        })

        local first_ok, first_err
        local first_thread = async.void(function()
          first_ok, first_err = async.pawait(file.create_buffer, file)
        end)
        first_thread()

        async.await(produce_data_started)

        local second_ok, second_err
        local second_thread = async.void(function()
          second_ok, second_err = async.pawait(file.create_buffer, file)
        end)
        second_thread()
        async.await(async.scheduler())

        yield_signal:send()

        vim.wait(2000, function()
          return first_ok ~= nil and second_ok ~= nil
        end, 5)

        assert.is_false(first_ok)
        assert.is_string(first_err)
        assert.is_not_nil(first_err:find(distinctive_err, 1, true))

        -- The waiter must see the in-flight load's original message,
        -- not a generic "Concurrent buffer load failed" placeholder.
        assert.is_false(second_ok)
        assert.is_string(second_err)
        assert.is_not_nil(second_err:find(distinctive_err, 1, true))
      end)
    )

    it(
      "wipes the freshly-created buffer when produce_data fails",
      helpers.async_test(function()
        local adapter = {
          ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
          is_binary = function()
            return false
          end,
          show = async.wrap(function(_, _, _, callback)
            callback({ "boom" })
          end),
        }

        local file = File({
          adapter = adapter,
          path = "produce_data_failure.txt",
          kind = "working",
          rev = GitRev(RevType.COMMIT, "abc1234"),
        })

        local ok, err = async.pawait(file.create_buffer, file)

        assert.is_false(ok)
        assert.is_string(err)
        assert.is_not_nil(err:find("boom", 1, true))
        -- The half-built `diffview://` buffer must not survive: otherwise
        -- a retry would find it via `find_named_buffer` and short-circuit
        -- with empty content.
        assert.is_nil(file.bufnr)
        assert.is_false(file.loaded)
      end)
    )

    it(
      "errors when find_named_buffer returns an unmarked buffer",
      helpers.async_test(function()
        -- Anchor on the production-computed buffer name by letting a
        -- successful run create it, then deliberately unset the marker
        -- to simulate a stale placeholder.
        local rev = GitRev(RevType.COMMIT, "abc1234567")
        local cwd = vim.uv.cwd()
        local adapter = {
          ctx = { toplevel = cwd, dir = cwd },
          is_binary = function()
            return false
          end,
          show = async.wrap(function(_, _, _, callback)
            callback(nil, { "first" })
          end),
        }

        local first = File({
          adapter = adapter,
          path = "unmarked.txt",
          kind = "working",
          rev = rev,
        })

        local bufnr = async.await(first:create_buffer())
        assert.is_not_nil(bufnr)
        assert.is_true(vim.b[bufnr].diffview_loaded)

        vim.b[bufnr].diffview_loaded = nil

        local second = File({
          adapter = adapter,
          path = "unmarked.txt",
          kind = "working",
          rev = rev,
        })

        local ok, err = async.pawait(second.create_buffer, second)
        assert.is_false(ok)
        assert.is_string(err)
        assert.is_not_nil(err:find("unloaded", 1, true))
        -- The second File should not have adopted the unmarked buffer.
        assert.is_nil(second.bufnr)
        assert.is_false(second.loaded)

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    it(
      "reuses a marked buffer when a second File resolves to the same fullname",
      helpers.async_test(function()
        local rev = GitRev(RevType.COMMIT, "abc1234567")
        local adapter = {
          ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
          is_binary = function()
            return false
          end,
          show = async.wrap(function(_, _, _, callback)
            callback(nil, { "shared" })
          end),
        }

        local first = File({
          adapter = adapter,
          path = "shared_loaded.txt",
          kind = "working",
          rev = rev,
        })
        local first_bufnr = async.await(first:create_buffer())
        assert.is_not_nil(first_bufnr)
        assert.is_true(vim.b[first_bufnr].diffview_loaded)

        local second = File({
          adapter = adapter,
          path = "shared_loaded.txt",
          kind = "working",
          rev = rev,
        })
        local second_bufnr = async.await(second:create_buffer())

        assert.equals(first_bufnr, second_bufnr)
        assert.is_true(second.loaded)

        pcall(vim.api.nvim_buf_delete, first_bufnr, { force = true })
      end)
    )
  end)

  -- Regression: project-scanning plugins (LSP, file managers, fzf-lua warm
  -- caches, ...) can register a buffer by name without loading its
  -- contents. `_create_local_buffer` reuses any buffer whose name matches
  -- the file path, so without a `bufload` guard it would hand the inline
  -- renderer an empty bufnr -- producing zero hunks and stranding the
  -- cursor at line 1 of an apparently-empty buffer.
  describe("LOCAL rev with a pre-existing unloaded buffer", function()
    local tmpdir, tmpfile, prelim

    before_each(function()
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      tmpfile = tmpdir .. "/working_unloaded.txt"
      vim.fn.writefile({ "line 1", "line 2", "line 3" }, tmpfile)
      prelim = nil
    end)

    after_each(function()
      if prelim then
        pcall(vim.api.nvim_buf_delete, prelim, { force = true })
      end
      vim.fn.delete(tmpdir, "rf")
    end)

    it("loads content into a pre-existing unloaded buffer", function()
      -- Mimic a project-scanning plugin that adds the file to the buffer
      -- list without ever loading it.
      prelim = vim.fn.bufadd(tmpfile)
      assert.is_true(prelim > 0)
      assert.is_false(vim.api.nvim_buf_is_loaded(prelim))

      local adapter = {
        ctx = { toplevel = tmpdir, dir = tmpdir },
        is_binary = function()
          return false
        end,
        on_local_buffer_reused = function() end,
      }

      local file = File({
        adapter = adapter,
        path = "working_unloaded.txt",
        absolute_path = tmpfile,
        kind = "working",
        rev = GitRev(RevType.LOCAL),
      })

      async.await(file:create_buffer())

      assert.equals(prelim, file.bufnr)
      assert.is_true(vim.api.nvim_buf_is_loaded(file.bufnr))
      assert.equals(3, vim.api.nvim_buf_line_count(file.bufnr))
    end)
  end)
end)
