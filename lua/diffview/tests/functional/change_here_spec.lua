local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")

local api = vim.api
local eq = helpers.eq
local commit = helpers.commit
local line_at = helpers.line_at
local body = helpers.body
local write = helpers.write

-- Only c3 edits the body. The commit after it prepends, which moves the body's
-- line numbers without changing a line of it, and so does the one before. c3b
-- leaves `file.txt` alone, so it shows up only in the unfiltered history:
--
--   c1   file.txt   body 1..20                 (20 lines)
--   c2   file.txt   head 1..30 + body          (50)
--   c3   file.txt   body 5 rewritten           (50)
--   c3b  other.txt  new file
--   c4   file.txt   mid 1..5 + head + body     (55)
local function make_repo()
  local repo = helpers.init_repo()
  local lines = body("body", 20)
  write(repo, "file.txt", lines)
  commit(repo, "c1")

  lines = vim.list_extend(body("head", 30), lines)
  write(repo, "file.txt", lines)
  commit(repo, "c2")

  lines[35] = "body 5 rewritten"
  write(repo, "file.txt", lines)
  commit(repo, "c3")

  write(repo, "other.txt", body("other", 8))
  commit(repo, "c3b")

  lines = vim.list_extend(body("mid", 5), lines)
  write(repo, "file.txt", lines)
  commit(repo, "c4")

  return repo
end

