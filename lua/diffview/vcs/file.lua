local async = require("diffview.async")
local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local GitRev = lazy.access("diffview.vcs.adapters.git.rev", "GitRev") ---@type GitRev|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local Signal = lazy.access("diffview.control", "Signal") ---@type Signal|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local await = async.await
local fmt = string.format
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

local api = vim.api
local M = {}

---@alias git.FileDataProducer fun(kind: vcs.FileKind, path: string, pos: "left"|"right"): string[]

---@class vcs.File : diffview.Object
---@field adapter GitAdapter
---@field path string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field kind vcs.FileKind
---@field nulled boolean
---@field rev Rev
---@field blob_hash string?
---@field commit Commit?
---@field symbol string?
---@field get_data git.FileDataProducer?
---@field bufnr? integer
---@field binary boolean
---@field active boolean
---@field loaded boolean # True once the buffer's content is fully populated. Required by `is_valid()` to distinguish a fully-loaded buffer from a mid-load placeholder.
---@field ready boolean
---@field winbar string?
---@field winopts WindowOptions
---@field _orig_ts_context_disable? boolean # Saved `ts_context_disable` before diffview overrode it.
---@field _orig_context_enabled? boolean # Saved `context_enabled` before diffview overrode it.
---@field _context_state_saved? boolean # Whether the two saved values above are populated.
---@field package _loading? Signal # Owned by the in-flight `create_buffer` call; concurrent callers await it before reading `bufnr`.
---@field package _loading_error? string # Error from the most recent failed `create_buffer`, exposed to concurrent waiters once the signal fires.
local File = oop.create_class("vcs.File")

---@type table<integer, vcs.File.AttachState>
File.attached = {}

---@type table<string, table<string, integer>>
File.index_bufmap = {}

---Tracks LOCAL buffers that were newly created by diffview (not pre-existing).
---@type table<integer, boolean>
File.created_bufs = {}

---Sentinel error value for cancelled buffer creation.
File.CANCELLED = "diffview:cancelled"

---@static
File.bufopts = {
  buftype = "nowrite",
  modifiable = false,
  swapfile = false,
  bufhidden = "hide",
  undolevels = -1,
}

---File constructor
---@param opt table
function File:init(opt)
  self.adapter = opt.adapter
  self.path = opt.path
  self.absolute_path = pl:absolute(opt.path, opt.adapter.ctx.toplevel)
  self.parent_path = pl:parent(opt.path) or ""
  self.basename = pl:basename(opt.path)
  self.extension = pl:extension(opt.path) or ""
  self.kind = opt.kind
  self.binary = utils.sate(opt.binary)
  self.nulled = not not opt.nulled
  self.rev = opt.rev
  self.commit = opt.commit
  self.symbol = opt.symbol
  self.get_data = opt.get_data
  self.active = true
  self.loaded = false
  self.ready = false

  self.winopts = opt.winopts
    or {
      diff = true,
      scrollbind = true,
      cursorbind = true,
      foldmethod = "diff",
      scrollopt = { "ver", "hor", "jump" },
      foldcolumn = "1",
      -- Resolved from `view.foldlevel` at window open (see `Window:open_file`).
      foldlevel = 0,
      foldenable = true,
      -- Use prepend method so diffview's highlights take precedence but don't
      -- clobber user's additional winhl customizations (#515).
      winhl = {
        "DiffAdd:DiffviewDiffAdd",
        "DiffDelete:DiffviewDiffDelete",
        "DiffChange:DiffviewDiffChange",
        "DiffText:DiffviewDiffText",
        opt = { method = "prepend" },
      },
    }

  -- Set winbar info
  if self.rev then
    local winbar, label

    if self.rev.type == RevType.LOCAL then
      winbar = " WORKING TREE - ${path}"
    elseif self.rev.type == RevType.COMMIT then
      winbar = " ${object_path}"
    elseif self.rev.type == RevType.STAGE then
      if self.kind == "conflicting" then
        label = ({
          [1] = "(Common ancestor) ",
          [2] = "(Current changes) ",
          [3] = "(Incoming changes) ",
        })[self.rev.stage] or ""
      end

      winbar = " INDEX ${label}- ${object_path}"
    end

    if winbar then
      self.winbar = utils.str_template(winbar, {
        path = self.path,
        object_path = self.rev:object_name(10) .. ":" .. self.path,
        label = label or "",
      })
    end
  end
