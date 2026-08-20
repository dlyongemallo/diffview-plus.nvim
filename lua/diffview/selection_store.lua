local lazy = require("diffview.lazy")
local config = lazy.require("diffview.config") ---@module "diffview.config"

local logger = DiffviewGlobal.logger

local M = {}

---Get the storage path from config or fall back to stdpath("data").
---@return string
function M.get_path()
  local conf = config.get_config()
  if conf.persist_selections and conf.persist_selections.path then
    return conf.persist_selections.path
  end
  return vim.fn.stdpath("data") .. "/diffview_selections.json"
end

---Compute a scope key for a diff view.
---@param toplevel string
---@param rev_arg string?
---@return string
function M.scope_key(toplevel, rev_arg)
  return toplevel .. ":" .. (rev_arg or "")
end

---Read the entire store from disk.
---@param path string
---@return table
local function read_store(path)
  local ok, content = pcall(vim.fn.readfile, path)
  if not ok or #content == 0 then
    return {}
  end
  local decode_ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
  if not decode_ok or type(data) ~= "table" then
    logger:warn("[SelectionStore] Corrupt store file; ignoring: " .. path)
    return {}
  end
  return data
end

---Write the entire store to disk atomically via a temp file + rename.
---@param path string
---@param data table
local function write_store(path, data)
  local ok, err = pcall(function()
    local dir = vim.fn.fnamemodify(path, ":h")
    vim.fn.mkdir(dir, "p")
    if vim.fn.isdirectory(dir) == 0 then
      error("mkdir failed: " .. dir)
    end
    local json = vim.json.encode(data)
    local tmp = path .. ".tmp"
    if vim.fn.writefile({ json }, tmp) ~= 0 then
      error("writefile failed: " .. tmp)
    end
    local rename_ok, rename_err = vim.uv.fs_rename(tmp, path)
    if not rename_ok then
      pcall(vim.fn.delete, tmp)
      error(rename_err or "fs_rename failed")
    end
  end)
  if not ok then
    logger:warn("[SelectionStore] Failed to write store: " .. tostring(err))
  end
end

---Load selections and hide state for a given scope.
---@param scope_key string
---@return string[] selection_keys
---@return boolean hide
function M.load(scope_key)
  local store = read_store(M.get_path())
  local scope = store[scope_key]
  if type(scope) == "table" and type(scope.selections) == "table" then
    return scope.selections, scope.hide == true
  end
  return {}, false
end

---Save selection keys and hide state for a given scope.
---@param scope_key string
---@param selection_keys string[]
---@param hide boolean?
function M.save(scope_key, selection_keys, hide)
  local path = M.get_path()
  local store = read_store(path)
  if #selection_keys == 0 and not hide then
    store[scope_key] = nil
  else
    store[scope_key] = {
      selections = selection_keys,
      hide = hide or false,
      timestamp = os.time(),
    }
  end
  write_store(path, store)
end

return M