describe("select_change_here", function()
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

  local function main_win()
    return view.cur_layout:get_main_win().id
  end

  ---Open the history on c4 and put the cursor on `text`.
  ---@param text string
  ---@param paths string[]? # Path filter. Defaults to `file.txt` only.
  ---@param n_entries integer? # Entries that filter yields. Defaults to 4.
  ---@return integer main_win
  local function open_on(text, paths, n_entries)
    view = lib.file_history(nil, paths or { "file.txt" })
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= (n_entries or 4) and view.cur_layout ~= nil
      end),
      "view never became ready"
    )
    assert.is_true(
      vim.wait(10000, function()
        return api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) >= 55
      end),
      "the b-side buffer never loaded"
    )

    local main = main_win()
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(main), 0, -1, false)
    local row = assert(vim.fn.index(lines, text) + 1 > 0 and vim.fn.index(lines, text) + 1)

    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { row, 0 })
    eq(text, line_at(main))

    return main
  end

  ---@param idx integer # Panel entry index the walk must come to rest on.
  ---@param lines integer # Line count of that commit's buffer, so the wait also
  ---covers the swap the panel move was only the start of.
  local function wait_for_entry(idx, lines)
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[idx]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == lines
      end),
      ("the walk never came to rest on entry %d"):format(idx)
    )
    vim.wait(200)
  end

  it("passes a commit that only shifts the line and opens the one that rewrote it", function()
    open_on("body 5 rewritten")

    view:select_change_here(1)

    -- c4 only prepends the `mid` block, so the line reads the same in c3 as in
    -- c4. c3 rewrote it, so that is where the walk stops: c2 merely shifts the
    -- line again and is not a commit that changes it.
    wait_for_entry(2, 50)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  it("stops on the commit that introduced the line when nothing since changed it", function()
    open_on("body 12")

    view:select_change_here(1)

    -- c3 and c2 only shift `body 12`. c1 added the file, and against its
    -- parent every line of it is new.
    wait_for_entry(4, 20)
    eq("body 12", line_at(main_win()))
  end)

  it("walks toward the newer commits", function()
    open_on("body 5 rewritten")

    -- c2 is the last commit before the rewrite, so `body 5` still holds its
    -- original text there.
    view:set_file(view.panel.entries[3].files[1])
    wait_for_entry(3, 50)
    local main = main_win()
    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { 35, 0 })
    eq("body 5", line_at(main))

    view:select_change_here(-1)

    wait_for_entry(2, 50)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  it("passes a commit that leaves the file alone", function()
    -- c3b touches `other.txt` only, so it cannot have changed `body 12` and the
    -- walk must not come to rest on it. Nothing older changes the line until
    -- c1, which added it.
    open_on("body 12", {}, 5)

    view:select_change_here(1)

    wait_for_entry(5, 20)
    eq("file.txt", view.panel.cur_item[2].path)
    eq("body 12", line_at(main_win()))
  end)

  it("says the history is still loading rather than claiming nothing changes the line", function()
    local main = open_on("body 12")
    local utils = require("diffview.utils")
    local original_info, message = utils.info, nil
    utils.info = function(msg)
      message = msg
    end
    -- The panel appends entries as the log streams in; mid-load the end of the
    -- list is the frontier, not the end of the history. c1 has not arrived
    -- yet, and it is the one commit older than c4 that changes the line.
    table.remove(view.panel.entries)
    view.panel.updating = true

    view:select_change_here(1)

    local got = vim.wait(10000, function()
      return message ~= nil
    end)
    utils.info = original_info
    view.panel.updating = false

    assert.is_true(got, "the walk never reported anything")
    assert.is_truthy(message:match("still loading"))
    eq("body 12", line_at(main))
  end)

  it("reports the end of the history walking toward the newer commits, even mid-load", function()
    local main = open_on("body 12")
    local utils = require("diffview.utils")
    local original_info, message = utils.info, nil
    utils.info = function(msg)
      message = msg
    end
    -- Entries are appended at the older end, so the newest commit is in place
    -- from the start and nothing newer can still be on its way.
    view.panel.updating = true

    view:select_change_here(-1)

    local got = vim.wait(10000, function()
      return message ~= nil
    end)
    utils.info = original_info
    view.panel.updating = false

    assert.is_true(got, "the walk never reported anything")
    assert.is_falsy(message:match("still loading"))
    eq("body 12", line_at(main))
  end)

  it("gives up when the view loses its tabpage", function()
    -- Nothing older changes `body 12`, so a walk that runs to the end would
    -- report that; giving up early reports nothing.
    open_on("body 12")
    local utils = require("diffview.utils")
    local original_info, message = utils.info, nil
    utils.info = function(msg)
      message = msg
    end
    -- The walk yields on every read, and a view whose tabpage is no longer
    -- current must not move the cursor or report anything when it resumes.
    vim.cmd("tabnew")

    view:select_change_here(1)
    vim.wait(2000, function()
      return message ~= nil or view.panel.cur_item[1] ~= view.panel.entries[1]
    end)
    utils.info = original_info
    vim.cmd("tabclose")

    eq(nil, message)
    eq(view.panel.entries[1], view.panel.cur_item[1])
  end)

  it("runs the walk through the registered action", function()
    open_on("body 5 rewritten")

    require("diffview.actions").select_next_change_here()

    wait_for_entry(2, 50)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  it("gives up when the reader picks another entry while it reads", function()
    -- Nothing older changes `body 12`, so a walk that runs to the end would
    -- report that; giving up early reports nothing.
    open_on("body 12")
    local utils = require("diffview.utils")
    local original_info, message = utils.info, nil
    utils.info = function(msg)
      message = msg
    end

    view:select_change_here(1)
    -- The walk is waiting on its first read. The selection it started from
    -- is gone by the time it resumes.
    view:set_file(view.panel.entries[3].files[1])

    wait_for_entry(3, 50)
    vim.wait(2000, function()
      return message ~= nil
    end)
    utils.info = original_info

    eq(nil, message)
    eq(view.panel.entries[3], view.panel.cur_item[1])
  end)

  it("waits for a swap still in flight before it reads the cursor", function()
    -- `mid 3` exists only in c4. A swap to c1 drops the cursor onto its first
    -- line, `body 1`, which no later commit changes. A walk that read the c4
    -- text against the c1 selection would take `mid 3` for the line and stop
    -- on c2, whose `head` block is new at that position.
    open_on("mid 3")
    local utils = require("diffview.utils")
    local original_info, message = utils.info, nil
    utils.info = function(msg)
      message = msg
    end

    view:set_file(view.panel.entries[4].files[1])
    view:select_change_here(-1)

    vim.wait(5000, function()
      return message ~= nil
    end)
    utils.info = original_info

    eq("No further commit changes this line.", message)
    eq(view.panel.entries[4], view.panel.cur_item[1])
  end)
end)

-- A history whose commits carry more than one file. `a_other.txt` sorts before
-- `file.txt`, so it is `entry.files[1]` wherever both appear: a walk that reads
-- the entry's first file rather than the one under the cursor lands here.
--
--   m1  a_other.txt + file.txt   body 1..20              (20 lines)
--   m2  a_other.txt + file.txt   body 5 rewritten        (20)
--   m3  a_other.txt              file.txt untouched
--   m4  file.txt                 head 1..10 + body       (30)
local function make_multi_repo()
  local repo = helpers.init_repo()
  local lines = body("body", 20)

  write(repo, "a_other.txt", body("other", 8))
  write(repo, "file.txt", lines)
  commit(repo, "m1")

  lines[5] = "body 5 rewritten"
  write(repo, "a_other.txt", body("other", 12))
  write(repo, "file.txt", lines)
  commit(repo, "m2")

  write(repo, "a_other.txt", body("other", 16))
  commit(repo, "m3")

  lines = vim.list_extend(body("head", 10), lines)
  write(repo, "file.txt", lines)
  commit(repo, "m4")

  return repo
end

describe("select_change_here across multi-file commits", function()
  local repo, cwd, view, original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    repo = make_multi_repo()
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

  ---@param idx integer # Panel entry index.
  ---@return FileEntry # That entry's `file.txt`.
  local function file_txt_in(idx)
    for _, f in ipairs(view.panel.entries[idx].files) do
      if f.path == "file.txt" then
        return f
      end
    end
    error("entry " .. idx .. " carries no file.txt")
  end

  ---Open the unfiltered history on m4 with the cursor on `body 5 rewritten`.
  ---@return integer main_win
  local function open_on_head()
    view = lib.file_history(nil, {})
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
        return api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) >= 30
      end),
      "the b-side buffer never loaded"
    )

    local main = main_win()
    eq("file.txt", view.panel.cur_item[2].path)
    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { 15, 0 })
    eq("body 5 rewritten", line_at(main))

    return main
  end

  it("reads the file under the cursor, not the commit's first file", function()
    open_on_head()

    view:select_change_here(1)

    -- m3 carries no `file.txt` and is passed over. m4 only prepends, so the
    -- line reads the same in m2, and reading m1 is what tells the walk that m2
    -- is where the text changed. Both m1 and m2 list `a_other.txt` first, which
    -- is the file a first-file walk would have opened instead.
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[3]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == 20
      end),
      "the walk never came to rest on m2"
    )

    eq("file.txt", view.panel.cur_item[2].path)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  it("finds the same file walking toward the newer commits", function()
    open_on_head()

    -- m1 is the last commit before the rewrite. The panel moves before the
    -- buffer swap finishes, and the walk reads the cursor and the buffer it
    -- starts from, so wait for m1 to be fully open.
    view:set_file(file_txt_in(4))
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[4]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == 20
      end),
      "m1 never opened"
    )
    vim.wait(200)

    local main = main_win()
    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { 5, 0 })
    eq("body 5", line_at(main))

    view:select_change_here(-1)

    -- Entries run newest first, so m2 is `entries[3]`. It lists `a_other.txt`
    -- first, and the walk has to come back to `file.txt` regardless.
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[3]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == 20
      end),
      "the walk never reached m2"
    )

    eq("file.txt", view.panel.cur_item[2].path)
    eq("body 5 rewritten", line_at(main_win()))
  end)
