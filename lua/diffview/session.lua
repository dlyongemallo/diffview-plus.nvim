-- Session restoration cleanup.
--
-- A Vim session file (`:mksession`) saves buffer names but not their
-- contents. When sourced, any `diffview://...` buffer comes back empty and
-- has no backing view, so the `:Diffview*` commands cannot interact with
-- it. This module wipes those stale buffers (and any tabpage that held
-- nothing else) after the session loads.

local api = vim.api

local M = {}

---Returns `true` if `bufnr` belongs to this plugin's UI.
---@param bufnr integer
---@return boolean
local function is_diffview_buf(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if api.nvim_buf_get_name(bufnr):match("^diffview://") then
    return true
  end
  local ft = vim.bo[bufnr].filetype
  return ft == "DiffviewFiles" or ft == "DiffviewFileHistory"
end

---Returns `true` if `bufnr` is the internal `diffview://null` singleton
---owned by `vcs/file.lua`.
---@param bufnr integer
---@return boolean
local function is_null_buf(bufnr)
  return api.nvim_buf_is_valid(bufnr) and api.nvim_buf_get_name(bufnr) == "diffview://null"
end

---Returns the set of tabpages hosting a live Diffview view, marked
---`t:diffview_view_initialized` by `StandardView`/`NullDiffView`.
---@return table<integer, true>
local function live_tab_set()
  local set = {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if vim.t[tab].diffview_view_initialized then
      set[tab] = true
    end
  end
  return set
end

---Returns `true` if `bufnr` is a stale, session-restored diffview buffer
---safe to wipe. A live view sets `b:diffview_loaded` on file buffers
---(see `vcs/file.lua`), but panel/commit-log buffers don't carry that
---flag, so we also exclude any buffer displayed in a live-view tab. This
---preserves a Diffview opened during `SessionLoadPost` (e.g. from a user
---autocmd) along with its panel buffers. The `diffview://null` singleton
---owned by `vcs/file.lua` is also excluded: wiping it dangles the cached
---`File.NULL_FILE.bufnr` handle until the next `_get_null_buffer` call.
---@param bufnr integer
---@param live_tabs table<integer, true>
---@return boolean
local function is_stale_diffview_buf(bufnr, live_tabs)
  if not is_diffview_buf(bufnr) or vim.b[bufnr].diffview_loaded then
    return false
  end
  if is_null_buf(bufnr) then
    return false
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if live_tabs[api.nvim_win_get_tabpage(win)] then
      return false
    end
  end
  return true
end

---Wipe leftover diffview buffers and close any tabpage that held only
---diffview windows. Safe to call when no such buffers exist.
local function cleanup()
  -- Tabs hosting a live Diffview view are excluded entirely: their
  -- buffers are filtered out by `is_stale_diffview_buf`, and the tabs
  -- themselves never enter `tab_has_other`.
  local live_tabs = live_tab_set()

  -- For each tabpage that displays a stale diffview buffer, track whether
  -- it also contains unrelated windows. Tabs that hosted *only* stale
  -- diffview content can be closed after wipeout; tabs with other windows
  -- must be left alone so the user's layout survives.
  local tab_has_other = {}
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if is_stale_diffview_buf(bufnr, live_tabs) then
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        local tab = api.nvim_win_get_tabpage(win)
        if tab_has_other[tab] == nil then
          tab_has_other[tab] = false
        end
      end
    end
  end
  for tab in pairs(tab_has_other) do
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      local b = api.nvim_win_get_buf(win)
      -- The `diffview://null` singleton is diffview UI too, even though it
      -- isn't stale; treating it as "other" would leave behind orphan tabs
      -- whose only remaining content is a null-buffer split.
      if not is_stale_diffview_buf(b, live_tabs) and not is_null_buf(b) then
        tab_has_other[tab] = true
        break
      end
    end
  end

  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if is_stale_diffview_buf(bufnr, live_tabs) then
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  -- Never close the last tabpage: Neovim would exit.
  for tab, has_other in pairs(tab_has_other) do
    if not has_other and api.nvim_tabpage_is_valid(tab) and #api.nvim_list_tabpages() > 1 then
      local pagenr = api.nvim_tabpage_get_number(tab)
      local ok, err = pcall(api.nvim_command, "tabclose " .. pagenr)
      if not ok and type(err) == "string" and err:match("E445") then
        vim.cmd("tabclose! " .. pagenr)
      end
    end
  end
end

M.cleanup = cleanup

---Register the `SessionLoadPost` autocmd. Called from `plugin/diffview.lua`
---so the hook is in place before any session is sourced.
function M.setup()
  api.nvim_create_autocmd("SessionLoadPost", {
    group = api.nvim_create_augroup("diffview_session", { clear = true }),
    -- Defer past the autocmd context: if the restored layout left the
    -- cursor on a stale diffview buffer with no real-buffer fallback,
    -- deleting it inside the autocmd hits `E814` because doing so would
    -- leave only the autocmd window. Running on the next tick lets
    -- Neovim drop into a `[No Name]` buffer instead.
    callback = function()
      vim.schedule(cleanup)
    end,
  })
end

return M
