local EventEmitter = require("diffview.events").EventEmitter
local File = require("diffview.vcs.file").File
local PerfTimer = require("diffview.perf").PerfTimer
local oop = require("diffview.oop")
local renderer = require("diffview.renderer")
local utils = require("diffview.utils")

local api = vim.api
local logger = DiffviewGlobal.logger
local pl = utils.path

local M = {}

local uid_counter = 0

---@alias PanelConfig PanelFloatSpec|PanelSplitSpec
---@alias PanelConfig.user PanelFloatSpec.user|PanelSplitSpec.user
---@alias PanelType "split"|"float"

---@type PerfTimer
local perf = PerfTimer("[Panel] redraw")

---@class Panel : diffview.Object
---@field type PanelType
---@field config_producer PanelConfig.user|fun(): PanelConfig.user
---@field state table
---@field bufid integer
---@field winid integer
---@field render_data RenderData
---@field components any
---@field bufname string
---@field au_event_map table<string, function[]>
---@field init_buffer_opts function Abstract
---@field update_components function Abstract
---@field render function Abstract
local Panel = oop.create_class("Panel")

Panel.winopts = {
  relativenumber = false,
  number = false,
  list = false,
  winfixbuf = true,
  winfixwidth = true,
  winfixheight = true,
  foldenable = false,
  spell = false,
  wrap = false,
  signcolumn = "yes",
  colorcolumn = "",
  foldmethod = "manual",
  foldcolumn = "0",
  scrollbind = false,
  cursorbind = false,
  diff = false,
}

Panel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  bufhidden = "hide",
  modeline = false,
  undolevels = -1,
}

Panel.default_type = "split"

---@class PanelSplitSpec
---@field type? "split"
---@field position "left"|"top"|"right"|"bottom"
---@field relative? "editor"|"win"
---@field win? integer
---@field width? integer|"auto"
---@field height? integer
---@field win_opts? WindowOptions

---@class PanelSplitSpec.user
---@field type? "split" `"split"` for a panel split.
---@field position? "left"|"top"|"right"|"bottom" Panel position.
---@field relative? "editor"|"win" What `position` is relative to.
---@field win? integer Target window handle (when `relative="win"`). Use `0` for current window.
---@field width? integer|"auto" Width (for `position="left"|"right"`). `"auto"` fits content, capped at `math.floor(vim.o.columns * 0.5)`.
---@field height? integer Height (for `position="top"|"bottom"`).
---@field win_opts? WindowOptions Window-local options to set on the panel window.

---@type PanelSplitSpec
Panel.default_config_split = {
  type = "split",
  position = "left",
  relative = "editor",
  win = 0,
  win_opts = {},
}

---@class PanelFloatSpec
---@field type "float"
---@field relative "editor"|"win"|"cursor"
---@field win? integer
---@field anchor? "NW"|"NE"|"SW"|"SE"
---@field width? integer
---@field height? integer
---@field row number
---@field col number
---@field zindex? integer
---@field style? "minimal"
---@field border? "none"|"single"|"double"|"rounded"|"solid"|"shadow"|string[]
---@field win_opts? WindowOptions

---@class PanelFloatSpec.user
---@field type? "float" `"float"` for a floating window.
---@field relative? "editor"|"win"|"cursor" See `|nvim_open_win()|`.
---@field win? integer Target window handle (when `relative="win"`).
---@field anchor? "NW"|"NE"|"SW"|"SE" Anchor corner.
---@field width? integer Width in character cells.
---@field height? integer Height in character cells.
---@field row? number Row offset.
---@field col? number Column offset.
---@field zindex? integer Stacking order.
---@field style? "minimal" Floating window style.
---@field border? "none"|"single"|"double"|"rounded"|"solid"|"shadow"|string[] Border style.
---@field win_opts? WindowOptions Window-local options to set on the panel window.

---@type PanelFloatSpec
Panel.default_config_float = {
  type = "float",
  relative = "editor",
  row = 0,
  col = 0,
  zindex = 50,
  style = "minimal",
  border = "single",
  win_opts = {},
}

Panel.au = {
  ---@type integer
  group = api.nvim_create_augroup("diffview_panels", {}),
  ---@type EventEmitter
  emitter = EventEmitter(),
  ---@type table<string, integer> Map of autocmd event names to its created autocmd ID.
  events = {},
  ---Delete all autocmds with no subscribed listeners.
  prune = function()
    for event, id in pairs(Panel.au.events) do
      if #(Panel.au.emitter:get(event) or {}) == 0 then
        api.nvim_del_autocmd(id)
        Panel.au.events[event] = nil
      end
    end
  end,
}

