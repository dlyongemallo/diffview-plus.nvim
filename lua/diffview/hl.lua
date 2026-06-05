local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local web_devicons, mini_icons
local provider_resolved = false
local icon_cache = {}

local M = {}

---@alias hl.HiValue<T> T|"NONE"

---@class hl.HiSpec
---@field fg?        hl.HiValue<string>
---@field bg?        hl.HiValue<string>
---@field sp?        hl.HiValue<string>
---@field style?     hl.HiValue<string>
---@field ctermfg?   hl.HiValue<integer>
---@field ctermbg?   hl.HiValue<integer>
---@field cterm?     hl.HiValue<string>
---@field blend?     hl.HiValue<integer>
---@field default?   hl.HiValue<boolean> Only set values if the hl group is cleared.
---@field link?      string|-1
---@field explicit?  boolean All undefined fields will be cleared from the hl group.

---@class hl.HiLinkSpec
---@field default? boolean

---@class hl.HlData
---@field link? string|integer
---@field fg? integer Foreground color integer
---@field bg? integer Background color integer
---@field sp? integer Special color integer
---@field x_fg? string Foreground color hex string
---@field x_bg? string Background color hex string
---@field x_sp? string Special color hex string
---@field bold? boolean
---@field italic? boolean
---@field underline? boolean
---@field underdouble? boolean
---@field undercurl? boolean
---@field underdashed? boolean
---@field underdotted? boolean
---@field strikethrough? boolean
---@field standout? boolean
---@field reverse? boolean
---@field blend? integer
---@field default? boolean

---@alias hl.HlAttrValue integer|boolean

---@enum HlAttribute
M.HlAttribute = {
  fg = 1,
  bg = 2,
  sp = 3,
  x_fg = 4,
  x_bg = 5,
  x_sp = 6,
  bold = 7,
  italic = 8,
  underline = 9,
  underdouble = 10,
  undercurl = 11,
  underdashed = 12,
  underdotted = 13,
  strikethrough = 14,
  standout = 15,
  reverse = 16,
  blend = 17,
}

local style_attrs = {
  "bold",
  "italic",
  "underline",
  "underdouble",
  "undercurl",
  "underdashed",
  "underdotted",
  "strikethrough",
  "standout",
  "reverse",
}

utils.add_reverse_lookup(M.HlAttribute)
utils.add_reverse_lookup(style_attrs)
local hlattr = M.HlAttribute

---@param name string Syntax group name.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return hl.HlData?
function M.get_hl(name, no_trans)
  local hl

  if no_trans then
    hl = api.nvim_get_hl(0, { name = name, link = true })
  else
    local id = api.nvim_get_hl_id_by_name(name)

    if id then
      hl = api.nvim_get_hl(0, { id = id, link = false })
    end
  end

  if hl then
    ---@cast hl hl.HlData
    if hl.fg then
      hl.x_fg = string.format("#%06x", hl.fg)
    end
    if hl.bg then
      hl.x_bg = string.format("#%06x", hl.bg)
    end
    if hl.sp then
      hl.x_sp = string.format("#%06x", hl.sp)
    end

    return hl
  end
end

---@param name string Syntax group name.
---@param attr HlAttribute|string Attribute kind.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return hl.HlAttrValue?
function M.get_hl_attr(name, attr, no_trans)
  local hl = M.get_hl(name, no_trans)

  if type(attr) == "string" then
    attr = hlattr[attr]
  end

  if not (hl and attr) then
    return
  end

  return hl[hlattr[attr]]
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_fg(groups, no_trans)
  no_trans = not not no_trans

  if type(groups) ~= "table" then
    groups = { groups }
  end

  for _, group in ipairs(groups) do
    local v = M.get_hl_attr(group, hlattr.x_fg, no_trans) --[[@as string? ]]

    if v then
      return v
    end
  end
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_bg(groups, no_trans)
  no_trans = not not no_trans

  if type(groups) ~= "table" then
    groups = { groups }
  end

  for _, group in ipairs(groups) do
    local v = M.get_hl_attr(group, hlattr.x_bg, no_trans) --[[@as string? ]]

    if v then
      return v
    end
  end
end

---@param groups string|string[] Syntax group name, or an ordered list of
---groups where the first found value will be returned.
---@param no_trans? boolean Don't translate the syntax group (follow links).
---@return string?
function M.get_style(groups, no_trans)
  no_trans = not not no_trans
  if type(groups) ~= "table" then
    groups = { groups }
  end

  for _, group in ipairs(groups) do
    local hl = M.get_hl(group, no_trans)

    if hl then
      local res = {}

      for _, attr in ipairs(style_attrs) do
        if hl[attr] then
          table.insert(res, attr)
        end
      end

      if #res > 0 then
        return table.concat(res, ",")
      end
    end
  end