end

---@param force? boolean Also delete buffers for LOCAL files.
function File:destroy(force)
  self.active = false
  self:detach_buffer()

  if force or self.rev.type ~= RevType.LOCAL and not lib.is_buf_in_use(self.bufnr, { self }) then
    File.safe_delete_buf(self.bufnr)
  end
end

function File:post_buf_created()
  local view = require("diffview.lib").get_current_view()

  if view then
    view.emitter:on("diff_buf_win_enter", function(_, bufnr, winid, ctx)
      if bufnr == self.bufnr then
        api.nvim_win_call(winid, function()
          DiffviewGlobal.emitter:emit("diff_buf_read", self.bufnr, ctx)
        end)

        return true
      end
    end)
  end
end

function File:_create_local_buffer()
  self.bufnr = utils.find_file_buffer(self.absolute_path)

  if not self.bufnr then
    local winid = utils.temp_win()
    assert(winid ~= 0, "Failed to create temporary window!")

    api.nvim_win_call(winid, function()
      vim.cmd("edit " .. vim.fn.fnameescape(self.absolute_path))
      self.bufnr = api.nvim_get_current_buf()
      vim.bo[self.bufnr].bufhidden = "hide"
    end)

    api.nvim_win_close(winid, true)

    -- Track this buffer as created by diffview so it can be cleaned up on close.
    File.created_bufs[self.bufnr] = true
  else
    -- Plugins that scan the project (LSP, file managers, grapple/harpoon-style
    -- pickers, fzf-lua warm caches, ...) sometimes register a buffer by name
    -- without ever loading its contents. `find_file_buffer` matches on name,
    -- so we'd happily reuse the empty placeholder -- `inline_diff.render`
    -- would then diff an empty new-side against the old-side content, the
    -- hunk cache wouldn't get populated, and `jump_to_first_change` would
    -- land on line 1 (or, in `diff1_inline`, error past the empty buffer's
    -- end). Force a load if the buffer is unloaded so its contents come from
    -- disk before we hand the bufnr to the diff renderer.
    if not api.nvim_buf_is_loaded(self.bufnr) then
      vim.fn.bufload(self.bufnr)
    end
    -- NOTE: LSP servers might load buffers in the background and unlist
    -- them. Explicitly set the buffer as listed when loading it here.
    vim.bo[self.bufnr].buflisted = true
    self.adapter:on_local_buffer_reused(self.bufnr)
  end

  self:post_buf_created()
end

---@private
---@param self vcs.File
---@param callback (fun(err?: string[], data?: string[]))
File.produce_data = async.wrap(function(self, callback)
  if self.get_data and vim.is_callable(self.get_data) then
    local pos = self.symbol == "a" and "left" or "right"
    local data = self.get_data(self.kind, self.path, pos)
    callback(nil, data)
  else
    local err, data = await(self.adapter:show(self.path, self.rev))

    if err then
      callback(err)
      return
    end

    callback(nil, data)
  end
end)