end)

---A four-line function block: signature, body, `end`, blank.
---@param name string
---@param ret integer?
---@return string[]
local function fn(name, ret)
  return { ("local function %s()"):format(name), ("  return %d"):format(ret or 0), "end", "" }
end

---@param ... string[]
---@return string[]
local function blocks(...)
  local out = {}
  for _, b in ipairs({ ... }) do
    vim.list_extend(out, b)
  end
  return out
end

-- Every function body is the same text, so a diff between two distant
-- revisions has more than one honest way to line them up. The walk has no such
-- trouble: it maps the cursor hop by hop, and each hop's diff is small enough
-- to have only one answer.
--
--   r1  fn_a fn_b fn_c fn_d                (16 lines)
--   r2  fn_c returns 3                     (16)
--   r3  fn_b dropped                       (12)
--   r4  fn_y fn_z prepended                (20)
--   r5  fn_e appended                      (24)
local function make_repeat_repo()
  local repo = helpers.init_repo()
  local a, b, c, d = fn("fn_a"), fn("fn_b"), fn("fn_c"), fn("fn_d")

  write(repo, "repeat.txt", blocks(a, b, c, d))
  commit(repo, "r1")

  c = fn("fn_c", 3)
  write(repo, "repeat.txt", blocks(a, b, c, d))
  commit(repo, "r2")

  write(repo, "repeat.txt", blocks(a, c, d))
  commit(repo, "r3")

  write(repo, "repeat.txt", blocks(fn("fn_y"), fn("fn_z"), a, c, d))
  commit(repo, "r4")

  write(repo, "repeat.txt", blocks(fn("fn_y"), fn("fn_z"), a, c, d, fn("fn_e")))
  commit(repo, "r5")

  return repo
