local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")

local api = vim.api
local eq = helpers.eq
local commit = helpers.commit
local line_at = helpers.line_at
local body = helpers.body
local write = helpers.write

-- Every commit prepends a different amount, so no two steps shift by the same
-- number of lines:
--
--   c1  body 1..20                          (20 lines)
--   c2  head 1..30 + body                   (50)
--   c3  mid 1..5 + head + body              (55)
--   c4  tag 1..10 + mid + head + body       (65)
local function make_repo()
  local repo = helpers.init_repo()
  local content = body("body", 20)
  write(repo, "file.txt", content)
  commit(repo, "c1")

  for i, layer in ipairs({ { "head", 30 }, { "mid", 5 }, { "tag", 10 } }) do
    content = vim.list_extend(body(layer[1], layer[2]), content)
    write(repo, "file.txt", content)
    commit(repo, "c" .. i + 1)
  end

  return repo
end

describe("file history cursor carry", function()
  local repo, cwd, view, original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    repo = make_repo()
    cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    helpers.close_view(view)
    view = nil
    helpers.cleanup_repo(repo)
    config.setup(original_config)
  end)

  ---@return integer # The layout's current main window.
  local function main_win()
    return view.cur_layout:get_main_win().id
  end

  ---Open the single-file history and wait until every commit is listed and the
  ---`b` side holds the full c4 content.
  ---@return integer main_win
  local function open_history()
    view = lib.file_history(nil, { "file.txt" })
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= 4 and view.cur_layout ~= nil
      end),
      "view never became ready"
    )
    assert.is_true(
      vim.wait(10000, function()
        return api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) >= 65
      end),
      "the b-side buffer never loaded"
    )

    return main_win()
  end

  ---Emit `event` and wait until the layout shows a different buffer.
  ---@param event string
  ---@param idx integer # Index of the entry the step must land on.
  local function step(event, idx)
    local prev = api.nvim_win_get_buf(main_win())

    view.emitter:emit(event)

    assert.is_true(
      vim.wait(10000, function()
        return view.panel.cur_item[1] == view.panel.entries[idx]
          and api.nvim_win_get_buf(main_win()) ~= prev
      end),
      ("%s never reached entry %d"):format(event, idx)
    )
    vim.wait(200)
  end

  ---Walk c4 -> c1 with `event`, requiring the cursor to hold its code line.
  ---@param event string
  local function assert_carries_across(event)
    local main = open_history()
    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { 50, 0 })
    eq("body 5", line_at(main))

    for idx = 2, 4 do
      step(event, idx)
      eq("body 5", line_at(main_win()))
    end

    eq(20, api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())))
  end

  it("opens the folds hiding the carried cursor", function()
    local main = open_history()
    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { 50, 0 })
    eq("body 5", line_at(main))

    step("select_next_commit", 2)

    -- `foldlevel` defaults to 0, so the arriving diff closes every unchanged
    -- region -- which is exactly where a carried line lands, since it is
    -- context in the commit being opened rather than part of its diff. Both
    -- panes are checked: `cursorbind` moves the other window's cursor but
    -- opens nothing, and a pane left folded misaligns against its partner.
    for i, win in ipairs(view.cur_layout.windows) do
      if win.id and api.nvim_win_is_valid(win.id) then
        local closed = api.nvim_win_call(win.id, function()
          return vim.fn.foldclosed(api.nvim_win_get_cursor(win.id)[1])
        end)
        eq(-1, closed, ("window %d left its cursor inside a closed fold"):format(i))
      end
    end

    eq("body 5", line_at(main_win()))
  end)

  it("keeps the cursor on the same code across select_next_commit", function()
    assert_carries_across("select_next_commit")
  end)

  it("keeps the cursor on the same code across select_next_entry", function()
    assert_carries_across("select_next_entry")
  end)

  -- Stepping back lands on an entry that was already opened once, which is the
  -- case `file_open_new` does not cover.
  it("carries the cursor back onto a commit visited earlier", function()
    local main = open_history()
    api.nvim_set_current_win(main)

    step("select_next_commit", 2)

    -- c3 drops c4's 10-line `tag` block, so `head 10` sits 10 rows higher here
    -- than it does in the commit we came from.
    api.nvim_win_set_cursor(main_win(), { 15, 0 })
    eq("head 10", line_at(main_win()))

    step("select_prev_commit", 1)

    eq("head 10", line_at(main_win()))
    eq(25, api.nvim_win_get_cursor(main_win())[1])
  end)