---@param self vcs.File
---@param callback function
File.create_buffer = async.wrap(function(self, callback)
  ---@diagnostic disable: invisible
  await(async.scheduler())

  if self == File.NULL_FILE then
    callback(File._get_null_buffer())
    return
  end

  if self:is_valid() then
    callback(self.bufnr)
    return
  end

  -- An in-flight `create_buffer` on this same File has set `bufnr` but
  -- hasn't finished populating its content. Wait for it instead of
  -- returning a half-built buffer.
  if self._loading then
    await(self._loading)
    if self:is_valid() then
      callback(self.bufnr)
      return
    end
    -- The in-flight call exited without marking the file loaded. Re-raise
    -- the same error it observed so all waiters share its outcome
    -- (cancellation, `produce_data` failure, etc.).
    error(self._loading_error or ("Concurrent buffer load failed for: " .. tostring(self.path)))
  end

  -- First caller: install the signal that concurrent callers will await.
  -- It must be sent on every exit path (success, error, cancellation) so
  -- waiters never hang.
  local loading = Signal()
  self._loading = loading

  -- Clear stale state from any prior successful load. A buffer wiped
  -- outside `dispose_buffer` (e.g. user `:bdelete`) leaves `loaded=true`
  -- with an invalid `bufnr`; without this reset, a concurrent caller
  -- would short-circuit on `is_valid()` as soon as we allocate the fresh
  -- bufnr below but before its content is populated.
  self.loaded = false
  if self.bufnr and not api.nvim_buf_is_valid(self.bufnr) then
    self.bufnr = nil
  end

  -- Tracks a `diffview://` buffer freshly allocated by this call. On any
  -- post-creation error we wipe it so a retry (or a sibling File instance)
  -- doesn't pick up the half-built placeholder via `find_named_buffer`.
  local created_fresh_bufnr

  local ok, err = pcall(function()
    -- Bail out if the file was deactivated during the scheduler yield
    -- (e.g. user navigated away). This covers all code paths below:
    -- binary check, local buffer creation, stage blob lookup, and
    -- produce_data.
    if not self.active then
      error(File.CANCELLED)
    end

    -- Don't probe a nulled side: the result is unused (it routes to the NULL
    -- buffer below), and for a deleted file the gone `LOCAL` path makes
    -- `is_binary` false-positive, which would hide the deletion in inline.
    if self.binary == nil and not self.nulled and not config.get_config().diff_binaries then
      self.binary = self.adapter:is_binary(self.path, self.rev)
    end

    if self.nulled or self.binary then
      self.bufnr = File._get_null_buffer()
      self:post_buf_created()
      return
    end

    if self.rev.type == RevType.LOCAL then
      self:_create_local_buffer()
      return
    end

    -- Unmerged entries may not have all stage blobs (e.g. delete/modify
    -- conflicts). Missing stage blobs should render as null buffers.
    if self.rev.type == RevType.STAGE and self.rev.stage > 0 and self.adapter.file_blob_hash then
      if not self.adapter:file_blob_hash(self.path, ":" .. self.rev.stage) then
        self.nulled = true
        self.bufnr = File._get_null_buffer()
        self:post_buf_created()
        return
      end
    end

    local context
    if self.rev.type == RevType.COMMIT then
      context = self.rev:abbrev(11)
    elseif self.rev.type == RevType.STAGE then
      context = fmt(":%d:", self.rev.stage)
    elseif self.rev.type == RevType.CUSTOM then
      context = "[custom]"
    end

    local fullname = pl:join("diffview://", self.adapter.ctx.dir, context, self.path)

    self.bufnr = utils.find_named_buffer(fullname)

    if self.bufnr then
      -- Only reuse a found buffer if a prior successful load marked it
      -- ready. An unmarked buffer may belong to a different File instance
      -- whose load is still in flight; since we don't yet coordinate
      -- across File instances, refuse to return a half-built buffer.
      if vim.b[self.bufnr].diffview_loaded then
        return
      end
      self.bufnr = nil
      error("Found unloaded `diffview://` buffer: " .. fullname)
    end

    -- Create buffer and set name *before* calling `produce_data()` to ensure
    -- that multiple file instances won't ever try to create the same file.
    self.bufnr = api.nvim_create_buf(false, false)
    created_fresh_bufnr = self.bufnr
    api.nvim_buf_set_name(self.bufnr, fullname)

    -- If the file was deactivated (e.g. the user navigated away) before we
    -- start the expensive produce_data call, bail out. The outer handler
    -- wipes `created_fresh_bufnr`.
    if not self.active then
      error(File.CANCELLED)
    end

    local data_err, lines = await(self:produce_data())
    if data_err then
      error(table.concat(data_err, "\n"))
    end

    await(async.scheduler())

    -- If the file was deactivated while produce_data was running, bail
    -- out. The outer handler wipes `created_fresh_bufnr`.
    if not self.active then
      error(File.CANCELLED)
    end

    -- Revalidate buffer in case the file was destroyed before `produce_data()`
    -- returned.
    if not api.nvim_buf_is_valid(self.bufnr) then
      error("The buffer has been invalidated!")
    end
    local bufopts = vim.deepcopy(File.bufopts)

    if self.rev.type == RevType.STAGE and self.rev.stage == 0 then
      self.blob_hash = self.adapter:file_blob_hash(self.path)
      bufopts.modifiable = true
      bufopts.buftype = "acwrite"
      bufopts.undolevels = nil
      utils.tbl_set(File.index_bufmap, { self.adapter.ctx.toplevel, self.path }, self.bufnr)

      api.nvim_create_autocmd("BufWriteCmd", {
        buffer = self.bufnr,
        nested = true,
        callback = function()
          self.adapter:stage_index_file(self)
        end,
      })
    end

    for option, value in pairs(bufopts) do
      vim.bo[self.bufnr][option] = value
    end

    local last_modifiable = vim.bo[self.bufnr].modifiable
    local last_modified = vim.bo[self.bufnr].modified
    vim.bo[self.bufnr].modifiable = true
    api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

    -- Prevent LSP clients from attaching to diffview:// buffers. LSP servers
    -- may not support the custom URI scheme, and the buffer content may be
    -- from a different revision making LSP features incorrect or harmful.
    api.nvim_create_autocmd("LspAttach", {
      buffer = self.bufnr,
      callback = function(ev)
        local client_id = ev.data and ev.data.client_id
        if not client_id then
          return
        end
        vim.schedule(function()
          if api.nvim_buf_is_valid(ev.buf) then
            pcall(vim.lsp.buf_detach_client, ev.buf, client_id)
          end
        end)
      end,
    })

    -- Disable auto-formatting. Diffview buffers contain committed or staged
    -- content that should not be reformatted. The `autoformat` variable is
    -- a common convention (LazyVim, conform.nvim, etc.).
    vim.b[self.bufnr].autoformat = false

    -- Disable treesitter highlighting on large non-LOCAL buffers. Treesitter
    -- may still perform an initial parse during filetype detection, but
    -- stopping it prevents the ongoing re-parses during cursor movement and
    -- scrolling that cause the actual performance problems in diff views.
    local threshold = config.get_config().large_file_threshold
    local disable_ts = threshold > 0 and #lines > threshold

    if disable_ts then
      vim.b[self.bufnr].diffview_disable_ts = true
    end

    api.nvim_buf_call(self.bufnr, function()
      vim.cmd("filetype detect")
    end)

    if disable_ts then
      pcall(vim.treesitter.stop, self.bufnr)
    end

    -- Match the index buffer's fileformat to the working tree file so that
    -- saving the buffer does not inadvertently convert line endings.
    if self.rev.type == RevType.STAGE and self.rev.stage == 0 then
      local abs_path = self.absolute_path or pl:absolute(self.path, self.adapter.ctx.toplevel)
      if vim.fn.filereadable(abs_path) == 1 then
        local first_line = vim.fn.readfile(abs_path, "B", 1)
        if first_line[1] and first_line[1]:find("\r$") then
          vim.bo[self.bufnr].fileformat = "dos"
        else
          vim.bo[self.bufnr].fileformat = "unix"
        end
      end
    end

    -- Disable context plugins that interfere with scrollbind alignment.
    -- Note: nvim-treesitter-context does NOT check this variable by default;
    -- users must configure `on_attach` callback to check it. context.vim does.
    vim.b[self.bufnr].ts_context_disable = true
    vim.b[self.bufnr].context_enabled = false

    vim.bo[self.bufnr].modifiable = last_modifiable
    vim.bo[self.bufnr].modified = last_modified
    -- Mark this `diffview://` buffer as fully populated. Other File
    -- instances that resolve to the same `fullname` via
    -- `find_named_buffer` use this flag to know the buffer's content is
    -- ready and safe to reuse.
    vim.b[self.bufnr].diffview_loaded = true
    self:post_buf_created()
  end)

  if not ok and created_fresh_bufnr then
    -- Wipe the half-built `diffview://` buffer so a retry (or a sibling
    -- File instance) doesn't pick it up via `find_named_buffer`.
    pcall(api.nvim_buf_delete, created_fresh_bufnr, { force = true })
    if self.bufnr == created_fresh_bufnr then
      self.bufnr = nil
    end
  end

  -- Mark loaded only on success; stash the error and signal either way so
  -- waiters unblock and see the same outcome.
  if ok then
    self.loaded = true
  end
  self._loading_error = err
  self._loading = nil
  loading:send()

  if not ok then
    error(err)
  end

  callback(self.bufnr)
  ---@diagnostic enable: invisible
