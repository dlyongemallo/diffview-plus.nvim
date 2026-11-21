local config = require("diffview.config")
local test_utils = require("diffview.tests.helpers")
local vcs = require("diffview.vcs")
local JjAdapter = require("diffview.vcs.adapters.jj").JjAdapter

local eq = test_utils.eq
local run = test_utils.run

-- `jj root` searches every ancestor for `.jj`, so from a Git repository inside
-- a Jujutsu repository it reports the outer one. These specs build that layout
-- with real repositories:
--
--   outer/            colocated Jujutsu repository
--   outer/nested/     Git repository
--   outer/worktree/   linked worktree of a Git repository elsewhere
--   standalone/       Jujutsu repository without `.git`
--   workspace/        Jujutsu workspace of `standalone`
describe("diffview.vcs.adapters.jj repository boundaries", function()
  local root, git_source
  local original_config

  before_each(function()
    if vim.fn.executable("jj") ~= 1 then
      pending("jj not installed")
      return
    end

    original_config = vim.deepcopy(config.get_config())
    -- Compare against the paths that `jj root` prints.
    root = vim.fn.tempname()
    eq(1, vim.fn.mkdir(root, "p"))
    root = assert(vim.uv.fs_realpath(root))
    for _, dir in ipairs({ "outer/nested/subdir", "outer/subdir", "outside", "standalone" }) do
      eq(1, vim.fn.mkdir(root .. "/" .. dir, "p"))
    end

    run({ "jj", "git", "init", "--colocate" }, root .. "/outer")
    run({ "git", "init", "-q" }, root .. "/outer/nested")
    vim.fn.writefile({ "nested" }, root .. "/outer/nested/file.txt")
    git_source = test_utils.make_repo()
    run({ "git", "worktree", "add", "-q", "--detach", root .. "/outer/worktree" }, git_source)
    run({ "jj", "git", "init", "--no-colocate" }, root .. "/standalone")
    run({ "jj", "workspace", "add", root .. "/workspace" }, root .. "/standalone")
    assert(vim.uv.fs_symlink(root .. "/outer/nested", root .. "/nested-link", { dir = true }))
  end)

  after_each(function()
    if root then
      config.setup(original_config)
      pcall(vim.fn.delete, root, "rf")
      pcall(vim.fn.delete, git_source, "rf")
      root, git_source = nil, nil
    end
  end)

  for _, path in ipairs({
    "outer/nested",
    "outer/nested/subdir",
    "outer/nested/file.txt",
    "outer/worktree",
    "nested-link",
  }) do
    it("declines " .. path .. ", whose nearest repository is Git-only", function()
      local err, toplevel = JjAdapter.find_toplevel({ root .. "/" .. path })
      assert.is_string(err)
      eq("", toplevel)
    end)
  end

  for path, toplevel in pairs({
    ["outer"] = "outer",
    ["outer/subdir"] = "outer",
    ["standalone"] = "standalone",
    ["workspace"] = "workspace",
  }) do
    it("accepts " .. path .. ", whose nearest repository has `.jj`", function()
      local err, found = JjAdapter.find_toplevel({ root .. "/" .. path })
      assert.is_nil(err)
      eq(root .. "/" .. toplevel, found)
    end)
  end

  it("decides by the first indicator that is in a repository", function()
    local nested, outer, outside = root .. "/outer/nested", root .. "/outer", root .. "/outside"

    local err, toplevel = JjAdapter.find_toplevel({ outside, nested, outer })
    assert.is_string(err)
    eq("", toplevel)

    err, toplevel = JjAdapter.find_toplevel({ outer, nested })
    assert.is_nil(err)
    eq(outer, toplevel)
  end)

  it('`preferred_adapter = "jj"` leaves a nested Git repository to the Git adapter', function()
    config.setup({ preferred_adapter = "jj" })

    local err, adapter = vcs.get_adapter({
      cmd_ctx = { path_args = {}, cpath = root .. "/outer/nested" },
    })
    assert.is_nil(err)
    eq("git", adapter.config_key)
    eq(root .. "/outer/nested", adapter.ctx.toplevel)

    err, adapter = vcs.get_adapter({
      cmd_ctx = { path_args = {}, cpath = root .. "/outer" },
    })
    assert.is_nil(err)
    eq("jj", adapter.config_key)
  end)
end)