end)

-- `--follow` keeps one file's history across a rename, so two neighbouring
-- entries list the same code under two different paths:
--
--   n1  keep.txt   body 1..20
--   n2  keep.txt   body 5 rewritten
--   n3  moved.txt  the rename, no content change
--   n4  moved.txt  head 1..10 prepended
local function make_rename_repo()
  local repo = helpers.init_repo()
  local lines = body("body", 20)
  write(repo, "keep.txt", lines)
  commit(repo, "n1")

  lines[5] = "body 5 rewritten"
  write(repo, "keep.txt", lines)
  commit(repo, "n2")

  helpers.run({ "git", "mv", "keep.txt", "moved.txt" }, repo)
  commit(repo, "n3")

  lines = vim.list_extend(body("head", 10), lines)
  write(repo, "moved.txt", lines)
  commit(repo, "n4")

  return repo
end

describe("file history cursor carry across a rename", function()
  local repo, cwd, view, original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    repo = make_rename_repo()
    cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    helpers.close_view(view)
    view = nil
    helpers.cleanup_repo(repo)
    config.setup(original_config)
  end)

  local function main_win()
    return view.cur_layout:get_main_win().id
  end

  ---Open the followed history of `moved.txt` and wait for n4's 30 lines.
  local function open_history()
    view = lib.file_history(nil, { "--follow", "moved.txt" })
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= 4 and view.cur_layout ~= nil
      end),
      "view never became ready"
    )
    assert.is_true(
      vim.wait(10000, function()
        return api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == 30
      end),
      "the b-side buffer never loaded"
    )

    api.nvim_set_current_win(main_win())
  end

  ---@param event string
  ---@param idx integer # Index of the entry the step must land on.
  ---@param path string # The name the file carries in that entry.
  ---@param lines integer # Its line count, so the swap is complete before we read.
  local function step(event, idx, path, lines)
    local prev = api.nvim_win_get_buf(main_win())

    view.emitter:emit(event)

    assert.is_true(
      vim.wait(10000, function()
        local buf = api.nvim_win_get_buf(main_win())
        return view.panel.cur_item[1] == view.panel.entries[idx]
          and buf ~= prev
          and api.nvim_buf_line_count(buf) == lines
      end),
      ("%s never reached entry %d"):format(event, idx)
    )
    eq(path, view.panel.cur_item[2].path)
    vim.wait(200)
  end

  it("carries the cursor from the new name onto the old one", function()
    open_history()
    api.nvim_win_set_cursor(main_win(), { 22, 0 })
    eq("body 12", line_at(main_win()))

    step("select_next_commit", 2, "moved.txt", 20)
    eq("body 12", line_at(main_win()))
    eq(12, api.nvim_win_get_cursor(main_win())[1])

    -- n2 lists the file as `keep.txt`. Nothing but `oldpath` on n3's entry
    -- says the two names hold the same code.
    step("select_next_commit", 3, "keep.txt", 20)
    eq("body 12", line_at(main_win()))
    eq(12, api.nvim_win_get_cursor(main_win())[1])
  end)

  it("carries the cursor from the old name onto the new one", function()
    open_history()
    step("select_next_commit", 2, "moved.txt", 20)
    step("select_next_commit", 3, "keep.txt", 20)

    api.nvim_win_set_cursor(main_win(), { 12, 0 })
    eq("body 12", line_at(main_win()))

    step("select_prev_commit", 2, "moved.txt", 20)
    eq("body 12", line_at(main_win()))
    eq(12, api.nvim_win_get_cursor(main_win())[1])
  end)
end)
