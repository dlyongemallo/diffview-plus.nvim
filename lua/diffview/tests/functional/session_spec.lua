local api = vim.api
local session = require("diffview.session")
local File = require("diffview.vcs.file").File

---Create a buffer with the given name and (optionally) filetype, and
---display it in the current window.
---@param name string
---@param ft? string
---@return integer bufnr
local function make_buf(name, ft)
  local bufnr = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(bufnr, name)
  if ft then
    vim.bo[bufnr].filetype = ft
  end
  api.nvim_set_current_buf(bufnr)
  return bufnr
end

---Open a new tab and put `bufnr` in its only window.
---@param bufnr integer
---@return integer tabpage
local function open_tab_with(bufnr)
  vim.cmd("tabnew")
  api.nvim_set_current_buf(bufnr)
  return api.nvim_get_current_tabpage()
end

describe("session cleanup", function()
  before_each(function()
    -- Drop any non-startup tabs/buffers from a previous test.
    while #api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      local name = api.nvim_buf_get_name(bufnr)
      local ft = vim.bo[bufnr].filetype
      -- Preserve the `diffview://null` singleton across tests: wiping it
      -- would dangle the cached `File.NULL_FILE.bufnr` and break any
      -- following test that relies on the real handle.
      if
        name ~= "diffview://null"
        and (name:match("^diffview://") or ft == "DiffviewFiles" or ft == "DiffviewFileHistory")
      then
        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end)

  it("wipes buffers whose names use the diffview URI scheme", function()
    local diff_buf = make_buf("diffview:///repo/blob/abc/file.lua")
    local panel_buf = make_buf("diffview:///panels/1/DiffviewFilePanel")

    session.cleanup()

    assert.is_false(api.nvim_buf_is_valid(diff_buf))
    assert.is_false(api.nvim_buf_is_valid(panel_buf))
  end)

  it("wipes buffers identified by diffview filetypes alone", function()
    -- A restored session may not preserve the `diffview://` URI for the
    -- panel buffers (they were anonymous scratch buffers in life), so the
    -- filetype is the fallback discriminator.
    local files_panel = make_buf("", "DiffviewFiles")
    local history_panel = make_buf("", "DiffviewFileHistory")

    session.cleanup()

    assert.is_false(api.nvim_buf_is_valid(files_panel))
    assert.is_false(api.nvim_buf_is_valid(history_panel))
  end)

  it("leaves unrelated buffers untouched", function()
    local plain = make_buf("/tmp/some_real_file.txt")

    session.cleanup()

    assert.is_true(api.nvim_buf_is_valid(plain))
    pcall(api.nvim_buf_delete, plain, { force = true })
  end)

  it("closes a tabpage that contained only diffview windows", function()
    -- Cover the case where the tab also holds a `diffview://null`
    -- window (a common arrangement after panels/views close). The null
    -- singleton is diffview UI even though it isn't stale, so the tab
    -- must still be considered orphan-only and closed.
    local diff_buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(diff_buf, "diffview:///repo/blob/abc/file.lua")
    local null_buf = File._get_null_buffer()
    local tab = open_tab_with(diff_buf)
    vim.cmd("vsplit")
    api.nvim_set_current_buf(null_buf)
    local tabs_before = #api.nvim_list_tabpages()

    session.cleanup()

    assert.is_false(api.nvim_tabpage_is_valid(tab))
    assert.equals(tabs_before - 1, #api.nvim_list_tabpages())
    assert.is_true(api.nvim_buf_is_valid(null_buf))
  end)

  it("keeps a tab that mixes diffview and non-diffview windows", function()
    local diff_buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(diff_buf, "diffview:///repo/blob/abc/file.lua")
    local real_buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(real_buf, "/tmp/keep_me.txt")
    vim.cmd("tabnew")
    api.nvim_set_current_buf(diff_buf)
    vim.cmd("vsplit")
    api.nvim_set_current_buf(real_buf)
    local tab = api.nvim_get_current_tabpage()

    session.cleanup()

    assert.is_true(api.nvim_tabpage_is_valid(tab))
    assert.is_false(api.nvim_buf_is_valid(diff_buf))
    assert.is_true(api.nvim_buf_is_valid(real_buf))
    pcall(api.nvim_buf_delete, real_buf, { force = true })
    if api.nvim_tabpage_is_valid(tab) then
      api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
    end
  end)

  it("closes a diffview tab whose only non-diffview window is a stale LOCAL", function()
    -- The session's diffview tab restores as: panel + diff-left + LOCAL
    -- right-side. Without `stale_local_paths`, the LOCAL window keeps
    -- the tab alive and the user lands on a half-restored stub (no
    -- panel, no diff). Passing the path classifies the LOCAL as
    -- diffview content for tab accounting, the tab closes entirely.
    -- The LOCAL buffer is unlisted (not wiped) so third-party plugins'
    -- pending callbacks against that bufnr don't `E680`.
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local path_local = tmpdir .. "/right_side.txt"
    vim.fn.writefile({ "" }, path_local)

    local diff_buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(diff_buf, "diffview:///repo/blob/abc/right_side.txt")
    local panel_buf = api.nvim_create_buf(true, false)
    vim.bo[panel_buf].filetype = "DiffviewFiles"
    local local_buf = vim.fn.bufadd(path_local)
    vim.fn.bufload(local_buf)
    local local_name = api.nvim_buf_get_name(local_buf)

    vim.cmd("tabnew")
    api.nvim_set_current_buf(panel_buf)
    vim.cmd("vsplit")
    api.nvim_set_current_buf(diff_buf)
    vim.cmd("vsplit")
    api.nvim_set_current_buf(local_buf)
    local tab = api.nvim_get_current_tabpage()

    session.cleanup({ local_name })

    assert.is_false(api.nvim_tabpage_is_valid(tab))
    assert.is_false(api.nvim_buf_is_valid(diff_buf))
    assert.is_false(api.nvim_buf_is_valid(panel_buf))
    assert.is_true(api.nvim_buf_is_valid(local_buf))
    assert.is_false(vim.bo[local_buf].buflisted)

    pcall(api.nvim_buf_delete, local_buf, { force = true })
    vim.fn.delete(tmpdir, "rf")
  end)

  it("keeps a tab when a stale LOCAL is modified (data-loss avoidance)", function()
    -- Modified buffers are excluded from `stale_local_bufs` so the
    -- tab's `tab_has_other` check sees a real non-diffview window and
    -- keeps the tab open. The user's edits survive, even though it
    -- means the half-restored stub stays around.
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local path_local = tmpdir .. "/dirty.txt"
    vim.fn.writefile({ "" }, path_local)

    local diff_buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(diff_buf, "diffview:///repo/blob/abc/dirty.txt")
    local local_buf = vim.fn.bufadd(path_local)
    vim.fn.bufload(local_buf)
    vim.bo[local_buf].buflisted = true
    api.nvim_buf_set_lines(local_buf, 0, -1, false, { "unsaved edits" })
    assert.is_true(vim.bo[local_buf].modified)
    local local_name = api.nvim_buf_get_name(local_buf)

    vim.cmd("tabnew")
    api.nvim_set_current_buf(diff_buf)
    vim.cmd("vsplit")
    api.nvim_set_current_buf(local_buf)
    local tab = api.nvim_get_current_tabpage()

    session.cleanup({ local_name })

    assert.is_true(api.nvim_tabpage_is_valid(tab))
    assert.is_false(api.nvim_buf_is_valid(diff_buf))
    assert.is_true(api.nvim_buf_is_valid(local_buf))
    -- Modified buffers are skipped entirely: not unlisted either, so
    -- the user can still see and reach their unsaved edits.
    assert.is_true(vim.bo[local_buf].buflisted)

    vim.bo[local_buf].modified = false
    pcall(api.nvim_buf_delete, local_buf, { force = true })
    if api.nvim_tabpage_is_valid(tab) then
      api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
    end
    vim.fn.delete(tmpdir, "rf")
  end)

  it("leaves a buffer flagged `b:diffview_loaded` untouched", function()
    -- A live Diffview view sets this flag once buffer contents are
    -- populated (see `vcs/file.lua`). Stale, session-restored buffers
    -- don't have it set, so the flag is the discriminator that protects
    -- active Diffview content opened during the same `SessionLoadPost`.
    local live_buf = make_buf("diffview:///repo/blob/abc/file.lua")
    vim.b[live_buf].diffview_loaded = true

    session.cleanup()

    assert.is_true(api.nvim_buf_is_valid(live_buf))
    vim.b[live_buf].diffview_loaded = nil
    pcall(api.nvim_buf_delete, live_buf, { force = true })
  end)

  it("leaves a panel buffer in a tab flagged `t:diffview_view_initialized` untouched", function()
    -- Panel buffers (`DiffviewFiles`/`DiffviewFileHistory`) don't set
    -- `b:diffview_loaded`, so when their view is opened during the same
    -- `SessionLoadPost` event, the tab-level flag is what keeps them alive.
    local panel = api.nvim_create_buf(true, false)
    vim.bo[panel].filetype = "DiffviewFiles"
    local tab = open_tab_with(panel)
    vim.t[tab].diffview_view_initialized = true

    session.cleanup()

    assert.is_true(api.nvim_tabpage_is_valid(tab))
    assert.is_true(api.nvim_buf_is_valid(panel))
    vim.t[tab].diffview_view_initialized = nil
    if api.nvim_tabpage_is_valid(tab) then
      api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
    end
    pcall(api.nvim_buf_delete, panel, { force = true })
  end)

  it("leaves a tab flagged `t:diffview_view_initialized` open", function()
    -- `StandardView`/`NullDiffView` mark a tab once `init_layout` has
    -- run. A user can legitimately open a Diffview from their own
    -- `SessionLoadPost` autocmd that fires before this cleanup; the tab
    -- and its buffers must survive.
    local diff_buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(diff_buf, "diffview:///repo/blob/abc/file.lua")
    vim.b[diff_buf].diffview_loaded = true
    local tab = open_tab_with(diff_buf)
    vim.t[tab].diffview_view_initialized = true

    session.cleanup()

    assert.is_true(api.nvim_tabpage_is_valid(tab))
    assert.is_true(api.nvim_buf_is_valid(diff_buf))
    vim.b[diff_buf].diffview_loaded = nil
    vim.t[tab].diffview_view_initialized = nil
    if api.nvim_tabpage_is_valid(tab) then
      api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
    end
  end)

  it("leaves the internal `diffview://null` singleton buffer untouched", function()
    -- `vcs/file.lua` caches `File.NULL_FILE.bufnr` for the shared null
    -- buffer; wiping it dangles that handle until the next
    -- `_get_null_buffer` call. Cleanup must never delete it even when
    -- it's hidden and not flagged as loaded. Use the real singleton so
    -- the cached `File.NULL_FILE.bufnr` is what's asserted, and leave it
    -- in place for the rest of the suite.
    local null_buf = File._get_null_buffer()

    session.cleanup()

    assert.is_true(api.nvim_buf_is_valid(null_buf))
    assert.equals(null_buf, File.NULL_FILE.bufnr)
  end)

  it("never closes the last remaining tabpage", function()
    -- Wipe everything else so only one tab remains, displaying a diffview
    -- buffer. Cleanup must not exit Neovim by closing it.
    while #api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
    local diff_buf = make_buf("diffview:///repo/blob/abc/file.lua")

    session.cleanup()

    assert.equals(1, #api.nvim_list_tabpages())
    assert.is_false(api.nvim_buf_is_valid(diff_buf))
  end)

  it("registers a SessionLoadPost autocmd via setup()", function()
    session.setup()
    local cmds = api.nvim_get_autocmds({
      event = "SessionLoadPost",
      group = "diffview_session",
    })
    assert.is_true(#cmds >= 1)
  end)

  it("registers VimLeave (primary) and SessionWritePost (interactive)", function()
    -- `VimLeave` is the primary save trigger because session managers
    -- typically run `:mksession` from `VimLeavePre`, and the
    -- `SessionWritePost` nested under that fires is suppressed
    -- (Neovim's nested-autocmd rule). `VimLeave` runs after every
    -- `VimLeavePre` autocmd has completed, so `v:this_session` is set
    -- by then. `SessionWritePost` is registered too, but only catches
    -- the interactive `:mksession` case. `VimLeavePre` is NOT
    -- registered: it would just hit the same suppression issue when
    -- it races auto-session's own `VimLeavePre`.
    session.setup()
    local vimleave = api.nvim_get_autocmds({
      event = "VimLeave",
      group = "diffview_session",
    })
    local vlp = api.nvim_get_autocmds({
      event = "VimLeavePre",
      group = "diffview_session",
    })
    assert.is_true(#vimleave >= 1)
    assert.equals(0, #vlp)
    if vim.fn.exists("##SessionWritePost") ~= 0 then
      local swp = api.nvim_get_autocmds({
        event = "SessionWritePost",
        group = "diffview_session",
      })
      assert.is_true(#swp >= 1)
    end
  end)

  it("defers cleanup past the SessionLoadPost autocmd context", function()
    -- Regression: when the restored layout left the cursor on a stale
    -- diffview buffer and the source flow held an autocmd window open,
    -- running the cleanup synchronously inside the autocmd hit `E814`
    -- and the buffer survived. The fix wraps the callback in
    -- `vim.schedule`; this asserts the deferral by checking that the
    -- wipe doesn't happen until after `doautocmd` returns.
    local diff_buf = make_buf("diffview:///repo/blob/abc/file.lua")
    session.setup()

    vim.cmd("doautocmd SessionLoadPost")
    assert.is_true(api.nvim_buf_is_valid(diff_buf))
    assert.is_true(vim.wait(500, function()
      return not api.nvim_buf_is_valid(diff_buf)
    end))
  end)
end)

describe("session save/restore", function()
  local lib = require("diffview.lib")
  local config = require("diffview.config")
  local original_config
  local tmp_session

  ---Build a minimal stand-in for a view. Avoids constructing a real DiffView
  ---(which would need an adapter + repo). Anything `capture_view` reads is
  ---present; the rest is left nil.
  ---@param opts table
  ---@return table
  local function fake_view(opts)
    return {
      _session_record = opts._session_record,
      tabpage = opts.tabpage,
      adapter = opts.adapter or { ctx = { toplevel = "/fake/repo" } },
      panel = opts.panel,
      cur_layout = opts.cur_layout,
    }
  end

  before_each(function()
    -- Drop any non-startup tabs left behind by a previous test so the
    -- tabpage-order assertions below don't depend on run order.
    while #api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
    original_config = vim.deepcopy(config.get_config())
    tmp_session = vim.fn.tempname() .. ".vim"
    vim.v.this_session = tmp_session
    lib.views = {}
  end)

  after_each(function()
    vim.v.this_session = ""
    pcall(os.remove, tmp_session .. ".diffview.json")
    pcall(os.remove, tmp_session)
    lib.views = {}
    config.setup(original_config)
    while #api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
  end)

  describe("record_view", function()
    it("attaches a `_session_record` with deep-copied args and range", function()
      local view = {}
      local args = { "HEAD~3..@", "src/foo.lua" }
      local range = { 1, 10 }
      session.record_view(view, "file_history", args, range)

      assert.equals("file_history", view._session_record.kind)
      assert.are.same(args, view._session_record.args)
      assert.are.same(range, view._session_record.range)

      -- Mutating the original input must not affect the stored record.
      args[1] = "MUTATED"
      range[1] = 99
      assert.equals("HEAD~3..@", view._session_record.args[1])
      assert.equals(1, view._session_record.range[1])
    end)

    it("is a no-op on a nil view", function()
      assert.has_no.errors(function()
        session.record_view(nil, "diffview_open", { "HEAD" })
      end)
    end)
  end)

  describe("save", function()
    it("writes a sidecar JSON with one entry per recorded view", function()
      local tab1 = api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      local tab2 = api.nvim_get_current_tabpage()

      lib.views = {
        fake_view({
          _session_record = { kind = "diffview_open", args = { "HEAD~1..@" } },
          tabpage = tab1,
          panel = { cur_file = { path = "src/init.lua" } },
        }),
        fake_view({
          _session_record = { kind = "file_history", args = { "--follow", "src/foo.lua" } },
          tabpage = tab2,
        }),
      }

      session.save()

      local f = assert(io.open(tmp_session .. ".diffview.json", "r"))
      local payload = vim.json.decode(f:read("*a"))
      f:close()

      assert.equals(1, payload.version)
      assert.equals(2, #payload.views)
      assert.equals("diffview_open", payload.views[1].kind)
      assert.equals("src/init.lua", payload.views[1].selected_file)
      assert.equals("file_history", payload.views[2].kind)
      assert.are.same({ "--follow", "src/foo.lua" }, payload.views[2].args)
    end)

    it("sorts entries by tabpage order", function()
      local tab1 = api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      local tab2 = api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      local tab3 = api.nvim_get_current_tabpage()

      -- Insert out of order: tab3 first, tab1 second, tab2 third.
      lib.views = {
        fake_view({
          _session_record = { kind = "diffview_open", args = { "C" } },
          tabpage = tab3,
        }),
        fake_view({
          _session_record = { kind = "diffview_open", args = { "A" } },
          tabpage = tab1,
        }),
        fake_view({
          _session_record = { kind = "diffview_open", args = { "B" } },
          tabpage = tab2,
        }),
      }

      session.save()

      local f = assert(io.open(tmp_session .. ".diffview.json", "r"))
      local payload = vim.json.decode(f:read("*a"))
      f:close()

      assert.equals("A", payload.views[1].args[1])
      assert.equals("B", payload.views[2].args[1])
      assert.equals("C", payload.views[3].args[1])
    end)

    it("removes a stale sidecar when no eligible views remain", function()
      -- Pre-existing sidecar from a previous save.
      local sidecar = tmp_session .. ".diffview.json"
      local f = assert(io.open(sidecar, "w"))
      f:write("{}")
      f:close()

      lib.views = {}
      session.save()

      assert.is_nil(io.open(sidecar, "r"))
    end)

    it("skips views that were never recorded", function()
      lib.views = {
        fake_view({ tabpage = api.nvim_get_current_tabpage() }), -- no `_session_record`
      }

      session.save()

      assert.is_nil(io.open(tmp_session .. ".diffview.json", "r"))
    end)

    it("is a no-op when `v:this_session` is empty", function()
      vim.v.this_session = ""
      lib.views = {
        fake_view({
          _session_record = { kind = "diffview_open", args = { "HEAD" } },
          tabpage = api.nvim_get_current_tabpage(),
        }),
      }
      assert.has_no.errors(session.save)
    end)

    it("is a no-op when `restore_session = false`", function()
      config.get_config().restore_session = false
      lib.views = {
        fake_view({
          _session_record = { kind = "diffview_open", args = { "HEAD" } },
          tabpage = api.nvim_get_current_tabpage(),
        }),
      }

      session.save()

      assert.is_nil(io.open(tmp_session .. ".diffview.json", "r"))
    end)

    it("captures `File.created_bufs` paths into `created_paths`", function()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      local path_a = tmpdir .. "/a.lua"
      local path_b = tmpdir .. "/b.lua"
      vim.fn.writefile({ "" }, path_a)
      vim.fn.writefile({ "" }, path_b)
      local buf_a = vim.fn.bufadd(path_a)
      local buf_b = vim.fn.bufadd(path_b)
      local name_a = api.nvim_buf_get_name(buf_a)
      local name_b = api.nvim_buf_get_name(buf_b)

      local prev_created = vim.deepcopy(File.created_bufs)
      File.created_bufs[buf_a] = true
      File.created_bufs[buf_b] = true

      lib.views = {
        fake_view({
          _session_record = { kind = "diffview_open", args = { "HEAD" } },
          tabpage = api.nvim_get_current_tabpage(),
        }),
      }

      local ok, err = pcall(session.save)

      -- Reset shared state before asserting so a failure here doesn't
      -- leak `File.created_bufs` entries into later tests.
      for k in pairs(File.created_bufs) do
        File.created_bufs[k] = nil
      end
      for k, v in pairs(prev_created) do
        File.created_bufs[k] = v
      end
      pcall(api.nvim_buf_delete, buf_a, { force = true })
      pcall(api.nvim_buf_delete, buf_b, { force = true })
      vim.fn.delete(tmpdir, "rf")

      assert.is_true(ok, tostring(err))

      local f = assert(io.open(tmp_session .. ".diffview.json", "r"))
      local payload = vim.json.decode(f:read("*a"))
      f:close()

      assert.is_table(payload.created_paths)
      table.sort(payload.created_paths)
      local expected = { name_a, name_b }
      table.sort(expected)
      assert.are.same(expected, payload.created_paths)
    end)
  end)

  describe("restore", function()
    local orig_diffview_open, orig_file_history
    local invocations

    before_each(function()
      invocations = {}
      orig_diffview_open = lib.diffview_open
      orig_file_history = lib.file_history
      lib.diffview_open = function(args)
        table.insert(invocations, { fn = "diffview_open", args = args })
        return {
          options = {},
          tabpage = nil,
          open = function() end,
        }
      end
      lib.file_history = function(range, args)
        table.insert(invocations, { fn = "file_history", range = range, args = args })
        return {
          tabpage = nil,
          open = function() end,
        }
      end
    end)

    after_each(function()
      lib.diffview_open = orig_diffview_open
      lib.file_history = orig_file_history
    end)

    it("re-invokes the right entry points for each saved view", function()
      local payload = {
        version = 1,
        views = {
          {
            kind = "diffview_open",
            args = { "HEAD~2..@" },
            tabpage_order = 1,
            selected_file = "init.lua",
          },
          {
            kind = "file_history",
            args = { "--follow", "src/foo.lua" },
            range = { 5, 8 },
            tabpage_order = 2,
          },
        },
      }
      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode(payload))
      f:close()

      session.restore()

      assert.equals(2, #invocations)
      assert.equals("diffview_open", invocations[1].fn)
      assert.are.same({ "HEAD~2..@" }, invocations[1].args)
      assert.equals("file_history", invocations[2].fn)
      assert.are.same({ 5, 8 }, invocations[2].range)
      assert.are.same({ "--follow", "src/foo.lua" }, invocations[2].args)
    end)

    it("propagates `selected_file` to options and rehydrates `cursor_map`", function()
      local captured
      lib.diffview_open = function(_)
        local v = { options = {}, tabpage = nil, open = function() end }
        captured = v
        return v
      end
      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode({
        version = 1,
        views = {
          {
            kind = "diffview_open",
            args = { "HEAD" },
            tabpage_order = 1,
            selected_file = "src/main.lua",
            cursor_map = {
              ["src/main.lua"] = { lnum = 42, col = 3, topline = 10 },
              ["src/other.lua"] = { lnum = 100, col = 0, topline = 80 },
            },
          },
        },
      }))
      f:close()

      session.restore()

      assert.is_not_nil(captured)
      assert.equals("src/main.lua", captured.options.selected_file)
      assert.are.same({
        ["src/main.lua"] = { lnum = 42, col = 3, topline = 10 },
        ["src/other.lua"] = { lnum = 100, col = 0, topline = 80 },
      }, captured.cursor_map)
    end)

    it("is a no-op when no sidecar exists", function()
      assert.has_no.errors(session.restore)
      assert.equals(0, #invocations)
    end)

    it("is a no-op when `restore_session = false`", function()
      config.get_config().restore_session = false
      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode({
        version = 1,
        views = {
          { kind = "diffview_open", args = { "HEAD" }, tabpage_order = 1 },
        },
      }))
      f:close()

      session.restore()

      assert.equals(0, #invocations)
    end)

    it("ignores entries with an unknown kind", function()
      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode({
        version = 1,
        views = {
          { kind = "nonsense", args = { "x" }, tabpage_order = 1 },
        },
      }))
      f:close()

      session.restore()

      assert.equals(0, #invocations)
    end)

    it("does not crash on a corrupt sidecar", function()
      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write("not valid json {{{")
      f:close()

      assert.has_no.errors(session.restore)
      assert.equals(0, #invocations)
    end)

    it("skips restore when a diffview view is already live", function()
      -- Mirrors `nvim -c "DiffviewOpen ..."` and similar startup paths
      -- that put a view into `lib.views` before `SessionLoadPost` fires.
      -- We don't want to stack a sidecar view on top of the user's
      -- explicit view.
      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode({
        version = 1,
        views = {
          { kind = "diffview_open", args = { "HEAD~1" }, tabpage_order = 1 },
        },
      }))
      f:close()

      local existing_tab = api.nvim_get_current_tabpage()
      table.insert(
        lib.views,
        fake_view({
          _session_record = { kind = "diffview_open", args = { "HEAD~3" } },
          tabpage = existing_tab,
        })
      )

      session.restore()

      assert.equals(0, #invocations)
    end)

    it("still restores when `lib.views` only holds entries with invalid tabpages", function()
      -- A View object that lingered in `lib.views` without a live tab
      -- shouldn't block restore: it's a leftover, not a deliberate
      -- user-initiated view.
      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode({
        version = 1,
        views = {
          { kind = "diffview_open", args = { "HEAD~1" }, tabpage_order = 1 },
        },
      }))
      f:close()

      table.insert(
        lib.views,
        fake_view({
          _session_record = { kind = "diffview_open", args = { "stale" } },
          tabpage = 999999, -- never a valid tabpage
        })
      )

      session.restore()

      assert.equals(1, #invocations)
      assert.are.same({ "HEAD~1" }, invocations[1].args)
    end)

    it("records `_session_record` on restored views so the next save can recapture them", function()
      -- Regression: without this, capturing during the next `:mksession`
      -- drops the restored view (no `_session_record`), the sidecar is
      -- wiped on the empty save, and the diffview disappears on the
      -- third run.
      --
      -- Recording now happens inside `lib.diffview_open` /
      -- `lib.file_history` themselves, so any caller (user command,
      -- `M.restore`, third-party plugin) gets covered. The stubs below
      -- mimic that placement: they tag the returned view as the real
      -- functions do.
      local captured_views = {}
      lib.diffview_open = function(args)
        local v = { options = {}, tabpage = nil, open = function() end }
        session.record_view(v, "diffview_open", args)
        captured_views[#captured_views + 1] = v
        return v
      end
      lib.file_history = function(range, args)
        local v = { tabpage = nil, open = function() end }
        session.record_view(v, "file_history", args, range)
        captured_views[#captured_views + 1] = v
        return v
      end

      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode({
        version = 1,
        views = {
          {
            kind = "diffview_open",
            args = { "HEAD~1" },
            tabpage_order = 1,
            selected_file = "src/a.lua",
          },
          {
            kind = "file_history",
            args = { "src/b.lua" },
            range = { 1, 10 },
            tabpage_order = 2,
          },
        },
      }))
      f:close()

      session.restore()

      assert.equals(2, #captured_views)
      assert.equals("diffview_open", captured_views[1]._session_record.kind)
      assert.are.same({ "HEAD~1" }, captured_views[1]._session_record.args)
      assert.equals("file_history", captured_views[2]._session_record.kind)
      assert.are.same({ "src/b.lua" }, captured_views[2]._session_record.args)
      assert.are.same({ 1, 10 }, captured_views[2]._session_record.range)
    end)

    it("unlists prior-session LOCAL buffers via the created_paths field", function()
      -- The user navigated through these files in diffview; on save
      -- they ended up in `:mksession`'s `badd` list and on load Neovim
      -- recreated them. `M.restore` unlists them so `:ls`/`:bnext`
      -- skip them and the next `:mksession` doesn't carry them
      -- forward. Buffers stay valid so third-party plugins' pending
      -- callbacks don't `E680`.
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      local path_a = tmpdir .. "/a.txt"
      local path_b = tmpdir .. "/b.txt"
      vim.fn.writefile({ "" }, path_a)
      vim.fn.writefile({ "" }, path_b)
      local buf_a = vim.fn.bufadd(path_a)
      local buf_b = vim.fn.bufadd(path_b)
      vim.fn.bufload(buf_a)
      vim.fn.bufload(buf_b)
      -- `bufadd` defaults to unlisted; simulate the session-restore
      -- state where these buffers came back via `:badd` (which lists).
      vim.bo[buf_a].buflisted = true
      vim.bo[buf_b].buflisted = true

      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode({
        version = 1,
        views = {},
        created_paths = { api.nvim_buf_get_name(buf_a), api.nvim_buf_get_name(buf_b) },
      }))
      f:close()

      session.restore()

      assert.is_true(api.nvim_buf_is_valid(buf_a))
      assert.is_true(api.nvim_buf_is_valid(buf_b))
      assert.is_false(vim.bo[buf_a].buflisted)
      assert.is_false(vim.bo[buf_b].buflisted)

      pcall(api.nvim_buf_delete, buf_a, { force = true })
      pcall(api.nvim_buf_delete, buf_b, { force = true })
      vim.fn.delete(tmpdir, "rf")
    end)

    it("leaves a modified LOCAL buffer listed (data-loss avoidance)", function()
      -- Modified buffers are skipped entirely: the user has unsaved
      -- edits, so we don't touch `:ls` visibility either.
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      local path = tmpdir .. "/modified.txt"
      vim.fn.writefile({ "" }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      vim.bo[bufnr].buflisted = true
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { "dirty content" })
      assert.is_true(vim.bo[bufnr].modified)

      local name = api.nvim_buf_get_name(bufnr)
      local f = assert(io.open(tmp_session .. ".diffview.json", "w"))
      f:write(vim.json.encode({
        version = 1,
        views = {},
        created_paths = { name },
      }))
      f:close()

      session.restore()

      assert.is_true(api.nvim_buf_is_valid(bufnr))
      assert.is_true(vim.bo[bufnr].buflisted)

      vim.bo[bufnr].modified = false
      pcall(api.nvim_buf_delete, bufnr, { force = true })
      vim.fn.delete(tmpdir, "rf")
    end)
  end)
end)