end

describe("select_change_here across identical bodies", function()
  local repo, cwd, view, original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    repo = make_repeat_repo()
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

  it("lands on the line the walk mapped, not the one an end-to-end diff finds", function()
    view = lib.file_history(nil, { "repeat.txt" })
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= 5 and view.cur_layout ~= nil
      end),
      "view never became ready"
    )
    assert.is_true(
      vim.wait(10000, function()
        return api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == 24
      end),
      "the b-side buffer never loaded"
    )

    local main = main_win()
    api.nvim_set_current_win(main)
    -- `fn_c`'s body in r5, the only line in the file that reads `return 3`.
    api.nvim_win_set_cursor(main, { 14, 0 })
    eq("  return 3", line_at(main))

    view:select_change_here(1)

    -- r4 and r3 only shift the line. r2 is where `fn_c` started returning 3,
    -- which reading r1 is what reveals, so the walk comes to rest on r2.
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[4]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == 16
      end),
      "the walk never came to rest on r2"
    )
    vim.wait(200)

    -- Line 10 is `fn_c`'s body. Diffing r5 against r2 in one step instead has
    -- more than one honest alignment of the identical bodies and leaves the
    -- cursor off the line the walk followed.
    eq(10, api.nvim_win_get_cursor(main_win())[1])
    eq("  return 3", line_at(main_win()))
  end)
end)

-- A history in which the file under the cursor is renamed partway through.
-- Commits older than the rename list the old path and newer ones the new path,
-- so a walk that matches on one name alone goes blind at the rename and runs
-- off the end of the history. The rename itself touches no line, so a walk
-- that crosses it has to pass it over like any other commit that leaves the
-- line alone. n2 rewrites a line above the one walked to, so the tests can
-- tell the walked line from the first change.
--
--   n1  a_other.txt + keep.txt            body 1..20                   (20 lines)
--   n2  a_other.txt + keep.txt            body 2 and 5 rewritten       (20)
--   n3  a_other.txt + keep.txt -> moved.txt  pure rename               (20)
--   n4  a_other.txt + moved.txt           head 1..10, body 12 rewritten (30)
local function make_rename_repo()
  local repo = helpers.init_repo()
  local lines = body("body", 20)

  write(repo, "a_other.txt", body("other", 8))
  write(repo, "keep.txt", lines)
  commit(repo, "n1")

  lines[2] = "body 2 rewritten"
  lines[5] = "body 5 rewritten"
  write(repo, "a_other.txt", body("other", 12))
  write(repo, "keep.txt", lines)
  commit(repo, "n2")

  helpers.run({ "git", "mv", "keep.txt", "moved.txt" }, repo)
  write(repo, "a_other.txt", body("other", 16))
  commit(repo, "n3")

  lines = vim.list_extend(body("head", 10), lines)
  lines[22] = "body 12 rewritten"
  write(repo, "moved.txt", lines)
  commit(repo, "n4")

  return repo
end

describe("select_change_here across a rename", function()
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

  ---Open the history and wait for n4.
  ---@param paths string[]? # Path filter. Defaults to the whole repo.
  local function open_history(paths)
    view = lib.file_history(nil, paths or {})
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
  end

  ---@param idx integer
  ---@param path string
  ---@param lines integer
  local function wait_for(idx, path, lines)
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[idx]
          and view.panel.cur_item[2].path == path
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == lines
      end),
      ("the walk never came to rest on entry %d at %s"):format(idx, path)
    )
    vim.wait(200)
  end

  ---Open `path` in `entries[idx]` and put the cursor on `text`.
  ---@return integer main_win
  local function go_to(idx, path, text, lines)
    local target
    for _, f in ipairs(view.panel.entries[idx].files) do
      if f.path == path then
        target = f
      end
    end
    view:set_file(assert(target))
    wait_for(idx, path, lines)

    local main = main_win()
    local buf = api.nvim_buf_get_lines(api.nvim_win_get_buf(main), 0, -1, false)
    local row = vim.fn.index(buf, text) + 1
    assert.is_true(row > 0, ("%q is not in %s"):format(text, path))

    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { row, 0 })
    eq(text, line_at(main))

    return main
  end

  it("crosses the rename walking toward the older commits", function()
    open_history()
    -- n4's prepend is the only thing between the cursor and the rename, and it
    -- leaves the line's text alone.
    go_to(1, "moved.txt", "body 5 rewritten", 30)

    view:select_change_here(1)

    -- n3 renames the file without touching a line of it, so it is passed over
    -- like any other commit that leaves the line alone. Everything older lists
    -- `keep.txt`, which the walk has to follow the file to: n2 is where the
    -- line was rewritten, and reading n1 is what tells.
    wait_for(3, "keep.txt", 20)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  it("crosses the rename walking toward the newer commits", function()
    open_history()
    go_to(4, "keep.txt", "body 12", 20)

    view:select_change_here(-1)

    -- Same rename from the other side: n3 lists the file under its new name,
    -- so only `oldpath` connects it to the `keep.txt` under the cursor, and
    -- past it the file goes by `moved.txt`. n4 is where the line changed.
    wait_for(1, "moved.txt", 30)
    eq("body 12 rewritten", line_at(main_win()))
  end)

  it("crosses the rename in a single-file history", function()
    -- `--follow` lists n2 and n1 under `keep.txt` even though the history was
    -- asked for `moved.txt`.
    open_history({ "moved.txt" })
    go_to(1, "moved.txt", "body 5 rewritten", 30)

    view:select_change_here(1)

    wait_for(3, "keep.txt", 20)
    eq("body 5 rewritten", line_at(main_win()))
  end)
end)

