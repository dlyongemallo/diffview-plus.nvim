require("diffview.bootstrap")

local async = require("diffview.async")
local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local FileHistoryView =
  lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local HelpPanel = lazy.access("diffview.ui.panels.help_panel", "HelpPanel") ---@type HelpPanel|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff1Inline = lazy.access("diffview.scene.layouts.diff_1_inline", "Diff1Inline") ---@type Diff1Inline|LazyModule
local Diff2Hor = lazy.access("diffview.scene.layouts.diff_2_hor", "Diff2Hor") ---@type Diff2Hor|LazyModule
local Diff2Ver = lazy.access("diffview.scene.layouts.diff_2_ver", "Diff2Ver") ---@type Diff2Ver|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3") ---@type Diff3|LazyModule
local Diff3Hor = lazy.access("diffview.scene.layouts.diff_3_hor", "Diff3Hor") ---@type Diff3Hor|LazyModule
local Diff3Ver = lazy.access("diffview.scene.layouts.diff_3_ver", "Diff3Ver") ---@type Diff3Ver|LazyModule
local Diff3Mixed = lazy.access("diffview.scene.layouts.diff_3_mixed", "Diff3Mixed") ---@type Diff3Mixed|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4") ---@type Diff4|LazyModule
local Diff4Mixed = lazy.access("diffview.scene.layouts.diff_4_mixed", "Diff4Mixed") ---@type Diff4Mixed|LazyModule

local api = vim.api
local await = async.await
local pl = lazy.access(utils, "path") --[[@as PathLib ]]

---@class DiffviewActionsCompat
---@field fold_cmds? DiffviewKeymapEntry[]

