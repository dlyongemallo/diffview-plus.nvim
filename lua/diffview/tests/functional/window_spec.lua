local async = require("diffview.async")
local config = require("diffview.config")
local control = require("diffview.control")
local File = require("diffview.vcs.file").File
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local Window = require("diffview.scene.window").Window
local helpers = require("diffview.tests.helpers")

local Signal = control.Signal

---Create a mock adapter with optional overrides.
---@param overrides? table
---@return table
local function mock_adapter(overrides)
  return vim.tbl_deep_extend("force", {
    ctx = {
      toplevel = vim.uv.cwd(),
      dir = vim.uv.cwd(),
    },
    is_binary = function()
      return false
    end,
  }, overrides or {})
end

---Create a Window attached to a File with the given adapter.
---@param adapter table
---@param file_opts? table
---@return Window, vcs.File
local function make_window(adapter, file_opts)
  local file = File(vim.tbl_extend("force", {
    adapter = adapter,
    path = "README.md",
    kind = "working",
    rev = GitRev(RevType.COMMIT, "abc1234"),
  }, file_opts or {}))

  local win = Window({
    id = vim.api.nvim_get_current_win(),
  })
  win:set_file(file)

  return win, file
end

describe("diffview.scene.window", function()
  it(
    "load_file bails out if the file is inactive",
    helpers.async_test(function()
      local show_called = false
      local adapter = mock_adapter({
        show = async.wrap(function(_, _, _, callback)
          show_called = true
          callback(nil, { "data" })
        end),
      })

      local win, file = make_window(adapter)
      file.active = false

      local ok = async.await(win:load_file())

      assert.False(ok)
      -- show should never have been called since we bailed before create_buffer.
      assert.False(show_called)
    end)
  )

  describe("_save_winopts global-only options", function()
    -- The global_only_opts set (e.g., "scrollopt") must be read via vim.o
    -- rather than vim.wo, because they are global-only and vim.wo would error.

    it("reads global-only options from vim.o", function()
      local adapter = mock_adapter()
      local win, file = make_window(adapter)

      -- Ensure the file has a winopts table that includes scrollopt.
      file.winopts = {
        scrollopt = { "ver", "hor", "jump" },
        diff = true,
      }

      -- Make the buffer valid so _save_winopts proceeds.
      local bufnr = vim.api.nvim_create_buf(false, true)
      file.bufnr = bufnr

      -- Clear any prior store entry.
      Window.winopt_store[bufnr] = nil

      -- Record the current global scrollopt value for comparison.
      local expected_scrollopt = vim.o.scrollopt

      win:_save_winopts()

      local store = Window.winopt_store[bufnr]
      assert.is_not_nil(store)
      assert.equals(expected_scrollopt, store.scrollopt)

      -- Clean up.
      Window.winopt_store[bufnr] = nil
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("reads non-global options from vim.wo", function()
      local adapter = mock_adapter()
      local win, file = make_window(adapter)

      local bufnr = vim.api.nvim_create_buf(false, true)
      file.bufnr = bufnr
      Window.winopt_store[bufnr] = nil

      -- Use only a window-local option.
      file.winopts = { diff = true }

      -- Set a known value via vim.wo so we can verify it is read from there.
      local winid = win.id
      local orig_diff = vim.wo[winid].diff
      vim.wo[winid].diff = false

      win:_save_winopts()

      local store = Window.winopt_store[bufnr]
      assert.is_not_nil(store)
      assert.is_false(store.diff)

      -- Restore mutated window option.
      vim.wo[winid].diff = orig_diff
      Window.winopt_store[bufnr] = nil
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("does not overwrite an existing store entry", function()
      local adapter = mock_adapter()
      local win, file = make_window(adapter)

      local bufnr = vim.api.nvim_create_buf(false, true)
      file.bufnr = bufnr

      -- Pre-populate the store.
      Window.winopt_store[bufnr] = { diff = true }

      file.winopts = { diff = false, scrollopt = { "ver" } }
      win:_save_winopts()

      -- The store should be unchanged.
      assert.is_true(Window.winopt_store[bufnr].diff)
      assert.is_nil(Window.winopt_store[bufnr].scrollopt)

      Window.winopt_store[bufnr] = nil
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("handles winopts with only global-only options", function()
      local adapter = mock_adapter()
      local win, file = make_window(adapter)

      local bufnr = vim.api.nvim_create_buf(false, true)
      file.bufnr = bufnr
      Window.winopt_store[bufnr] = nil

      -- Only scrollopt, no window-local options.
      file.winopts = { scrollopt = { "ver", "hor" } }

      local expected = vim.o.scrollopt
      win:_save_winopts()

      local store = Window.winopt_store[bufnr]
      assert.is_not_nil(store)
      assert.equals(expected, store.scrollopt)
      -- No other keys should be present.
      assert.is_nil(store.diff)

      Window.winopt_store[bufnr] = nil
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("open_file view.foldlevel", function()
    -- Regression (#121): `view.foldlevel` must be copied onto the window's
    -- `foldlevel` option when the diff buffer is shown, even if the file's
    -- preset `winopts` table does not already have a `foldlevel` key.

    local original_config
    local test_winid

    before_each(function()
      original_config = vim.deepcopy(config.get_config())
      -- Run each test in a dedicated split so `apply_file_winopts` cannot
      -- leak window-local option changes (foldlevel, diff, scrollbind, ...)
      -- into the surrounding test-runner window.
      vim.cmd("new")
      test_winid = vim.api.nvim_get_current_win()
    end)

    after_each(function()
      config.setup(original_config)
      if test_winid and vim.api.nvim_win_is_valid(test_winid) then
        vim.api.nvim_win_close(test_winid, true)
      end
      test_winid = nil
    end)

    ---Minimal parent stub for `Window.open_file`: supplies the `name` field
    ---that the `diff_buf_win_enter` emitter reads, plus an `instanceof` that
    ---always returns false so `config.get_layout_keymaps` falls through to
    ---nil (no layout-specific keymaps are registered).
    local function stub_parent()
      return {
        name = "test",
        instanceof = function()
          return false
        end,
      }
    end

    it(
      "propagates the configured value to the window",
      helpers.async_test(function()
        config.setup({ view = { foldlevel = 77 } })

        local adapter = mock_adapter()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local win, file = make_window(adapter)
        file.bufnr = bufnr
        file.loaded = true
        win.parent = stub_parent()

        async.await(win:open_file())

        assert.equals(77, vim.wo[win.id].foldlevel)

        -- Close the dedicated window before deleting the buffer it displays,
        -- so buffer deletion does not force an unrelated window onto `bufnr`.
        if vim.api.nvim_win_is_valid(test_winid) then
          vim.api.nvim_win_close(test_winid, true)
        end
        test_winid = nil
        Window.winopt_store[bufnr] = nil
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    )

    it(
      "applies the configured value even when `file.winopts` omits `foldlevel`",
      helpers.async_test(function()
        config.setup({ view = { foldlevel = 77 } })

        local adapter = mock_adapter()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local win, file = make_window(adapter)
        file.bufnr = bufnr
        file.loaded = true
        -- Custom winopts table that lacks a `foldlevel` key: the fix must
        -- still populate it from config so the user override is not dropped.
        file.winopts = { diff = true, scrollbind = true, cursorbind = true }
        win.parent = stub_parent()

        async.await(win:open_file())

        assert.equals(77, vim.wo[win.id].foldlevel)

        if vim.api.nvim_win_is_valid(test_winid) then
          vim.api.nvim_win_close(test_winid, true)
        end
        test_winid = nil
        Window.winopt_store[bufnr] = nil
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    )

    it(
      "preserves the layout's `foldlevel` for non-diff windows (`diff = false`)",
      helpers.async_test(function()
        -- `diff1_raw` opens the buffer as a plain file, so the user's
        -- `view.foldlevel` (which targets diff buffers) must not clobber
        -- the layout's high foldlevel.
        config.setup({ view = { foldlevel = 0 } })

        local adapter = mock_adapter()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local win, file = make_window(adapter)
        file.bufnr = bufnr
        file.loaded = true
        file.winopts = {
          diff = false,
          scrollbind = false,
          cursorbind = false,
          foldmethod = "manual",
          foldlevel = 99,
        }
        win.parent = stub_parent()

        async.await(win:open_file())

        assert.equals(99, vim.wo[win.id].foldlevel)

        if vim.api.nvim_win_is_valid(test_winid) then
          vim.api.nvim_win_close(test_winid, true)
        end
        test_winid = nil
        Window.winopt_store[bufnr] = nil
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    )

    -- Regression (#299): fold winopts must be skipped on the content
    -- side of an added/deleted file, so the buffer's own folding
    -- (ftplugin, treesitter, ufo, ...) survives.
    it(
      "does not override fold options when the paired window's file is nulled",
      helpers.async_test(function()
        config.setup({ view = { foldlevel = 0 } })

        local adapter = mock_adapter()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local win, file = make_window(adapter)
        file.bufnr = bufnr
        file.loaded = true

        local sibling_file = { nulled = true }
        local sibling_win = { file = sibling_file }
        win.parent = vim.tbl_extend("force", stub_parent(), { windows = { win, sibling_win } })

        -- Values distinct from what `winopts` would install, so survival
        -- proves the override was skipped rather than coincidentally matching.
        vim.wo[win.id].foldmethod = "marker"
        vim.wo[win.id].foldlevel = 42
        vim.wo[win.id].foldenable = false

        async.await(win:open_file())

        assert.equals("marker", vim.wo[win.id].foldmethod)
        assert.equals(42, vim.wo[win.id].foldlevel)
        assert.is_false(vim.wo[win.id].foldenable)

        if vim.api.nvim_win_is_valid(test_winid) then
          vim.api.nvim_win_close(test_winid, true)
        end
        test_winid = nil
        Window.winopt_store[bufnr] = nil
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    )

    it(
      "still applies fold options when no sibling window is nulled",
      helpers.async_test(function()
        config.setup({ view = { foldlevel = 0 } })

        local adapter = mock_adapter()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local win, file = make_window(adapter)
        file.bufnr = bufnr
        file.loaded = true

        local sibling_file = { nulled = false }
        local sibling_win = { file = sibling_file }
        win.parent = vim.tbl_extend("force", stub_parent(), { windows = { win, sibling_win } })

        vim.wo[win.id].foldmethod = "marker"

        async.await(win:open_file())

        assert.equals("diff", vim.wo[win.id].foldmethod)
        assert.equals(0, vim.wo[win.id].foldlevel)

        if vim.api.nvim_win_is_valid(test_winid) then
          vim.api.nvim_win_close(test_winid, true)
        end
        test_winid = nil
        Window.winopt_store[bufnr] = nil
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    )

    -- Regression: `Layout.open_files` yields between its load loop and its
    -- open loop. A rapid navigation in that gap deactivates the in-flight
    -- file; bailing on `active=false` here used to leave the window holding
    -- the `open_null` placeholder while `file.loaded=true` claimed the
    -- buffer was ready, tripping `jump_to_first_change` (silent `]c` on an
    -- empty buffer; "Cursor position outside buffer" in `diff1_inline`).
    -- Once the buffer is populated, displaying it is cheap, so `open_file`
    -- proceeds regardless of `active`.
    it(
      "displays an already-loaded buffer even when the file got deactivated",
      helpers.async_test(function()
        local adapter = mock_adapter()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local win, file = make_window(adapter)
        file.bufnr = bufnr
        file.loaded = true
        file.active = false -- deactivated post-load.
        win.parent = stub_parent()

        async.await(win:open_file())

        assert.equals(bufnr, vim.api.nvim_win_get_buf(win.id))

        if vim.api.nvim_win_is_valid(test_winid) then
          vim.api.nvim_win_close(test_winid, true)
        end
        test_winid = nil
        Window.winopt_store[bufnr] = nil
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    )
  end)

  it(
    "load_file suppresses error when create_buffer is cancelled mid-async",
    helpers.async_test(function()
      local yield_signal = Signal("yield")
      local produce_data_started = Signal("produce_data_started")

      local adapter = mock_adapter({
        show = async.wrap(function(_, _, _, callback)
          produce_data_started:send()
          async.await(yield_signal)
          callback(nil, { "data" })
        end),
      })

      local win, file = make_window(adapter)

      -- Start load_file in a separate thread so we can deactivate mid-flight.
      local load_ok

      local load_thread = async.void(function()
        load_ok = async.await(win:load_file())
      end)

      load_thread()

      -- Wait until we're inside produce_data (the show mock).
      async.await(produce_data_started)

      -- Deactivate and let the show mock finish.
      file.active = false
      yield_signal:send()
      async.await(async.scheduler())

      -- load_file should report failure without a user-visible error.
      assert.False(load_ok)
      assert.is_nil(file.bufnr)
    end)
  )
end)