-- A copy carries `oldpath` too, naming the file it was copied from. Git only
-- reports copies when asked, and only for sources modified in the same commit,
-- so `keep.txt` changes as it is copied. `copy.txt` sorts first, so a walk that
-- takes `oldpath` at face value picks the copy and loses the original.
--
--   p1  keep.txt                       body 1..20         (20 lines)
--   p2  keep.txt -> copy.txt (C100)    copy of p1's text  (20)
--       keep.txt                       body 12 rewritten  (20)
local function make_copy_repo()
  local repo = helpers.init_repo()
  helpers.run({ "git", "config", "diff.renames", "copies" }, repo)
  local lines = body("body", 20)

  write(repo, "keep.txt", lines)
  commit(repo, "p1")

  write(repo, "copy.txt", lines)
  lines[12] = "body 12 rewritten"
  write(repo, "keep.txt", lines)
  commit(repo, "p2")

  return repo
end

describe("select_change_here across a copy", function()
  local repo, cwd, view, original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    repo = make_copy_repo()
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

  it("stays with the original rather than following the copy", function()
    view = lib.file_history(nil, {})
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= 2 and view.cur_layout ~= nil
      end),
      "view never became ready"
    )

    -- The fixture only holds if git reported the copy as one.
    local copy
    for _, f in ipairs(view.panel.entries[1].files) do
      if f.path == "copy.txt" then
        copy = f
      end
    end
    eq("C", assert(copy).status)
    eq("keep.txt", copy.oldpath)

    -- Open p1 with the cursor on the line p2 rewrites in `keep.txt`.
    view:set_file(view.panel.entries[2].files[1])
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[2]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == 20
      end),
      "p1 never opened"
    )
    vim.wait(200)
    local main = main_win()
    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { 12, 0 })
    eq("body 12", line_at(main))

    view:select_change_here(-1)

    -- p2 lists `copy.txt` first, with `oldpath` naming `keep.txt`. The copy
    -- still reads `body 12`; the rewrite happened in `keep.txt`.
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[1]
          and view.panel.cur_item[2].path == "keep.txt"
      end),
      "the walk never came to rest on keep.txt in p2"
    )
    vim.wait(200)
    eq("body 12 rewritten", line_at(main_win()))
  end)
end)

