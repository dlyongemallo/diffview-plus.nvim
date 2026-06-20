local api = vim.api

describe("diffview.close", function()
  local diffview = require("diffview")
  local lib = require("diffview.lib")
  local View = require("diffview.scene.view").View
  local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
  local RevType = require("diffview.vcs.rev").RevType
  local EventEmitter = require("diffview.events").EventEmitter
  local Signal = require("diffview.control").Signal

  local orig_emitter
  local orig_views

  before_each(function()
    orig_emitter = DiffviewGlobal.emitter
    DiffviewGlobal.emitter = EventEmitter()
    -- Isolate the view registry so the dispatch logic has a known state.
    orig_views = lib.views
    lib.views = {}
  end)

  after_each(function()
    DiffviewGlobal.emitter = orig_emitter
    lib.views = orig_views
    -- Discard any tabpages left over from a test.
    while #api.nvim_list_tabpages() > 1 do
      vim.cmd("tabclose")
    end
  end)

  --- A registered View occupying a fresh tabpage.
  local function open_view()
    local view = View({ default_layout = {} })
    vim.cmd("tabnew")
    view.tabpage = api.nvim_get_current_tabpage()
    lib.add_view(view)
    return view
  end

  --- A stand-in view that records how it was closed without actually closing
  --- its tabpage. Its `close` returns `close_ret` (default `true`).
  local function make_stub(tabpage, close_ret)
    return {
      tabpage = tabpage,
      closed = false,
      closed_with = nil,
      close = function(self, opts)
        self.closed = true
        self.closed_with = opts
        return close_ret == nil and true or close_ret
      end,
    }
  end

  --- A registered stub view bound to a fresh, live tabpage.
  local function open_stub(close_ret)
    vim.cmd("tabnew")
    local view = make_stub(api.nvim_get_current_tabpage(), close_ret)
    lib.add_view(view)
    return view
  end

  --- A registered, real `DiffView` bound to a fresh tabpage whose stage buffer
  --- has unsaved edits. It carries the actual class methods so the guarded-close
  --- path (`can_close` -> `_modified_stage_paths`) runs for real, but skips the
  --- heavy `open` machinery: only the fields read by that path, plus those the
  --- global tab-event handlers touch (`closing`, `emitter`), are populated.
  local function open_dirty_stage_view()
    vim.cmd("tabnew")
    local tabpage = api.nvim_get_current_tabpage()

    -- A loaded, modified buffer standing in for an edited stage entry. It must
    -- be a normal buffer (not a `nofile` scratch one, which never tracks as
    -- modified) so the unsaved-edit check sees the pending change.
    local bufnr = api.nvim_create_buf(false, false)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { "edited" })
    vim.bo[bufnr].modified = true

    local file = {
      path = "foo.txt",
      layout = {
        files = function()
          return { { rev = { type = RevType.STAGE }, bufnr = bufnr } }
        end,
      },
    }

    local view = setmetatable({
      tabpage = tabpage,
      closing = Signal("closing"),
      emitter = EventEmitter(),
      files = {
        iter = function()
          local done = false
          return function()
            if done then
              return
            end
            done = true
            return 1, file
          end
        end,
      },
    }, { __index = DiffView })

    lib.add_view(view)
    return view
  end

  -- Regression for #249: passing a tabpage handle must close the view in that
  -- tabpage. Previously this branch only disposed stray views, so a view in a
  -- live tabpage was never closed.
  it("closes the view in the given tabpage", function()
    local view = open_view()
    local tab = view.tabpage

    -- Focus a different tabpage so the target is not the current one.
    vim.cmd("tabnew")
    local other = api.nvim_get_current_tabpage()

    local closed = diffview.close(tab, { force = true })

    assert.is_true(closed)
    assert.is_false(api.nvim_tabpage_is_valid(tab))
    assert.is_true(api.nvim_tabpage_is_valid(other))
    assert.is_nil(lib.tabpage_to_view(tab))
    assert.is_false(lib.has_view(view))
  end)

  -- The close options must reach `view:close` so that, e.g., `force = false`
  -- can still gate on unsaved stage edits when closing by tabpage.
  it("forwards opts to the targeted view", function()
    local view = open_stub()
    local opts = { force = true }

    local closed = diffview.close(view.tabpage, opts)

    assert.is_true(closed)
    assert.is_true(view.closed)
    assert.are.equal(opts, view.closed_with)
    assert.is_false(lib.has_view(view))
  end)

  -- An aborted close (subclass returns false) must propagate and leave the
  -- view registered.
  it("reports an aborted close and keeps the view", function()
    local view = open_stub(false)

    local closed = diffview.close(view.tabpage, { force = false })

    assert.is_false(closed)
    assert.is_true(view.closed)
    assert.is_true(lib.has_view(view))
  end)

  -- A guarded close (`force = false`) of a non-current DiffView must gate on the
  -- target view's own stage buffers, not the focused tabpage. With an unsaved
  -- stage edit the close aborts, leaving the view registered and its tabpage
  -- intact, even though a different tabpage is current.
  it("aborts a guarded close of a non-current DiffView with unsaved stage edits", function()
    local view = open_dirty_stage_view()

    -- Focus a different tabpage so the target is not the current one.
    vim.cmd("tabnew")
    assert.is_false(view.tabpage == api.nvim_get_current_tabpage())

    local closed = diffview.close(view.tabpage, { force = false })

    assert.is_false(closed)
    assert.is_true(lib.has_view(view))
    assert.is_true(api.nvim_tabpage_is_valid(view.tabpage))
  end)

  -- The validity guard: an already-closed (invalid) tabpage handle must be a
  -- no-op, even if a stale view is still registered under that handle. This
  -- stops a stale handle, or a tab number that collides with another view's
  -- handle, from closing the wrong view.
  it("is a no-op for an invalid tabpage", function()
    -- Make a handle stale before binding a stub to it, so the stub is never the
    -- current view while a tabpage is closed.
    vim.cmd("tabnew")
    local stale = api.nvim_get_current_tabpage()
    vim.cmd("tabclose")
    assert.is_false(api.nvim_tabpage_is_valid(stale))

    local view = make_stub(stale)
    lib.add_view(view)

    local closed = diffview.close(stale, { force = true })

    assert.is_true(closed)
    assert.is_false(view.closed)
    assert.is_true(lib.has_view(view))
  end)

  -- A live tabpage with no associated view is a no-op, and other views are
  -- left untouched.
  it("does nothing when the tabpage has no view", function()
    local view = open_view()

    vim.cmd("tabnew")
    local empty = api.nvim_get_current_tabpage()

    local closed = diffview.close(empty, { force = true })

    assert.is_true(closed)
    assert.is_true(api.nvim_tabpage_is_valid(view.tabpage))
    assert.is_true(lib.has_view(view))
  end)

  -- Without a tabpage, the current view is closed (the original behaviour).
  it("closes the current view when no tabpage is given", function()
    local view = open_view()
    local tab = view.tabpage
    api.nvim_set_current_tabpage(tab)

    local closed = diffview.close(nil, { force = true })

    assert.is_true(closed)
    assert.is_false(api.nvim_tabpage_is_valid(tab))
    assert.is_false(lib.has_view(view))
  end)
end)
