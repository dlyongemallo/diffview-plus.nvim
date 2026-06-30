local actions = require("diffview.actions")
local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("diffview.actions goto_file API", function()
  it("exports all five goto_file functions", function()
    assert.is_function(actions.goto_file)
    assert.is_function(actions.goto_file_edit)
    assert.is_function(actions.goto_file_edit_close)
    assert.is_function(actions.goto_file_split)
    assert.is_function(actions.goto_file_tab)
  end)

  -- The goto_file functions require an active DiffView to operate.
  -- Without one, prepare_goto_file accesses a nil view, which is the
  -- expected pre-existing behaviour (they are only called from keymaps
  -- bound inside a DiffView tabpage). Verify they consistently error
  -- rather than silently misbehaving.
  it("goto_file errors without an active view (expected guard)", function()
    assert.has_error(function()
      actions.goto_file()
    end)
  end)

  it("goto_file_edit errors without an active view (expected guard)", function()
    assert.has_error(function()
      actions.goto_file_edit()
    end)
  end)

  it("goto_file_edit_close errors without an active view (expected guard)", function()
    assert.has_error(function()
      actions.goto_file_edit_close()
    end)
  end)

  it("goto_file_split errors without an active view (expected guard)", function()
    assert.has_error(function()
      actions.goto_file_split()
    end)
  end)

  it("goto_file_tab errors without an active view (expected guard)", function()
    assert.has_error(function()
      actions.goto_file_tab()
    end)
  end)
end)

