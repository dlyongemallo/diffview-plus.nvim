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
