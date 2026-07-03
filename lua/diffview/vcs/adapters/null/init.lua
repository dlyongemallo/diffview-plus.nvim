local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local NullRev = lazy.access("diffview.vcs.adapters.null.rev", "NullRev") ---@type NullRev|LazyModule
local VCSAdapter = lazy.access("diffview.vcs.adapter", "VCSAdapter") ---@type VCSAdapter|LazyModule
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"

local M = {}

---@class NullAdapter : VCSAdapter
---@field Rev NullRev
local NullAdapter = oop.create_class("NullAdapter", VCSAdapter.__get())

NullAdapter.Rev = NullRev --[[@as NullRev ]]

---@class NullAdapter.create.Opt
---@field toplevel string

---@param opt NullAdapter.create.Opt
---@return NullAdapter
function NullAdapter.create(opt)
  return NullAdapter(opt)
end

---@param opt NullAdapter.create.Opt
function NullAdapter:init(opt)
  self:super()
  self.ctx = {
    toplevel = opt.toplevel,
    dir = opt.toplevel,
    path_args = {},
  }
  self.comp = {
    file_history = arg_parser.FlagValueMap(),
    open = arg_parser.FlagValueMap(),
  }
end

-- Bootstrap is always successful for the null adapter.
function NullAdapter.run_bootstrap()
  NullAdapter.bootstrap = {
    done = true,
    ok = true,
  }
end

---@param path string
---@param rev Rev
---@return boolean
function NullAdapter:is_binary(path, rev)
  return false
end

function NullAdapter:init_completion() end

---@param arg_lead string
---@param opt? RevCompletionSpec
---@return string[]
function NullAdapter:rev_candidates(arg_lead, opt)
  return {}
end

---@return Rev?
function NullAdapter:head_rev()
  return nil
end

---@param path string
---@param rev_arg string?
---@return string?
function NullAdapter:file_blob_hash(path, rev_arg)
  return nil
end

---@param path string
---@param rev_arg string
---@return boolean
function NullAdapter:file_exists_at_rev(path, rev_arg)
  return false
end

---@return string[]
function NullAdapter:get_command()
  if vim.fn.has("win32") == 1 then
    return { "cmd.exe", "/C", "exit", "0" }
  end
  return { "true" }
end

---@param path string
---@param rev Rev
---@return string[]
function NullAdapter:get_show_args(path, rev)
  return {}
end

---@param args table
---@param paths? string[]
---@return string[]
---@diagnostic disable-next-line: unused-local
function NullAdapter:get_log_args(args, paths)
  return {}
end

---@return vcs.MergeContext?
function NullAdapter:get_merge_context()
  return nil
end

---@param range? { [1]: integer, [2]: integer }
---@param paths string[]
---@param argo ArgObject
---@return nil
function NullAdapter:file_history_options(range, paths, argo)
  return nil
end

---@param out_stream any
---@param opt any
NullAdapter.file_history_worker = async.void(function(self, out_stream, opt) end)

---@param left Rev
---@param right Rev
---@return string[]
function NullAdapter:rev_to_args(left, right)
  return {}
end

---@param left Rev
---@param right Rev
---@return string|nil
function NullAdapter:rev_to_pretty_string(left, right)
  return nil
end

---@param argo ArgObject
---@return nil
function NullAdapter:diffview_options(argo)
  return nil
end

---@param opt? VCSAdapter.show_untracked.Opt
---@return boolean
function NullAdapter:show_untracked(opt)
  return false
end

---@param path string
---@param kind string
---@param commit string
function NullAdapter:restore_file(path, kind, commit) end

---@param paths string[]
---@return boolean
function NullAdapter:add_files(paths)
  return false
end

---@param paths string[]?
---@return boolean
function NullAdapter:reset_files(paths)
  return false
end

---@param file vcs.File
---@return boolean
function NullAdapter:stage_index_file(file)
  return false
end

---@param left Rev
---@param right Rev
---@param args string[]
---@param kind vcs.FileKind
---@param opt table
---@param callback fun(err?: string[], files?: FileEntry[], conflicts?: FileEntry[])
NullAdapter.tracked_files = async.wrap(function(self, left, right, args, kind, opt, callback)
  callback(nil, {}, {})
end, 7)

---@param left Rev
---@param right Rev
---@param opt table
---@param callback? fun(err?: string[], files?: FileEntry[])
NullAdapter.untracked_files = async.wrap(function(self, left, right, opt, callback)
  if callback then
    callback(nil, {})
  end
end, 5)

---@param path_args string[]
---@param cpath? string
---@return string[], string[]
function NullAdapter.get_repo_paths(path_args, cpath)
  return {}, {}
end

---@param top_indicators string[]
---@return string?, string
function NullAdapter.find_toplevel(top_indicators)
  return nil, ""
end

---@param left Rev
---@param right Rev
---@return boolean
function NullAdapter:force_entry_refresh_on_noop(left, right)
  return false
end

M.NullAdapter = NullAdapter
return M
