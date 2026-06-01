local config = require("diffview.config")
local hl = require("diffview.hl")
local utils = require("diffview.utils")

local api = vim.api
local pl = utils.path

local selection_signs_ns = api.nvim_create_namespace("diffview_selection_signs")

---Check whether any configured selection sign is wide (>= 2 display cells).
---When true, sign_column mode adds a padding space between the sign column
---and the buffer text so that wide characters don't crowd the status letter.
---@param conf DiffviewConfig
---@return boolean
local function has_wide_sign(conf)
  local signs = conf.signs
  for _, s in ipairs({
    signs.selected_file,
    signs.unselected_file,
    signs.selected_dir,
    signs.partially_selected_dir,
    signs.unselected_dir,
  }) do
    if vim.fn.strdisplaywidth(s) >= 2 then
      return true
    end
  end
  return false
end

---Format a folder name, optionally appending a trailing slash.
---@param name string
---@param tree_options table
---@return string
local function format_folder_name(name, tree_options)
  return name .. (tree_options.folder_trailing_slash and "/" or "")
end

---Render the file count annotation for a collapsed folder.
---@param comp table  RenderComponent-like object supporting add_text().
---@param node table  Tree node whose leaves() will be counted.
---@param tree_options table  Config tree_options table.
local function render_folder_count(comp, node, tree_options)
  if tree_options.folder_count_style == "none" then
    return
  end

  if tree_options.folder_count_style == "grouped" then
    local leaves = node:leaves()
    local status_counts = {}
    for _, leaf in ipairs(leaves) do
      local s = leaf.data.status or "?"
      status_counts[s] = (status_counts[s] or 0) + 1
    end

    -- Sort status letters for consistent display order.
    local statuses = vim.tbl_keys(status_counts)
    table.sort(statuses)

    comp:add_text(" (", "DiffviewDim1")
    for i, s in ipairs(statuses) do
      if i > 1 then
        comp:add_text(" ", "DiffviewDim1")
      end
      comp:add_text(tostring(status_counts[s]) .. hl.get_status_icon(s), hl.get_git_hl(s))
    end
    comp:add_text(")", "DiffviewDim1")
  else
    local file_count = #node:leaves()
    comp:add_text(" (" .. file_count .. ")", "DiffviewDim1")
  end
end

---@param conf DiffviewConfig
---@param panel FilePanel
---@param comp  RenderComponent
---@param show_path boolean
---@param depth integer|nil
---@param sign_pad boolean|nil  Pad after sign column for wide signs.
local function render_file(conf, panel, comp, show_path, depth, sign_pad)
  ---@type FileEntry
  local file = comp.context

  local show_marks = conf.file_panel.mark_placement ~= "sign_column"
    and (conf.file_panel.always_show_marks or panel:has_any_selections())

  if sign_pad then
    comp:add_text(" ")
  end
  comp:add_text(hl.get_status_icon(file.status) .. " ", hl.get_git_hl(file.status))

  if show_marks then
    local mark, mark_hl
    if panel:is_selected(file) then
      mark = conf.signs.selected_file
      mark_hl = "DiffviewFilePanelMarked"
    else
      mark = conf.signs.unselected_file
    end

    if depth then
      comp:add_text(string.rep(" ", depth * 2))
    end

    comp:add_text(mark .. " ", mark_hl)
  else
    if depth then
      comp:add_text(string.rep(" ", depth * 2 + 2))
    end
  end

  local icon, icon_hl = hl.get_file_icon(file.basename, file.extension)
  comp:add_text(icon, icon_hl)

  local name_hl = file.active and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName"
  local path_style = show_path and conf.file_panel.list_options.path_style or nil

  if path_style == "full" and #file.parent_path > 0 then
    comp:add_text(file.parent_path .. "/", name_hl)
  end

  comp:add_text(file.basename, name_hl)

  if file.stats then
    if file.stats.additions then
      comp:add_text(" ")
      comp:add_text(tostring(file.stats.additions), "DiffviewFilePanelInsertions")
      comp:add_text(", ")
      comp:add_text(tostring(file.stats.deletions), "DiffviewFilePanelDeletions")
    elseif file.stats.conflicts then
      local has_conflicts = file.stats.conflicts > 0
      comp:add_text(
        " " .. (has_conflicts and file.stats.conflicts or conf.signs.done),
        has_conflicts and "DiffviewFilePanelConflicts" or "DiffviewFilePanelInsertions"
      )
    end
  end

  if file.kind == "conflicting" and not (file.stats and file.stats.conflicts) then
    comp:add_text(" !", "DiffviewFilePanelConflicts")
  end

  if show_path and path_style ~= "full" then
    comp:add_text(" " .. file.parent_path, "DiffviewFilePanelPath")
  end

  comp:ln()