end)

function File:is_valid()
  -- `loaded` is set only after `produce_data` populates the buffer, so a
  -- mid-load placeholder (bufnr created, content pending) does not read
  -- as valid.
  return self.bufnr ~= nil and api.nvim_buf_is_valid(self.bufnr) and self.loaded
end

---@param t1 table
---@param t2 table
---@return vcs.File.AttachState
local function prepare_attach_opt(t1, t2)
  local res = vim.tbl_extend("keep", t1, {
    keymaps = {},
    disable_diagnostics = false,
  })

  for k, v in pairs(t2) do
    local t = type(res[k])

    if t == "boolean" then
      res[k] = res[k] or v
    elseif t == "table" and type(v) == "table" then
      res[k] = vim.tbl_extend("force", res[k], v)
    else
      res[k] = v
    end
  end

  return res
end

---@class vcs.File.AttachState
---@field keymaps? table
---@field saved_keymaps table<string, table> Original buffer keymaps saved before overwriting.
---@field disable_diagnostics boolean

---Save any existing buffer-local keymap for the given mode and lhs before
---diffview overwrites it, so we can restore it on detach.
---@param bufnr integer
---@param saved table<string, table>
---@param mode_map_cache table<string, table>
---@param mode string
---@param lhs string
local function save_existing_keymap(bufnr, saved, mode_map_cache, mode, lhs)
  local key = mode .. " " .. lhs
  if saved[key] then
    return
  end

  local mode_cache = mode_map_cache[mode]
  if not mode_cache then
    mode_cache = {}
    for _, km in ipairs(api.nvim_buf_get_keymap(bufnr, mode)) do
      if km.lhs and mode_cache[km.lhs] == nil then
        mode_cache[km.lhs] = km
      end
    end
    mode_map_cache[mode] = mode_cache
  end

  local km = mode_cache[lhs]
  if not km then
    return
  end

  saved[key] = {
    mode = mode,
    lhs = lhs,
    rhs = km.rhs or "",
    callback = km.callback,
    opts = {
      buffer = bufnr,
      desc = km.desc,
      silent = km.silent == 1 or km.silent == true,
      noremap = km.noremap == 1 or km.noremap == true,
      nowait = km.nowait == 1 or km.nowait == true,
      expr = km.expr == 1 or km.expr == true,
    },
  }