---@class PanelSpec
---@field type PanelType
---@field config PanelConfig.user|fun(): PanelConfig.user
---@field bufname string

---@param opt PanelSpec
function Panel:init(opt)
  self.config_producer = opt.config or {}
  self.state = {}
  self.bufname = opt.bufname or "DiffviewPanel"
  self.au_event_map = {}
end

---Produce and validate config.
---@return PanelConfig
function Panel:get_config()
  local config

  if vim.is_callable(self.config_producer) then
    config = self.config_producer()
  elseif type(self.config_producer) == "table" then
    config = utils.tbl_deep_clone(self.config_producer)
  end

  ---@cast config table

  local default_config = self:get_default_config(config.type)
  config = vim.tbl_deep_extend("force", default_config, config or {}) --[[@as table ]]

  local function valid_enum(arg, values, optional)
    return {
      arg,
      function(v)
        return (optional and v == nil) or vim.tbl_contains(values, v)
      end,
      table.concat(
        vim.tbl_map(function(v)
          return ([['%s']]):format(v)
        end, values),
        "|"
      ),
    }
  end

  vim.validate({ type = valid_enum(config.type, { "split", "float" }) })

  if config.type == "split" then
    ---@cast config PanelSplitSpec
    self.state.form = vim.tbl_contains({ "top", "bottom" }, config.position) and "row" or "column"

    vim.validate({
      position = valid_enum(config.position, { "left", "top", "right", "bottom" }),
      relative = valid_enum(config.relative, { "editor", "win" }),
      width = {
        config.width,
        function(v)
          return v == nil or v == "auto" or type(v) == "number"
        end,
        "'auto' or number",
      },
      height = { config.height, "number", true },
      win_opts = { config.win_opts, "table" },
    })
  else
    ---@cast config PanelFloatSpec
    local border = { "none", "single", "double", "rounded", "solid", "shadow" }

    vim.validate({
      relative = valid_enum(config.relative, { "editor", "win", "cursor" }),
      win = { config.win, "number", true },
      anchor = valid_enum(config.anchor, { "NW", "NE", "SW", "SE" }, true),
      width = { config.width, "number", false },
      height = { config.height, "number", false },
      row = { config.row, "number", false },
      col = { config.col, "number", false },
      zindex = { config.zindex, "number", true },
      style = valid_enum(config.style, { "minimal" }, true),
      win_opts = { config.win_opts, "table" },
      border = {
        config.border,
        function(v)
          if v == nil then
            return true
          end

          if type(v) == "table" then
            return #v >= 2
          end

          return vim.tbl_contains(border, v)
        end,
        ("%s or a list of length >=2"):format(table.concat(
          vim.tbl_map(function(v)
            return ([['%s']]):format(v)
          end, border),
          "|"
        )),
      },
    })
  end

  return config
end

---@param tabpage? integer
---@return boolean
function Panel:is_open(tabpage)
  local valid = self.winid and api.nvim_win_is_valid(self.winid)
  if not valid then
    self.winid = nil
  elseif tabpage then
    return vim.tbl_contains(api.nvim_tabpage_list_wins(tabpage), self.winid)
  end
  return valid
end

function Panel:is_focused()
  return self:is_open() and api.nvim_get_current_win() == self.winid
end

---@param no_open? boolean Don't open the panel if it's closed.
function Panel:focus(no_open)
  if self:is_open() then
    api.nvim_set_current_win(self.winid)
  elseif not no_open then
    self:open()
    api.nvim_set_current_win(self.winid)
  end
end

function Panel:resize()
  if not self:is_open(0) then
    return
  end

  self._programmatic_resize = true
  local config = self:get_config()

  if config.type == "split" then
    if self.state.form == "column" then
      local width = config.width
      if width == "auto" then
        local old_width = api.nvim_win_get_width(self.winid)
        width = self:compute_content_width()
        -- Clamp and use pcall: the computed width may exceed available space.
        local max_width = math.floor(vim.o.columns * 0.5)
        width = math.min(width, max_width)
        local ok = pcall(api.nvim_win_set_width, self.winid, width)
        if ok and api.nvim_win_get_width(self.winid) ~= old_width then
          vim.cmd("wincmd =")
          -- Re-render so that header lines (path, revision info, etc.) are
          -- truncated to the actual panel width rather than left at full length.
          self:render()
          renderer.render(self.bufid, self.render_data)
        end
      elseif width then
        api.nvim_win_set_width(self.winid, width --[[@as integer]])
      end
    elseif self.state.form == "row" and config.height then
      api.nvim_win_set_height(self.winid, config.height)
    end
  elseif config.type == "float" then
    api.nvim_win_set_width(self.winid, config.width)
    api.nvim_win_set_height(self.winid, config.height)
  end

  self._programmatic_resize = nil