end

---@param conf DiffviewConfig
---@param panel FilePanel
---@param comp RenderComponent
local function render_file_list(conf, panel, comp, sign_pad)
  for _, file_comp in ipairs(comp.components) do
    render_file(conf, panel, file_comp, true, nil, sign_pad)
  end
end

---@param ctx DirData
---@param tree_options DiffviewTreeOptions
---@return string
local function get_dir_status_text(ctx, tree_options)
  local folder_statuses = tree_options.folder_statuses

  if folder_statuses == "always" or (folder_statuses == "only_folded" and ctx.collapsed) then
    return ctx.status
  end

  return " "
end

---@param conf DiffviewConfig
---@param panel FilePanel
---@param depth integer
---@param comp RenderComponent
---@param sign_pad boolean|nil  Pad after sign column for wide signs.
local function render_file_tree_recurse(conf, panel, depth, comp, sign_pad)
  if comp.name == "file" then
    render_file(conf, panel, comp, false, depth, sign_pad)
    return
  end

  if comp.name ~= "directory" then
    return
  end

  -- Directory component structure:
  -- {
  --   name = "directory",
  --   context = <DirData>,
  --   { name = "dir_name" },
  --   { name = "items", ...<files> },
  -- }

  local dir = comp.components[1]
  local items = comp.components[2]
  local ctx = comp.context --[[@as DirData ]]

  local show_marks = conf.file_panel.mark_placement ~= "sign_column"
    and (conf.file_panel.always_show_marks or panel:has_any_selections())

  if show_marks then
    local sel_state = panel:dir_selection_state(ctx)
    local sel_mark ---@type string
    local sel_mark_hl ---@type string?

    if sel_state == "all" then
      sel_mark = conf.signs.selected_dir
      sel_mark_hl = "DiffviewFilePanelMarked"
    elseif sel_state == "some" then
      sel_mark = conf.signs.partially_selected_dir
      sel_mark_hl = "DiffviewFilePanelMarked"
    else
      sel_mark = conf.signs.unselected_dir
    end

    -- Place the selection mark just before the fold indicator, stealing 1 char
    -- from indent (depth > 0) or from the status trailing space (depth 0).
    if depth > 0 then
      dir:add_text(
        hl.get_status_icon(get_dir_status_text(ctx, conf.file_panel.tree_options)) .. " ",
        hl.get_git_hl(ctx.status)
      )
      dir:add_text(string.rep(" ", depth * 2 - 1))
    else
      dir:add_text(
        hl.get_status_icon(get_dir_status_text(ctx, conf.file_panel.tree_options)),
        hl.get_git_hl(ctx.status)
      )
    end
    dir:add_text(sel_mark, sel_mark_hl)
  else
    if sign_pad then
      dir:add_text(" ")
    end
    dir:add_text(
      hl.get_status_icon(get_dir_status_text(ctx, conf.file_panel.tree_options)) .. " ",
      hl.get_git_hl(ctx.status)
    )
    dir:add_text(string.rep(" ", depth * 2))
  end

  dir:add_text(ctx.collapsed and conf.signs.fold_closed or conf.signs.fold_open, "DiffviewNonText")

  if conf.use_icons then
    dir:add_text(
      " " .. (ctx.collapsed and conf.icons.folder_closed or conf.icons.folder_open) .. " ",
      "DiffviewFolderSign"
    )
  end

  local tree_options = conf.file_panel.tree_options
  dir:add_text(format_folder_name(ctx.name, tree_options), "DiffviewFolderName")
  -- Show file count when folder is collapsed.
  if ctx.collapsed and ctx._node then
    render_folder_count(dir, ctx._node, tree_options)
  end
  dir:ln()

  if not ctx.collapsed then
    for _, item in ipairs(items.components) do
      render_file_tree_recurse(conf, panel, depth + 1, item, sign_pad)
    end
  end