end

---@param force? boolean
---@param opt? vcs.File.AttachState
function File:attach_buffer(force, opt)
  if self.bufnr then
    local new_opt = false
    local cur_state = File.attached[self.bufnr] or {}
    local state = prepare_attach_opt(cur_state, opt or {})

    if opt then
      new_opt = not vim.deep_equal(cur_state or {}, opt)
    end

    if force or new_opt or not cur_state then
      local conf = config.get_config()

      -- Keymaps
      state.keymaps = config.extend_keymaps(conf.keymaps.view, state.keymaps)
      state.saved_keymaps = state.saved_keymaps or {}
      local default_map_opt = { silent = true, nowait = true, buffer = self.bufnr }
      local existing_maps_by_mode = {}

      for _, mapping in ipairs(state.keymaps) do
        local modes = type(mapping[1]) == "table" and mapping[1] or { mapping[1] }
        for _, mode in ipairs(modes) do
          save_existing_keymap(
            self.bufnr,
            state.saved_keymaps,
            existing_maps_by_mode,
            mode,
            mapping[2]
          )
        end
        local map_opt =
          vim.tbl_extend("force", default_map_opt, mapping[4] or {}, { buffer = self.bufnr })
        vim.keymap.set(mapping[1], mapping[2], mapping[3], map_opt)
      end

      -- Diagnostics
      if state.disable_diagnostics then
        vim.diagnostic.enable(false, { bufnr = self.bufnr })
      end

      -- Inlay hints: Always disable for non-LOCAL buffers to prevent
      -- "Invalid 'col': out of range" errors. Inlay hint positions are
      -- computed for the current file version, which may differ from the
      -- revision shown in the diff buffer.
      if self.rev and self.rev.type ~= RevType.LOCAL then
        pcall(vim.lsp.inlay_hint.enable, false, { bufnr = self.bufnr })
      end

      File.attached[self.bufnr] = state

      -- Keymaps are registered asynchronously (after buffer creation and
      -- content loading). Fire BufReadPost once so plugins like which-key.nvim
      -- re-scan buffer-local keymaps and make them discoverable immediately.
      -- Guard: emit only on first attach to avoid re-running all BufReadPost
      -- handlers on repeated open_file() calls for the same buffer.
      -- Skip for buffers where treesitter was intentionally disabled
      -- (large_file_threshold): BufReadPost would trigger a full treesitter
      -- re-parse, defeating the large-file optimisation.
      -- Suppress FileType during the synthetic emission: nvim's
      -- `filetypedetect` augroup re-runs filetype detection on BufReadPost,
      -- which re-fires FileType. A user FileType handler can then clobber
      -- diffview's window-local options (e.g. replacing `foldmethod = "diff"`
      -- with `foldmethod = "expr"`). See #113.
      local should_emit_buf_read = not vim.b[self.bufnr].diffview_buf_read_emitted
        and not vim.b[self.bufnr].diffview_disable_ts
      if should_emit_buf_read then
        vim.b[self.bufnr].diffview_buf_read_emitted = true
        local saved_ei = vim.o.eventignore
        ---@diagnostic disable-next-line: undefined-field -- `vim.opt.X` is magic; LuaLS doesn't see it as `vim.Option`.
        vim.opt.eventignore:append("FileType")
        pcall(api.nvim_buf_call, self.bufnr, function()
          api.nvim_exec_autocmds("BufReadPost", { buffer = self.bufnr, modeline = false })
        end)
        vim.o.eventignore = saved_ei
      end
    end
  end