end

function Panel:open()
  if not self:buf_loaded() then
    self:init_buffer()
  end
  if self:is_open() then
    return
  end

  local config = self:get_config()

  if config.type == "split" then
    local split_dir = vim.tbl_contains({ "top", "left" }, config.position) and "aboveleft"
      or "belowright"
    local split_cmd = self.state.form == "row" and "sp" or "vsp"
    local rel_winid = config.relative == "win"
        and api.nvim_win_is_valid(config.win or -1)
        and config.win
      or 0

    api.nvim_win_call(rel_winid, function()
      vim.cmd(split_dir .. " " .. split_cmd)
      self.winid = api.nvim_get_current_win()
      local ok, err = utils.set_win_buf(self.winid, self.bufid)
      if not ok then
        error(err)
      end

      if config.relative == "editor" then
        local dir = ({ left = "H", bottom = "J", top = "K", right = "L" })[config.position]
        vim.cmd("wincmd " .. dir)
        vim.cmd("wincmd =")
      end
    end)
  elseif config.type == "float" then
    self.winid = vim.api.nvim_open_win(self.bufid, false, utils.sanitize_float_config(config))
    if self.winid == 0 then
      self.winid = nil
      error("[diffview+] Failed to open float panel window!")
    end
  end

  utils.set_local(self.winid, self.class.winopts)
  utils.set_local(self.winid, config.win_opts)
  self:resize()

  -- Re-render on manual window resize so header/footer lines re-truncate
  -- to the new width.
  if not self._win_resized_au then
    self._win_resized_au = api.nvim_create_autocmd("WinResized", {
      group = Panel.au.group,
      callback = function()
        if self._programmatic_resize then
          return
        end
        if not self:is_open() or not self:buf_loaded() then
          return
        end
        for _, w in ipairs(vim.v.event.windows) do
          if w == self.winid then
            self:render()
            self:redraw()
            return
          end
        end
      end,
    })
  end
end

function Panel:close()
  if self._win_resized_au then
    api.nvim_del_autocmd(self._win_resized_au)
    self._win_resized_au = nil
  end

  if self:is_open() then
    -- Count normal windows only, to match `pivot_producer`'s `was_only_win`
    -- check: floats (LSP/completion/treesitter-context) don't anchor a
    -- tabpage. Skip when the panel is itself a float, so closing a float
    -- panel can't spuriously split an unrelated sole editor window.
    local tabpage = api.nvim_win_get_tabpage(self.winid)
    local is_normal_panel = api.nvim_win_get_config(self.winid).relative == ""
    local normal_wins = utils.tabpage_list_normal_wins(tabpage)

    if is_normal_panel and #normal_wins == 1 then
      -- Ensure that the tabpage doesn't close if the panel is the last window.
      api.nvim_win_call(self.winid, function()
        vim.cmd("sp")
        File.load_null_buffer(0)
      end)
    elseif self:is_focused() then
      vim.cmd("wincmd p")
    end

    pcall(api.nvim_win_close, self.winid, true)
  end
end

function Panel:destroy()
  self:close()
  if self:buf_loaded() then
    api.nvim_buf_delete(self.bufid, { force = true })
  end

  -- Disable autocmd listeners
  for _, cbs in pairs(self.au_event_map) do
    for _, cb in ipairs(cbs) do
      Panel.au.emitter:off(cb)
    end
  end
  Panel.au.prune()
end

---@param focus? boolean Focus the panel if it's opened.
function Panel:toggle(focus)
  if self:is_open() then
    self:close()
  elseif focus then
    self:focus()
  else
    self:open()
  end
end

function Panel:buf_loaded()
  return self.bufid and api.nvim_buf_is_loaded(self.bufid)
end

---Stop any tree-sitter parser that external plugins may have attached to
---a panel buffer. Panel content is rendered manually (extmarks from
---`diffview:///panels/...` namespaces) and must not be parsed as code.
---Without this guard, plugins like `render-markdown.nvim` start a
---markdown parser on arbitrary filetypes, producing spurious italic
---spans on `_word_` patterns in file paths and commit subjects.
---@param bufid integer
local function stop_external_treesitter(bufid)
  if not api.nvim_buf_is_valid(bufid) then
    return
  end
  pcall(vim.treesitter.stop, bufid)
