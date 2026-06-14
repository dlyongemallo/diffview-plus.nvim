local assert = require("luassert")
local async = require("diffview.async")

local await, pawait = async.await, async.pawait

local M = {}

function M.eq(a, b)
  if a == nil or b == nil then
    return assert.are.equal(a, b)
  end
  return assert.are.same(a, b)
end

function M.neq(a, b)
  if a == nil or b == nil then
    return assert.are_not.equal(a, b)
  end
  return assert.are_not.same(a, b)
end

---@param test_func function
function M.async_test(test_func)
  local afunc = async.void(test_func)

  return function(...)
    local ok, err = pawait(afunc(...))
    await(async.scheduler())

    if not ok then
      error(err)
    end
  end
end

--- Run a system command synchronously and return the completed result.
---@param cmd string[]
---@param cwd? string
---@param opts? { env?: table<string, string>, allow_nonzero?: boolean }
function M.system(cmd, cwd, opts)
  opts = opts or {}
  local res = vim.system(cmd, { cwd = cwd, env = opts.env, text = true }):wait()
  if not opts.allow_nonzero then
    assert.equals(0, res.code, (table.concat(cmd, " ") .. "\n" .. (res.stderr or "")))
  end
  return res
end

--- Run a system command synchronously and return its trimmed stdout.
---@param cmd string[]
---@param cwd? string
---@param opts? { env?: table<string, string>, allow_nonzero?: boolean }
---@return string
function M.run(cmd, cwd, opts)
  return vim.trim(M.system(cmd, cwd, opts).stdout or "")
end

--- Create an empty temporary git repo with a test identity configured.
---@return string repo Absolute path to the new repo.
function M.init_repo()
  local repo = vim.fn.tempname()
  assert.equals(1, vim.fn.mkdir(repo, "p"))

  M.run({ "git", "init", "-q" }, repo)
  M.run({ "git", "config", "user.name", "Diffview Test" }, repo)
  M.run({ "git", "config", "user.email", "diffview@test.local" }, repo)

  return repo
end

--- Create a temporary git repo with a single commit (`init.txt`).
---@return string repo Absolute path to the new repo.
function M.make_repo()
  local repo = M.init_repo()

  local path = repo .. "/init.txt"
  local f = assert(io.open(path, "w"))
  f:write("init\n")
  f:close()

  M.run({ "git", "add", "init.txt" }, repo)
  M.run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" }, repo)

  return repo
end

--- Remove a temporary repo, scheduled to avoid event-loop issues.
---@param repo string
function M.cleanup_repo(repo)
  vim.schedule(function()
    pcall(vim.fn.delete, repo, "rf")
  end)
  await(async.scheduler())
end

--- Close a view and its tabpage, then dispose of it.
---@param view any
function M.close_view(view)
  if not view then
    return
  end

  if view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage) then
    view:close()
  end

  require("diffview.lib").dispose_view(view)
end

return M