end

---@param spec hl.HiSpec
---@return hl.HlData
function M.hi_spec_to_def_map(spec)
  ---@type hl.HlData
  local res = {}
  local fields = { "fg", "bg", "sp", "ctermfg", "ctermbg", "default", "link" }

  for _, field in ipairs(fields) do
    res[field] = spec[field]
  end

  if spec.style then
    local spec_attrs = utils.add_reverse_lookup(vim.split(spec.style, ","))

    for _, attr in ipairs(style_attrs) do
      res[attr] = spec_attrs[attr] ~= nil
    end
  end

  return res
end

---@param groups string|string[] Syntax group name or a list of group names.
---@param opt hl.HiSpec
function M.hi(groups, opt)
  if type(groups) ~= "table" then
    groups = { groups }
  end

  for _, group in ipairs(groups) do
    local def_spec

    if opt.explicit then
      def_spec = M.hi_spec_to_def_map(opt)
    else
      def_spec = M.hi_spec_to_def_map(vim.tbl_extend("force", M.get_hl(group, true) or {}, opt))
    end

    for k, v in pairs(def_spec) do
      if v == "NONE" then
        def_spec[k] = nil
      end
    end

    api.nvim_set_hl(0, group, def_spec --[[@as vim.api.keyset.highlight]])
  end
end

---@param from string|string[] Syntax group name or a list of group names.
---@param to? string Syntax group name. (default: `"NONE"`)
---@param opt? hl.HiLinkSpec
function M.hi_link(from, to, opt)
  if to and tostring(to):upper() == "NONE" then
    ---@diagnostic disable-next-line: cast-local-type
    to = -1
  end

  opt = opt or {}

  if type(from) ~= "table" then
    from = { from }
  end

  -- Bypass `M.hi`: its merge-with-existing path inherits `default = true`
  -- from a prior default link, silently no-op'ing force-relinks like
  -- `enhanced_diff_hl`'s `DiffviewDiffDelete` to `DiffviewDiffDeleteDim`.
  for _, f in ipairs(from) do
    api.nvim_set_hl(0, f, { default = opt.default, link = to })
  end
end

---Clear highlighting for a given syntax group, or all groups if no group is
---given.
---@param groups? string|string[]
function M.hi_clear(groups)
  if not groups then
    vim.cmd("hi clear")
    return
  end

  if type(groups) ~= "table" then
    groups = { groups }
  end

  for _, g in ipairs(groups) do
    api.nvim_set_hl(0, g, {})
  end
end

function M.get_file_icon(name, ext, render_data, line_idx, offset)
  if not config.get_config().use_icons then
    return ""
  end

  if not (web_devicons or mini_icons) then
    if provider_resolved then
      return ""
    end

    local ok, mod = pcall(require, "nvim-web-devicons")
    if ok then
      web_devicons = mod
    else
      ok, mod = pcall(require, "mini.icons")
      if ok then
        mini_icons = mod
      end
    end

    provider_resolved = true

    if not ok then
      return ""
    end
  end

  local icon, hl
  local icon_key = (name or "") .. "|&|" .. (ext or "")

  if icon_cache[icon_key] then
    icon, hl = unpack(icon_cache[icon_key])
  elseif web_devicons then
    icon, hl = web_devicons.get_icon(name, ext, { default = true })
    icon_cache[icon_key] = { icon, hl }
  else
    icon, hl = mini_icons.get("file", name)
    icon_cache[icon_key] = { icon, hl }
  end

  if icon then
    if hl and render_data then
      render_data:add_hl(hl, line_idx, offset, offset + string.len(icon) + 1)
    end

    return icon .. " ", hl
  end

  return ""
end

local git_status_hl_map = {
  ["A"] = "DiffviewStatusAdded",
  ["?"] = "DiffviewStatusUntracked",
  ["M"] = "DiffviewStatusModified",
  ["R"] = "DiffviewStatusRenamed",
  ["C"] = "DiffviewStatusCopied",
  ["T"] = "DiffviewStatusTypeChanged",
  ["U"] = "DiffviewStatusUnmerged",
  ["X"] = "DiffviewStatusUnknown",
  ["D"] = "DiffviewStatusDeleted",
  ["B"] = "DiffviewStatusBroken",
  ["!"] = "DiffviewStatusIgnored",
}

function M.get_git_hl(status)
  return git_status_hl_map[status]
end