end

---@param conf DiffviewConfig
---@param panel FilePanel
---@param comp RenderComponent
local function render_file_tree(conf, panel, comp, sign_pad)
  for _, c in ipairs(comp.components) do
    render_file_tree_recurse(conf, panel, 0, c, sign_pad)
  end
end

---@param conf DiffviewConfig
---@param panel FilePanel
---@param listing_style "list"|"tree"
---@param comp RenderComponent
local function render_files(conf, panel, listing_style, comp)
  local sign_pad = conf.file_panel.mark_placement == "sign_column" and has_wide_sign(conf)
  if listing_style == "list" then
    return render_file_list(conf, panel, comp, sign_pad)
  end
  render_file_tree(conf, panel, comp, sign_pad)
end

-- -----------------------------------------------------------------------
-- Sign column selection marks
-- -----------------------------------------------------------------------

---Recursively place selection signs on file and directory components.
---@param conf DiffviewConfig
---@param panel FilePanel
---@param comp RenderComponent
local function place_signs_recurse(conf, panel, comp)
  if comp.name == "file" then
    if comp.lstart >= 0 and comp.lstart < comp.lend then
      local sign_text, sign_hl
      if panel:is_selected(comp.context) then
        sign_text = conf.signs.selected_file
        sign_hl = "DiffviewFilePanelMarked"
      else
        sign_text = conf.signs.unselected_file
      end
      api.nvim_buf_set_extmark(panel.bufid, selection_signs_ns, comp.lstart, 0, {
        sign_text = sign_text,
        sign_hl_group = sign_hl,
      })
    end
    return
  end

  if comp.name == "directory" then
    local dir_name = comp.components[1]
    local items = comp.components[2]

    if dir_name and dir_name.lstart >= 0 and dir_name.lstart < dir_name.lend then
      local sel_state = panel:dir_selection_state(comp.context)
      local sign_text, sign_hl

      if sel_state == "all" then
        sign_text = conf.signs.selected_dir
        sign_hl = "DiffviewFilePanelMarked"
      elseif sel_state == "some" then
        sign_text = conf.signs.partially_selected_dir
        sign_hl = "DiffviewFilePanelMarked"
      else
        sign_text = conf.signs.unselected_dir
      end

      api.nvim_buf_set_extmark(panel.bufid, selection_signs_ns, dir_name.lstart, 0, {
        sign_text = sign_text,
        sign_hl_group = sign_hl,
      })
    end

    if items then
      for _, child in ipairs(items.components) do
        place_signs_recurse(conf, panel, child)
      end
    end
    return
  end

  -- Generic container: recurse into children.
  if comp.components then
    for _, child in ipairs(comp.components) do
      place_signs_recurse(conf, panel, child)
    end
  end
end

---Place selection marks as signs in the sign column.
---Called after the buffer has been written by the renderer so that
---component lstart/lend values are available.
---@param panel FilePanel
local function place_selection_signs(panel)
  if not panel:buf_loaded() then
    return
  end

  -- Always clear existing signs so that switching from sign_column to inline
  -- does not leave stale extmarks behind.
  api.nvim_buf_clear_namespace(panel.bufid, selection_signs_ns, 0, -1)

  local conf = config.get_config()
  if conf.file_panel.mark_placement ~= "sign_column" then
    return
  end
  if not panel.components then
    return
  end

  local show_marks = conf.file_panel.always_show_marks or panel:has_any_selections()

  if not show_marks then
    return
  end

  for _, section in ipairs({ "conflicting", "working", "staged" }) do
    local files_comp = panel.components[section].files.comp
    for _, child in ipairs(files_comp.components) do
      place_signs_recurse(conf, panel, child)
    end
  end
end

