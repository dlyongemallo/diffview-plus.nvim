local VCSAdapter = require("diffview.vcs.adapter").VCSAdapter
local helpers = require("diffview.tests.helpers")
local utils = require("diffview.utils")

local eq = helpers.eq
local pl = utils.path

describe("VCSAdapter.append_implicit_indicators", function()
  local prev_buf
  local tmpdirs

  before_each(function()
    prev_buf = vim.api.nvim_get_current_buf()
    tmpdirs = {}
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(prev_buf) then
      vim.api.nvim_set_current_buf(prev_buf)
    end
    for _, dir in ipairs(tmpdirs) do
      pcall(vim.fn.delete, dir, "rf")
    end
  end)

  local function make_tmpdir()
    local dir = vim.fn.tempname()
    assert.equals(1, vim.fn.mkdir(dir, "p"))
    table.insert(tmpdirs, dir)
    return dir
  end

  -- Replace the current buffer with a fresh one whose name and buftype are
  -- under the test's control.  Returns the bufnr so the test can clean up.
  local function set_current_buffer(name, buftype)
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_current_buf(buf)
    if name and name ~= "" then
      vim.api.nvim_buf_set_name(buf, name)
    end
    vim.bo[buf].buftype = buftype or ""
    return buf
  end

  it("uses cpath alone when given, ignoring buffer state", function()
    local dir = make_tmpdir()
    -- Even with a named normal-file buffer, cpath wins outright.
    set_current_buffer(dir .. "/should_be_ignored.txt", "")

    local indicators = {}
    VCSAdapter.append_implicit_indicators(indicators, dir)

    eq({ pl:realpath(dir) }, indicators)
  end)

  it("falls back to cwd realpath when buftype is non-empty", function()
    -- A terminal/scratch/help buffer should not contribute its name; the
    -- only implicit indicator is the cwd.
    set_current_buffer("/tmp/scratch", "nofile")

    local indicators = {}
    VCSAdapter.append_implicit_indicators(indicators, nil)

    eq({ pl:realpath(".") }, indicators)
  end)

  it("falls back to cwd realpath when buffer is unnamed", function()
    -- `:enew`-style buffer with no file name behind it.
    set_current_buffer(nil, "")

    local indicators = {}
    VCSAdapter.append_implicit_indicators(indicators, nil)

    eq({ pl:realpath(".") }, indicators)
  end)

  it("appends absolute cfile and cwd for a named non-symlink file buffer", function()
    local dir = make_tmpdir()
    local file = dir .. "/real.txt"
    assert(io.open(file, "w")):close()

    set_current_buffer(file, "")

    local indicators = {}
    VCSAdapter.append_implicit_indicators(indicators, nil)

    eq({ pl:absolute(file), pl:realpath(".") }, indicators)
  end)

  it("also appends the resolved target when the buffer's path is a symlink", function()
    local dir = make_tmpdir()
    local target = dir .. "/target.txt"
    local link = dir .. "/link.txt"
    assert(io.open(target, "w")):close()
    -- Relative target exercises the `pl:parent(absolute_cfile)` resolution.
    assert(vim.uv.fs_symlink("target.txt", link))

    set_current_buffer(link, "")

    local indicators = {}
    VCSAdapter.append_implicit_indicators(indicators, nil)

    local absolute_link = pl:absolute(link)
    eq({
      absolute_link,
      pl:realpath("."),
      pl:absolute("target.txt", pl:parent(absolute_link)),
    }, indicators)
  end)
end)