end

function Panel:init_buffer()
  local bn = api.nvim_create_buf(false, false)

  for k, v in pairs(self.class.bufopts) do
    vim.bo[bn][k] = v
  end

  local bufname
  if pl:is_abs(self.bufname) or pl:is_uri(self.bufname) then
    bufname = self.bufname
  else
    bufname = string.format("diffview:///panels/%d/%s", Panel.next_uid(), self.bufname)
  end

  local ok = pcall(api.nvim_buf_set_name, bn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    api.nvim_buf_set_name(bn, bufname)
  end

  self.bufid = bn
  self.render_data = renderer.RenderData(bufname)

  api.nvim_buf_call(self.bufid, function()
    vim.api.nvim_exec_autocmds({ "BufNew", "BufFilePre" }, {
      group = Panel.au.group,
      buffer = self.bufid,
      modeline = false,
    })
  end)

  stop_external_treesitter(bn)

  -- Re-stop when a plugin re-attaches as the buffer enters a window.
  -- `vim.schedule` defers to after all other `BufWinEnter` handlers.
  api.nvim_create_autocmd("BufWinEnter", {
    group = Panel.au.group,
    buffer = bn,
    callback = function()
      vim.schedule(function()
        stop_external_treesitter(bn)
      end)
    end,
  })

  self:update_components()
  self:render()
  self:redraw()

  return bn
end

---Apply keymaps from the config for the given keymap section.
---@param keymap_key string Key into config.keymaps (e.g., "file_panel").
---@param extra_defaults table? Additional default keymap options.
---@return table config The full config table for further use.
function Panel:apply_keymaps(keymap_key, extra_defaults)
  local config = require("diffview.config")
  local conf = config.get_config()
  local default_opt =
    vim.tbl_extend("force", { silent = true, buffer = self.bufid }, extra_defaults or {})
  for _, mapping in ipairs(conf.keymaps[keymap_key]) do
    local opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufid })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end
  return conf
end

function Panel:update_components()
  oop.abstract_stub()
end

function Panel:render()
  oop.abstract_stub()
end

function Panel:redraw()
  if not self.render_data then
    return
  end
  perf:reset()
  renderer.render(self.bufid, self.render_data)
  perf:time()
  logger:lvl(10):debug(perf)

  -- Only resize on redraw when auto-fitting; fixed dimensions are applied
  -- once in open() and should not override user-initiated resizing.
  local config = self:get_config()
  if config.type == "split" and config.width == "auto" then
    self:resize()
  end
end

---Get the components whose content drives auto-sizing.
---Override in subclasses to restrict which content affects the computed
---width. When nil is returned, all buffer lines are measured.
---@return RenderComponent[]|nil
function Panel:get_autosize_components()
  return nil
end

---Compute the minimum window width needed to display all buffer content
---without truncation, accounting for sign column and other gutter elements.
---@return integer
function Panel:compute_content_width()
  if not self:buf_loaded() then
    -- Fall back to configured width if numeric, otherwise a sensible default.
    local config = self:get_config()
    local default = self.class.default_config_split and self.class.default_config_split.width
    if type(default) == "number" then
      return default
    elseif type(config.width) == "number" then
      return config.width --[[@as integer]]
    end
    return 35
  end

  local lines = api.nvim_buf_get_lines(self.bufid, 0, -1, false)
  local max_width = 0

  -- When the subclass specifies autosize components, only measure lines
  -- that fall within those components (e.g. file entries, not headers).
  -- Fall back to all lines when no valid lines are marked (e.g. during
  -- initial loading when components have zero height).
  local autosize_comps = self:get_autosize_components()
  local valid_lines
  if autosize_comps then
    valid_lines = {}
    for _, comp in ipairs(autosize_comps) do
      for j = comp.lstart, comp.lend - 1 do
        valid_lines[j] = true
      end
    end
    if not next(valid_lines) then
      valid_lines = nil
    end
  end

  for i, line in ipairs(lines) do
    if not valid_lines or valid_lines[i - 1] then
      local w = api.nvim_strwidth(line)
      if w > max_width then
        max_width = w
      end
    end
  end

  -- Account for gutter columns (sign column, etc.).
  local textoff = 0
  if self:is_open() then
    local info = vim.fn.getwininfo(self.winid)
    if info and info[1] then
      textoff = info[1].textoff
    end
  else
    -- Default: signcolumn = "yes" adds 2 columns.
    textoff = 2
  end

  -- +1 for a bit of right-side breathing room.
  return max_width + textoff + 1
end