---@param panel FilePanel
local function render_panel(panel)
  if not panel.render_data then
    return
  end

  panel.render_data:clear()
  local conf = config.get_config()
  local width = panel:infer_width()

  local comp = panel.components.path.comp

  if conf.show_root_path then
    comp:add_line(
      pl:truncate(pl:vim_fnamemodify(panel.adapter.ctx.toplevel, ":~"), width - 6),
      "DiffviewFilePanelRootPath"
    )
  end

  if conf.file_panel.show_branch_name then
    local branch_name = panel.adapter:get_branch_name()
    if branch_name then
      comp:add_text("Branch: ", "DiffviewFilePanelPath")
      comp:add_line(branch_name, "DiffviewFilePanelTitle")
    end
  end

  if conf.show_help_hints and panel.help_mapping then
    comp:add_text("Help: ", "DiffviewFilePanelPath")
    comp:add_line(panel.help_mapping, "DiffviewFilePanelCounter")
    comp:add_line()
  end

  if panel.is_loading then
    comp:add_line("  Fetching changes...", "DiffviewDim1")
    return
  end

  if #panel.files.conflicting > 0 then
    comp = panel.components.conflicting.title.comp
    comp:add_text("Conflicts ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.conflicting .. ")", "DiffviewFilePanelCounter")
    comp:ln()

    render_files(conf, panel, panel.listing_style, panel.components.conflicting.files.comp)
    panel.components.conflicting.margin.comp:add_line()
  end

  local has_other_files = #panel.files.conflicting > 0 or #panel.files.staged > 0
  local always_show = conf.file_panel.always_show_sections

  -- Don't show the 'Changes' section if it's empty and we have other visible
  -- sections (unless always_show_sections is enabled).
  if #panel.files.working > 0 or not has_other_files or always_show then
    comp = panel.components.working.title.comp
    comp:add_text("Changes ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.working .. ")", "DiffviewFilePanelCounter")
    comp:ln()

    -- Show friendly message when working tree is clean.
    if #panel.files.working == 0 and not has_other_files then
      panel.components.working.files.comp:add_line("  Working tree clean", "DiffviewDim1")
    elseif #panel.files.working == 0 then
      panel.components.working.files.comp:add_line("  (empty)", "DiffviewDim1")
    else
      render_files(conf, panel, panel.listing_style, panel.components.working.files.comp)
    end
    panel.components.working.margin.comp:add_line()
  end

  if #panel.files.staged > 0 or always_show then
    comp = panel.components.staged.title.comp
    comp:add_text("Staged changes ", "DiffviewFilePanelTitle")
    comp:add_text("(" .. #panel.files.staged .. ")", "DiffviewFilePanelCounter")
    comp:ln()

    if #panel.files.staged == 0 then
      panel.components.staged.files.comp:add_line("  (empty)", "DiffviewDim1")
    else
      render_files(conf, panel, panel.listing_style, panel.components.staged.files.comp)
    end
    panel.components.staged.margin.comp:add_line()
  end

  if panel.rev_pretty_name or (panel.path_args and #panel.path_args > 0) then
    comp = panel.components.info.title.comp
    comp:add_line("Showing changes for:", "DiffviewFilePanelTitle")

    comp = panel.components.info.entries.comp

    -- Truncate the revision name from the tail so the start of the hash
    -- stays visible.
    if panel.rev_pretty_name then
      comp:add_line(
        utils.str_trunc(panel.rev_pretty_name, math.max(width - 5, 1)),
        "DiffviewFilePanelPath"
      )
    end

    for _, arg in ipairs(panel.path_args or {}) do
      local relpath = pl:relative(arg, panel.adapter.ctx.toplevel)
      if relpath == "" then
        relpath = "."
      end
      comp:add_line(pl:truncate(relpath, width - 5), "DiffviewFilePanelPath")
    end
  end
end

return setmetatable({
  place_selection_signs = place_selection_signs,
  -- Exposed for testing only.
  _test = {
    format_folder_name = format_folder_name,
    has_wide_sign = has_wide_sign,
    render_file = render_file,
    render_folder_count = render_folder_count,
    selection_signs_ns = selection_signs_ns,
  },
}, {
  __call = function(_, panel)
    render_panel(panel)
  end,
})