-- The walk judges each commit against its own first parent, so the list order
-- carries no meaning beyond "these are the commits". The histories here are
-- the ones where the order lies: reversed, or listing both sides of a merge.
-- And the modes where the main window does not show the commit at all.
describe("select_change_here judges each commit by its own parent", function()
  local repo, cwd, view, original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    cwd = vim.fn.getcwd()
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

  ---Open the history with `args` and wait for the entry it lands on.
  ---@param args string[]
  ---@param n_entries integer
  ---@param lines integer # Line count of the buffer the view opens on.
  local function open_with(args, n_entries, lines)
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    view = lib.file_history(nil, args)
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= n_entries and view.cur_layout ~= nil
      end),
      "view never became ready"
    )
    assert.is_true(
      vim.wait(10000, function()
        return api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == lines
      end),
      "the b-side buffer never loaded"
    )
    vim.wait(200)
  end

  ---@param text string
  local function cursor_on(text)
    local main = main_win()
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(main), 0, -1, false)
    local row = vim.fn.index(lines, text) + 1
    assert.is_true(row > 0, ("%q is not in the buffer"):format(text))

    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { row, 0 })
    eq(text, line_at(main))
  end

  ---@param idx integer
  ---@param lines integer
  local function wait_for_entry(idx, lines)
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[idx]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == lines
      end),
      ("the walk never came to rest on entry %d"):format(idx)
    )
    vim.wait(200)
  end

  ---Wait for the walk to end on the entry it started from, which is only
  ---observable by its message.
  ---@return string
  local function walk_reports(dir)
    local utils = require("diffview.utils")
    local original_info, message = utils.info, nil
    utils.info = function(msg)
      message = msg
    end

    view:select_change_here(dir)

    local got = vim.wait(10000, function()
      return message ~= nil
    end)
    utils.info = original_info
    assert.is_true(got, "the walk never reported anything")

    return message
  end

  it("walks the reversed list in the right direction", function()
    repo = make_repo()
    -- Oldest first: c1, c2, c3, c4. An index step up is a step toward the
    -- newer commits here.
    open_with({ "--reverse", "file.txt" }, 4, 20)
    eq(view.panel.entries[1], view.panel.cur_item[1])
    cursor_on("body 5")

    view:select_change_here(-1)

    -- c2 only prepends; c3 rewrote the line.
    wait_for_entry(3, 50)
    eq("body 5 rewritten", line_at(main_win()))

    -- c4 prepends again. Nothing newer changes the line, and the newest
    -- entry is the end of the list that grows, so mid-load that is not yet
    -- known.
    view.panel.updating = true
    assert.is_truthy(walk_reports(-1):match("still loading"))
    view.panel.updating = false
    eq(view.panel.entries[3], view.panel.cur_item[1])

    view:set_file(view.panel.entries[4].files[1])
    wait_for_entry(4, 55)
    cursor_on("body 5 rewritten")

    view:select_change_here(1)

    wait_for_entry(3, 50)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  it("reads the commits rather than the pinned working tree", function()
    repo = make_repo()
    -- The main window shows the working tree for every entry, so the text
    -- under the cursor never changes; the commits behind the entries do.
    open_with({ "--pin-local", "file.txt" }, 4, 55)
    cursor_on("body 5 rewritten")

    view:select_change_here(1)

    wait_for_entry(2, 55)
    eq("body 5 rewritten", line_at(main_win()))

    view:select_change_here(1)

    -- c2 shifts the line. c1 added the file; under `--pin-local` an entry's
    -- a-side is the commit itself, which is no parent to judge it by.
    wait_for_entry(4, 55)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  it("reads the commits rather than the fixed base", function()
    repo = make_repo()
    open_with({ "--base=HEAD", "file.txt" }, 4, 55)
    cursor_on("body 5 rewritten")

    view:select_change_here(1)

    wait_for_entry(2, 55)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  -- A side branch rewrites the line while the mainline shifts it, and the
  -- merge brings the rewrite over. Listed newest-first that is
  --
  --   1  M   merge of s1 into m2      head 1..10 + body, body 5 rewritten  (30)
  --   2  m2  mainline: head 1..10 + body                                   (30)
  --   3  s1  side: body 5 rewritten                                        (20)
  --   4  m1  body 1..20                                                    (20)
  --
  -- m2 sits next to M in the list and differs from it on the line, but it is
  -- s1's rewrite that M carries, not m2's. m2 changed nothing on the line
  -- against its own parent.
  local function make_merge_repo()
    local r = helpers.init_repo()
    local vcs = "git"
    local function commit_at(msg, second)
      helpers.run({ vcs, "add", "-A" }, r)
      local date = ("2020-01-01T00:00:%02d+0000"):format(second)
      helpers.run(
        { vcs, "-c", "commit.gpgsign=false", "commit", "-q", "-m", msg },
        r,
        { env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } }
      )
    end

    local lines = body("body", 20)
    write(r, "file.txt", lines)
    commit_at("m1", 0)

    helpers.run({ vcs, "checkout", "-q", "-b", "side" }, r)
    lines[5] = "body 5 rewritten"
    write(r, "file.txt", lines)
    commit_at("s1", 1)

    helpers.run({ vcs, "checkout", "-q", "-" }, r)
    lines = vim.list_extend(body("head", 10), body("body", 20))
    write(r, "file.txt", lines)
    commit_at("m2", 2)

    local date = "2020-01-01T00:00:03+0000"
    helpers.run(
      { vcs, "-c", "commit.gpgsign=false", "merge", "-q", "--no-edit", "--no-ff", "side" },
      r,
      { env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } }
    )

    return r
  end

  it("passes a mainline commit next to the merge and stops on the side commit", function()
    repo = make_merge_repo()
    open_with({ "file.txt" }, 4, 30)
    eq("m2", view.panel.entries[2].commit.subject)
    cursor_on("body 5 rewritten")

    view:select_change_here(1)

    wait_for_entry(3, 20)
    eq("s1", view.panel.cur_item[1].commit.subject)
    eq("body 5 rewritten", line_at(main_win()))
  end)

  it("stops on the merge that brought the side commit's change over", function()
    repo = make_merge_repo()
    open_with({ "file.txt" }, 4, 30)

    view:set_file(view.panel.entries[3].files[1])
    wait_for_entry(3, 20)
    cursor_on("body 5 rewritten")

    view:select_change_here(-1)

    -- m2 comes first and holds the original line, so the walk must look past
    -- it: against its own parent it changed nothing there. M's diff against
    -- its first parent m2 is where the rewrite arrives.
    wait_for_entry(1, 30)
    eq("body 5 rewritten", line_at(main_win()))
  end)
end)

