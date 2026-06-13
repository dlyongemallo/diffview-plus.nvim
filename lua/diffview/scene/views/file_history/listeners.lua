local async = require("diffview.async")
local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local JobStatus = lazy.access("diffview.vcs.utils", "JobStatus") ---@type JobStatus|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local actions = lazy.require("diffview.actions") --[[@as DiffviewActions ]]
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local api = vim.api
local await = async.await

---@param view FileHistoryView
return function(view)
  return {
    tab_enter = function()
      local file = view.panel.cur_item[2]
      if file then
        view:set_file(file)
      end

      view:restore_panel_cursor()
    end,
    tab_leave = function()
      local file = view.panel.cur_item[2]
      view:save_panel_cursor()

      if file then
        file.layout:detach_files()
      end

      for _, entry in ipairs(view.panel.entries) do
        for _, f in ipairs(entry.files) do
          f.layout:restore_winopts()
        end
      end
    end,
    file_open_new = function(_, entry)
      -- See `DiffView`'s listener: drop bridged events from sibling
      -- views, and replay saved cursor + viewport on first open.
      if view.cur_entry ~= entry then
        return
      end
      if view:restore_main_view(entry.path) then
        return
      end
      actions.jump_to_first_change(view)
    end,
    open_in_diffview = function()
      local file = view:infer_cur_file()

      if file then
        local revs = file.revs

        local new_view = DiffView({
          adapter = view.adapter,
          rev_arg = view.adapter:rev_to_pretty_string(revs.a, revs.b),
          left = revs.a,
          right = revs.b,
          options = { selected_file = file.absolute_path },
        })

        lib.add_view(new_view)
        new_view:open()
      end
    end,
    ---Open a diffview comparing HEAD with the commit under cursor.
    diff_against_head = function()
      local item = view.panel:get_item_at_cursor()
      if not item then
        return
      end

      local commit = item.commit
      if not commit or not commit.hash then
        return
      end

      local new_view = DiffView({
        adapter = view.adapter,
        rev_arg = commit.hash,
        left = view.adapter.Rev(RevType.COMMIT, commit.hash),
        right = view.adapter.Rev(RevType.LOCAL),
      })

      lib.add_view(new_view)
      new_view:open()
    end,
    select_next_entry = function()
      view:next_item()
    end,
    select_prev_entry = function()
      view:prev_item()
    end,
    select_first_entry = function()
      local entry = view.panel.entries[1]
      if entry and #entry.files > 0 then
        -- `pick_entry_target` routes through `_resolve_pinned_target` in
        -- pin_local mode so the snap-to-first-entry preserves the pinned
        -- path instead of jumping to `files[1]` of that commit.
        view:set_file(view:pick_entry_target(entry) or entry.files[1])
      end
    end,
    select_last_entry = function()
      local entry = view.panel.entries[#view.panel.entries]
      if entry and #entry.files > 0 then
        -- Non-pin_local: open the LAST file in the last commit (the action's
        -- historical contract). In pin_local mode the user expects the
        -- pinned file (or its overlay) regardless of position in the
        -- commit, so route through `pick_entry_target` only when pinned.
        local target = view.pin_local and view:pick_entry_target(entry) or entry.files[#entry.files]
        view:set_file(target)
      end
    end,
    select_next_commit = function()
      local cur_entry = view.panel.cur_item[1]
      if not cur_entry then
        return
      end
      local entry_idx = utils.vec_indexof(view.panel.entries, cur_entry)
      if entry_idx == -1 then
        return
      end

      local next_idx
      if config.get_config().wrap_entries then
        next_idx = (entry_idx + vim.v.count1 - 1) % #view.panel.entries + 1
      else
        next_idx = math.min(entry_idx + vim.v.count1, #view.panel.entries)
        if next_idx == entry_idx then
          return
        end
      end
      local next_entry = view.panel.entries[next_idx]
      -- See `select_first_entry` for the pin_local rationale.
      view:set_file(view:pick_entry_target(next_entry) or next_entry.files[1])
    end,
    select_prev_commit = function()
      local cur_entry = view.panel.cur_item[1]
      if not cur_entry then
        return
      end
      local entry_idx = utils.vec_indexof(view.panel.entries, cur_entry)
      if entry_idx == -1 then
        return
      end

      local next_idx
      if config.get_config().wrap_entries then
        next_idx = (entry_idx - vim.v.count1 - 1) % #view.panel.entries + 1
      else
        next_idx = math.max(entry_idx - vim.v.count1, 1)
        if next_idx == entry_idx then
          return
        end
      end
      local next_entry = view.panel.entries[next_idx]
      -- See `select_first_entry` for the pin_local rationale.
      view:set_file(view:pick_entry_target(next_entry) or next_entry.files[1])
    end,
    ---Navigate to next file within the current commit.
    next_entry_in_commit = function()
      local cur_entry = view.panel.cur_item[1]
      local cur_file = view.panel.cur_item[2]
      if not cur_entry or not cur_file or #cur_entry.files == 0 then
        return
      end

      local file_idx = utils.vec_indexof(cur_entry.files, cur_file)
      if file_idx == -1 then
        -- pin_local overlay (or any FileEntry not in `cur_entry.files`):
        -- treat the overlay as if it were files[1] for navigation. Without
        -- this, j/`]f` would silently no-op for exactly the commits where
        -- pin_local needs the overlay path.
        file_idx = 1
      end

      local next_idx
      if config.get_config().wrap_entries then
        next_idx = (file_idx % #cur_entry.files) + 1
      else
        next_idx = math.min(file_idx + 1, #cur_entry.files)
        if next_idx == file_idx then
          return
        end
      end
      view:set_file(cur_entry.files[next_idx])
    end,
    ---Navigate to previous file within the current commit.
    prev_entry_in_commit = function()
      local cur_entry = view.panel.cur_item[1]
      local cur_file = view.panel.cur_item[2]
      if not cur_entry or not cur_file or #cur_entry.files == 0 then
        return
      end

      local file_idx = utils.vec_indexof(cur_entry.files, cur_file)
      if file_idx == -1 then
        -- See `next_entry_in_commit` for the overlay rationale.
        file_idx = 1
      end

      local prev_idx
      if config.get_config().wrap_entries then
        prev_idx = ((file_idx - 2) % #cur_entry.files) + 1
      else
        prev_idx = math.max(file_idx - 1, 1)
        if prev_idx == file_idx then
          return
        end
      end
      view:set_file(cur_entry.files[prev_idx])
    end,
    next_entry = function()
      view.panel:highlight_next_file()
    end,
    prev_entry = function()
      view.panel:highlight_prev_item()
    end,
    select_entry = function()
      if view.panel:is_focused() then
        local item = view.panel:get_item_at_cursor()
        if item then
          if item.files then
            if view.panel.single_file then
              view:set_file(item.files[1], false)
            else
              view.panel:toggle_entry_fold(item --[[@as LogEntry ]])
            end
          else
            view:set_file(item, false)
          end
        end
      elseif view.panel.option_panel:is_focused() then
        local option = view.panel.option_panel:get_item_at_cursor()
        if option then
          view.panel.option_panel.emitter:emit("set_option", option.key)
        end
      end
    end,
    focus_entry = function()
      if view.panel:is_focused() then
        local item = view.panel:get_item_at_cursor()
        if item then
          if item.files then
            if view.panel.single_file then
              view:set_file(item.files[1], true)
            else
              view.panel:toggle_entry_fold(item --[[@as LogEntry ]])
            end
          else
            view:set_file(item, true)
          end
        end
      end
    end,
    open_commit_log = function()
      local file = view:infer_cur_file()
      if file then
        local entry = view.panel:find_entry(file)
        if entry and entry.commit and entry.commit.hash then
          view.commit_log_panel:update(view.adapter.Rev.to_range(entry.commit.hash))
        end
      end
    end,
    focus_files = function()
      view.panel:focus()
    end,
    toggle_files = function()
      view.panel:toggle(true)
    end,
    refresh_files = function()
      view.panel:update_entries(function(_, status)
        if status >= JobStatus.ERROR then
          return
        end
        if not view:cur_file() then
          view:next_item()
        end
      end)
    end,
    open_all_folds = function()
      if view.panel:is_focused() and not view.panel.single_file then
        for _, entry in ipairs(view.panel.entries) do
          entry.folded = false
        end
        view.panel:render()
        view.panel:redraw()
      end
    end,
    close_all_folds = function()
      if view.panel:is_focused() and not view.panel.single_file then
        for _, entry in ipairs(view.panel.entries) do
          entry.folded = true
        end
        view.panel:render()
        view.panel:redraw()
      end
    end,
    open_fold = function()
      if view.panel.single_file or not view.panel:is_focused() then
        return
      end
      local entry = view.panel:get_log_entry_at_cursor()
      if entry then
        view.panel:set_entry_fold(entry, true)
      end
    end,
    close_fold = function()
      if view.panel.single_file or not view.panel:is_focused() then
        return
      end
      local entry = view.panel:get_log_entry_at_cursor()
      if entry then
        view.panel:set_entry_fold(entry, false)
      end
    end,
    toggle_fold = function()
      if view.panel.single_file or not view.panel:is_focused() then
        return
      end
      local entry = view.panel:get_log_entry_at_cursor()
      if entry then
        view.panel:toggle_entry_fold(entry)
      end
    end,
    close = function()
      if view.panel.option_panel:is_focused() then
        view.panel.option_panel:close()
      elseif view.panel:is_focused() then
        view.panel:close()
      elseif view:is_cur_tabpage() then
        -- Don't close the view if a floating window is focused; the float's
        -- own close listener should handle it.
        local win_conf = api.nvim_win_get_config(0)
        if win_conf.relative == "" then
          view:close()
        end
      end
    end,
    options = function()
      view.panel.option_panel:focus()
    end,
    copy_hash = function()
      if view.panel:is_focused() then
        local item = view.panel:get_item_at_cursor()
        if item and item.commit and item.commit.hash then
          local reg = vim.v.register
          vim.fn.setreg(reg, item.commit.hash)
          local reg_desc = (reg == '"' or reg == "") and "the default register"
            or string.format("register '%s'", reg)
          utils.info(string.format("Copied '%s' to %s.", item.commit.hash, reg_desc))
        end
      end
    end,
    open_commit_in_browser = function()
      local item = view.panel:get_item_at_cursor()
      if not item then
        item = view.panel.cur_item[1]
      end
      if not item or not item.commit or not item.commit.hash then
        return
      end

      if not view.adapter.get_commit_url then
        utils.err("Opening commits in browser is not supported for this VCS.")
        return
      end

      local url = view.adapter:get_commit_url(item.commit.hash)
      if not url then
        utils.err("Could not construct browser URL. Remote URL not recognized.")
        return
      end

      local cmd
      if vim.fn.has("mac") == 1 then
        cmd = { "open", url }
      elseif vim.fn.has("wsl") == 1 then
        cmd = { "wslview", url }
      elseif vim.fn.has("unix") == 1 then
        cmd = { "xdg-open", url }
      elseif vim.fn.has("win32") == 1 then
        cmd = { "cmd", "/c", "start", "", url }
      end

      if cmd then
        vim.fn.jobstart(cmd, { detach = true })
      end
    end,
    restore_entry = async.void(function()
      local item = view:infer_cur_file()
      if not item or not item.commit or not item.commit.hash then
        return
      end

      local bufid = utils.find_file_buffer(item.path)

      if bufid and vim.bo[bufid].modified then
        utils.err("The file is open with unsaved changes! Aborting file restoration.")
        return
      end

      await(vcs_utils.restore_file(view.adapter, item.path, item.kind, item.commit.hash))
    end),
  }
end
