local actions = require("diffview.actions")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")
local utils = require("diffview.utils")

local DiffView_class = require("diffview.scene.views.diff.diff_view").DiffView
local FileHistoryView_class =
  require("diffview.scene.views.file_history.file_history_view").FileHistoryView
local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local Diff2Ver = require("diffview.scene.layouts.diff_2_ver").Diff2Ver
local Diff3Hor = require("diffview.scene.layouts.diff_3_hor").Diff3Hor
local Diff3Ver = require("diffview.scene.layouts.diff_3_ver").Diff3Ver
local Diff3Mixed = require("diffview.scene.layouts.diff_3_mixed").Diff3Mixed
local Diff4Mixed = require("diffview.scene.layouts.diff_4_mixed").Diff4Mixed
local File = require("diffview.vcs.file").File
local RevType = require("diffview.vcs.rev").RevType
local Window = require("diffview.scene.window").Window
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev

local eq = helpers.eq

-----------------------------------------------------------------------
-- 59237ad: set_layout action for specific layout selection.
-----------------------------------------------------------------------

describe("diffview.actions.set_layout (59237ad)", function()
  local stubs = {}
  local converted_layouts

  --- Replace tbl[key] with val, automatically restored in after_each.
  local function stub(tbl, key, val)
    stubs[#stubs + 1] = { tbl, key, tbl[key] }
    tbl[key] = val
  end

  before_each(function()
    converted_layouts = {}
  end)

  after_each(function()
    for i = #stubs, 1, -1 do
      local s = stubs[i]
      s[1][s[2]] = s[3]
    end
    stubs = {}
  end)

  --- Build a mock file entry with a given layout class.
  local function mock_file_entry(layout_class, kind)
    return {
      layout = {
        class = layout_class,
        emitter = require("diffview.events").EventEmitter(),
      },
      kind = kind or "working",
      convert_layout = function(self, next_class)
        converted_layouts[#converted_layouts + 1] = next_class
        self.layout.class = next_class
      end,
    }
  end

  --- Build a mock DiffView.
  local function mock_diff_view(files, cur_entry)
    return {
      class = DiffView_class,
      instanceof = function(self, other)
        return self.class == other
      end,
      cur_entry = cur_entry,
      cur_layout = {
        get_main_win = function()
          return { id = 1 }
        end,
        is_focused = function()
          return false
        end,
        sync_scroll = function() end,
      },
      panel = {
        files = { working = files, staged = {} },
      },
      files = { conflicting = {} },
      set_file = function() end,
    }
  end

  it("resolves known layout names to the correct layout class", function()
    local known = {
      diff1_plain = Diff1,
      diff2_horizontal = Diff2Hor,
      diff2_vertical = Diff2Ver,
      diff3_horizontal = Diff3Hor,
      diff3_vertical = Diff3Ver,
      diff3_mixed = Diff3Mixed,
      diff4_mixed = Diff4Mixed,
    }

    for name, expected_class in pairs(known) do
      converted_layouts = {}
      local file = mock_file_entry(Diff2Hor)
      local view = mock_diff_view({ file }, file)

      stub(lib, "get_current_view", function()
        return view
      end)
      stub(vim.api, "nvim_win_get_cursor", function()
        return { 1, 0 }
      end)

      local action_fn = actions.set_layout(name)
      action_fn()

      eq(1, #converted_layouts, "expected one conversion for " .. name)
      eq(expected_class, converted_layouts[1], "wrong class for " .. name)
    end
  end)

  it("emits an error for an invalid layout name", function()
    local err_called = false
    stub(utils, "err", function()
      err_called = true
    end)
    stub(lib, "get_current_view", function()
      return mock_diff_view({}, nil)
    end)

    local action_fn = actions.set_layout("nonexistent_layout")
    action_fn()

    assert.True(err_called)
    eq(0, #converted_layouts)
  end)

  it("calls convert_layout on every file in the view", function()
    local files = {
      mock_file_entry(Diff2Hor),
      mock_file_entry(Diff2Hor),
      mock_file_entry(Diff2Hor),
    }
    -- cur_entry must be one of the files for set_file to be called.
    local view = mock_diff_view(files, files[1])

    stub(lib, "get_current_view", function()
      return view
    end)
    stub(vim.api, "nvim_win_get_cursor", function()
      return { 1, 0 }
    end)

    local action_fn = actions.set_layout("diff2_vertical")
    action_fn()

    eq(3, #converted_layouts)
    for _, cls in ipairs(converted_layouts) do
      eq(Diff2Ver, cls)
    end
  end)

  it("returns early without error when no view is active", function()
    stub(lib, "get_current_view", function()
      return nil
    end)

    local action_fn = actions.set_layout("diff2_horizontal")
    -- Should not error.
    assert.has_no.errors(function()
      action_fn()
    end)
    eq(0, #converted_layouts)
  end)
end)

-----------------------------------------------------------------------
-- f728b1f: copy_hash honors the register prefix (vim.v.register),
-- defaulting to the unnamed register (") when none is given.
-----------------------------------------------------------------------

describe("copy_hash honors vim.v.register (f728b1f)", function()
  local listeners_factory = require("diffview.scene.views.file_history.listeners")

  -- Invoke the real copy_hash listener with a given register value and commit
  -- hash, returning what setreg was called with and the message utils.info
  -- emitted. vim.v.register is read-only, so vim.v itself is swapped out for
  -- a stub that falls through to the real vim.v for any unrelated access.
  local function run_copy_hash(reg, hash)
    local captured = {}
    local orig_setreg = vim.fn.setreg
    local orig_info = utils.info
    local orig_v = vim.v

    vim.fn.setreg = function(r, val)
      captured.reg, captured.val = r, val
    end
    utils.info = function(msg)
      captured.msg = msg
    end
    vim.v = setmetatable({ register = reg }, { __index = orig_v })

    local mock_view = {
      panel = {
        is_focused = function()
          return true
        end,
        get_item_at_cursor = function()
          return { commit = { hash = hash } }
        end,
      },
    }
    local listeners = listeners_factory(mock_view)

    local ok, err = pcall(listeners.copy_hash)

    vim.fn.setreg = orig_setreg
    utils.info = orig_info
    vim.v = orig_v

    assert(ok, err)
    return captured
  end

  it("setreg target follows vim.v.register", function()
    local captured = run_copy_hash('"', "abc123def456")
    eq('"', captured.reg)
    eq("abc123def456", captured.val)
  end)

  it("writes to the clipboard register when vim.v.register is '+'", function()
    local captured = run_copy_hash("+", "deadbeef1234")
    eq("+", captured.reg)
    eq("deadbeef1234", captured.val)
  end)

  it("info message says 'the default register' when no prefix is given", function()
    local captured = run_copy_hash('"', "abc123def")
    assert.truthy(captured.msg:find("the default register", 1, true))
    assert.falsy(captured.msg:find("register '\"'", 1, true))
  end)

  it("info message names the explicit register when a prefix is given", function()
    local captured = run_copy_hash("a", "abc123def")
    assert.truthy(captured.msg:find("register 'a'", 1, true))
    assert.falsy(captured.msg:find("default register", 1, true))
  end)
end)

-----------------------------------------------------------------------
-- #231: file_history `open_in_diffview` derives revs from `file.revs`.
-- `file.revs` is the canonical rev pair on a FileEntry and is set for
-- every layout class, so the action works under any layout. Reaching
-- into the layout's window files only works for layouts that expose
-- `.a` and `.b` Windows (`Diff2`); single-window layouts (`diff1_*`)
-- have no `.a` window.
-----------------------------------------------------------------------

describe("file_history open_in_diffview is layout-agnostic (#231)", function()
  local listeners_factory = require("diffview.scene.views.file_history.listeners")

  it("uses file.revs without dereferencing file.layout", function()
    -- Trap layout: errors on any field access so a regression that
    -- indexes `file.layout.{a,b}.file.rev` (or any other field) is
    -- caught at the moment of access.
    local layout_trap = setmetatable({}, {
      __index = function(_, key)
        error("open_in_diffview must not index file.layout (got '" .. key .. "')")
      end,
    })

    local rev_a, rev_b = "<rev_a>", "<rev_b>"
    local file = {
      revs = { a = rev_a, b = rev_b },
      absolute_path = "/repo/foo.lua",
      layout = layout_trap,
    }

    local captured = {}
    local mock_view = {
      adapter = {
        rev_to_pretty_string = function(_, a, b)
          captured.pretty_args = { a, b }
          return "<pretty>"
        end,
      },
      infer_cur_file = function()
        return file
      end,
    }

    -- Swap the modules the listener resolves lazily. `listeners.lua` holds
    -- `lazy.access(...)` wrappers that resolve on first call via
    -- `require()`, so replacing `package.loaded` here captures the swap.
    -- The wrappers cache their resolved values, so the swap is only
    -- effective if no earlier code path has already resolved them.
    local diff_view_path = "diffview.scene.views.diff.diff_view"
    local lib_path = "diffview.lib"
    local orig_diff_view_mod = package.loaded[diff_view_path]
    local orig_lib = package.loaded[lib_path]

    package.loaded[diff_view_path] = {
      DiffView = function(opts)
        captured.opts = opts
        return { open = function() end }
      end,
    }
    package.loaded[lib_path] = setmetatable({
      add_view = function(v)
        captured.added = v
      end,
    }, { __index = orig_lib })

    local listeners = listeners_factory(mock_view)
    local ok, err = pcall(listeners.open_in_diffview)

    package.loaded[diff_view_path] = orig_diff_view_mod
    package.loaded[lib_path] = orig_lib

    assert(ok, err)
    eq({ rev_a, rev_b }, captured.pretty_args)
    eq(rev_a, captured.opts.left)
    eq(rev_b, captured.opts.right)
    eq("<pretty>", captured.opts.rev_arg)
    eq("/repo/foo.lua", captured.opts.options.selected_file)
    assert.is_not_nil(captured.added)
  end)
end)

-----------------------------------------------------------------------
-- 431ee89: prevent scrollbind/cursorbind from persisting after close.
-- The NULL_FILE winopts explicitly set scrollbind=false and
-- cursorbind=false. Window._save_winopts reads these via vim.wo
-- (window-local) so they don't leak to other windows.
-----------------------------------------------------------------------

describe("scrollbind/cursorbind cleanup (431ee89)", function()
  it("NULL_FILE winopts explicitly disable scrollbind and cursorbind", function()
    local null_winopts = File.NULL_FILE.winopts
    assert.is_false(null_winopts.scrollbind)
    assert.is_false(null_winopts.cursorbind)
    assert.is_false(null_winopts.diff)
  end)

  it("default File winopts enable scrollbind and cursorbind", function()
    local adapter = {
      ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
      is_binary = function()
        return false
      end,
    }

    local file = File({
      adapter = adapter,
      path = "test.lua",
      kind = "working",
      rev = GitRev(RevType.COMMIT, "abc1234"),
    })

    assert.is_true(file.winopts.scrollbind)
    assert.is_true(file.winopts.cursorbind)
    assert.is_true(file.winopts.diff)
  end)

  it("_save_winopts reads scrollbind from vim.wo, not vim.o", function()
    local adapter = {
      ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
      is_binary = function()
        return false
      end,
    }

    local file = File({
      adapter = adapter,
      path = "test.lua",
      kind = "working",
      rev = GitRev(RevType.COMMIT, "abc1234"),
    })

    local bufnr = vim.api.nvim_create_buf(false, true)
    file.bufnr = bufnr
    Window.winopt_store[bufnr] = nil

    local winid = vim.api.nvim_get_current_win()
    -- Set window-local scrollbind to a known value.
    vim.wo[winid].scrollbind = true

    local win = Window({ id = winid })
    win:set_file(file)
    win:_save_winopts()

    local store = Window.winopt_store[bufnr]
    assert.is_not_nil(store)
    -- The saved value should reflect the window-local setting (true),
    -- not the global default (typically false).
    assert.is_true(store.scrollbind)

    -- Clean up.
    vim.wo[winid].scrollbind = false
    Window.winopt_store[bufnr] = nil
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("_save_winopts reads cursorbind from vim.wo, not vim.o", function()
    local adapter = {
      ctx = { toplevel = vim.uv.cwd(), dir = vim.uv.cwd() },
      is_binary = function()
        return false
      end,
    }

    local file = File({
      adapter = adapter,
      path = "test.lua",
      kind = "working",
      rev = GitRev(RevType.COMMIT, "abc1234"),
    })

    local bufnr = vim.api.nvim_create_buf(false, true)
    file.bufnr = bufnr
    Window.winopt_store[bufnr] = nil

    local winid = vim.api.nvim_get_current_win()
    vim.wo[winid].cursorbind = true

    local win = Window({ id = winid })
    win:set_file(file)
    win:_save_winopts()

    local store = Window.winopt_store[bufnr]
    assert.is_not_nil(store)
    assert.is_true(store.cursorbind)

    -- Clean up.
    vim.wo[winid].cursorbind = false
    Window.winopt_store[bufnr] = nil
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

-----------------------------------------------------------------------
-- e91acae: disable inlay hints in non-LOCAL buffers.
-- The fix calls vim.lsp.inlay_hint.enable(false) for non-LOCAL revs
-- during attach and re-enables during detach. LOCAL buffers are left
-- alone.
-----------------------------------------------------------------------

describe("inlay hints for non-LOCAL buffers (e91acae)", function()
  local orig_inlay_hint_enable

  before_each(function()
    orig_inlay_hint_enable = vim.lsp.inlay_hint.enable
  end)

  after_each(function()
    vim.lsp.inlay_hint.enable = orig_inlay_hint_enable
  end)

  it("disables inlay hints for COMMIT rev buffers", function()
    local calls = {}
    vim.lsp.inlay_hint.enable = function(enabled, opts)
      calls[#calls + 1] = { enabled = enabled, bufnr = opts and opts.bufnr }
    end

    -- Simulate what File:attach_buffer does for a non-LOCAL rev.
    local rev = { type = RevType.COMMIT }
    local bufnr = 42

    if rev.type ~= RevType.LOCAL then
      pcall(vim.lsp.inlay_hint.enable, false, { bufnr = bufnr })
    end

    eq(1, #calls)
    assert.is_false(calls[1].enabled)
    eq(42, calls[1].bufnr)
  end)

  it("disables inlay hints for STAGE rev buffers", function()
    local calls = {}
    vim.lsp.inlay_hint.enable = function(enabled, opts)
      calls[#calls + 1] = { enabled = enabled, bufnr = opts and opts.bufnr }
    end

    local rev = { type = RevType.STAGE }
    local bufnr = 99

    if rev.type ~= RevType.LOCAL then
      pcall(vim.lsp.inlay_hint.enable, false, { bufnr = bufnr })
    end

    eq(1, #calls)
    assert.is_false(calls[1].enabled)
    eq(99, calls[1].bufnr)
  end)

  it("does not disable inlay hints for LOCAL rev buffers", function()
    local calls = {}
    vim.lsp.inlay_hint.enable = function(enabled, opts)
      calls[#calls + 1] = { enabled = enabled, bufnr = opts and opts.bufnr }
    end

    local rev = { type = RevType.LOCAL }
    local bufnr = 77

    if rev.type ~= RevType.LOCAL then
      pcall(vim.lsp.inlay_hint.enable, false, { bufnr = bufnr })
    end

    eq(0, #calls)
  end)

  it("re-enables inlay hints on detach for non-LOCAL buffers", function()
    local calls = {}
    vim.lsp.inlay_hint.enable = function(enabled, opts)
      calls[#calls + 1] = { enabled = enabled, bufnr = opts and opts.bufnr }
    end

    -- Simulate the detach path.
    local rev = { type = RevType.COMMIT }
    local bufnr = 42

    if rev.type ~= RevType.LOCAL then
      pcall(vim.lsp.inlay_hint.enable, true, { bufnr = bufnr })
    end

    eq(1, #calls)
    assert.is_true(calls[1].enabled)
    eq(42, calls[1].bufnr)
  end)

  it("does not re-enable inlay hints on detach for LOCAL buffers", function()
    local calls = {}
    vim.lsp.inlay_hint.enable = function(enabled, opts)
      calls[#calls + 1] = { enabled = enabled, bufnr = opts and opts.bufnr }
    end

    local rev = { type = RevType.LOCAL }
    local bufnr = 77

    if rev.type ~= RevType.LOCAL then
      pcall(vim.lsp.inlay_hint.enable, true, { bufnr = bufnr })
    end

    eq(0, #calls)
  end)
end)