-- d2 deletes one line and nothing else. d3 prepends, which moves every line
-- below without changing one:
--
--   d1   body 1..10                 (10 lines)
--   d2   body 5 deleted             (9)
--   d3   head 1..3 + body           (12)
local function make_deletion_repo()
  local repo = helpers.init_repo()
  local lines = body("body", 10)
  write(repo, "file.txt", lines)
  commit(repo, "d1")

  table.remove(lines, 5)
  write(repo, "file.txt", lines)
  commit(repo, "d2")

  lines = vim.list_extend(body("head", 3), lines)
  write(repo, "file.txt", lines)
  commit(repo, "d3")

  return repo
end

describe("select_change_here across a pure deletion", function()
  local repo, cwd, view, original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    repo = make_deletion_repo()
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

  ---Open the history on entry `idx` and put the cursor on `text`.
  ---@param idx integer
  ---@param text string
  local function open_on(idx, text)
    view = lib.file_history(nil, { "file.txt" })
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= 3 and view.cur_layout ~= nil
      end),
      "view never became ready"
    )
    view:set_file(view.panel.entries[idx].files[1])
    assert.is_true(
      vim.wait(10000, function()
        local buf = api.nvim_win_get_buf(main_win())
        return view.panel.cur_item[1] == view.panel.entries[idx]
          and vim.fn.index(api.nvim_buf_get_lines(buf, 0, -1, false), text) >= 0
      end),
      "the b-side buffer never loaded"
    )
    vim.wait(200)

    local main = main_win()
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(main), 0, -1, false)
    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { vim.fn.index(lines, text) + 1, 0 })
    eq(text, line_at(main))
  end

  ---@param idx integer
  ---@param lines integer
  local function wait_for_entry(idx, lines)
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[idx]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == lines
      end),
      ("the walk never came to rest on entry %d"):format(idx)
    )
    vim.wait(200)
  end

  it("stops on the commit that deleted the line walking toward the newer commits", function()
    open_on(3, "body 5")

    view:select_change_here(-1)

    -- The line is gone in d2, so the cursor lands on the last line before it.
    wait_for_entry(2, 9)
    eq("body 4", line_at(main_win()))
  end)

  it("passes the deletion walking toward the older commits from the line after it", function()
    open_on(1, "body 6")

    view:select_change_here(1)

    -- d3 shifts `body 6`, d2 deleted the line above it and left it alone, and
    -- d1 added it.
    wait_for_entry(3, 10)
    eq("body 6", line_at(main_win()))
  end)
end)

-- The file turns binary for one commit. c2 keeps the text of c1 and appends a
-- NUL byte to its last line, so a walk that fails to notice the blob reads it
-- as leaving `body 5` alone and passes it.
--
--   c1  file.txt   body 1..20
--   c2  file.txt   the same, with a NUL byte on the last line
--   c3  file.txt   body 1..20
local function make_binary_repo()
  local repo = helpers.init_repo()
  local lines = body("body", 20)
  write(repo, "file.txt", lines)
  commit(repo, "c1")

  local f = assert(io.open(repo .. "/file.txt", "wb"))
  f:write(table.concat(lines, "\n") .. "\0\n")
  f:close()
  commit(repo, "c2")

  write(repo, "file.txt", lines)
  commit(repo, "c3")

  return repo
