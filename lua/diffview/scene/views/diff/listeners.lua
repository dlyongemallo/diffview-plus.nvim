local async = require("diffview.async")
local lazy = require("diffview.lazy")

local EventName = lazy.access("diffview.events", "EventName") ---@type EventName|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local actions = lazy.require("diffview.actions") --[[@as DiffviewActions ]]
local config = lazy.require("diffview.config") ---@module "diffview.config"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"
local vcs_utils = lazy.require("diffview.vcs.utils") ---@module "diffview.vcs.utils"

local api = vim.api
local await = async.await

---@param view DiffView
return function(view)
  -- Re-arm `auto_close_on_empty` retry after a deferred close. Set when the
  -- guarded close aborts (dirty stage buffer); cleared when the retry either
  -- succeeds or no longer applies (working/conflicting non-empty).
  local auto_close_pending = false

  ---Run the `auto_close_on_empty` policy. Closes the view when there are no
  ---working/conflicting entries left and stage buffers are clean. If the
  ---guarded close aborts, set the retry flag so the next stage save (via
  ---`buf_write_post`) re-evaluates.
  ---
  ---When `silent` is true, the dirty-stage gate is pre-checked and the close
  ---call is skipped if it would fail. The BufWritePost retry path uses this
  ---to avoid re-warning on every save: the autocmd fires globally without
  ---buffer context, so unrelated saves would otherwise repeatedly trip the
  ---gate while a stage buffer stays dirty.
  ---@param silent? boolean
  local function maybe_auto_close(silent)
    if not config.get_config().auto_close_on_empty then
      auto_close_pending = false
      return
    end
    if #view.files.working ~= 0 or #view.files.conflicting ~= 0 then
      auto_close_pending = false
      return
    end
    if silent and #view:_modified_stage_paths() > 0 then
      auto_close_pending = true
      return
    end
    if view:close({ force = false }) ~= false then
      auto_close_pending = false
      lib.dispose_view(view)
    else
      auto_close_pending = true
    end
  end

  return {
    tab_enter = function()
      local file = view.panel.cur_file
      if file then
        -- Suppress highlight_file to avoid expanding collapsed directories;
        -- the panel cursor is restored separately below.
        view:set_file(file, false, false)
      end

      view:restore_panel_cursor()

      if view.ready then
        view:update_files()
      end
    end,
    tab_leave = function()
      local file = view.panel.cur_file
      view:save_panel_cursor()

      if file then
        file.layout:detach_files()
      end

      for _, f in view.panel.files:iter() do
        f.layout:restore_winopts()
      end
    end,
    buf_write_post = function()
      -- Saving a stage buffer clears the dirty flag that aborted a previous
      -- guarded auto-close; retry afterwards so `auto_close_on_empty` doesn't
      -- strand the user in an empty view. Use the silent path: the original
      -- action already warned when the close was first deferred, and
      -- BufWritePost fires for every save (any buffer, any tab), so a
      -- non-silent retry would re-warn on every unrelated save until the
      -- stage buffer is finally saved.
      --
      -- The retry must run *after* the `update_files` refresh so a save that
      -- reintroduces working/conflicting entries (e.g. user edited a tracked
      -- file) is reflected in `view.files` before the gate is re-evaluated;
      -- otherwise the close would fire against pre-refresh state.
      local function retry_auto_close()
        if auto_close_pending then
          maybe_auto_close(true)
        end
      end

      if view.adapter:has_local(view.left, view.right) then
        view.update_needed = true
        if api.nvim_get_current_tabpage() == view.tabpage then
          view:update_files(nil, retry_auto_close)
          return
        end
      end

      -- No refresh scheduled (different tabpage, or this view's range doesn't
      -- track local). The file list can't change from this save, so a sync
      -- retry is safe.
      retry_auto_close()
    end,
    file_open_new = function(_, entry)
      -- `file_open_new` is bridged via `DiffviewGlobal.emitter` →
      -- current view's emitter, so while multiple views are restoring
      -- in parallel an event from view A can arrive bound to view B's
      -- closure. Drop events that aren't ours.
      if view.cur_entry ~= entry then
        return
      end

      -- Session-restored entries: replay the saved cursor + viewport
      -- instead of jumping to the first hunk. `restore_main_view` is
      -- one-shot, so re-visits in the same nvim run fall through.
      if view:restore_main_view(entry.path) then
        -- Per-invocation `--selected-row` is an explicit "land me here"
        -- request, so it focuses the main diff window on the targeted
        -- file regardless of `focus_diff`. Session restore reuses the
        -- `cursor_map` plumbing but must not yank focus, so we
        -- discriminate by `selected_row`: only the CLI path sets it.
        local opts = view.options
        if opts and opts.selected_row and opts.selected_file == entry.path then
          local win = view.cur_layout and view.cur_layout:get_main_win()
          if win and win.id and api.nvim_win_is_valid(win.id) then
            api.nvim_set_current_win(win.id)
          end
          opts.selected_row = nil
        end
        return
      end
      actions.jump_to_first_change(view)
    end,
    ---@diagnostic disable-next-line: unused-local
    files_updated = function(_, files)
      view.initialized = true
      -- File entries may be replaced on update; prune stale selections.
      view.panel:prune_selections()
    end,
    close = function()
      if view.panel:is_focused() then
        view.panel:close()
      elseif view:is_cur_tabpage() then
        -- Don't close the view if a floating window is focused; the float's
        -- own close listener should handle it.
        local win_conf = api.nvim_win_get_config(0)
        if win_conf.relative == "" then
          view:close({ force = false })
        end
      end
    end,
    select_first_entry = function()
      local files = view.panel:ordered_file_list()
      if files and #files > 0 then
        view:set_file(files[1], false, true)
      end
    end,
    select_last_entry = function()
      local files = view.panel:ordered_file_list()
      if files and #files > 0 then
        view:set_file(files[#files], false, true)
      end
    end,
    select_next_entry = function()
      view:next_file(true)
    end,
    select_prev_entry = function()
      view:prev_file(true)
    end,
    next_entry = function()
      view.panel:highlight_next_file()
    end,
    prev_entry = function()
      view.panel:highlight_prev_file()
    end,
    select_entry = function()
      if view.panel:is_open() then
        ---@type any
        local item = view.panel:get_item_at_cursor()
        if item then
          if type(item.collapsed) == "boolean" then
            view.panel:toggle_item_fold(item)
          else
            view:set_file(item, false)
          end
        end
      end
    end,
    toggle_select_entry = function()
      if not view.panel:is_open() then
        return
      end

      -- Visual-mode: toggle all files in the selected line range.
      local mode = api.nvim_get_mode().mode
      if mode == "v" or mode == "V" or mode == "\22" then
        local start_line = vim.fn.line("v")
        local end_line = vim.fn.line(".")
        if start_line > end_line then
          start_line, end_line = end_line, start_line
        end

        view.panel:batch_selection(function()
          for line = start_line, end_line do
            local item = view.panel:get_item_at_line(line)
            if item and type(item.collapsed) ~= "boolean" then
              ---@cast item FileEntry
              view.panel:toggle_selection(item)
            end
          end
        end)

        -- Exit visual mode.
        api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        view.panel:render()
        view.panel:redraw()
        return
      end

      ---@type any
      local item = view.panel:get_item_at_cursor()
      if not item then
        return
      end

      if type(item.collapsed) == "boolean" then
        -- Directory: select all if any child is unselected, else deselect all.
        ---@cast item DirData
        local node = item._node
        if not node then
          return
        end

        local leaves = node:leaves()
        local all_selected = true
        for _, leaf in ipairs(leaves) do
          if leaf.data and not view.panel:is_selected(leaf.data) then
            all_selected = false
            break
          end
        end

        view.panel:batch_selection(function()
          for _, leaf in ipairs(leaves) do
            if leaf.data then
              if all_selected then
                view.panel:deselect_file(leaf.data)
              else
                view.panel:select_file(leaf.data)
              end
            end
          end
        end)
      else
        ---@cast item FileEntry
        view.panel:toggle_selection(item)
      end

      view.panel:render()
      view.panel:redraw()
      view.panel:highlight_next_file()
    end,
    clear_select_entries = function()
      if not view.panel:is_open() then
        return
      end
      view.panel:clear_selections()
      view.panel:render()
      view.panel:redraw()
    end,
    focus_entry = function()
      if view.panel:is_open() then
        ---@type any
        local item = view.panel:get_item_at_cursor()
        if item then
          if type(item.collapsed) == "boolean" then
            view.panel:toggle_item_fold(item)
          else
            view:set_file(item, true)
          end
        end
      end
    end,
    open_commit_log = function()
      if view.left.type == RevType.STAGE and view.right.type == RevType.LOCAL then
        utils.info("Changes not committed yet. No log available for these changes.")
        return
      end

      local range = view.adapter.Rev.to_range(view.left, view.right)

      if range then
        view.commit_log_panel:update(range)
      end
    end,
    toggle_stage_entry = function()
      if not (view.left.type == RevType.STAGE and view.right.type == RevType.LOCAL) then
        return
      end

      local selected = view.panel:get_selected_files()

      if #selected > 0 then
        -- Batch operation on selected files.
        local to_stage = {}
        local to_unstage = {}

        for _, file in ipairs(selected) do
          if file.kind == "working" or file.kind == "conflicting" then
            to_stage[#to_stage + 1] = file.path
          elseif file.kind == "staged" then
            to_unstage[#to_unstage + 1] = file.path
          end
        end

        if #to_stage == 0 and #to_unstage == 0 then
          return
        end

        local failed = {}

        if #to_stage > 0 then
          if not view.adapter:add_files(to_stage) then
            -- Batch failed; try one at a time to identify which files failed.
            for _, path in ipairs(to_stage) do
              if not view.adapter:add_files({ path }) then
                failed[#failed + 1] = path
              end
            end
          end
        end

        if #to_unstage > 0 then
          if not view.adapter:reset_files(to_unstage) then
            for _, path in ipairs(to_unstage) do
              if not view.adapter:reset_files({ path }) then
                failed[#failed + 1] = path
              end
            end
          end
        end

        if #failed > 0 then
          utils.err(
            ("Failed to stage/unstage %d file(s): %s"):format(#failed, table.concat(failed, ", "))
          )
        end

        view.panel:clear_selections()
      else
        -- Single file operation (existing behaviour).
        local item = view:infer_cur_file(true)
        if not item then
          return
        end

        local success
        if item.kind == "working" or item.kind == "conflicting" then
          success = view.adapter:add_files({ item.path })
        elseif item.kind == "staged" then
          success = view.adapter:reset_files({ item.path })
        end

        if not success then
          utils.err(("Failed to stage/unstage file: '%s'"):format(item.path))
          return
        end

        if type(item.collapsed) == "boolean" then
          ---@cast item DirData
          ---@type FileTree
          local tree

          if item.kind == "conflicting" then
            tree = view.panel.files.conflicting_tree
          elseif item.kind == "working" then
            tree = view.panel.files.working_tree
          else
            tree = view.panel.files.staged_tree
          end

          ---@type Node
          local item_node
          tree.root:deep_some(function(node, _, _)
            if node == item._node then
              item_node = node
              return true
            end
          end)

          if item_node then
            local next_leaf = item_node:next_leaf()
            if next_leaf then
              view:set_file(next_leaf.data)
            else
              view:set_file(view.panel.files[1])
            end
          end
        else
          view.panel:set_cur_file(item)
          view:next_file()
        end
      end

      view:update_files(
        nil,
        vim.schedule_wrap(function()
          view.panel:highlight_cur_file()
          maybe_auto_close()
        end)
      )
      view.emitter:emit(EventName.FILES_STAGED, view)
    end,
    stage_all = function()
      local args = vim.tbl_map(function(file)
        return file.path
      end, utils.vec_join(view.files.working, view.files.conflicting))

      if #args > 0 then
        local success = view.adapter:add_files(args)

        if not success then
          utils.err("Failed to stage files!")
          return
        end

        view:update_files(nil, function()
          view.panel:highlight_cur_file()
          maybe_auto_close()
        end)
        view.emitter:emit(EventName.FILES_STAGED, view)
      end
    end,
    unstage_all = function()
      local success = view.adapter:reset_files()

      if not success then
        utils.err("Failed to unstage files!")
        return
      end

      view:update_files()
      view.emitter:emit(EventName.FILES_STAGED, view)
    end,
    restore_entry = async.void(function()
      if view.right.type ~= RevType.LOCAL then
        utils.err("The right side of the diff is not local! Aborting file restoration.")
        return
      end

      local commit
      if view.left.type ~= RevType.STAGE then
        commit = view.left.commit
      end

      local selected = view.panel:get_selected_files()

      if #selected > 0 then
        -- Batch restore selected files.
        local restored_count = 0
        for _, file in ipairs(selected) do
          local bufid = utils.find_file_buffer(file.path)
          if bufid and vim.bo[bufid].modified then
            utils.warn(("Skipping '%s': file has unsaved changes."):format(file.path))
          else
            await(vcs_utils.restore_file(view.adapter, file.path, file.kind, commit))
            restored_count = restored_count + 1
          end
        end

        view.panel:clear_selections()

        if restored_count > 0 then
          utils.info(("Restored %d file(s)."):format(restored_count))
        end
      else
        -- Single item restore (existing behaviour).
        local item = view:infer_cur_file(true)
        if not item then
          return
        end

        if type(item.collapsed) == "boolean" then
          ---@cast item DirData
          local node = item._node
          if not node then
            return
          end

          local leaves = node:leaves()
          local restored_count = 0
          for _, leaf in ipairs(leaves) do
            local file = leaf.data
            if file and file.path then
              local bufid = utils.find_file_buffer(file.path)
              if bufid and vim.bo[bufid].modified then
                utils.warn(("Skipping '%s': file has unsaved changes."):format(file.path))
              else
                await(vcs_utils.restore_file(view.adapter, file.path, file.kind, commit))
                restored_count = restored_count + 1
              end
            end
          end

          if restored_count > 0 then
            utils.info(("Restored %d file(s)."):format(restored_count))
          end
        else
          local bufid = utils.find_file_buffer(item.path)
          if bufid and vim.bo[bufid].modified then
            utils.err("The file is open with unsaved changes! Aborting file restoration.")
            return
          end

          await(vcs_utils.restore_file(view.adapter, item.path, item.kind, commit))
        end
      end

      view:update_files()
    end),
    listing_style = function()
      if view.panel.listing_style == "list" then
        view.panel.listing_style = "tree"
      else
        view.panel.listing_style = "list"
      end
      view.panel:update_components()
      view.panel:render()
      view.panel:redraw()
    end,
    toggle_flatten_dirs = function()
      view.panel.tree_options.flatten_dirs = not view.panel.tree_options.flatten_dirs
      view.panel:update_components()
      view.panel:render()
      view.panel:redraw()
    end,
    toggle_untracked = function()
      -- Only applicable to working tree comparisons.
      if not (view.left.type == RevType.STAGE and view.right.type == RevType.LOCAL) then
        utils.info("Toggle untracked is only available when comparing staged vs working tree.")
        return
      end

      view.options.show_untracked = not view.options.show_untracked
      local state = view.options.show_untracked and "shown" or "hidden"
      utils.info(("Untracked files: %s"):format(state))
      view:update_files()
    end,
    focus_files = function()
      view.panel:focus()
    end,
    toggle_files = function()
      view.panel:toggle(true)
    end,
    refresh_files = function(_, opts)
      view:update_files(opts)
    end,
    open_all_folds = function()
      if not view.panel:is_focused() or view.panel.listing_style ~= "tree" then
        return
      end

      for _, file_set in ipairs({
        view.panel.components.conflicting.files,
        view.panel.components.working.files,
        view.panel.components.staged.files,
      }) do
        file_set.comp:deep_some(function(comp, _, _)
          if comp.name == "directory" then
            view.panel:set_dir_collapsed(comp.context --[[@as DirData ]], false)
          end
        end)
      end

      view.panel:render()
      view.panel:redraw()
    end,
    close_all_folds = function()
      if not view.panel:is_focused() or view.panel.listing_style ~= "tree" then
        return
      end

      for _, file_set in ipairs({
        view.panel.components.conflicting.files,
        view.panel.components.working.files,
        view.panel.components.staged.files,
      }) do
        file_set.comp:deep_some(function(comp, _, _)
          if comp.name == "directory" then
            view.panel:set_dir_collapsed(comp.context --[[@as DirData ]], true)
          end
        end)
      end

      view.panel:render()
      view.panel:redraw()
    end,
    open_fold = function()
      if not view.panel:is_focused() then
        return
      end
      local dir = view.panel:get_dir_at_cursor()
      if dir then
        view.panel:set_item_fold(dir, true)
      end
    end,
    close_fold = function()
      if not view.panel:is_focused() then
        return
      end
      local dir, comp = view.panel:get_dir_at_cursor()
      if dir and comp then
        if not dir.collapsed then
          view.panel:set_item_fold(dir, false)
        else
          local dir_parent = utils.tbl_access(comp, "parent.parent")
          if dir_parent and dir_parent.name == "directory" then
            view.panel:set_item_fold(dir_parent.context, false)
          end
        end
      end
    end,
    toggle_fold = function()
      if not view.panel:is_focused() then
        return
      end
      local dir = view.panel:get_dir_at_cursor()
      if dir then
        view.panel:toggle_item_fold(dir)
      end
    end,
  }
end