end

function File:detach_buffer()
  if self.bufnr then
    local state = File.attached[self.bufnr]

    if state then
      -- Keymaps: remove diffview's mappings.
      for lhs, mapping in pairs(state.keymaps) do
        if type(lhs) == "number" then
          local modes = type(mapping[1]) == "table" and mapping[1] or { mapping[1] }
          for _, mode in ipairs(modes) do
            pcall(api.nvim_buf_del_keymap, self.bufnr, mode, mapping[2])
          end
        else
          pcall(api.nvim_buf_del_keymap, self.bufnr, "n", lhs)
        end
      end

      -- Restore original buffer keymaps that were saved before attach.
      if state.saved_keymaps then
        for _, km in pairs(state.saved_keymaps) do
          local rhs = km.callback or km.rhs
          if rhs and api.nvim_buf_is_valid(self.bufnr) then
            pcall(vim.keymap.set, km.mode, km.lhs, rhs, km.opts)
          end
        end
      end

      -- Diagnostics
      if state.disable_diagnostics then
        vim.diagnostic.enable(true, { bufnr = self.bufnr })
      end

      -- Re-enable inlay hints for non-LOCAL buffers (if they were disabled).
      if self.rev and self.rev.type ~= RevType.LOCAL then
        pcall(vim.lsp.inlay_hint.enable, true, { bufnr = self.bufnr })
      end

      File.attached[self.bufnr] = nil
    end
  end