end

describe("select_change_here across a binary revision", function()
  local repo, cwd, view, original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    repo = make_binary_repo()
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

  it("opens the binary revision rather than judging it", function()
    view = lib.file_history(nil, { "file.txt" })
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= 3 and view.cur_layout ~= nil
      end),
      "view never became ready"
    )
    local main = view.cur_layout:get_main_win().id
    assert.is_true(
      vim.wait(10000, function()
        return api.nvim_buf_line_count(api.nvim_win_get_buf(main)) >= 20
      end),
      "the b-side buffer never loaded"
    )
    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { 5, 0 })
    eq("body 5", line_at(main))

    view:select_change_here(1)

    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[2]
      end),
      "the walk never came to rest on the binary revision"
    )
    vim.wait(200)
    eq(view.panel.entries[2], view.panel.cur_item[1])
  end)
end)

describe("select_change_here on what the log was asked for", function()
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

  local function main_win()
    return view.cur_layout:get_main_win().id
  end

  ---@param args string[]
  ---@param n_entries integer
  ---@param lines integer
  local function open_with(args, n_entries, lines)
    view = lib.file_history(nil, args)
    assert.is_not_nil(view)
    view:open()

    assert.is_true(
      vim.wait(10000, function()
        return view.ready and #view.panel.entries >= n_entries and view.cur_layout ~= nil
      end),
      "view never became ready"
    )
    assert.is_true(
      vim.wait(10000, function()
        return api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == lines
      end),
      "the b-side buffer never loaded"
    )
    vim.wait(200)
  end

  ---@param text string
  local function cursor_on(text)
    local main = main_win()
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(main), 0, -1, false)
    local row = vim.fn.index(lines, text) + 1
    assert.is_true(row > 0, ("%q is not in the buffer"):format(text))

    api.nvim_set_current_win(main)
    api.nvim_win_set_cursor(main, { row, 0 })
    eq(text, line_at(main))
  end

  ---@param idx integer
  ---@param lines integer
  local function wait_for_entry(idx, lines)
    assert.is_true(
      vim.wait(20000, function()
        return view.panel.cur_item[1] == view.panel.entries[idx]
          and api.nvim_buf_line_count(api.nvim_win_get_buf(main_win())) == lines
      end),
      ("the walk never came to rest on entry %d"):format(idx)
    )
    vim.wait(200)
  end

  ---@return string
  local function walk_reports(dir)
    local utils = require("diffview.utils")
    local original_info, message = utils.info, nil
    utils.info = function(msg)
      message = msg
    end

    view:select_change_here(dir)

    local got = vim.wait(10000, function()
      return message ~= nil
    end)
    utils.info = original_info
    assert.is_true(got, "the walk never reported anything")

    return message
  end

  it("refuses to read the cursor from the a-side window", function()
    open_with({ "file.txt" }, 4, 55)
    cursor_on("body 5 rewritten")
    -- The a-side shows c3, where the line reads the same, so a walk that
    -- read it from there would find c1 and move.
    api.nvim_set_current_win(view.cur_layout.a.id)

    eq("The line is read from the right-hand window. Move the cursor there first.", walk_reports(1))
    eq(view.panel.entries[1], view.panel.cur_item[1])
  end)

  it("says the range ran out rather than the history when the log was limited", function()
    open_with({ "--max-count=2", "file.txt" }, 2, 55)
    cursor_on("body 5 rewritten")

    view:select_change_here(1)

    wait_for_entry(2, 50)
    eq("body 5 rewritten", line_at(main_win()))
    -- c1 added the line, but the log stops at c3.
    eq("No further commit in the selected range changes this line.", walk_reports(1))
    -- Toward the newer commits the list is whole: c4 only shifts the line.
    eq("No further commit changes this line.", walk_reports(-1))
  end)

  it("walks the list git's own -L filtered down to", function()
    -- `body 5 rewritten` is line 40 of c4. c4 and c2 only shift it, so git
    -- lists c3 and c1, and the view opens on c3.
    open_with({ "-L40,40:file.txt" }, 2, 50)
    cursor_on("body 5 rewritten")

    view:select_change_here(1)

    wait_for_entry(2, 20)
    eq("body 5", line_at(main_win()))
  end)
end)
