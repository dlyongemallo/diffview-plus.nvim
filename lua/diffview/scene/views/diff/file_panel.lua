local config = require("diffview.config")
local oop = require("diffview.oop")
local renderer = require("diffview.renderer")
local utils = require("diffview.utils")
local Panel = require("diffview.ui.panel").Panel
local api = vim.api
local M = {}

---@class FilePanel : Panel
---@field adapter VCSAdapter
---@field files FileDict
---@field path_args string[]
---@field rev_pretty_name string|nil
---@field cur_file FileEntry
---@field listing_style "list"|"tree"
---@field tree_options DiffviewTreeOptions
---@field render_data RenderData
---@field components CompStruct
---@field constrain_cursor function
---@field help_mapping string
---@field selected_files table<string, true>
---@field hide_selected boolean
---@field on_selection_changed fun(selected_files: table<string, true>)?
local FilePanel = oop.create_class("FilePanel", Panel)

FilePanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
    opt = { method = "prepend" },
  },
})

FilePanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewFiles",
})

---FilePanel constructor.
---@param adapter VCSAdapter
---@param files FileEntry[]
---@param path_args string[]
function FilePanel:init(adapter, files, path_args, rev_pretty_name)
  local conf = config.get_config()
  self:super({
    config = conf.file_panel.win_config,
    bufname = "DiffviewFilePanel",
  })
  self.adapter = adapter
  self.files = files
  self.path_args = path_args
  self.rev_pretty_name = rev_pretty_name
  self.listing_style = conf.file_panel.listing_style
  self.tree_options = conf.file_panel.tree_options
  self.selected_files = {}
  self.hide_selected = false
  self.is_loading = true

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })
end

---@override
function FilePanel:open()
  FilePanel.super_class.open(self)
  local conf = self:get_config()
  if not (conf.type == "split" and conf.width == "auto") then
    vim.cmd("wincmd =")
  end
  self:highlight_cur_file()
end

function FilePanel:setup_buffer()
  local conf = self:apply_keymaps("file_panel", { nowait = true })
  local help_keymap = config.find_help_keymap(conf.keymaps.file_panel)
  if help_keymap then
    self.help_mapping = help_keymap[2]
  end
end