describe("diffview.actions goto_file command routing", function()
  local lib = require("diffview.lib")
  local utils = require("diffview.utils")
  local DiffView_class = require("diffview.scene.views.diff.diff_view").DiffView

  local stubs = {}
  local cmds_issued
  local close_calls
  local disposed_views
  local mock_view

  --- Replace tbl[key] with val, automatically restored in after_each.
  local function stub(tbl, key, val)
    stubs[#stubs + 1] = { tbl, key, tbl[key] }
    tbl[key] = val
  end

  before_each(function()
    cmds_issued = {}
    close_calls = 0
    disposed_views = {}

    local mock_file = {
      absolute_path = "/tmp/test.lua",
      layout = {
        restore_winopts = function() end,
        get_main_win = function()
          return { id = 1 }
        end,
      },
      active = true,
    }
    mock_view = {
      class = DiffView_class,
      instanceof = function(self, other)
        return self.class == other
      end,
      infer_cur_file = function()
        return mock_file
      end,
      cur_entry = nil,
      cur_layout = {
        get_main_win = function()
          return { id = 1 }
        end,
      },
      can_close = function()
        return true
      end,
      close = function()
        close_calls = close_calls + 1
      end,
    }

    stub(lib, "get_current_view", function()
      return mock_view
    end)
    stub(lib, "get_prev_non_view_tabpage", function()
      return nil
    end)
    stub(lib, "dispose_view", function(v)
      disposed_views[#disposed_views + 1] = v
    end)
    stub(utils, "set_cursor", function() end)
    stub(utils.path, "readable", function()
      return true
    end)
    stub(vim.api, "nvim_set_current_tabpage", function() end)
    stub(vim.api, "nvim_get_current_buf", function()
      return 999
    end)
    stub(vim.api, "nvim_buf_delete", function() end)
    stub(vim.fn, "fnameescape", function(p)
      return p
    end)
    stub(vim, "cmd", function(c)
      cmds_issued[#cmds_issued + 1] = c
    end)
  end)

  after_each(function()
    for i = #stubs, 1, -1 do
      local s = stubs[i]
      s[1][s[2]] = s[3]
    end
    stubs = {}
  end)

  it("goto_file issues 'tabnew' then 'keepalt edit' when no previous tab", function()
    actions.goto_file()
    eq("tabnew", cmds_issued[1])
    assert.truthy(cmds_issued[2]:find("^keepalt edit"))
  end)

  it("goto_file_edit issues 'tabnew' then 'keepalt edit' when no previous tab", function()
    actions.goto_file_edit()
    eq("tabnew", cmds_issued[1])
    assert.truthy(cmds_issued[2]:find("^keepalt edit"))
  end)

  it("goto_file issues 'sp <file>' when a previous tab exists", function()
    lib.get_prev_non_view_tabpage = function()
      return 1
    end
    actions.goto_file()
    eq(1, #cmds_issued)
    assert.truthy(cmds_issued[1]:find("^sp "))
  end)

  it("goto_file_edit issues 'edit <file>' when a previous tab exists", function()
    lib.get_prev_non_view_tabpage = function()
      return 1
    end
    actions.goto_file_edit()
    eq(1, #cmds_issued)
    assert.truthy(cmds_issued[1]:find("^edit "))
  end)

  it("goto_file_split issues 'new' then 'keepalt edit'", function()
    actions.goto_file_split()
    eq("new", cmds_issued[1])
    assert.truthy(cmds_issued[2]:find("^keepalt edit"))
  end)

  it("goto_file_tab issues 'tabnew' then 'keepalt edit'", function()
    actions.goto_file_tab()
    eq("tabnew", cmds_issued[1])
    assert.truthy(cmds_issued[2]:find("^keepalt edit"))
  end)

  it("goto_file_edit_close issues 'tabnew' then 'keepalt edit' when no previous tab", function()
    actions.goto_file_edit_close()
    eq("tabnew", cmds_issued[1])
    assert.truthy(cmds_issued[2]:find("^keepalt edit"))
  end)

  it("goto_file_edit_close issues 'edit <file>' when a previous tab exists", function()
    lib.get_prev_non_view_tabpage = function()
      return 1
    end
    actions.goto_file_edit_close()
    eq(1, #cmds_issued)
    assert.truthy(cmds_issued[1]:find("^edit "))
  end)

  it("goto_file_edit_close closes and disposes the view after navigating", function()
    actions.goto_file_edit_close()
    eq(1, close_calls)
    eq(1, #disposed_views)
    eq(mock_view, disposed_views[1])
  end)

  it("goto_file_edit_close closes and disposes the view when a previous tab exists", function()
    lib.get_prev_non_view_tabpage = function()
      return 1
    end
    actions.goto_file_edit_close()
    eq(1, close_calls)
    eq(1, #disposed_views)
    eq(mock_view, disposed_views[1])
  end)

  it("goto_file_edit_close does not close or dispose when no file is inferred", function()
    mock_view.infer_cur_file = function()
      return nil
    end
    actions.goto_file_edit_close()
    eq(0, #cmds_issued)
    eq(0, close_calls)
    eq(0, #disposed_views)
  end)

  -- Pre-flight gate: an aborted close must not navigate first, otherwise the
  -- user is stranded in the target file with the diffview still open. See the
  -- fix that introduced `DiffView:can_close()`.
  it("goto_file_edit_close aborts before navigating when can_close returns false", function()
    mock_view.can_close = function()
      return false
    end
    actions.goto_file_edit_close()
    eq(0, #cmds_issued)
    eq(0, close_calls)
    eq(0, #disposed_views)
  end)
end)

describe("diffview.actions._is_applicable", function()
  local RevType = require("diffview.vcs.rev").RevType

  local make_view = function(opts)
    opts = opts or {}
    local v = { merge_ctx = opts.merge_ctx and {} or nil }
    if opts.left then
      v.left = { type = opts.left }
    end
    if opts.right then
      v.right = { type = opts.right }
    end
    return v
  end

  it("returns true for untagged functions", function()
    assert.is_true(actions._is_applicable(function() end, make_view()))
  end)

  it("returns true for non-function rhs (vim command strings)", function()
    assert.is_true(actions._is_applicable("<Cmd>echo 'hi'<CR>", make_view()))
  end)

  it("hides `merge_only` actions when the view has no merge context", function()
    assert.is_false(actions._is_applicable(actions.next_conflict, make_view()))
    assert.is_false(actions._is_applicable(actions.prev_conflict, make_view()))
  end)

  it("shows `merge_only` actions when the view has a merge context", function()
    assert.is_true(actions._is_applicable(actions.next_conflict, make_view({ merge_ctx = true })))
    assert.is_true(actions._is_applicable(actions.prev_conflict, make_view({ merge_ctx = true })))
  end)

  it("propagates `merge_only` tag through `conflict_choose` factory", function()
    local fn = actions.conflict_choose("ours")
    assert.is_false(actions._is_applicable(fn, make_view()))
    assert.is_true(actions._is_applicable(fn, make_view({ merge_ctx = true })))
  end)

  it("propagates `merge_only` tag through `conflict_choose_all` factory", function()
    local fn = actions.conflict_choose_all("ours")
    assert.is_false(actions._is_applicable(fn, make_view()))
    assert.is_true(actions._is_applicable(fn, make_view({ merge_ctx = true })))
  end)

  it("propagates `merge_only` tag through `conflict_choose_side` factory", function()
    local fn = actions.conflict_choose_side("ours")
    assert.is_false(actions._is_applicable(fn, make_view()))
    assert.is_true(actions._is_applicable(fn, make_view({ merge_ctx = true })))
  end)

  it("returns false when view is nil and the action is `merge_only`", function()
    assert.is_false(actions._is_applicable(actions.next_conflict, nil))
  end)

  it("shows `working_tree_only` actions when comparing STAGE against LOCAL", function()
    local view = make_view({ left = RevType.STAGE, right = RevType.LOCAL })
    assert.is_true(actions._is_applicable(actions.toggle_stage_entry, view))
    assert.is_true(actions._is_applicable(actions.stage_all, view))
    assert.is_true(actions._is_applicable(actions.unstage_all, view))
  end)

  it("hides `working_tree_only` actions when comparing two commits", function()
    local view = make_view({ left = RevType.COMMIT, right = RevType.COMMIT })
    assert.is_false(actions._is_applicable(actions.toggle_stage_entry, view))
    assert.is_false(actions._is_applicable(actions.stage_all, view))
    assert.is_false(actions._is_applicable(actions.unstage_all, view))
  end)

  it("hides `working_tree_only` actions when right side is not LOCAL", function()
    local view = make_view({ left = RevType.STAGE, right = RevType.COMMIT })
    assert.is_false(actions._is_applicable(actions.toggle_stage_entry, view))
  end)

  it("hides `working_tree_only` actions when left side is not STAGE", function()
    local view = make_view({ left = RevType.COMMIT, right = RevType.LOCAL })
    assert.is_false(actions._is_applicable(actions.toggle_stage_entry, view))
  end)

  it("hides `working_tree_only` actions when view lacks left/right (non-DiffView)", function()
    assert.is_false(actions._is_applicable(actions.toggle_stage_entry, make_view()))
  end)

  it("returns false when view is nil and the action is `working_tree_only`", function()
    assert.is_false(actions._is_applicable(actions.toggle_stage_entry, nil))
  end)
end)
