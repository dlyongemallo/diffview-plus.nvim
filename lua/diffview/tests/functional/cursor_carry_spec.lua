local helpers = require("diffview.tests.helpers")
local StandardView = require("diffview.scene.views.standard.standard_view").StandardView

local api = vim.api
local eq = helpers.eq
local body = helpers.body

local function window_pool()
  local wins = {}

  return {
    ---@param lines string[]
    ---@return integer winid, integer bufnr
    open = function(lines)
      vim.cmd("new")
      local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
      vim.bo[buf].buftype = "nofile"
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      wins[#wins + 1] = win
      return win, buf
    end,
    close_all = function()
      for _, win in ipairs(wins) do
        pcall(api.nvim_win_close, win, true)
      end
      wins = {}
    end,
  }
end

---A view whose layout is shaped like `Diff2`: two windows, `b` is the main one.
---@param a_win integer
---@param b_win integer
local function make_view(a_win, b_win)
  return setmetatable({
    cursor_map = {},
    cur_layout = {
      symbols = { "a", "b" },
      a = { id = a_win },
      b = { id = b_win },
      get_main_win = function(self)
        return self.b
      end,
    },
  }, { __index = StandardView })
end

describe("diffview.standard_view _map_lnum", function()
  it("leaves a line preceding every hunk untouched", function()
    eq(3, StandardView._map_lnum({ { 10, 0, 11, 5 } }, 3))
  end)

  it("shifts a line following an insertion by the inserted count", function()
    eq(35, StandardView._map_lnum({ { 0, 0, 1, 30 } }, 5))
  end)

  it("shifts a line following a deletion back by the deleted count", function()
    eq(5, StandardView._map_lnum({ { 1, 30, 0, 0 } }, 35))
  end)

  it("maps a line inside a changed hunk to the hunk start on the new side", function()
    eq(12, StandardView._map_lnum({ { 10, 4, 12, 6 } }, 11))
  end)

  it("maps a line inside a deleted hunk to the last surviving line before it", function()
    eq(4, StandardView._map_lnum({ { 5, 3, 4, 0 } }, 6))
  end)

  it("accumulates deltas across several preceding hunks", function()
    eq(14, StandardView._map_lnum({ { 0, 0, 1, 3 }, { 5, 4, 9, 2 } }, 13))
  end)

  it("returns the line unchanged for an empty diff", function()
    eq(7, StandardView._map_lnum({}, 7))
  end)

  it("never returns a line below 1", function()
    eq(1, StandardView._map_lnum({ { 1, 3, 0, 0 } }, 2))
  end)
end)

describe("diffview.standard_view _translate_winview", function()
  local pool = window_pool()

  after_each(pool.close_all)

  it("moves the cursor onto the same text after a prepend is dropped", function()
    local _, old = pool.open(vim.list_extend(body("head", 30), body("body", 20)))
    local _, new = pool.open(body("body", 20))

    local out = StandardView._translate_winview({ lnum = 35, topline = 30 }, old, new)

    eq(5, out.lnum)
    eq("body 5", api.nvim_buf_get_lines(new, out.lnum - 1, out.lnum, false)[1])
  end)

  it("shifts the viewport with the cursor", function()
    local _, old = pool.open(body("body", 20))
    local _, new = pool.open(vim.list_extend(body("head", 30), body("body", 20)))

    local out = StandardView._translate_winview({ lnum = 5, topline = 3 }, old, new)

    eq(35, out.lnum)
    eq(33, out.topline)
  end)

  it("leaves the dict untouched when the buffers are identical", function()
    local _, old = pool.open(body("body", 20))
    local _, new = pool.open(body("body", 20))
    local winview = { lnum = 7, topline = 4 }

    eq(winview, StandardView._translate_winview(winview, old, new))
  end)

  it("maps a line inside a deleted tail onto the last surviving line", function()
    local _, old = pool.open(body("body", 20))
    local _, new = pool.open(body("body", 5))

    eq(5, StandardView._translate_winview({ lnum = 18 }, old, new).lnum)
  end)

  it("leaves an untranslatable line past the new EOF for `winrestview` to clamp", function()
    local new_win, new = pool.open(body("body", 5))

    local out = StandardView._translate_winview({ lnum = 18 }, nil, new)

    api.nvim_win_call(new_win, function()
      vim.fn.winrestview(out)
    end)
    eq(5, api.nvim_win_get_cursor(new_win)[1])
  end)

  it("falls back to the raw dict when the source buffer is gone", function()
    local win, old = pool.open(body("body", 20))
    local _, new = pool.open(body("body", 5))
    api.nvim_win_close(win, true)
    api.nvim_buf_delete(old, { force = true })

    eq({ lnum = 18 }, StandardView._translate_winview({ lnum = 18 }, old, new))
  end)

  it("falls back to the raw dict when no source buffer was recorded", function()
    local _, new = pool.open(body("body", 5))

    eq({ lnum = 18 }, StandardView._translate_winview({ lnum = 18 }, nil, new))
  end)

  it("shifts a line sitting directly below an insertion", function()
    local _, old = pool.open(body("body", 10))
    local lines = body("body", 3)
    table.insert(lines, "inserted")
    vim.list_extend(lines, vim.list_slice(body("body", 10), 4, 10))
    local _, new = pool.open(lines)

    local out = StandardView._translate_winview({ lnum = 4 }, old, new)

    eq(5, out.lnum)
    eq("body 4", api.nvim_buf_get_lines(new, out.lnum - 1, out.lnum, false)[1])
  end)

  it("nets out a deletion and an insertion above the cursor", function()
    local _, old =
      pool.open(vim.list_extend(vim.list_extend(body("del", 2), body("keep", 5)), body("tail", 5)))
    local _, new =
      pool.open(vim.list_extend(vim.list_extend(body("keep", 5), body("new", 3)), body("tail", 5)))

    local out = StandardView._translate_winview({ lnum = 10 }, old, new)

    eq(11, out.lnum)
    eq("tail 3", api.nvim_buf_get_lines(new, out.lnum - 1, out.lnum, false)[1])
  end)

  it("maps a line inside a rewritten block to the block's first new line", function()
    local _, old =
      pool.open(vim.list_extend(vim.list_extend(body("keep", 3), body("old", 2)), body("keep", 3)))
    local _, new = pool.open(
      vim.list_extend(vim.list_extend(body("keep", 3), body("fresh", 3)), body("keep", 3))
    )

    local out = StandardView._translate_winview({ lnum = 5 }, old, new)

    eq(4, out.lnum)
    eq("fresh 1", api.nvim_buf_get_lines(new, out.lnum - 1, out.lnum, false)[1])
  end)
end)

describe("diffview.standard_view _rename_alias", function()
  it("aliases the arriving path when the leaving entry names it as its old path", function()
    local from = { path = "moved.txt", oldpath = "keep.txt", status = "R" }
    eq("keep.txt", StandardView._rename_alias(from, { path = "keep.txt", status = "M" }))
  end)

  it("aliases the arriving path when the arriving entry names the leaving one", function()
    local to = { path = "moved.txt", oldpath = "keep.txt", status = "R" }
    eq("moved.txt", StandardView._rename_alias({ path = "keep.txt", status = "M" }, to))
  end)

  it("still aliases when neither entry carries a status, as in line-trace mode", function()
    local to = { path = "moved.txt", oldpath = "keep.txt" }
    eq("moved.txt", StandardView._rename_alias({ path = "keep.txt" }, to))
  end)

  it("does not alias a copy, whose `oldpath` names a different file", function()
    -- `src.txt` survives the copy, so `copy.txt` opens on its own first
    -- change rather than inheriting the source's cursor.
    local to = { path = "copy.txt", oldpath = "src.txt", status = "C" }
    eq(nil, StandardView._rename_alias({ path = "src.txt", status = "M" }, to))
    eq(nil, StandardView._rename_alias(to, { path = "src.txt", status = "M" }))
  end)

  it("does not alias when there is no arriving entry", function()
    eq(nil, StandardView._rename_alias({ path = "moved.txt", oldpath = "keep.txt" }, nil))
  end)
end)

describe("diffview.standard_view carry snapshot/restore", function()
  local pool = window_pool()

  after_each(pool.close_all)

  it("stores the main window's view state and the buffer it came from", function()
    local a_win = pool.open(body("old", 20))
    local b_win, b_buf = pool.open(body("body", 50))
    local view = make_view(a_win, b_win)

    api.nvim_set_current_win(b_win)
    api.nvim_win_set_cursor(b_win, { 35, 0 })
    view:snapshot_main_view("file.txt")

    local saved = view.cursor_map["file.txt"]
    eq(35, saved.winview.lnum)
    eq(b_buf, saved.bufnr)
  end)

  it("translates the main window on restore", function()
    local a_win = pool.open(vim.list_extend(body("head", 30), body("body", 20)))
    local b_win = pool.open(vim.list_extend(body("head", 30), body("body", 20)))
    local view = make_view(a_win, b_win)

    api.nvim_win_set_cursor(b_win, { 35, 0 })
    view:snapshot_main_view("file.txt")

    -- The next commit shows the same path in a fresh buffer, without the
    -- 30-line prepend. That swap is what the carry has to translate across.
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, body("body", 20))
    api.nvim_win_set_buf(b_win, buf)

    assert.is_true(view:restore_main_view("file.txt"))
    eq(5, api.nvim_win_get_cursor(b_win)[1])
  end)

  it("clears the entry so a re-visit falls through", function()
    local a_win = pool.open(body("body", 20))
    local b_win = pool.open(body("body", 20))
    local view = make_view(a_win, b_win)

    api.nvim_set_current_win(b_win)
    view:snapshot_main_view("file.txt")

    assert.is_true(view:restore_main_view("file.txt"))
    eq(nil, view.cursor_map["file.txt"])
    eq(false, view:restore_main_view("file.txt"))
  end)

  it("restores a state that carries no buffer, as a session sidecar does", function()
    local a_win = pool.open(body("body", 20))
    local b_win = pool.open(body("body", 20))
    local view = make_view(a_win, b_win)
    view.cursor_map["file.txt"] = { winview = { lnum = 12 } }

    assert.is_true(view:restore_main_view("file.txt"))
    eq(12, api.nvim_win_get_cursor(b_win)[1])
  end)

  it("refuses an entry that carries no view state", function()
    local a_win = pool.open(body("body", 20))
    local b_win = pool.open(body("body", 20))
    local view = make_view(a_win, b_win)
    view.cursor_map["file.txt"] = { lnum = 12 }

    eq(false, view:restore_main_view("file.txt"))
  end)

  it("skips the translation when the recorded handle now names another buffer", function()
    local a_win = pool.open(body("body", 20))
    local b_win, b_buf = pool.open(body("body", 20))
    local view = make_view(a_win, b_win)

    view.cursor_map["file.txt"] = {
      winview = { lnum = 12 },
      bufnr = b_buf,
      bufname = "/gone/from/this/session.txt",
    }

    assert.is_true(view:restore_main_view("file.txt"))
    eq(12, api.nvim_win_get_cursor(b_win)[1])
  end)
end)