---Get the configured status icon for a git status letter.
---@param status string Git status letter (e.g., "M", "A", "D").
---@return string
function M.get_status_icon(status)
  return config.get_config().status_icons[status] or status
end

function M.get_colors()
  return {
    white = M.get_fg("Normal") or "White",
    red = M.get_fg("Keyword") or "Red",
    green = M.get_fg("Character") or "Green",
    yellow = M.get_fg("PreProc") or "Yellow",
    blue = M.get_fg("Include") or "Blue",
    purple = M.get_fg("Define") or "Purple",
    cyan = M.get_fg("Conditional") or "Cyan",
    dark_red = M.get_fg("Keyword") or "DarkRed",
    orange = M.get_fg("Number") or "Orange",
  }
end

function M.get_hl_groups()
  local colors = M.get_colors()

  return {
    FilePanelTitle = { fg = M.get_fg("Label") or colors.blue, style = "bold" },
    FilePanelCounter = { fg = M.get_fg("Identifier") or colors.purple, style = "bold" },
    -- FilePanelFileName is linked to Normal in hl_links.
    -- FilePanelSelected (active filename) is linked to `Type` in hl_links.
    CommitSelected = { style = "bold" },
    Dim1 = { fg = M.get_fg("Comment") or colors.white },
    Primary = { fg = M.get_fg("Function") or "Purple" },
    Secondary = { fg = M.get_fg("String") or "Orange" },
  }
end

M.hl_links = {
  Normal = "Normal",
  NonText = "NonText",
  CursorLine = "CursorLine",
  WinSeparator = "WinSeparator",
  SignColumn = "Normal",
  StatusLine = "StatusLine",
  StatusLineNC = "StatusLineNC",
  EndOfBuffer = "EndOfBuffer",
  FilePanelRootPath = "DiffviewFilePanelTitle",
  FilePanelFileName = "Normal",
  FilePanelSelected = "Type",
  FilePanelPath = "Comment",
  FilePanelInsertions = "diffAdded",
  FilePanelDeletions = "diffRemoved",
  FilePanelConflicts = "DiagnosticSignWarn",
  FilePanelMarked = "DiagnosticSignInfo",
  FolderName = "Directory",
  FolderSign = "PreProc",
  Hash = "Identifier",
  Reference = "Function",
  ReflogSelector = "Special",
  StatusAdded = "diffAdded",
  StatusUntracked = "diffAdded",
  StatusModified = "diffChanged",
  StatusRenamed = "diffChanged",
  StatusCopied = "diffChanged",
  StatusTypeChange = "diffChanged",
  StatusUnmerged = "diffChanged",
  StatusUnknown = "diffRemoved",
  StatusDeleted = "diffRemoved",
  StatusBroken = "diffRemoved",
  StatusIgnored = "Comment",
  CommitRemoteRef = "Function",
  CommitLocalOnly = "WarningMsg",
  CommitMerged = "String",
  DiffAdd = "DiffAdd",
  DiffDelete = "DiffDelete",
  DiffChange = "DiffChange",
  DiffText = "DiffText",
}