---Covers both the emit-stub actions registered dynamically by the
---`action_names` loop at the bottom of this file (which LuaLS can't infer from
---the `M[name] = ...` assignment) and the directly-defined actions below
---(listed here so the `@as DiffviewActions` cast on `M` doesn't exclude them).
---@class DiffviewActions
---@field compat DiffviewActionsCompat Internal.
---@field close fun()
---@field close_all_folds fun()
---@field close_fold fun()
---@field copy_hash fun()
---@field diff_against_head fun()
---@field focus_entry fun()
---@field focus_files fun()
---@field listing_style fun()
---@field next_entry fun()
---@field next_entry_in_commit fun()
---@field open_all_folds fun()
---@field open_commit_in_browser fun()
---@field open_commit_log fun()
---@field open_fold fun()
---@field open_in_diffview fun()
---@field options fun()
---@field prev_entry fun()
---@field prev_entry_in_commit fun()
---@field restore_entry fun()
---@field select_entry fun()
---@field select_next_entry fun()
---@field select_prev_entry fun()
---@field select_first_entry fun()
---@field select_last_entry fun()
---@field select_next_commit fun()
---@field select_prev_commit fun()
---@field stage_all fun()
---@field toggle_files fun()
---@field toggle_flatten_dirs fun()
---@field toggle_fold fun()
---@field toggle_select_entry fun()
---@field clear_select_entries fun()
---@field toggle_stage_entry fun()
---@field toggle_untracked fun()
---@field unstage_all fun()
---@field conflict_choose fun(target: DiffviewConflictTarget): fun()
---@field conflict_choose_all fun(target: DiffviewConflictTarget): AsyncFunc
---@field conflict_choose_side fun(target: DiffviewConflictSideTarget): AsyncFunc
---@field cycle_layout fun()
---@field diff_against_default_branch fun()
---@field diffget fun(target: DiffviewDiffgetTarget): fun()
---@field diffget_inline fun()
---@field diffput fun(target: DiffviewDiffgetTarget): fun()
---@field goto_file fun()
---@field goto_file_edit fun()
---@field goto_file_edit_close fun()
---@field goto_file_split fun()
---@field goto_file_tab fun()
---@field help fun(keymap_groups: string|string[]): fun()
---@field jump_to_first_change fun(view: StandardView)
---@field jumpto_conflict fun(num: integer, use_delta?: boolean): diffview.ConflictCount?
---@field next_conflict fun(): diffview.ConflictCount?
---@field next_inline_hunk fun()
---@field open_file_external fun()
---@field open_in_new_tab fun()
---@field prev_conflict fun(): diffview.ConflictCount?
---@field prev_inline_hunk fun()
---@field refresh_files fun(opts?: DiffviewRefreshFilesOpts)
---@field scroll_view fun(distance: number): fun()
---@field set_layout fun(layout_name: LayoutName): fun()
---@field view_windo fun(cmd: string|fun(layout_name: string, symbol: string)): fun()
local M = setmetatable({}, {
  __index = function(_, k)
    utils.err(
      (
        "The action '%s' does not exist! "
        .. "See ':h diffview-available-actions' for an overview of available actions."
      ):format(k)
    )
  end,
}) --[[@as DiffviewActions ]]

M.compat = {}

---Applicability metadata attached to actions whose effect depends on the
---current view. The help panel consults this (via `M._is_applicable`) to
---suppress entries that would be no-ops in the current view. Weak keys let
---closures returned by action factories be collected once no keymap references
---them anymore.
---@alias diffview.ActionTag "merge_only" | "working_tree_only"
---@type table<function, diffview.ActionTag>
local action_meta = setmetatable({}, { __mode = "k" })

---Attach an applicability tag to `fn`. Returns `fn` so the call can be used
---inline at the point an action factory returns its closure:
---   return tag(function() ... end, "merge_only")
---@generic F : function
---@param fn F
---@param tag_name diffview.ActionTag
---@return F
local function tag(fn, tag_name)
  action_meta[fn] = tag_name
  return fn
end

---Whether `fn` is applicable in `view`'s current state. Untagged functions
---are considered always-applicable (default: shown). Used by the help panel
---to filter context-only mappings.
---@param fn unknown # Typically the `rhs` of a keymap entry.
---@param view StandardView?
---@return boolean
function M._is_applicable(fn, view)
  if type(fn) ~= "function" then
    return true
  end
  local t = action_meta[fn]
  if t == nil then
    return true
  end
  if t == "merge_only" then
    -- `merge_ctx` is a `DiffView` field; on other views the access is nil-safe.
    return view ~= nil and (view --[[@as DiffView]]).merge_ctx ~= nil
  end
  if t == "working_tree_only" then
    -- Index-vs-worktree actions (staging, etc.) are only meaningful when the
    -- diff compares STAGE against LOCAL. `left`/`right` exist on `DiffView`
    -- and `FileHistoryView`; in the latter, `left.type` is `COMMIT`, so the
    -- predicate correctly evaluates to false there.
    if view == nil then
      return false
    end
    local v = view --[[@as DiffView]]
    return v.left ~= nil
      and v.right ~= nil
      and v.left.type == RevType.STAGE
      and v.right.type == RevType.LOCAL
  end
  return true
end

---Return the view's main window and its file's bufnr if both are valid,
---otherwise nil. Use this at the top of any action that reads or modifies the
---currently-displayed file buffer.
---@param view StandardView?
---@return Window? main
---@return integer? bufnr # Only valid when `main` is non-nil.
local function get_valid_main(view)
  local main = view and view.cur_layout and view.cur_layout:get_main_win()
  if not (main and main:is_valid() and main.file and main.file:is_valid()) then
    return nil, nil
  end
  return main, main.file.bufnr
end

---@return FileEntry?
---@return integer[]? cursor
local function prepare_goto_file()
  local view = lib.get_current_view()

  if
    view and not (view:instanceof(DiffView.__get()) or view:instanceof(FileHistoryView.__get()))
  then
    return
  end

  ---@cast view DiffView|FileHistoryView

  local file = view:infer_cur_file()
  if file then
    ---@cast file FileEntry
    -- Ensure file exists
    if not pl:readable(file.absolute_path) then
      utils.err(
        string.format("File does not exist on disk: '%s'", pl:relative(file.absolute_path, "."))
      )
      return
    end

    local cursor
    local cur_file = view.cur_entry
    if file == cur_file then
      local win = view.cur_layout:get_main_win()
      cursor = api.nvim_win_get_cursor(win.id)
    end

    return file, cursor
  end
end

---@param opts { cmd: string, target_tab?: boolean, target_tab_cmd?: string }
---@return boolean ok
local function open_goto_file(opts)
  local file, cursor = prepare_goto_file()
  if not file then
    return false
  end

  local fpath = vim.fn.fnameescape(file.absolute_path)

  if opts.target_tab then
    local target_tab = lib.get_prev_non_view_tabpage()
    if target_tab then
      api.nvim_set_current_tabpage(target_tab)
      file.layout:restore_winopts()
      vim.cmd(opts.target_tab_cmd .. " " .. fpath)
      if cursor then
        utils.set_cursor(0, unpack(cursor))
      end
      return true
    end
  end

  vim.cmd(opts.cmd)
  local temp_bufnr = api.nvim_get_current_buf()
  file.layout:restore_winopts()
  vim.cmd("keepalt edit " .. fpath)

  if temp_bufnr ~= api.nvim_get_current_buf() then
    api.nvim_buf_delete(temp_bufnr, { force = true })
  end

  if cursor then
    utils.set_cursor(0, unpack(cursor))
  end

  return true
end

function M.goto_file()
  open_goto_file({ target_tab = true, target_tab_cmd = "sp", cmd = "tabnew" })
end

function M.goto_file_edit()
  open_goto_file({ target_tab = true, target_tab_cmd = "edit", cmd = "tabnew" })
end

---Like |diffview-actions-goto_file_edit|, but also closes the current diffview
---after navigating. If there is no previous non-view tabpage, the file is
---opened in a new tabpage (same fallback as |diffview-actions-goto_file_edit|),
---and closing the diffview tab leaves you on that new tabpage.
function M.goto_file_edit_close()
  local view = lib.get_current_view()

  -- Pre-flight the guarded close before navigating: the action's contract is
  -- "navigate and close", so an aborted close after a successful navigation
  -- would leave the user on the target file with the diffview still open.
  if view and view:instanceof(DiffView.__get()) then
    ---@cast view DiffView
    if not view:can_close({ force = false }) then
      return
    end
  end

  if not open_goto_file({ target_tab = true, target_tab_cmd = "edit", cmd = "tabnew" }) then
    return
  end

  if view then
    view:close()
    lib.dispose_view(view)
  end
end

function M.goto_file_split()
  open_goto_file({ cmd = "new" })
end

function M.goto_file_tab()
  open_goto_file({ cmd = "tabnew" })
end

---Open the current file with the system default application.
function M.open_file_external()
  local file = prepare_goto_file()

  if file then
    local cmd
    if vim.fn.has("mac") == 1 then
      cmd = { "open", file.absolute_path }
    elseif vim.fn.has("unix") == 1 then
      cmd = { "xdg-open", file.absolute_path }
    elseif vim.fn.has("win32") == 1 then
      cmd = { "cmd", "/c", "start", "", file.absolute_path }
    else
      utils.err("Unsupported platform for opening files externally.")
      return
    end

    vim.fn.jobstart(cmd, { detach = true })
  end
end

---Open the current diffview in a new tab with the same revision.
function M.open_in_new_tab()
  local view = lib.get_current_view()

  if not view then
    return
  end

  -- Only works for DiffView (not FileHistoryView).
  if not DiffView.__get():ancestorof(view) then
    utils.info("This action only works in a diff view.")
    return
  end
  ---@cast view DiffView

  local new_view = DiffView({
    adapter = view.adapter,
    rev_arg = view.rev_arg,
    left = view.left,
    right = view.right,
    path_args = view.path_args,
    options = view.options or {},
  })

  lib.add_view(new_view)
  new_view:open()
end

---Open a diffview comparing the default branch against working tree.
---The default branch is detected automatically (main, master, or from origin/HEAD).
function M.diff_against_default_branch()
  local view = lib.get_current_view()
  local adapter

  if view then
    ---@cast view DiffView|FileHistoryView
    adapter = view.adapter
  else
    -- Get an adapter for the current working directory.
    local err
    local cfile = pl:vim_expand("%")
    local top_indicators =
      utils.vec_join(vim.bo.buftype == "" and pl:absolute(cfile) or nil, pl:realpath("."))
    err, adapter = require("diffview.vcs").get_adapter({ top_indicators = top_indicators })
    if err or not adapter then
      utils.err("Failed to get VCS adapter: " .. (err or "unknown error"))
      return
    end
  end

  local default_branch = adapter:get_default_branch()
  if not default_branch then
    utils.err("Could not detect default branch (main/master). Please specify manually.")
    return
  end

  local new_view = DiffView({
    adapter = adapter,
    rev_arg = default_branch,
    left = adapter.Rev(RevType.COMMIT, default_branch),
    right = adapter.Rev(RevType.LOCAL),
  })

  lib.add_view(new_view)
  new_view:open()
end

---@class diffview.ConflictCount
---@field total integer
---@field current integer
---@field cur_conflict? ConflictRegion
---@field conflicts ConflictRegion[]

---@param num integer
---@param use_delta? boolean
---@return diffview.ConflictCount?
function M.jumpto_conflict(num, use_delta)
  local view = lib.get_current_view()

  if view and view:instanceof(StandardView.__get()) then
    ---@cast view StandardView
    local main, bufnr = get_valid_main(view)

    if main then
      ---@cast bufnr integer
      local next_idx
      local conflicts, cur, cur_idx =
        vcs_utils.parse_conflicts(api.nvim_buf_get_lines(bufnr, 0, -1, false), main.id)

      if #conflicts > 0 then
        if not use_delta then
          next_idx = utils.clamp(num, 1, #conflicts)
        else
          local delta = num

          if not cur and delta < 0 and cur_idx <= #conflicts then
            delta = delta + 1
          end

          if (delta < 0 and cur_idx < 1) or (delta > 0 and cur_idx > #conflicts) then
            cur_idx = utils.clamp(cur_idx, 1, #conflicts)
          end

          next_idx = (cur_idx + delta - 1) % #conflicts + 1
        end

        local next_conflict = conflicts[next_idx]
        local curwin = api.nvim_get_current_win()

        api.nvim_win_call(main.id, function()
          api.nvim_win_set_cursor(main.id, { next_conflict.first, 0 })
          if curwin ~= main.id then
            view.cur_layout:sync_scroll()
          end
        end)

        api.nvim_echo({ { ("Conflict [%d/%d]"):format(next_idx, #conflicts) } }, false, {})

        return {
          total = #conflicts,
          current = next_idx,
          cur_conflict = next_conflict,
          conflicts = conflicts,
        }
      end
    end
  end
end

---Jump to the next merge conflict marker.
---@return diffview.ConflictCount?
function M.next_conflict()
  return M.jumpto_conflict(1, true)
end
tag(M.next_conflict, "merge_only")

---Jump to the previous merge conflict marker.
---@return diffview.ConflictCount?
function M.prev_conflict()
  return M.jumpto_conflict(-1, true)
end
tag(M.prev_conflict, "merge_only")

---Move the cursor to an inline-diff hunk in the current `diff1_inline` window,
---as picked by `picker(bufnr, cursor_row)`.
---@param picker fun(bufnr: integer, cursor_row: integer): integer?
local function jump_inline_hunk_by(picker)
  local view = lib.get_current_view()
  if not (view and view:instanceof(StandardView.__get())) then
    return
  end
  ---@cast view StandardView

  local main, bufnr = get_valid_main(view)
  if not main then
    return
  end
  ---@cast bufnr integer

  local cur = api.nvim_win_get_cursor(main.id)[1] - 1
  local row = picker(bufnr, cur)
  if row then
    api.nvim_win_set_cursor(main.id, { row + 1, 0 })
  end
end

---Jump to the next inline-diff hunk in the current `diff1_inline` window.
function M.next_inline_hunk()
  jump_inline_hunk_by(require("diffview.scene.inline_diff").next_hunk_row)
end

---Jump to the previous inline-diff hunk in the current `diff1_inline` window.
function M.prev_inline_hunk()
  jump_inline_hunk_by(require("diffview.scene.inline_diff").prev_hunk_row)
end

---Jump the cursor to the first change in the view's main window after a file
---is opened. Centralizes the per-layout dispatch (conflict / inline / native
---`]c`) so it stays consistent across `DiffView` and `FileHistoryView`.
---@param view StandardView
function M.jump_to_first_change(view)
  local main, bufnr = get_valid_main(view)
  if not main then
    return
  end
  ---@cast bufnr integer

  api.nvim_win_call(main.id, function()
    utils.set_cursor(0, 1, 0)

    if view.cur_entry and view.cur_entry.kind == "conflicting" then
      M.next_conflict()
    elseif view.cur_layout.name == "diff1_inline" then
      -- Inline view has `diff=false`, so native `]c` does nothing. Use the
      -- renderer's cached hunks to land on the first change.
      local rows = require("diffview.scene.inline_diff").hunk_anchor_rows(bufnr)
      if rows[1] then
        api.nvim_win_set_cursor(main.id, { rows[1] + 1, 0 })
      end
    else
      local is_diff = vim.fn.diff_hlID(1, 1) ~= 0 or vim.fn.diff_filler(1) ~= 0
      if is_diff then
        return
      end
      pcall(api.nvim_command, "norm! ]c")
    end
    vim.cmd("norm! zz")
  end)

  view.cur_layout:sync_scroll()
end

---Execute `cmd` for each target window in the current view. If no targets
---are given, all windows are targeted.
---@param cmd string|fun(layout_name: string, symbol: string) The vim cmd to execute, or a function.
---@return fun()
function M.view_windo(cmd)
  local fun

  if type(cmd) == "string" then
    fun = function(_, _)
      vim.cmd(cmd)
    end
  else
    fun = cmd
  end

  return function()
    local view = lib.get_current_view()

    if view and view:instanceof(StandardView.__get()) then
      ---@cast view StandardView

      for _, symbol in ipairs({ "a", "b", "c", "d" }) do
        local win = view.cur_layout[symbol] --[[@as Window? ]]

        if win then
          api.nvim_win_call(win.id, function()
            fun(view.cur_layout.name, symbol)
          end)
        end
      end
    end
  end
end

---@param distance number Either an exact number of lines, or a fraction of the window height.
---@return fun()
function M.scroll_view(distance)
  local scroll_opr = distance < 0 and [[\<c-y>]] or [[\<c-e>]]
  local scroll_cmd

  if distance % 1 == 0 then
    scroll_cmd = ([[exe "norm! %d%s"]]):format(distance, scroll_opr)
  else
    scroll_cmd = ([[exe "norm! " . float2nr(winheight(0) * %f) . "%s"]]):format(
      math.abs(distance),
      scroll_opr
    )
  end

  return function()
    local view = lib.get_current_view()

    if view and view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      local max = -1
      local target

      for _, win in ipairs(view.cur_layout.windows) do
        local height = utils.win_content_height(win.id)
        if height > max then
          max = height
          target = win.id
        end
      end

      if target then
        api.nvim_win_call(target, function()
          vim.cmd(scroll_cmd)
        end)
      end
    end
  end
end

---@param kind "ours"|"theirs"|"base"|"local"
local function diff_copy_target(kind)
  local view = lib.get_current_view() --[[@as DiffView|FileHistoryView ]]
  local file = view.cur_entry

  if file then
    local layout = file.layout
    local bufnr

    if layout:instanceof(Diff3.__get()) then
      ---@cast layout Diff3
      if kind == "ours" then
        bufnr = layout.a.file.bufnr
      elseif kind == "theirs" then
        bufnr = layout.c.file.bufnr
      elseif kind == "local" then
        bufnr = layout.b.file.bufnr
      end
    elseif layout:instanceof(Diff4.__get()) then
      ---@cast layout Diff4
      if kind == "ours" then
        bufnr = layout.a.file.bufnr
      elseif kind == "theirs" then
        bufnr = layout.c.file.bufnr
      elseif kind == "base" then
        bufnr = layout.d.file.bufnr
      elseif kind == "local" then
        bufnr = layout.b.file.bufnr
      end
    end

    if bufnr then
      return bufnr
    end
  end
end

---@param view DiffView
---@param target "ours"|"theirs"|"base"|"all"|"none"
local function resolve_all_conflicts(view, target)
  local main, bufnr = get_valid_main(view)

  if main then
    ---@cast bufnr integer
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local conflicts = vcs_utils.parse_conflicts(lines, main.id)

    if next(conflicts) then
      local content
      local offset = 0
      local first, last

      for _, cur_conflict in ipairs(conflicts) do
        -- add offset to line numbers
        first = cur_conflict.first + offset
        last = cur_conflict.last + offset

        if target == "ours" then
          content = cur_conflict.ours.content
        elseif target == "theirs" then
          content = cur_conflict.theirs.content
        elseif target == "base" then
          content = cur_conflict.base.content
        elseif target == "all" then
          content = utils.vec_join(
            cur_conflict.ours.content,
            cur_conflict.base.content,
            cur_conflict.theirs.content
          )
        end

        content = content or {}
        api.nvim_buf_set_lines(bufnr, first - 1, last, false, content)
        offset = offset + (#content - (last - first) - 1)
      end

      utils.set_cursor(
        main.id,
        unpack({
          (content and #content or 0) + first - 1,
          content and content[1] and #content[#content] or 0,
        })
      )

      view.cur_layout:sync_scroll()
    end
  end
end

---@param target DiffviewConflictTarget
---@return AsyncFunc
function M.conflict_choose_all(target)
  return tag(
    async.void(function()
      local view = lib.get_current_view() --[[@as DiffView ]]

      if view and view:instanceof(DiffView.__get()) then
        ---@cast view DiffView

        if view.panel:is_focused() then
          local item = view:infer_cur_file(false) ---@cast item -DirData
          if not item then
            return
          end

          if not item.active then
            -- Open the entry
            await(view:set_file(item))
          end
        end

        resolve_all_conflicts(view, target)
      end
    end),
    "merge_only"
  )
end

---@param target DiffviewConflictTarget
---@return fun()
function M.conflict_choose(target)
  return tag(function()
    local view = lib.get_current_view()

    if view and view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      local main, bufnr = get_valid_main(view)

      if main then
        ---@cast bufnr integer
        local _, cur =
          vcs_utils.parse_conflicts(api.nvim_buf_get_lines(bufnr, 0, -1, false), main.id)

        if cur then
          local content

          if target == "ours" then
            content = cur.ours.content
          elseif target == "theirs" then
            content = cur.theirs.content
          elseif target == "base" then
            content = cur.base.content
          elseif target == "all" then
            content = utils.vec_join(cur.ours.content, cur.base.content, cur.theirs.content)
          end

          api.nvim_buf_set_lines(bufnr, cur.first - 1, cur.last, false, content or {})

          utils.set_cursor(
            main.id,
            unpack({
              (content and #content or 0) + cur.first - 1,
              content and content[1] and #content[#content] or 0,
            })
          )
        end
      end
    end
  end, "merge_only")
end

---Replace the entire MERGED buffer with the content of the OURS, THEIRS, or
---BASE side. Unlike `conflict_choose_all`, this does not parse conflict
---markers; it overwrites the whole buffer with the side's lines. Useful when
---the merge driver did not emit markers (e.g., modify/delete conflicts, or
---jj with `merge-tool-edits-conflict-markers = false`).
---@param target DiffviewConflictSideTarget
---@return AsyncFunc
function M.conflict_choose_side(target)
  return tag(
    async.void(function()
      local view = lib.get_current_view() --[[@as DiffView ]]

      if not (view and view:instanceof(DiffView.__get())) then
        return
      end
      ---@cast view DiffView

      if view.panel:is_focused() then
        local item = view:infer_cur_file(false) ---@cast item -DirData
        if not item then
          return
        end

        if not item.active then
          await(view:set_file(item))
        end
      end

      local main, bufnr = get_valid_main(view)
      if not main then
        return
      end
      ---@cast bufnr integer

      local src_bufnr = diff_copy_target(target)
      if not (src_bufnr and api.nvim_buf_is_valid(src_bufnr)) then
        return
      end

      local src_lines = api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, src_lines)

      utils.set_cursor(main.id, 1, 0)
      view.cur_layout:sync_scroll()
    end),
    "merge_only"
  )
end

---@param target DiffviewDiffgetTarget
---@return fun()
function M.diffget(target)
  return function()
    local bufnr = diff_copy_target(target)

    if bufnr and api.nvim_buf_is_valid(bufnr) then
      local range

      if api.nvim_get_mode().mode:match("^[vV]") then
        range = ("%d,%d"):format(unpack(utils.vec_sort({
          vim.fn.line("."),
          vim.fn.line("v"),
        })))
      end

      vim.cmd(("%sdiffget %d"):format(range or "", bufnr))

      if range then
        api.nvim_feedkeys(utils.t("<esc>"), "n", false)
      end
    end
  end
end

---Obtain (`diffget`) the old-side content of every hunk the cursor or the
---current visual range covers, in a `diff1_inline` layout. The inline layout
---disables native diff mode and renders the old side as extmarks, so vim's
---built-in `:diffget` has no second window to read from; this action drives
---the layout's splice-based implementation, which reuses the renderer's
---cached hunks and old-side content. No-op outside a `diff1_inline` layout.
function M.diffget_inline()
  local view = lib.get_current_view()
  if not (view and view:instanceof(StandardView.__get())) then
    return
  end
  ---@cast view StandardView

  local layout = view.cur_layout
  if not (layout and layout:instanceof(Diff1Inline.__get())) then
    return
  end
  ---@cast layout Diff1Inline

  local main = layout:get_main_win()
  if not (main and main:is_valid()) then
    return
  end

  local is_visual = api.nvim_get_mode().mode:match("^[vV" .. utils.t("<C-v>") .. "]") ~= nil
  local first, last

  if is_visual then
    first, last = unpack(utils.vec_sort({
      vim.fn.line("."),
      vim.fn.line("v"),
    }))
  else
    first = api.nvim_win_get_cursor(main.id)[1]
    last = first
  end

  layout:diffget(first, last)

  if is_visual then
    api.nvim_feedkeys(utils.t("<esc>"), "n", false)
  end
end

---@param target DiffviewDiffgetTarget
---@return fun()
function M.diffput(target)
  return function()
    local bufnr = diff_copy_target(target)

    if bufnr and api.nvim_buf_is_valid(bufnr) then
      vim.cmd("diffput " .. bufnr)
    end
  end
end

---@type table<string, Layout|LazyModule>
local layout_name_map = {
  diff1_plain = Diff1,
  diff1_inline = Diff1Inline,
  diff2_horizontal = Diff2Hor,
  diff2_vertical = Diff2Ver,
  diff3_horizontal = Diff3Hor,
  diff3_vertical = Diff3Ver,
  diff3_mixed = Diff3Mixed,
  diff4_mixed = Diff4Mixed,
}

function M.cycle_layout()
  local conf = config.get_config()
  local cycle_config = conf.view.cycle_layouts or {}

  -- Convert layout names to layout classes.
  local function resolve_layouts(names)
    local result = {}
    for _, name in ipairs(names or {}) do
      local layout_class = layout_name_map[name]
      if layout_class then
        result[#result + 1] = layout_class.__get()
      end
    end
    return result
  end

  -- Use config or fall back to defaults.
  local default_standard = { Diff2Hor.__get(), Diff2Ver.__get() }
  local default_merge_tool =
    { Diff3Hor.__get(), Diff3Ver.__get(), Diff3Mixed.__get(), Diff4Mixed.__get(), Diff1.__get() }

  local resolved_standard = resolve_layouts(cycle_config.default)
  local resolved_merge_tool = resolve_layouts(cycle_config.merge_tool)

  local layout_cycles = {
    standard = #resolved_standard > 0 and resolved_standard or default_standard,
    merge_tool = #resolved_merge_tool > 0 and resolved_merge_tool or default_merge_tool,
  }

  local view = lib.get_current_view()

  if not view then
    return
  end

  local layouts, files, cur_file

  if view:instanceof(FileHistoryView.__get()) then
    ---@cast view FileHistoryView
    layouts = layout_cycles.standard
    files = view.panel:list_files()
    cur_file = view:cur_file()
  elseif view:instanceof(DiffView.__get()) then
    ---@cast view DiffView
    cur_file = view.cur_entry

    if cur_file then
      layouts = cur_file.kind == "conflicting" and layout_cycles.merge_tool
        or layout_cycles.standard
      files = cur_file.kind == "conflicting" and view.files.conflicting
        or utils.vec_join(view.panel.files.working, view.panel.files.staged)
    end
  else
    return
  end

  if not files then
    return
  end

  for _, entry in ipairs(files) do
    local cur_layout = entry.layout
    -- Normalise a pinned current class to its unpinned sibling for the
    -- lookup: the cycle list contains unpinned classes, so without this
    -- step pin_local mode never matches and cycling sticks on the first
    -- layout. `unpinned_layout` is a no-op for non-pinned classes.
    local cur_for_lookup = cur_layout.class --[[@as Layout ]]
    if view.unpinned_layout then
      cur_for_lookup = (view --[[@as FileHistoryView ]]):unpinned_layout(cur_for_lookup)
    end
    local idx = utils.vec_indexof(layouts, cur_for_lookup)
    -- If the current layout isn't in the cycle list, start at the first
    -- entry rather than the last (Lua's `-1 % N + 1 == N` quirk).
    local next_idx = (idx == -1 and 0 or idx) % #layouts + 1
    local target = layouts[next_idx]
    -- File-history pin_local must stay on a pinned Diff2 variant: an
    -- unpinned class would let `FileEntry:destroy` tear down the
    -- view-owned working-tree File once per entry and break the shared
    -- LOCAL buffer. `resolve_pinned_layout` is a no-op when pin_local
    -- is off, so the cast is safe even when the view happens to be a
    -- DiffView in some refactor down the line.
    if view.resolve_pinned_layout then
      target = (view --[[@as FileHistoryView ]]):resolve_pinned_layout(target)
    end
    entry:convert_layout(target)
  end

  -- `panel:list_files()` doesn't include pin_local overlays (transient
  -- FileEntries built by `_resolve_pinned_target` for commits that don't
  -- touch the pinned path). When the active diff IS an overlay, the loop
  -- above misses it and the next `set_file` would reopen the stale layout.
  -- Convert it explicitly with the same target the loop computed.
  if cur_file and utils.vec_indexof(files, cur_file) == -1 then
    local cur_for_lookup = cur_file.layout.class --[[@as Layout ]]
    if view.unpinned_layout then
      cur_for_lookup = (view --[[@as FileHistoryView ]]):unpinned_layout(cur_for_lookup)
    end
    local idx = utils.vec_indexof(layouts, cur_for_lookup)
    local next_idx = (idx == -1 and 0 or idx) % #layouts + 1
    local target = layouts[next_idx]
    if view.resolve_pinned_layout then
      target = (view --[[@as FileHistoryView ]]):resolve_pinned_layout(target)
    end
    cur_file:convert_layout(target)
  end

  if cur_file then
    local main = view.cur_layout:get_main_win()
    local pos = api.nvim_win_get_cursor(main.id)
    local was_focused = view.cur_layout:is_focused()

    cur_file.layout.emitter:once("files_opened", function()
      utils.set_cursor(main.id, unpack(pos))
      if not was_focused then
        view.cur_layout:sync_scroll()
      end
    end)

    view:set_file(cur_file, false)
    main = view.cur_layout:get_main_win()

    if was_focused then
      main:focus()
    end
  end
end

---Set a specific layout for the current view.
---@param layout_name LayoutName
---@return fun()
function M.set_layout(layout_name)
  return function()
    local layout_class = layout_name_map[layout_name]
    if not layout_class then
      utils.err(
        ("Unknown layout: '%s'. See ':h diffview-config-view.x.layout' for valid layouts."):format(
          layout_name
        )
      )
      return
    end

    local view = lib.get_current_view()
    if not view then
      return
    end

    local files, cur_file

    if view:instanceof(FileHistoryView.__get()) then
      ---@cast view FileHistoryView
      files = view.panel:list_files()
      cur_file = view:cur_file()
    elseif view:instanceof(DiffView.__get()) then
      ---@cast view DiffView
      cur_file = view.cur_entry
      if cur_file then
        files = cur_file.kind == "conflicting" and view.files.conflicting
          or utils.vec_join(view.panel.files.working, view.panel.files.staged)
      end
    else
      return
    end

    if not files then
      return
    end

    local target_layout = layout_class.__get()
    -- See `cycle_layout` for the pin_local rationale.
    if view.resolve_pinned_layout then
      target_layout = (view --[[@as FileHistoryView ]]):resolve_pinned_layout(target_layout)
    end

    for _, entry in ipairs(files) do
      entry:convert_layout(target_layout)
    end

    -- See `cycle_layout` for why pin_local overlays need explicit handling.
    if cur_file and utils.vec_indexof(files, cur_file) == -1 then
      cur_file:convert_layout(target_layout)
    end

    if cur_file then
      local main = view.cur_layout:get_main_win()
      local pos = api.nvim_win_get_cursor(main.id)
      local was_focused = view.cur_layout:is_focused()

      cur_file.layout.emitter:once("files_opened", function()
        utils.set_cursor(main.id, unpack(pos))
        if not was_focused then
          view.cur_layout:sync_scroll()
        end
      end)

      view:set_file(cur_file, false)
      main = view.cur_layout:get_main_win()

      if was_focused then
        main:focus()
      end
    end
  end
end

---@class DiffviewRefreshFilesOpts
---@field force? boolean Force-reload stage diff buffers, discarding unsaved edits.
---@field focus_gained? boolean Set when the refresh was triggered by `FocusGained`. The file-history view ignores these (rebuilding the whole log on every focus is costly and rarely reflects a real change); the diff view still refreshes.

---Refresh the file list for the current view.
---
---With `opts.force = true`, entries that include a STAGE buffer are destroyed
---and recreated rather than updated in place, discarding any unsaved edits in
---those buffers (parity with vim-fugitive's `:edit!` for the staged buffer).
---Only entries with a STAGE-rev side are affected; LOCAL working-tree buffers
---are left alone (use `:edit!` on them via the standard Vim mechanism). Without
---the flag, `refresh_files` is a no-op for stage buffers whose index entry
---hasn't changed (the default `R` behaviour).
---@param opts? DiffviewRefreshFilesOpts
function M.refresh_files(opts)
  require("diffview").emit("refresh_files", opts)
end

---@param keymap_groups string|string[]
---@return fun()
function M.help(keymap_groups)
  keymap_groups = type(keymap_groups) == "table" and keymap_groups or { keymap_groups }

  return function()
    local view = lib.get_current_view()

    if view then
      local help_panel = HelpPanel(view, keymap_groups) --[[@as HelpPanel ]]
      help_panel:focus()
    end
  end
end

do
  M.compat.fold_cmds = {}

  -- For file entries that use custom folds with `foldmethod=manual` we need to
  -- replicate fold commands in all diff windows, as folds are only
  -- synchronized between diff windows when `foldmethod=diff`.
  local function compat_fold(fold_cmd)
    return function()
      if vim.wo.foldmethod ~= "manual" then
        local ok, msg = pcall(api.nvim_command, "norm! " .. fold_cmd)
        if not ok and msg then
          api.nvim_echo({ { msg, "ErrorMsg" } }, true, { err = true })
        end
        return
      end

      local view = lib.get_current_view()

      if view and view:instanceof(StandardView.__get()) then
        ---@cast view StandardView
        local err

        for _, win in ipairs(view.cur_layout.windows) do
          api.nvim_win_call(win.id, function()
            local ok, msg = pcall(api.nvim_command, "norm! " .. fold_cmd)
            if not ok then
              err = msg
            end
          end)
        end

        if err then
          api.nvim_echo({ { err, "ErrorMsg" } }, true, { err = true })
        end
      end
    end
  end

  for _, fold_cmd in ipairs({
    "za",
    "zA",
    "ze",
    "zE",
    "zo",
    "zc",
    "zO",
    "zC",
    "zr",
    "zm",
    "zR",
    "zM",
    "zv",
    "zx",
    "zX",
    "zn",
    "zN",
    "zi",
  }) do
    table.insert(M.compat.fold_cmds, {
      "n",
      fold_cmd,
      compat_fold(fold_cmd),
      { desc = "diffview_ignore" },
    })
  end
end

-- Keep in sync with the emit-stub subset of the `DiffviewActions` class above.
-- Directly-defined actions in this file (also listed in `DiffviewActions`) are
-- not registered here.
local action_names = {
  "close",
  "close_all_folds",
  "close_fold",
  "copy_hash",
  "diff_against_head",
  "focus_entry",
  "focus_files",
  "listing_style",
  "next_entry",
  "next_entry_in_commit",
  "open_all_folds",
  "open_commit_in_browser",
  "open_commit_log",
  "open_fold",
  "open_in_diffview",
  "options",
  "prev_entry",
  "prev_entry_in_commit",
  "restore_entry",
  "select_entry",
  "select_next_entry",
  "select_prev_entry",
  "select_first_entry",
  "select_last_entry",
  "select_next_commit",
  "select_prev_commit",
  "stage_all",
  "toggle_files",
  "toggle_flatten_dirs",
  "toggle_fold",
  "toggle_select_entry",
  "clear_select_entries",
  "toggle_stage_entry",
  "toggle_untracked",
  "unstage_all",
}

---Applicability tags for emit-stub actions. Listed here (rather than at each
---stub site) because the stubs are generated in the loop below.
---@type table<string, diffview.ActionTag>
local action_tags = {
  toggle_stage_entry = "working_tree_only",
  stage_all = "working_tree_only",
  unstage_all = "working_tree_only",
}

for _, name in ipairs(action_names) do
  M[name] = function()
    require("diffview").emit(name)
  end
  if action_tags[name] then
    tag(M[name], action_tags[name])
  end
end

return M