---@param files FileEntry[]
---@return table
local function build_file_list(files)
  local comp = { name = "files" }
  for _, file in ipairs(files) do
    comp[#comp + 1] = { name = "file", context = file }
  end
  return comp
end

---@param tree any
---@param tree_options table
---@return table
local function build_file_tree(tree, tree_options)
  tree:update_statuses()
  return utils.tbl_merge(
    { name = "files" },
    tree:create_comp_schema({ flatten_dirs = tree_options.flatten_dirs })
  )
end

function FilePanel:update_components()
  if not self.render_data then
    return
  end

  local conflicting_files
  local working_files
  local staged_files

  if self.listing_style == "list" then
    conflicting_files = build_file_list(self.files.conflicting)
    working_files = build_file_list(self.files.working)
    staged_files = build_file_list(self.files.staged)
  elseif self.listing_style == "tree" then
    conflicting_files = build_file_tree(self.files.conflicting_tree, self.tree_options)
    working_files = build_file_tree(self.files.working_tree, self.tree_options)
    staged_files = build_file_tree(self.files.staged_tree, self.tree_options)
  end

  self.components = self.render_data:create_component({
    { name = "path" },
    {
      name = "conflicting",
      { name = "title" },
      conflicting_files,
      { name = "margin" },
    },
    {
      name = "working",
      { name = "title" },
      working_files,
      { name = "margin" },
    },
    {
      name = "staged",
      { name = "title" },
      staged_files,
      { name = "margin" },
    },
    { name = "hidden_hint" },
    {
      name = "info",
      { name = "title" },
      { name = "entries" },
    },
  }) --[[@as CompStruct ]]

  self.constrain_cursor = renderer.create_cursor_constraint({
    self.components.conflicting.files.comp,
    self.components.working.files.comp,
    self.components.staged.files.comp,
  })
end

---@return FileEntry[]
function FilePanel:ordered_file_list()
  if self.listing_style == "list" then
    local list = {}

    for _, file in self.files:iter() do
      if not (self.hide_selected and self:is_selected(file)) then
        list[#list + 1] = file
      end
    end

    return list
  else
    local nodes = utils.vec_join(
      self.files.conflicting_tree.root:leaves(),
      self.files.working_tree.root:leaves(),
      self.files.staged_tree.root:leaves()
    )

    local result = {}
    for _, node in ipairs(nodes) do
      if node.data and not (self.hide_selected and self:is_selected(node.data)) then
        result[#result + 1] = node.data
      end
    end
    return result --[[@as vector ]]
  end
end

---Toggle the hide-selected filter.
---When active, marked (reviewed) files are hidden from the file panel.
function FilePanel:toggle_hide_selected()
  self.hide_selected = not self.hide_selected
end

---Count selected files across every kind.
---@return integer
function FilePanel:count_selected()
  local count = 0
  for _, file in self.files:iter() do
    if self:is_selected(file) then
      count = count + 1
    end
  end
  return count
end

---Count visible (non-hidden) files for a given kind.
---@param kind "conflicting"|"working"|"staged"
---@return integer visible, integer total
function FilePanel:count_visible(kind)
  local files = self.files[kind]
  if not files then
    return 0, 0
  end
  local total = #files
  if not self.hide_selected then
    return total, total
  end
  local hidden = 0
  for _, file in ipairs(files) do
    if self:is_selected(file) then
      hidden = hidden + 1
    end
  end
  return total - hidden, total
end

function FilePanel:set_cur_file(file)
  if self.cur_file then
    self.cur_file:set_active(false)
  end

  self.cur_file = file
  if self.cur_file then
    self.cur_file:set_active(true)
  end
end

function FilePanel:prev_file()
  local files = self:ordered_file_list()
  if not self.cur_file and self.files:len() > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end

  local i = utils.vec_indexof(files, self.cur_file)
  if i ~= -1 then
    local new_idx
    if config.get_config().wrap_entries then
      new_idx = (i - vim.v.count1 - 1) % #files + 1
    else
      new_idx = math.max(i - vim.v.count1, 1)
      if new_idx == i then
        return
      end
    end
    self:set_cur_file(files[new_idx])
    return self.cur_file
  end
end

function FilePanel:next_file()
  local files = self:ordered_file_list()
  if not self.cur_file and self.files:len() > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end

  local i = utils.vec_indexof(files, self.cur_file)
  if i ~= -1 then
    local new_idx
    if config.get_config().wrap_entries then
      new_idx = (i + vim.v.count1 - 1) % #files + 1
    else
      new_idx = math.min(i + vim.v.count1, #files)
      if new_idx == i then
        return
      end
    end
    self:set_cur_file(files[new_idx])
    return self.cur_file
  end
end

---Get the item (file or directory) at a given line number.
---@param line integer 1-based line number
---@return (FileEntry|DirData)?
function FilePanel:get_item_at_line(line)
  local comp = self.components.comp:get_comp_on_line(line)
  if comp and comp.name == "file" then
    return comp.context
  elseif comp and comp.name == "dir_name" then
    return comp.parent.context
  end
end

---Get the file entry under the cursor.
---@return (FileEntry|DirData)?
function FilePanel:get_item_at_cursor()
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local line = api.nvim_win_get_cursor(self:cursor_winid())[1]
  return self:get_item_at_line(line)
end

---Get the parent directory data of the item under the cursor.
---@return DirData?
---@return RenderComponent?
function FilePanel:get_dir_at_cursor()
  if self.listing_style ~= "tree" then
    return
  end
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local line = api.nvim_win_get_cursor(self:cursor_winid())[1]
  local comp = self.components.comp:get_comp_on_line(line)

  if not comp then
    return
  end

  if comp.name == "dir_name" then
    local dir_comp = comp.parent
    return dir_comp.context, dir_comp
  elseif comp.name == "file" then
    local dir_comp = comp.parent.parent
    return dir_comp.context, dir_comp
  end
end

function FilePanel:highlight_file(file)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  local target_row
  if self.listing_style == "list" then
    for _, file_list in ipairs({
      self.components.conflicting.files,
      self.components.working.files,
      self.components.staged.files,
    }) do
      for _, comp_struct in ipairs(file_list) do
        if file == comp_struct.comp.context then
          target_row = comp_struct.comp.lstart + 1
        end
      end
    end
  else -- tree
    for _, comp_struct in ipairs({
      self.components.conflicting.files,
      self.components.working.files,
      self.components.staged.files,
    }) do
      comp_struct.comp:deep_some(function(cur)
        if file == cur.context then
          local was_concealed = false
          local dir = cur.parent.parent

          while dir and dir.name == "directory" do
            if dir.context and dir.context.collapsed then
              was_concealed = true
              self:set_dir_collapsed(dir.context, false)
            end

            dir = utils.tbl_access(dir, { "parent", "parent" })
          end

          if was_concealed then
            self:render()
            self:redraw()
          end

          target_row = cur.lstart + 1
          return true
        end

        return false
      end)
    end
  end

  for _, w in ipairs(self:cursor_winids()) do
    if target_row then
      utils.set_cursor(w, target_row, 0)
    end
    -- Needed to update the cursorline highlight when the panel is not focused.
    utils.update_win(w)
  end
end

function FilePanel:highlight_cur_file()
  if self.cur_file then
    self:highlight_file(self.cur_file)
  end
end

function FilePanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  local target_row = self.constrain_cursor(self:cursor_winid(), -vim.v.count1)
  for _, w in ipairs(self:cursor_winids()) do
    pcall(api.nvim_win_set_cursor, w, { target_row, 0 })
    utils.update_win(w)
  end
end

function FilePanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  local target_row = self.constrain_cursor(self:cursor_winid(), vim.v.count1)
  for _, w in ipairs(self:cursor_winids()) do
    pcall(api.nvim_win_set_cursor, w, { target_row, 0 })
    utils.update_win(w)
  end
end

function FilePanel:reconstrain_cursor()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  local target_row
  if #self:ordered_file_list() == 0 then
    -- All files may still exist while the hide-reviewed filter leaves no
    -- selectable rows. In that case, use the repository path at the top of
    -- the panel as the stable resting position for the cursor.
    local path_comp = self.components and self.components.path and self.components.path.comp
    target_row = path_comp and math.max(path_comp.lstart + 1, 1) or 1
  else
    target_row = self.constrain_cursor(self:cursor_winid(), 0)
  end

  for _, w in ipairs(self:cursor_winids()) do
    pcall(api.nvim_win_set_cursor, w, { target_row, 0 })
  end
end

---Set collapsed state for a directory, propagating to underlying tree nodes
---so that get_collapsed_state() picks up the correct value for flattened dirs.
---@param item DirData
---@param collapsed boolean
function FilePanel:set_dir_collapsed(item, collapsed)
  item.collapsed = collapsed
  if item._node then
    local node = item._node
    while node do
      if node.data and type(node.data.collapsed) == "boolean" then
        node.data.collapsed = collapsed
      end
      if #node.children == 1 and node.children[1]:has_children() then
        node = node.children[1]
      else
        break
      end
    end
  end
end

---@param item DirData|any
---@param open boolean
function FilePanel:set_item_fold(item, open)
  if type(item.collapsed) == "boolean" and open == item.collapsed then
    self:set_dir_collapsed(item, not open)
    self:render()
    self:redraw()

    if item.collapsed then
      local target_row
      self.components.comp:deep_some(function(comp, _, _)
        if comp.context == item then
          target_row = comp.lstart + 1
          return true
        end
      end)
      if target_row then
        for _, w in ipairs(self:cursor_winids()) do
          utils.set_cursor(w, target_row)
        end
      end
    end
  end
end

function FilePanel:toggle_item_fold(item)
  self:set_item_fold(item, item.collapsed)
end

---Compute a stable key for a file entry that survives object replacement.
---@param file FileEntry
---@return string
function FilePanel.selection_key(file)
  return file.kind .. ":" .. file.path
end

---Suppress selection-change notifications for the duration of `fn`, then
---fire a single notification afterwards if any changes occurred.
---@param fn fun()
function FilePanel:batch_selection(fn)
  self._suppress_notify = true
  self._batch_changed = false
  local ok, err = xpcall(fn, debug.traceback)
  local changed = self._batch_changed
  self._suppress_notify = false
  self._batch_changed = false
  if changed then
    self:_notify_selection_changed()
  end
  if not ok then
    error(err, 0)
  end
end

---Notify listeners that selections have changed.
function FilePanel:_notify_selection_changed()
  if self._suppress_notify then
    self._batch_changed = true
    return
  end
  if self.on_selection_changed then
    self.on_selection_changed(self.selected_files)
  end
end

---Select a file entry.
---@param file FileEntry
function FilePanel:select_file(file)
  self.selected_files[FilePanel.selection_key(file)] = true
  self:_notify_selection_changed()
end

---Deselect a file entry.
---@param file FileEntry
function FilePanel:deselect_file(file)
  self.selected_files[FilePanel.selection_key(file)] = nil
  self:_notify_selection_changed()
end

---Toggle selection for a file entry.
---@param file FileEntry
function FilePanel:toggle_selection(file)
  local key = FilePanel.selection_key(file)
  if self.selected_files[key] then
    self.selected_files[key] = nil
  else
    self.selected_files[key] = true
  end
  self:_notify_selection_changed()
end

---@param file FileEntry
---@return boolean
function FilePanel:is_selected(file)
  return self.selected_files[FilePanel.selection_key(file)] == true
end

---Return true when at least one file is selected.
---@return boolean
function FilePanel:has_any_selections()
  return next(self.selected_files) ~= nil
end

---Return the selection state of a directory's files.
---@param dir_data DirData
---@return "all"|"some"|"none"
function FilePanel:dir_selection_state(dir_data)
  if not dir_data._node then
    return "none"
  end
  local leaves = dir_data._node:leaves()
  if #leaves == 0 then
    return "none"
  end
  local selected, total = 0, 0
  for _, leaf in ipairs(leaves) do
    if leaf.data then
      total = total + 1
      if self:is_selected(leaf.data) then
        selected = selected + 1
      end
    end
  end
  if selected == 0 then
    return "none"
  end
  if selected == total then
    return "all"
  end
  return "some"
end

---Get all currently selected files.
---@return FileEntry[]
function FilePanel:get_selected_files()
  local result = {}
  for _, file in self.files:iter() do
    if self.selected_files[FilePanel.selection_key(file)] then
      result[#result + 1] = file
    end
  end
  return result
end

---Remove selections for files that no longer exist.
function FilePanel:prune_selections()
  local valid_keys = {}
  for _, file in self.files:iter() do
    valid_keys[FilePanel.selection_key(file)] = true
  end
  local changed = false
  for key in pairs(self.selected_files) do
    if not valid_keys[key] then
      self.selected_files[key] = nil
      changed = true
    end
  end
  if changed then
    self:_notify_selection_changed()
  end
end

---Clear all file selections.
function FilePanel:clear_selections()
  local had_selections = next(self.selected_files) ~= nil
  self.selected_files = {}
  if had_selections then
    self:_notify_selection_changed()
  end
end

---@override
function FilePanel:get_autosize_components()
  if not self.components then
    return nil
  end
  return {
    self.components.conflicting.comp,
    self.components.working.comp,
    self.components.staged.comp,
  }
end

function FilePanel:render()
  require("diffview.scene.views.diff.render")(self)
end

function FilePanel:redraw()
  FilePanel.super_class.redraw(self)
  require("diffview.scene.views.diff.render").place_selection_signs(self)
end

M.FilePanel = FilePanel
return M