-- Compute the inline-overlay `bg` and kept style attrs from `group`'s
-- colours. `bg` comes from `group`; when the group uses `reverse`/`standout`
-- the visible bg is actually its `fg` (the swap moves it there), so read that
-- instead -- otherwise reverse-only colourschemes lose the bg entirely once
-- we strip `reverse`. Returns `bg` ("NONE" when the group has no usable
-- background) and the comma-joined style string ("NONE" when empty), with
-- `reverse`/`standout` dropped (see `derive_inline_hl` for why).
---@param group string
---@return string bg
---@return string style
local function inline_bg_and_style(group)
  local kept_attrs = {}
  local is_reversed = false

  for _, attr in ipairs(vim.split(M.get_style(group) or "", ",")) do
    if attr == "reverse" or attr == "standout" then
      is_reversed = true
    elseif attr ~= "" then
      kept_attrs[#kept_attrs + 1] = attr
    end
  end

  local bg
  if is_reversed then
    bg = M.get_fg(group) or M.get_bg(group) or "NONE"
  else
    bg = M.get_bg(group) or "NONE"
  end

  return bg, #kept_attrs > 0 and table.concat(kept_attrs, ",") or "NONE"
end

-- Derive an inline char-range highlight `target` from `source`'s colours,
-- used by the `diff1_inline` layout to paint changed/added characters on top
-- of a paired row (priority-200 extmark). `fg` is dropped so tree-sitter
-- foreground composes through the extmark instead of being stomped; `reverse`
-- and `standout` are stripped for the same reason (they swap fg/bg at render
-- time, which would let the `source` bg paint over the syntax `fg`).
--
-- When `source` yields no usable background (e.g. a colourscheme that defines
-- `DiffAdd`/`DiffChange` but leaves `DiffText` unset), derive from `fallback`
-- instead so the overlay never regresses to invisible.
--
-- Set with `explicit` rather than `default`: a `default` highlight is a no-op
-- once the group exists, which would pin whatever value was derived at the
-- first `setup()` (e.g. from a built-in `DiffAdd` active before the user's
-- colourscheme loaded) and never refresh it on later `ColorScheme` events.
-- `explicit` rebuilds the group from scratch each call so it always tracks
-- the active colourscheme.
---@param source string Source highlight group to derive from.
---@param target string Target highlight group to (re)define.
---@param fallback? string Source used when `source` has no usable background.
local function derive_inline_hl(source, target, fallback)
  local bg, style = inline_bg_and_style(source)
  if bg == "NONE" and fallback then
    bg, style = inline_bg_and_style(fallback)
  end

  M.hi(target, {
    bg = bg,
    style = style,
    explicit = true,
  })
end

function M.update_diff_hl()
  local fg = M.get_fg("DiffDelete", true) or "NONE"
  local bg = M.get_bg("DiffDelete", true) or "NONE"
  local style = M.get_style("DiffDelete", true) or "NONE"

  M.hi("DiffviewDiffAddAsDelete", { fg = fg, bg = bg, style = style })
  M.hi_link("DiffviewDiffDeleteDim", "Comment", { default = true })

  if config.get_config().enhanced_diff_hl then
    M.hi_link("DiffviewDiffDelete", "DiffviewDiffDeleteDim")
  end

  -- Used by the `diff1_inline` layout in "overleaf" style to render deletions
  -- as strikethrough virtual text. Inherits fg/bg from `DiffviewDiffDelete`
  -- (resolving through its link chain) so that users who customize diffview's
  -- deletion colours pick up the change here too, and so `enhanced_diff_hl`
  -- mode — which relinks `DiffviewDiffDelete` to `DiffviewDiffDeleteDim` —
  -- is honoured. Runs AFTER the relink above so the final state is read.
  local del_fg = M.get_fg("DiffviewDiffDelete") or "NONE"
  local del_bg = M.get_bg("DiffviewDiffDelete") or "NONE"
  -- `explicit` (not `default`) so the group is rebuilt on every `ColorScheme`
  -- rather than pinned to the value derived at the first `setup()`; see
  -- `derive_inline_hl` for the full rationale.
  M.hi("DiffviewDiffDeleteInline", {
    fg = del_fg,
    bg = del_bg,
    style = "strikethrough",
    explicit = true,
  })

  -- `diff1_inline` overlays for changed/added char ranges (priority 200,
  -- layered on the paired row). The two inline styles need different
  -- backdrops, so each derives from a different source group:
  --   * "unified" paints the paired row with `DiffviewDiffChange` and
  --     overlays `DiffviewDiffTextInline`, derived from `DiffText` -- the
  --     same group the built-in side-by-side diff uses for intra-line
  --     changes. Deriving from `DiffText` (not `DiffAdd`) keeps the overlay
  --     visible against the `DiffChange` backdrop even when a colourscheme
  --     gives `DiffAdd` and `DiffChange` near-identical backgrounds (e.g.
  --     tokyonight), which would otherwise hide the change. Falls back to
  --     `DiffAdd` for the rare colourscheme that leaves `DiffText` unset.
  --   * "overleaf" leaves the row unpainted and overlays
  --     `DiffviewDiffAddInline`, derived from `DiffAdd` -- the natural
  --     "added" colour read against the normal background.
  derive_inline_hl("DiffviewDiffText", "DiffviewDiffTextInline", "DiffviewDiffAdd")
  derive_inline_hl("DiffviewDiffAdd", "DiffviewDiffAddInline")
end

function M.setup()
  -- Ensure diff highlights are defined by loading the diff syntax if needed.
  -- Some colorschemes don't set diffAdded/diffRemoved/diffChanged until the
  -- diff filetype is encountered.
  if vim.fn.hlexists("diffAdded") == 0 then
    vim.cmd("runtime! syntax/diff.vim")
  end

  for name, v in pairs(M.get_hl_groups()) do
    v = vim.tbl_extend("force", v, { default = true })
    M.hi("Diffview" .. name, v)
  end

  for from, to in pairs(M.hl_links) do
    M.hi_link("Diffview" .. from, to, { default = true })
  end

  M.update_diff_hl()
end

return M