end

function File:dispose_buffer()
  if self.bufnr and api.nvim_buf_is_loaded(self.bufnr) then
    self:detach_buffer()

    if not lib.is_buf_in_use(self.bufnr, { self }) then
      File.safe_delete_buf(self.bufnr)
    end

    self.bufnr = nil
    -- Reset so a later `create_buffer` re-loads from scratch.
    self.loaded = false
  end
end

function File.safe_delete_buf(bufnr)
  if not bufnr or bufnr == File.NULL_FILE.bufnr or not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  for _, winid in ipairs(utils.win_find_buf(bufnr, 0)) do
    File.load_null_buffer(winid)
  end

  pcall(api.nvim_buf_delete, bufnr, { force = true })
end

---@static Get the bufid of the null buffer. Create it if it's not loaded.
---@return integer
function File._get_null_buffer()
  if not api.nvim_buf_is_loaded(File.NULL_FILE.bufnr or -1) then
    local bufname = "diffview://null"
    -- Adopt an existing `diffview://null` buffer if one is still around
    -- (e.g., from a previous diffview session). Wiping it would call
    -- `nvim_win_close` on every window showing it, which throws E444 when
    -- that buffer happens to occupy the only window in the current tabpage.
    local bn = utils.find_named_buffer(bufname) or api.nvim_create_buf(false, false)
    -- An adopted buffer may be unloaded; force-load it so the outer guard
    -- above sees it as loaded on later calls.
    if not api.nvim_buf_is_loaded(bn) then
      vim.fn.bufload(bn)
    end
    -- Reset content in case the adopted buffer carries stale lines from a
    -- previous session; the null buffer must always be empty.
    vim.bo[bn].modifiable = true
    api.nvim_buf_set_lines(bn, 0, -1, false, {})
    for option, value in pairs(File.bufopts) do
      vim.bo[bn][option] = value
    end
    -- `nvim_buf_set_lines` flips `modified`; clear it so a hidden adopted
    -- null buffer never trips `:quit`/`bdelete` with unsaved-changes errors.
    vim.bo[bn].modified = false

    if vim.fn.bufname(bn) ~= bufname then
      api.nvim_buf_set_name(bn, bufname)
    end

    File.NULL_FILE.bufnr = bn
  end

  return File.NULL_FILE.bufnr
end

---@static
function File.load_null_buffer(winid)
  local bn = File._get_null_buffer()
  local ok, err = utils.set_win_buf(winid, bn)
  if not ok then
    error(err)
  end
  File.NULL_FILE:attach_buffer()
end

---@type vcs.File
File.NULL_FILE = File({
  -- NOTE: consider changing this adapter to be an actual adapter instance
  adapter = {
    ctx = {
      toplevel = "diffview://",
    },
  },
  path = "null",
  kind = "working",
  status = "X",
  binary = false,
  nulled = true,
  rev = GitRev.new_null_tree(),
  -- Explicitly disable diff-related window options for the null buffer.
  -- This prevents scrollbind/cursorbind from persisting after closing diffview.
  winopts = {
    diff = false,
    scrollbind = false,
    cursorbind = false,
    foldmethod = "manual",
    scrollopt = {},
    foldcolumn = "0",
    foldlevel = 99,
    foldenable = false,
    winhl = {},
  },
})
-- The NULL buffer skips `create_buffer`'s loading path (it's created
-- on-demand by `_get_null_buffer`), so mark it loaded so `is_valid()`
-- accepts it.
File.NULL_FILE.loaded = true

M.File = File
return M