---Update components, render and redraw.
function Panel:sync()
  if self:buf_loaded() then
    self:update_components()
    self:render()
    self:redraw()
  end
end

---@class PanelAutocmdSpec
---@field callback function
---@field once? boolean

---@param event string|string[]
---@param opts PanelAutocmdSpec
function Panel:on_autocmd(event, opts)
  if type(event) ~= "table" then
    event = { event }
  end

  local callback = function(_, state)
    local win_match, buf_match
    if state.event:match("^Win") then
      if
        vim.tbl_contains({ "WinLeave", "WinEnter" }, state.event)
        and api.nvim_get_current_win() == self.winid
      then
        buf_match = state.buf
      else
        win_match = tonumber(state.match)
      end
    elseif state.event:match("^Buf") then
      buf_match = state.buf
    else
      -- Cursor/text/insert/etc. events carry the active buffer in `state.buf`;
      -- match by buffer so subscribers can target panel-buffer-local events
      -- (e.g. `CursorMoved`) without bypassing this dispatcher.
      buf_match = state.buf
    end

    if (win_match and win_match == self.winid) or (buf_match and buf_match == self.bufid) then
      opts.callback(state)
    end
  end

  for _, e in ipairs(event) do
    if not self.au_event_map[e] then
      self.au_event_map[e] = {}
    end
    table.insert(self.au_event_map[e], callback)

    if not Panel.au.events[e] then
      Panel.au.events[e] = api.nvim_create_autocmd(e, {
        group = Panel.au.group,
        callback = function(state)
          Panel.au.emitter:emit(e, state)
        end,
      })
    end

    if opts.once then
      Panel.au.emitter:once(e, callback)
    else
      Panel.au.emitter:on(e, callback)
    end
  end
end

---Unsubscribe an autocmd listener. If no event is given, the callback is
---disabled for all events.
---@param callback function
---@param event? string
function Panel:off_autocmd(callback, event)
  for e, cbs in pairs(self.au_event_map) do
    if (event == nil or event == e) and utils.vec_indexof(cbs, callback) ~= -1 then
      Panel.au.emitter:off(callback, event)
    end
    Panel.au.prune()
  end
end

function Panel:get_default_config(panel_type)
  local producer = self.class["default_config_" .. (panel_type or self.class.default_type)]

  local config
  if vim.is_callable(producer) then
    config = producer()
  elseif type(producer) == "table" then
    config = producer
  end

  return config
end

---@return integer?
function Panel:get_width()
  if self:is_open() then
    return api.nvim_win_get_width(self.winid)
  end
end

---@return integer?
function Panel:get_height()
  if self:is_open() then
    return api.nvim_win_get_height(self.winid)
  end
end

function Panel:infer_width()
  local config = self:get_config()

  -- When auto-fitting and the panel is already open, use the current window
  -- width so that header lines are truncated to fit. Before the panel opens
  -- we fall through to vim.o.columns so that content renders at full width
  -- for the initial measurement pass.
  if config.width == "auto" then
    local cur_width = self:get_width()
    if cur_width then
      return cur_width
    end
    return vim.o.columns
  end

  local cur_width = self:get_width()
  if cur_width then
    return cur_width
  end

  if config.width then
    return config.width
  end

  -- PanelFloatSpec requires both width and height to be defined. If we get
  -- here then the panel is a split.
  ---@cast config PanelSplitSpec

  if config.win and api.nvim_win_is_valid(config.win) then
    if self.state.form == "row" then
      return api.nvim_win_get_width(config.win)
    elseif self.state.form == "column" then
      return math.floor(api.nvim_win_get_width(config.win) / 2)
    end
  end

  if self.state.form == "row" then
    return vim.o.columns
  end

  return math.floor(vim.o.columns / 2)
end

function Panel:infer_height()
  local cur_height = self:get_height()
  if cur_height then
    return cur_height
  end

  local config = self:get_config()
  if config.height then
    return config.height
  end

  -- PanelFloatSpec requires both width and height to be defined. If we get
  -- here then the panel is a split.
  ---@cast config PanelSplitSpec

  if config.win and api.nvim_win_is_valid(config.win) then
    if self.state.form == "row" then
      return math.floor(api.nvim_win_get_height(config.win) / 2)
    elseif self.state.form == "column" then
      return api.nvim_win_get_height(config.win)
    end
  end

  if self.state.form == "row" then
    return math.floor(vim.o.lines / 2)
  end

  return vim.o.lines
end

function Panel.next_uid()
  local uid = uid_counter
  uid_counter = uid_counter + 1
  return uid
end

M.Panel = Panel
return M
