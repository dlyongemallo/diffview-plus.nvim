require("diffview.bootstrap")

---@diagnostic disable: deprecated
local EventEmitter = require("diffview.events").EventEmitter
local actions = require("diffview.actions")
local lazy = require("diffview.lazy")

local Diff1 = lazy.access("diffview.scene.layouts.diff_1", "Diff1") ---@type Diff1|LazyModule
local Diff1Inline = lazy.access("diffview.scene.layouts.diff_1_inline", "Diff1Inline") ---@type Diff1Inline|LazyModule
local Diff1InlinePinned =
  lazy.access("diffview.scene.layouts.diff_1_inline_pinned", "Diff1InlinePinned") ---@type Diff1InlinePinned|LazyModule
local Diff1Pinned = lazy.access("diffview.scene.layouts.diff_1_pinned", "Diff1Pinned") ---@type Diff1Pinned|LazyModule
local Diff1Raw = lazy.access("diffview.scene.layouts.diff_1_raw", "Diff1Raw") ---@type Diff1Raw|LazyModule
local Diff2 = lazy.access("diffview.scene.layouts.diff_2", "Diff2") ---@type Diff2|LazyModule
local Diff2Hor = lazy.access("diffview.scene.layouts.diff_2_hor", "Diff2Hor") ---@type Diff2Hor|LazyModule
local Diff2HorPinned = lazy.access("diffview.scene.layouts.diff_2_hor_pinned", "Diff2HorPinned") ---@type Diff2HorPinned|LazyModule
local Diff2Ver = lazy.access("diffview.scene.layouts.diff_2_ver", "Diff2Ver") ---@type Diff2Ver|LazyModule
local Diff2VerPinned = lazy.access("diffview.scene.layouts.diff_2_ver_pinned", "Diff2VerPinned") ---@type Diff2VerPinned|LazyModule
local Diff3 = lazy.access("diffview.scene.layouts.diff_3", "Diff3") ---@type Diff3|LazyModule
local Diff3Hor = lazy.access("diffview.scene.layouts.diff_3_hor", "Diff3Hor") ---@type Diff3Hor|LazyModule
local Diff3Mixed = lazy.access("diffview.scene.layouts.diff_3_mixed", "Diff3Mixed") ---@type Diff3Mixed|LazyModule
local Diff3Ver = lazy.access("diffview.scene.layouts.diff_3_ver", "Diff3Ver") ---@type Diff3Hor|LazyModule
local Diff4 = lazy.access("diffview.scene.layouts.diff_4", "Diff4") ---@type Diff4|LazyModule
local Diff4Mixed = lazy.access("diffview.scene.layouts.diff_4_mixed", "Diff4Mixed") ---@type Diff4Mixed|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

local setup_done = false

---@deprecated
function M.diffview_callback(cb_name)
  if cb_name == "select" then
    -- Reroute deprecated action
    return actions.select_entry
  end
  return actions[cb_name]
end

-- Layout aliases used across multiple view kinds and cycle_layouts. The
-- pinned variants (`diff1_*_pinned`, `diff2_*_pinned`) intentionally
-- aren't listed here: they're internal to file-history `pin_local` mode
-- and are selected by the view based on whether `--pin-local` is active,
-- not by direct user configuration. The `LayoutName` alias below still
-- includes them so `name_to_layout` can resolve them internally.
---@alias DiffviewStandardLayout "diff1_plain"|"diff1_inline"|"diff2_horizontal"|"diff2_vertical"
---@alias DiffviewMergeLayout "diff1_plain"|"diff3_horizontal"|"diff3_vertical"|"diff3_mixed"|"diff4_mixed"
---@alias DiffviewInferredLayout -1
---@alias DiffviewOneSidedLayout "default"|"raw"

-- Targets consumed by action factories in `actions.lua` (referenced from keymaps).
---@alias DiffviewConflictTarget "ours"|"theirs"|"base"|"all"|"none"
---@alias DiffviewDiffgetTarget "ours"|"theirs"|"base"|"local"

---@class DiffviewKeymapOpts
---@field desc? string
---@field silent? boolean
---@field nowait? boolean
---@field noremap? boolean
---@field expr? boolean
---@field buffer? integer|boolean

---@class DiffviewKeymapEntry
---@field [1] string|string[] Mode(s).
---@field [2] string Left-hand side.
---@field [3] string|(fun(...): any?)|false Right-hand side; `false` disables the default. Callable may return a `Future` for async actions.
---@field [4]? DiffviewKeymapOpts

-- stylua: ignore start

-- Keymaps shared across view, file_panel, and file_history_panel.
local common_nav_keymaps = {
  { "n", "<tab>",       actions.select_next_entry,   { desc = "Open the diff for the next file" } },
  { "n", "<s-tab>",     actions.select_prev_entry,   { desc = "Open the diff for the previous file" } },
  { "n", "[F",          actions.select_first_entry,  { desc = "Open the diff for the first file" } },
  { "n", "]F",          actions.select_last_entry,   { desc = "Open the diff for the last file" } },
  { "n", "gf",          actions.goto_file_edit,      { desc = "Open the file in the previous tabpage" } },
  { "n", "<C-w><C-f>",  actions.goto_file_split,     { desc = "Open the file in a new split" } },
  { "n", "<C-w>gf",     actions.goto_file_tab,       { desc = "Open the file in a new tabpage" } },
  { "n", "gx",          actions.open_file_external,  { desc = "Open the file with default system application" } },
  { "n", "<leader>e",   actions.focus_files,         { desc = "Bring focus to the file panel" } },
  { "n", "<leader>b",   actions.toggle_files,        { desc = "Toggle the file panel" } },
}

-- Keymaps shared between file_panel and file_history_panel.
local common_panel_keymaps = {
  { "n", "j",              actions.next_entry,          { desc = "Bring the cursor to the next file entry" } },
  { "n", "<down>",         actions.next_entry,          { desc = "Bring the cursor to the next file entry" } },
  { "n", "k",              actions.prev_entry,          { desc = "Bring the cursor to the previous file entry" } },
  { "n", "<up>",           actions.prev_entry,          { desc = "Bring the cursor to the previous file entry" } },
  { "n", "<cr>",           actions.select_entry,        { desc = "Open the diff for the selected entry" } },
  { "n", "o",              actions.select_entry,        { desc = "Open the diff for the selected entry" } },
  { "n", "l",              actions.select_entry,        { desc = "Open the diff for the selected entry" } },
  { "n", "<2-LeftMouse>",  actions.select_entry,        { desc = "Open the diff for the selected entry" } },
  { "n", "<c-b>",          actions.scroll_view(-0.25),  { desc = "Scroll the view up" } },
  { "n", "<c-f>",          actions.scroll_view(0.25),   { desc = "Scroll the view down" } },
  { "n", "zo",             actions.open_fold,           { desc = "Expand fold" } },
  { "n", "h",              actions.close_fold,          { desc = "Collapse fold" } },
  { "n", "zc",             actions.close_fold,          { desc = "Collapse fold" } },
  { "n", "za",             actions.toggle_fold,         { desc = "Toggle fold" } },
  { "n", "zR",             actions.open_all_folds,      { desc = "Expand all folds" } },
  { "n", "zM",             actions.close_all_folds,     { desc = "Collapse all folds" } },
}

-- Conflict-resolution keymaps spliced into the `keymaps.diff1`/`diff3`/`diff4`
-- groups below, covering every layout in the default `merge_tool` cycle.
-- `keymaps.diff1` applies to all `Diff1` layouts except `diff1_inline`, which
-- has its own keymap group. These operate on conflict markers in the local
-- buffer, so they only make sense when a merge is in progress.
local conflict_keymaps = {
  { "n", "[x",          actions.prev_conflict,                  { desc = "Jump to the previous conflict marker" } },
  { "n", "]x",          actions.next_conflict,                  { desc = "Jump to the next conflict marker" } },
  { "n", "<leader>co",  actions.conflict_choose("ours"),        { desc = "Choose the OURS version of a conflict" } },
  { "n", "<leader>ct",  actions.conflict_choose("theirs"),      { desc = "Choose the THEIRS version of a conflict" } },
  { "n", "<leader>cb",  actions.conflict_choose("base"),        { desc = "Choose the BASE version of a conflict" } },
  { "n", "<leader>ca",  actions.conflict_choose("all"),         { desc = "Choose all the versions of a conflict" } },
  { "n", "dx",          actions.conflict_choose("none"),        { desc = "Delete the conflict region" } },
  { "n", "<leader>cO",  actions.conflict_choose_all("ours"),    { desc = "Choose the OURS version of a conflict for the whole file" } },
  { "n", "<leader>cT",  actions.conflict_choose_all("theirs"),  { desc = "Choose the THEIRS version of a conflict for the whole file" } },
  { "n", "<leader>cB",  actions.conflict_choose_all("base"),    { desc = "Choose the BASE version of a conflict for the whole file" } },
  { "n", "<leader>cA",  actions.conflict_choose_all("all"),     { desc = "Choose all the versions of a conflict for the whole file" } },
  { "n", "dX",          actions.conflict_choose_all("none"),    { desc = "Delete the conflict region for the whole file" } },
}

---@class DiffviewConfig
---@field diff_binaries boolean
---@field enhanced_diff_hl boolean
---@field git_cmd string[]
---@field hg_cmd string[]
---@field jj_cmd string[]
---@field p4_cmd string[]
---@field preferred_adapter? DiffviewPreferredAdapter
---@field rename_threshold? integer
---@field use_icons boolean
---@field show_help_hints boolean
---@field show_root_path boolean
---@field watch_index boolean
---@field hide_merge_artifacts boolean
---@field auto_close_on_empty boolean
---@field wrap_entries boolean
---@field large_file_threshold integer
---@field diffopt table
---@field clean_up_buffers boolean
---@field persist_selections DiffviewPersistSelectionsConfig
---@field restore_session boolean
---@field icons DiffviewIcons
---@field status_icons DiffviewStatusIcons
---@field signs DiffviewSigns
---@field view DiffviewViewConfig
---@field file_panel DiffviewFilePanelConfig
---@field file_history_panel DiffviewFileHistoryPanelConfig
---@field commit_log_panel DiffviewCommitLogPanelConfig
---@field default_args DiffviewDefaultArgs
---@field hooks DiffviewHooks
---@field keymaps DiffviewKeymapsConfig

---@class DiffviewConfig.user
---@field diff_binaries? boolean Show diffs for binary files.
---@field enhanced_diff_hl? boolean See `|diffview-config-enhanced_diff_hl|`.
---@field git_cmd? string[] The git executable followed by default args.
---@field hg_cmd? string[] The hg executable followed by default args.
---@field jj_cmd? string[] The jj executable followed by default args.
---@field p4_cmd? string[] The p4 executable followed by default args.
---@field preferred_adapter? DiffviewPreferredAdapter Preferred VCS adapter; tried first when detecting repos.
---@field rename_threshold? integer Rename detection similarity (0-100). Nil uses git default (50%).
---@field use_icons? boolean Requires nvim-web-devicons or mini.icons.
---@field show_help_hints? boolean Show hints for how to open the help panel.
---@field show_root_path? boolean Show repository root path in panel headers.
---@field watch_index? boolean Update views and index buffers when the git index changes.
---@field hide_merge_artifacts? boolean Hide merge artifact files (*.orig, *.BACKUP.*, *.BASE.*, *.LOCAL.*, *.REMOTE.*).
---@field auto_close_on_empty? boolean Close diffview when the last file is staged/resolved.
---@field wrap_entries? boolean Wrap around when navigating past the first/last file entry.
---@field large_file_threshold? integer Line count above which treesitter is disabled on non-LOCAL diff buffers. 0 disables this behaviour.
---@field diffopt? table Override `diffopt` while diffview is open. Restored on close.
---@field clean_up_buffers? boolean Delete file buffers created by diffview on close.
---@field persist_selections? DiffviewPersistSelectionsConfig.user Persist file selections across Neovim restarts.
---@field restore_session? boolean Restore open Diffview/FileHistory views from a sourced Vim session.
---@field icons? DiffviewIcons.user Folder icons; only applies when `use_icons` is true.
---@field status_icons? DiffviewStatusIcons.user Icons for git status letters.
---@field signs? DiffviewSigns.user Sign characters used throughout the UI.
---@field view? DiffviewViewConfig.user Layout and behaviour of different view types.
---@field file_panel? DiffviewFilePanelConfig.user File panel configuration.
---@field file_history_panel? DiffviewFileHistoryPanelConfig.user File history panel configuration.
---@field commit_log_panel? DiffviewCommitLogPanelConfig.user Commit log panel configuration.
---@field default_args? DiffviewDefaultArgs.user Default args prepended to the arg-list for `:DiffviewOpen` / `:DiffviewFileHistory`.
---@field hooks? DiffviewHooks Event hooks. See `|diffview-config-hooks|`.
---@field keymaps? DiffviewKeymapsConfig.user Keymap overrides; merged with defaults unless `disable_defaults` is true.

---@type DiffviewConfig
M.defaults = {
  diff_binaries = false,
  enhanced_diff_hl = false,
  git_cmd = { "git" },
  hg_cmd = { "hg" },
  jj_cmd = { "jj" },
  p4_cmd = { "p4" },
  ---@alias DiffviewPreferredAdapter "git"|"hg"|"jj"|"p4"
  preferred_adapter = nil, -- Preferred VCS adapter ("git", "hg", "jj", "p4"). Tried first when detecting repos.
  rename_threshold = nil, -- Similarity threshold for rename detection (e.g. 40 for 40%). Nil uses git default (50%).
  use_icons = true,
  show_help_hints = true,
  show_root_path = true, -- Show repository root path in panel headers.
  watch_index = true,
  hide_merge_artifacts = false, -- Hide merge artifact files (*.orig, *.BACKUP.*, etc.)
  auto_close_on_empty = false, -- Automatically close diffview when the last file is staged/resolved.
  wrap_entries = true, -- Wrap around when navigating past the first/last file entry.
  -- Line count threshold for disabling treesitter highlighting on non-LOCAL
  -- revision buffers. Set to 0 to disable this behaviour.
  large_file_threshold = 0,
  -- Override diffopt settings while diffview is open. Restored on close.
  -- Keys: algorithm, context, linematch, indent_heuristic, iwhite, iwhiteall,
  -- iwhiteeol, iblank, icase.
  -- Example: { algorithm = "histogram", linematch = 60 }
  diffopt = {},
  clean_up_buffers = false, -- Delete file buffers created by diffview on close (only buffers not open before diffview).

  ---@class DiffviewPersistSelectionsConfig
  ---@field enabled boolean
  ---@field path? string

  ---@class DiffviewPersistSelectionsConfig.user
  ---@field enabled? boolean Persist file selections to disk across Neovim restarts.
  ---@field path? string Storage path. Nil uses `stdpath("data") .. "/diffview_selections.json"`.
  persist_selections = {
    enabled = false, -- Persist file selections to disk across Neovim restarts.
    path = nil, -- Storage path. Nil uses stdpath("data") .. "/diffview_selections.json".
  },
  restore_session = true, -- Restore open Diffview/FileHistory views from a sourced Vim session.

  ---@class DiffviewIcons
  ---@field folder_closed string
  ---@field folder_open string

  ---@class DiffviewIcons.user
  ---@field folder_closed? string Icon for a collapsed folder.
  ---@field folder_open? string Icon for an expanded folder.
  icons = {
    folder_closed = "",
    folder_open = "",
  },

  ---@class DiffviewStatusIcons
  ---@field ["A"] string Added.
  ---@field ["?"] string Untracked.
  ---@field ["M"] string Modified.
  ---@field ["R"] string Renamed.
  ---@field ["C"] string Copied.
  ---@field ["T"] string Type changed.
  ---@field ["U"] string Unmerged.
  ---@field ["X"] string Unknown.
  ---@field ["D"] string Deleted.
  ---@field ["B"] string Broken.
  ---@field ["!"] string Ignored.

  ---@class DiffviewStatusIcons.user
  ---@field ["A"]? string Added.
  ---@field ["?"]? string Untracked.
  ---@field ["M"]? string Modified.
  ---@field ["R"]? string Renamed.
  ---@field ["C"]? string Copied.
  ---@field ["T"]? string Type changed.
  ---@field ["U"]? string Unmerged.
  ---@field ["X"]? string Unknown.
  ---@field ["D"]? string Deleted.
  ---@field ["B"]? string Broken.
  ---@field ["!"]? string Ignored.
  status_icons = {
    ["A"] = "A",  -- Added
    ["?"] = "?",  -- Untracked
    ["M"] = "M",  -- Modified
    ["R"] = "R",  -- Renamed
    ["C"] = "C",  -- Copied
    ["T"] = "T",  -- Type changed
    ["U"] = "U",  -- Unmerged
    ["X"] = "X",  -- Unknown
    ["D"] = "D",  -- Deleted
    ["B"] = "B",  -- Broken
    ["!"] = "!",  -- Ignored
  },

  ---@class DiffviewSigns
  ---@field fold_closed string
  ---@field fold_open string
  ---@field done string
  ---@field selected_file string
  ---@field unselected_file string
  ---@field selected_dir string
  ---@field partially_selected_dir string
  ---@field unselected_dir string

  ---@class DiffviewSigns.user
  ---@field fold_closed? string Sign for a closed fold.
  ---@field fold_open? string Sign for an open fold.
  ---@field done? string Sign for a completed item (e.g. resolved conflict).
  ---@field selected_file? string Sign for a selected file mark.
  ---@field unselected_file? string Sign for an unselected file mark.
  ---@field selected_dir? string Sign for a fully selected directory.
  ---@field partially_selected_dir? string Sign for a partially selected directory.
  ---@field unselected_dir? string Sign for an unselected directory.
  signs = {
    fold_closed = "",
    fold_open = "",
    done = "✓",
    selected_file = "■",
    unselected_file = "□",
    selected_dir = "■",
    partially_selected_dir = "▣",
    unselected_dir = "□",
  },

  ---@class DiffviewViewConfig
  ---@field default DiffviewStandardViewTypeConfig
  ---@field merge_tool DiffviewMergeViewTypeConfig
  ---@field file_history DiffviewStandardViewTypeConfig
  ---@field foldlevel integer
  ---@field one_sided_layout DiffviewOneSidedLayout
  ---@field cycle_layouts DiffviewCycleLayouts
  ---@field inline DiffviewInlineConfig

  ---@class DiffviewViewConfig.user
  ---@field default? DiffviewStandardViewTypeConfig.user Config for changed files, and staged files in diff views.
  ---@field merge_tool? DiffviewMergeViewTypeConfig.user Config for conflicted files in diff views during a merge or rebase.
  ---@field file_history? DiffviewStandardViewTypeConfig.user Config for changed files in file history views.
  ---@field foldlevel? integer See `|diffview-config-view.foldlevel|`.
  ---@field one_sided_layout? DiffviewOneSidedLayout Layout used for files whose diff is one-sided (status `A`/`?` or `D`). `"default"` keeps the configured layout (a Diff2 leaves an empty pane; a `diff1_plain` keeps its diff-mode chrome). `"raw"` substitutes `diff1_raw`: a single non-diff window where `A`/`?` shows the b-side directly (editable working-tree buffer when b is `LOCAL`, read-only when b is a commit rev) and `D` shows the pre-deletion content from `revs.a` (read-only when that's a commit; editable when it's the index, with `:w` writing back via the usual STAGE-0 path). Applies to both diff views and file history views, and to `diff1_plain` and Diff2 base layouts. Has no effect on `diff1_inline` (which already renders one-sided content coherently), on renames, modifications, merge conflicts, or when file history's `pin_local` mode owns the right-hand window. See `|diffview-config-view.one_sided_layout|`.
  ---@field cycle_layouts? DiffviewCycleLayouts.user Layouts to cycle through with `cycle_layout`.
  ---@field inline? DiffviewInlineConfig.user Options that apply to the `diff1_inline` layout.
  view = {
    ---@class DiffviewStandardViewTypeConfig
    ---@field layout DiffviewStandardLayout|DiffviewInferredLayout
    ---@field disable_diagnostics boolean
    ---@field winbar_info boolean
    ---@field focus_diff boolean
    ---@field pin_local? boolean

    ---@class DiffviewMergeViewTypeConfig
    ---@field layout DiffviewMergeLayout|DiffviewInferredLayout
    ---@field disable_diagnostics boolean
    ---@field winbar_info boolean
    ---@field focus_diff boolean

    ---@class DiffviewStandardViewTypeConfig.user
    ---@field layout? DiffviewStandardLayout|DiffviewInferredLayout Layout to use for this view type. See `|diffview-config-view.x.layout|`.
    ---@field disable_diagnostics? boolean Temporarily disable diagnostics for diff buffers while in the view.
    ---@field winbar_info? boolean See `|diffview-config-view.x.winbar_info|`.
    ---@field focus_diff? boolean Focus the main diff window on open instead of the file panel.
    ---@field pin_local? boolean File-history only: pin the b-window to the working-tree LOCAL buffer across log navigation, so you can browse history while diffing each commit against your live file. Per-invocation, `--pin-local` enables and `--pin-local=false` disables (overriding any value set here). For git, `--base=<rev>` is an alternative that pins to a fixed commit instead. See `|diffview-config-view.file_history.pin_local|`.

    ---@class DiffviewMergeViewTypeConfig.user
    ---@field layout? DiffviewMergeLayout|DiffviewInferredLayout Layout to use for this view type. See `|diffview-config-view.x.layout|`.
    ---@field disable_diagnostics? boolean Temporarily disable diagnostics for diff buffers while in the view.
    ---@field winbar_info? boolean See `|diffview-config-view.x.winbar_info|`.
    ---@field focus_diff? boolean Focus the main diff window on open instead of the file panel.

    ---@type DiffviewStandardViewTypeConfig
    default = {
      layout = "diff2_horizontal",
      disable_diagnostics = false,
      winbar_info = false,
      focus_diff = false,
    },
    merge_tool = {
      layout = "diff3_horizontal",
      disable_diagnostics = true,
      winbar_info = true,
      focus_diff = false,
    },
    file_history = {
      layout = "diff2_horizontal",
      disable_diagnostics = false,
      winbar_info = false,
      focus_diff = false,
      pin_local = false,
    },
    -- Initial 'foldlevel' for diff buffers. Default 0 collapses unchanged
    -- regions; set to a high value (e.g. 99) to keep all folds open.
    foldlevel = 0,
    -- Layout used for files whose diff is one-sided (added, untracked, or
    -- deleted). `"default"` keeps the configured layout. `"raw"` substitutes
    -- `diff1_raw`: a single non-diff window where additions and untracked
    -- files open as editable buffers backed by the file on disk, and
    -- deletions show the pre-deletion content from `revs.a` (read-only
    -- against a commit; editable against the index, with `:w` writing
    -- back via the usual STAGE-0 path). Applies to `diff1_plain` and
    -- Diff2 base layouts; `diff1_inline` (which renders one-sided content
    -- as all-added or all-deleted virt_lines) is left alone.
    one_sided_layout = "default",

    ---@class DiffviewCycleLayouts
    ---@field default DiffviewStandardLayout[]
    ---@field merge_tool DiffviewMergeLayout[]

    ---@class DiffviewCycleLayouts.user
    ---@field default? DiffviewStandardLayout[] Layouts cycled by `cycle_layout` in standard views.
    ---@field merge_tool? DiffviewMergeLayout[] Layouts cycled by `cycle_layout` in conflict views.
    -- Layouts to cycle through with `cycle_layout` action.
    cycle_layouts = {
      default = { "diff2_horizontal", "diff2_vertical" },
      merge_tool = { "diff3_horizontal", "diff3_vertical", "diff3_mixed", "diff4_mixed", "diff1_plain" },
    },

    ---@alias DiffviewInlineStyle "unified"|"overleaf"
    ---@alias DiffviewInlineDeletionHighlight "text"|"full_width"|"hanging"
    ---@class DiffviewInlineConfig
    ---@field style DiffviewInlineStyle
    ---@field deletion_highlight DiffviewInlineDeletionHighlight
    ---@field deletion_treesitter boolean

    ---@class DiffviewInlineConfig.user
    ---@field style? DiffviewInlineStyle Rendering style for `diff1_inline`. "unified" shows old lines as virt_lines above; "overleaf" renders deletions as inline strikethrough virt_text.
    ---@field deletion_highlight? DiffviewInlineDeletionHighlight Extent of the `DiffDelete` background on deleted virt_lines: `"text"` covers only the deleted chars, `"full_width"` pads to the row, `"hanging"` covers everything except the leading indent.
    ---@field deletion_treesitter? boolean Layer tree-sitter syntax highlights over the deleted virt_lines so they read like the rest of the buffer. Falls back transparently when no parser is attached.
    -- Options specific to the `diff1_inline` layout.
    inline = {
      -- Rendering style. "unified": proper unified diff -- old lines shown
      -- above modifications as virt_lines, added chars highlighted in place.
      -- "overleaf": deleted chars on modified lines rendered inline as
      -- strikethrough virtual text (Overleaf-editor style); no block echo.
      style = "unified",
      -- How far the `DiffDelete` background extends on deleted virt_lines:
      --   "text":       just the deleted characters.
      --   "full_width": highlight the row, which matches `diff2_horizontal`'s
      --                 native look.
      --   "hanging":    skip the leading indent, then highlight the rest of
      --                 the row.
      deletion_highlight = "text",
      -- Layer tree-sitter syntax highlights over the deleted virt_lines so
      -- they read like the rest of the buffer. No-op when no parser is
      -- attached for the buffer's filetype.
      deletion_treesitter = true,
    },
  },

  ---@alias DiffviewSortFile fun(a_name: string, b_name: string, a_data: any?, b_data: any?): boolean
  ---@alias DiffviewListingStyle "tree"|"list"
  ---@alias DiffviewMarkPlacement "inline"|"sign_column"
  ---@class DiffviewFilePanelConfig
  ---@field listing_style DiffviewListingStyle
  ---@field sort_file? DiffviewSortFile
  ---@field tree_options DiffviewTreeOptions
  ---@field list_options DiffviewListOptions
  ---@field win_config DiffviewFilePanelWinConfig
  ---@field show boolean
  ---@field always_show_sections boolean
  ---@field always_show_marks boolean
  ---@field mark_placement DiffviewMarkPlacement
  ---@field show_branch_name boolean

  ---@class DiffviewFilePanelConfig.user
  ---@field listing_style? DiffviewListingStyle "list" or "tree".
  ---@field sort_file? DiffviewSortFile Custom file comparator.
  ---@field tree_options? DiffviewTreeOptions.user Only applies when `listing_style` is "tree".
  ---@field list_options? DiffviewListOptions.user Only applies when `listing_style` is "list".
  ---@field win_config? DiffviewFilePanelWinConfig.user File panel window config.
  ---@field show? boolean Show the file panel when opening Diffview.
  ---@field always_show_sections? boolean Always show Changes and Staged sections even when empty.
  ---@field always_show_marks? boolean Show selection marks even when no files are selected.
  ---@field mark_placement? DiffviewMarkPlacement Where to render selection marks.
  ---@field show_branch_name? boolean Show branch name in the file panel header.
  file_panel = {
    listing_style = "tree",
    sort_file = nil, -- Custom file comparator: function(a_name, b_name, a_data, b_data) -> boolean

    ---@alias DiffviewFolderStatuses "never"|"only_folded"|"always"
    ---@alias DiffviewFolderCountStyle "grouped"|"simple"|"none"
    ---@class DiffviewTreeOptions
    ---@field flatten_dirs boolean
    ---@field folder_statuses DiffviewFolderStatuses
    ---@field folder_count_style DiffviewFolderCountStyle
    ---@field folder_trailing_slash boolean

    ---@class DiffviewTreeOptions.user
    ---@field flatten_dirs? boolean Flatten dirs that only contain one single dir.
    ---@field folder_statuses? DiffviewFolderStatuses When to show folder status counts.
    ---@field folder_count_style? DiffviewFolderCountStyle How to render folder counts ("grouped", "simple", "none").
    ---@field folder_trailing_slash? boolean Append "/" to folder names in the file tree.
    tree_options = {
      flatten_dirs = true,
      folder_statuses = "only_folded",
      folder_count_style = "grouped", -- "grouped" (e.g. "2M 1D"), "simple" (e.g. "3"), or "none".
      folder_trailing_slash = true, -- Append "/" to folder names in the file tree.
    },

    ---@alias DiffviewPathStyle "basename"|"full"
    ---@class DiffviewListOptions
    ---@field path_style DiffviewPathStyle

    ---@class DiffviewListOptions.user
    ---@field path_style? DiffviewPathStyle "basename" (name + dimmed path) or "full" (uniform highlight).
    list_options = {
      path_style = "basename", -- "basename" (name + dimmed path) or "full" (full path, uniform highlight).
    },

    ---@alias DiffviewFilePanelWinConfig PanelConfig.user|fun(): PanelConfig.user
    ---@alias DiffviewFilePanelWinConfig.user PanelConfig.user|fun(): PanelConfig.user
    win_config = {
      position = "left",
      width = 35,
      win_opts = {}
    },
    show = true, -- Show the file panel by default when opening Diffview.
    always_show_sections = false, -- Always show Changes and Staged changes sections even when empty.
    always_show_marks = false, -- Show selection marks even when no files are selected.
    mark_placement = "inline", -- Where to show selection marks: "inline" (next to file names) or "sign_column" (in the sign column).
    show_branch_name = false, -- Show branch name in the file panel header.
  },

  ---@alias DiffviewStatStyle "number"|"bar"|"both"
  ---@alias DiffviewSubjectHighlight "ref_aware"|"merge_aware"|"plain"
  ---@alias DiffviewCommitFormatField "status"|"files"|"stats"|"hash"|"reflog"|"ref"|"subject"|"author"|"date"
  ---@alias DiffviewDateFormat "auto"|"relative"|"iso"
  ---@class DiffviewFileHistoryPanelConfig
  ---@field stat_style DiffviewStatStyle
  ---@field subject_highlight DiffviewSubjectHighlight
  ---@field commit_format DiffviewCommitFormatField[]
  ---@field log_options DiffviewFileHistoryLogOptions
  ---@field win_config DiffviewFileHistoryPanelWinConfig
  ---@field show boolean
  ---@field commit_subject_max_length integer
  ---@field date_format DiffviewDateFormat

  ---@class DiffviewFileHistoryPanelConfig.user
  ---@field stat_style? DiffviewStatStyle "number", "bar", or "both".
  ---@field subject_highlight? DiffviewSubjectHighlight "ref_aware" colours by pushed/unpushed; "merge_aware" adds a third colour for commits reachable from a main/master branch; "plain" is uniform.
  ---@field commit_format? DiffviewCommitFormatField[] Ordered components shown per commit entry.
  ---@field log_options? DiffviewFileHistoryLogOptions.user Log options per adapter. See `|diffview-config-log_options|`.
  ---@field win_config? DiffviewFileHistoryPanelWinConfig.user File history panel window config.
  ---@field show? boolean Show the file history panel when opening DiffviewFileHistory.
  ---@field commit_subject_max_length? integer Max length for commit subject display.
  ---@field date_format? DiffviewDateFormat "auto", "relative", or "iso".
  file_history_panel = {
    stat_style = "number", -- "number" (e.g. "5, 3"), "bar" (e.g. "| 8 +++++---"), or "both".
    subject_highlight = "ref_aware", -- "ref_aware" (pushed vs unpushed), "merge_aware" (adds a third colour for merged-to-main/master), or "plain".
    -- Ordered list of components to show for each commit entry.
    -- Available: "status", "files", "stats", "hash", "reflog", "ref", "subject", "author", "date"
    commit_format = { "status", "files", "stats", "hash", "reflog", "ref", "subject", "author", "date" },

    ---@class DiffviewFileHistoryLogOptions
    ---@field git ConfigLogOptions
    ---@field hg ConfigLogOptions
    ---@field jj ConfigLogOptions
    ---@field p4 ConfigLogOptions

    ---@class DiffviewFileHistoryLogOptions.user
    ---@field git? ConfigLogOptions.user Log options for git.
    ---@field hg? ConfigLogOptions.user Log options for hg.
    ---@field jj? ConfigLogOptions.user Log options for Jujutsu.
    ---@field p4? ConfigLogOptions.user Log options for Perforce.

    ---@class ConfigLogOptions
    ---@field single_file LogOptions
    ---@field multi_file LogOptions

    ---@class ConfigLogOptions.user
    ---@field single_file? LogOptions.user
    ---@field multi_file? LogOptions.user
    log_options = {
      ---@type ConfigLogOptions.user
      git = {
        single_file = {
          diff_merges = "first-parent",
          follow = true,
        },
        multi_file = {
          diff_merges = "first-parent",
        },
      },
      ---@type ConfigLogOptions.user
      hg = {
        single_file = {},
        multi_file = {},
      },
      ---@type ConfigLogOptions.user
      jj = {
        single_file = {},
        multi_file = {},
      },
      ---@type ConfigLogOptions.user
      p4 = {
        single_file = {},
        multi_file = {},
      },
    },

    ---@alias DiffviewFileHistoryPanelWinConfig PanelConfig.user|fun(): PanelConfig.user
    ---@alias DiffviewFileHistoryPanelWinConfig.user PanelConfig.user|fun(): PanelConfig.user
    win_config = {
      position = "bottom",
      height = 16,
      win_opts = {}
    },
    show = true, -- Show the file history panel by default when opening DiffviewFileHistory.
    commit_subject_max_length = 72, -- Max length for commit subject display.
    date_format = "auto", -- Date format: "auto" (relative for recent, ISO for old), "relative", or "iso".
  },

  ---@class DiffviewCommitLogPanelConfig
  ---@field win_config DiffviewCommitLogPanelWinConfig

  ---@class DiffviewCommitLogPanelConfig.user
  ---@field win_config? DiffviewCommitLogPanelWinConfig.user Commit log panel window config.
  commit_log_panel = {
    ---@alias DiffviewCommitLogPanelWinConfig PanelConfig.user|fun(): PanelConfig.user
    ---@alias DiffviewCommitLogPanelWinConfig.user PanelConfig.user|fun(): PanelConfig.user
    win_config = {
      win_opts = {}
    },
  },

  ---@class DiffviewDefaultArgs
  ---@field DiffviewOpen string[]
  ---@field DiffviewFileHistory string[]

  ---@class DiffviewDefaultArgs.user
  ---@field DiffviewOpen? string[] Default args prepended to `:DiffviewOpen`.
  ---@field DiffviewFileHistory? string[] Default args prepended to `:DiffviewFileHistory`.
  default_args = {
    DiffviewOpen = {},
    DiffviewFileHistory = {},
  },

  ---@class DiffviewDiffBufCtx
  ---@field symbol string Layout-window symbol ("a"|"b"|"c"|"d").
  ---@field layout_name string Concrete layout, e.g. "diff2_horizontal".

  ---@class DiffviewHooks
  ---@field view_opened? fun(view: View)
  ---@field view_closed? fun(view: View)
  ---@field view_enter? fun(view: View)
  ---@field view_leave? fun(view: View)
  ---@field view_post_layout? fun(view: View)
  ---@field diff_buf_read? fun(bufnr: integer, ctx: DiffviewDiffBufCtx)
  ---@field diff_buf_win_enter? fun(bufnr: integer, winid: integer, ctx: DiffviewDiffBufCtx)
  ---@field selection_changed? fun(view: DiffView)
  ---@field files_staged? fun(view: DiffView)
  ---@field [string] fun(...): any?
  hooks = {},

  ---@class DiffviewKeymapsConfig
  ---@field disable_defaults boolean
  ---@field view DiffviewKeymapEntry[]
  ---@field diff1 DiffviewKeymapEntry[]
  ---@field diff1_inline DiffviewKeymapEntry[]
  ---@field diff2 DiffviewKeymapEntry[]
  ---@field diff3 DiffviewKeymapEntry[]
  ---@field diff4 DiffviewKeymapEntry[]
  ---@field file_panel DiffviewKeymapEntry[]
  ---@field file_history_panel DiffviewKeymapEntry[]
  ---@field option_panel DiffviewKeymapEntry[]
  ---@field help_panel DiffviewKeymapEntry[]
  ---@field commit_log_panel DiffviewKeymapEntry[]

  ---@class DiffviewKeymapsConfig.user
  ---@field disable_defaults? boolean
  ---@field view? DiffviewKeymapEntry[]
  ---@field diff1? DiffviewKeymapEntry[]
  ---@field diff1_inline? DiffviewKeymapEntry[]
  ---@field diff2? DiffviewKeymapEntry[]
  ---@field diff3? DiffviewKeymapEntry[]
  ---@field diff4? DiffviewKeymapEntry[]
  ---@field file_panel? DiffviewKeymapEntry[]
  ---@field file_history_panel? DiffviewKeymapEntry[]
  ---@field option_panel? DiffviewKeymapEntry[]
  ---@field help_panel? DiffviewKeymapEntry[]
  ---@field commit_log_panel? DiffviewKeymapEntry[]
  -- Tabularize formatting pattern: `\v(\"[^"]{-}\",\ze(\s*)actions)|actions\.\w+(\(.{-}\))?,?|\{\ desc\ \=`
  keymaps = {
    disable_defaults = false, -- Disable the default keymaps
    view = utils.vec_join(common_nav_keymaps, {
      -- The `view` bindings are active in the diff buffers, only when the current
      -- tabpage is a Diffview.
      { "n", "<C-w>T",      actions.open_in_new_tab,                { desc = "Open diffview in a new tab" } },
      { "n", "g<C-x>",      actions.cycle_layout,                   { desc = "Cycle through available layouts" } },
    }, actions.compat.fold_cmds),
    diff1 = utils.vec_join({
      -- Mappings in single-window diff layouts (all `Diff1` subclasses except
      -- `diff1_inline`, which has its own keymap group). These layouts
      -- participate in the default `merge_tool` cycle, so they inherit the
      -- conflict-resolution mappings too.
      { "n", "g?", actions.help({ "view", "diff1" }), { desc = "Open the help panel" } },
    }, conflict_keymaps),
    diff1_inline = {
      -- Mappings in the `diff1_inline` unified diff layout. Native `]c`/`[c`
      -- and `do` don't work here because the window has `diff=false`, so we
      -- provide equivalents that walk the renderer's cached hunks.
      { "n", "]c",  actions.next_inline_hunk,                            { desc = "Jump to the next inline-diff hunk" } },
      { "n", "[c",  actions.prev_inline_hunk,                            { desc = "Jump to the previous inline-diff hunk" } },
      { { "n", "x" }, "do", actions.diffget_inline,                      { desc = "Obtain the diff hunk from the old-side version" } },
      { "n", "g?",  actions.help({ "view", "diff1", "diff1_inline" }),   { desc = "Open the help panel" } },
    },
    diff2 = {
      -- Mappings in 2-way diff layouts
      { "n", "g?", actions.help({ "view", "diff2" }), { desc = "Open the help panel" } },
    },
    diff3 = utils.vec_join({
      -- Mappings in 3-way diff layouts
      { { "n", "x" }, "2do",  actions.diffget("ours"),            { desc = "Obtain the diff hunk from the OURS version of the file" } },
      { { "n", "x" }, "3do",  actions.diffget("theirs"),          { desc = "Obtain the diff hunk from the THEIRS version of the file" } },
      { "n",          "g?",   actions.help({ "view", "diff3" }),  { desc = "Open the help panel" } },
    }, conflict_keymaps),
    diff4 = utils.vec_join({
      -- Mappings in 4-way diff layouts
      { { "n", "x" }, "1do",  actions.diffget("base"),            { desc = "Obtain the diff hunk from the BASE version of the file" } },
      { { "n", "x" }, "2do",  actions.diffget("ours"),            { desc = "Obtain the diff hunk from the OURS version of the file" } },
      { { "n", "x" }, "3do",  actions.diffget("theirs"),          { desc = "Obtain the diff hunk from the THEIRS version of the file" } },
      { "n",          "g?",   actions.help({ "view", "diff4" }),  { desc = "Open the help panel" } },
    }, conflict_keymaps),
    file_panel = utils.vec_join(common_panel_keymaps, common_nav_keymaps, {
      { { "n", "x" }, "w",    actions.toggle_select_entry,            { desc = "Toggle file selection for multi-file operations" } },
      { "n", "C",              actions.clear_select_entries,           { desc = "Clear all file selections" } },
      { "n", "-",              actions.toggle_stage_entry,             { desc = "Stage / unstage the selected entry" } },
      { "n", "s",              actions.toggle_stage_entry,             { desc = "Stage / unstage the selected entry" } },
      { "n", "S",              actions.stage_all,                      { desc = "Stage all entries" } },
      { "n", "U",              actions.unstage_all,                    { desc = "Unstage all entries" } },
      { "n", "X",              actions.restore_entry,                  { desc = "Restore entry to the state on the left side" } },
      { "n", "L",              actions.open_commit_log,                { desc = "Open the commit log panel" } },
      { "n", "<C-w>T",        actions.open_in_new_tab,                { desc = "Open diffview in a new tab" } },
      { "n", "i",              actions.listing_style,                  { desc = "Toggle between 'list' and 'tree' views" } },
      { "n", "f",              actions.toggle_flatten_dirs,            { desc = "Flatten empty subdirectories in tree listing style" } },
      { "n", "R",              actions.refresh_files,                  { desc = "Update stats and entries in the file list" } },
      { "n", "g<C-x>",         actions.cycle_layout,                   { desc = "Cycle available layouts" } },
      { "n", "[x",             actions.prev_conflict,                  { desc = "Go to the previous conflict" } },
      { "n", "]x",             actions.next_conflict,                  { desc = "Go to the next conflict" } },
      { "n", "g?",             actions.help("file_panel"),             { desc = "Open the help panel" } },
      { "n", "<leader>cO",     actions.conflict_choose_all("ours"),    { desc = "Choose the OURS version of a conflict for the whole file" } },
      { "n", "<leader>cT",     actions.conflict_choose_all("theirs"),  { desc = "Choose the THEIRS version of a conflict for the whole file" } },
      { "n", "<leader>cB",     actions.conflict_choose_all("base"),    { desc = "Choose the BASE version of a conflict for the whole file" } },
      { "n", "<leader>cA",     actions.conflict_choose_all("all"),     { desc = "Choose all the versions of a conflict for the whole file" } },
      { "n", "dX",             actions.conflict_choose_all("none"),    { desc = "Delete the conflict region for the whole file" } },
    }),
    file_history_panel = utils.vec_join(common_panel_keymaps, common_nav_keymaps, {
      { "n", "g!",            actions.options,                     { desc = "Open the option panel" } },
      { "n", "<C-A-d>",       actions.open_in_diffview,            { desc = "Open the entry under the cursor in a diffview" } },
      { "n", "H",             actions.diff_against_head,           { desc = "Open a diffview comparing HEAD with the commit under the cursor" } },
      { "n", "y",             actions.copy_hash,                   { desc = "Copy the commit hash of the entry under the cursor" } },
      { "n", "L",             actions.open_commit_log,             { desc = "Show commit details" } },
      { "n", "X",             actions.restore_entry,               { desc = "Restore file to the state from the selected entry" } },
      { "n", "g<C-x>",        actions.cycle_layout,                { desc = "Cycle available layouts" } },
      { "n", "g?",            actions.help("file_history_panel"),  { desc = "Open the help panel" } },
    }),
    option_panel = {
      { "n", "<tab>", actions.select_entry,          { desc = "Change the current option" } },
      { "n", "q",     actions.close,                 { desc = "Close the panel" } },
      { "n", "g?",    actions.help("option_panel"),  { desc = "Open the help panel" } },
    },
    help_panel = {
      { "n", "q",     actions.close,  { desc = "Close help menu" } },
      { "n", "<esc>", actions.close,  { desc = "Close help menu" } },
    },
    commit_log_panel = {
      { "n", "q",     actions.close,  { desc = "Close commit log" } },
      { "n", "<esc>", actions.close,  { desc = "Close commit log" } },
    },
  },
}
-- stylua: ignore end

---@type EventEmitter
M.user_emitter = EventEmitter()
---@type DiffviewConfig
M._config = M.defaults

---@class GitLogOptions
---@field follow boolean
---@field first_parent boolean
---@field show_pulls boolean
---@field reflog boolean
---@field walk_reflogs boolean
---@field all boolean
---@field merges boolean
---@field no_merges boolean
---@field reverse boolean
---@field cherry_pick boolean
---@field left_only boolean
---@field right_only boolean
---@field max_count integer
---@field L string[]
---@field author? string
---@field grep? string
---@field G? string
---@field S? string
---@field diff_merges? string
---@field rev_range? string
---@field base? string
---@field path_args string[]
---@field after? string
---@field before? string

---@class HgLogOptions
---@field follow? string
---@field limit integer
---@field user? string
---@field no_merges boolean
---@field rev? string
---@field keyword? string
---@field branch? string
---@field bookmark? string
---@field include? string
---@field exclude? string
---@field path_args string[]

---@class JjLogOptions
---@field limit integer
---@field reversed boolean
---@field revisions? string
---@field path_args string[]

---@alias LogOptions GitLogOptions|HgLogOptions|JjLogOptions

---@class GitLogOptions.user
---@field follow? boolean
---@field first_parent? boolean
---@field show_pulls? boolean
---@field reflog? boolean
---@field walk_reflogs? boolean
---@field all? boolean
---@field merges? boolean
---@field no_merges? boolean
---@field reverse? boolean
---@field cherry_pick? boolean
---@field left_only? boolean
---@field right_only? boolean
---@field max_count? integer
---@field L? string[]
---@field author? string
---@field grep? string
---@field G? string
---@field S? string
---@field diff_merges? string
---@field rev_range? string
---@field base? string
---@field path_args? string[]
---@field after? string
---@field before? string

---@class HgLogOptions.user
---@field follow? string
---@field limit? integer
---@field user? string
---@field no_merges? boolean
---@field rev? string
---@field keyword? string
---@field branch? string
---@field bookmark? string
---@field include? string
---@field exclude? string
---@field path_args? string[]

---@class JjLogOptions.user
---@field limit? integer
---@field reversed? boolean
---@field revisions? string
---@field path_args? string[]

---@alias LogOptions.user GitLogOptions.user|HgLogOptions.user|JjLogOptions.user

M.log_option_defaults = {
  ---@type GitLogOptions
  git = {
    follow = false,
    first_parent = false,
    show_pulls = false,
    reflog = false,
    walk_reflogs = false,
    all = false,
    merges = false,
    no_merges = false,
    reverse = false,
    cherry_pick = false,
    left_only = false,
    right_only = false,
    rev_range = nil,
    base = nil,
    max_count = 256,
    L = {},
    diff_merges = nil,
    author = nil,
    grep = nil,
    G = nil,
    S = nil,
    path_args = {},
  },
  ---@type HgLogOptions
  hg = {
    limit = 256,
    user = nil,
    no_merges = false,
    rev = nil,
    keyword = nil,
    include = nil,
    exclude = nil,
    path_args = {},
  },
  ---@type JjLogOptions
  jj = {
    limit = 256,
    reversed = false,
    revisions = nil,
    path_args = {},
  },
  ---@type HgLogOptions # P4 reuses the `HgLogOptions` schema; see `P4Adapter.config_key`.
  p4 = {
    limit = 256,
    user = nil,
    no_merges = false,
    rev = nil,
    keyword = nil,
    include = nil,
    exclude = nil,
    path_args = {},
  },
}

---@return DiffviewConfig
function M.get_config()
  if not setup_done then
    M.setup()
  end

  return M._config
end

---@param single_file boolean
---@param t? LogOptions|LogOptions.user # Optional overrides; defaults to `{}`. The returned table is a deep copy callers may mutate safely.
---@param vcs "git"|"hg"|"jj"|"p4" # P4 reuses the `HgLogOptions` schema.
---@return LogOptions
function M.get_log_options(single_file, t, vcs)
  t = t or {}
  local log_options

  if single_file then
    log_options = M._config.file_history_panel.log_options[vcs].single_file
  else
    log_options = M._config.file_history_panel.log_options[vcs].multi_file
  end

  log_options = vim.tbl_extend("force", utils.tbl_deep_clone(log_options), t)

  for k, _ in pairs(log_options) do
    if t[k] == "" then
      log_options[k] = nil
    end
  end

  return log_options
end

---@alias LayoutName "diff1_plain"
---       | "diff1_plain_pinned"
---       | "diff1_inline"
---       | "diff1_inline_pinned"
---       | "diff1_raw"
---       | "diff2_horizontal"
---       | "diff2_horizontal_pinned"
---       | "diff2_vertical"
---       | "diff2_vertical_pinned"
---       | "diff3_horizontal"
---       | "diff3_vertical"
---       | "diff3_mixed"
---       | "diff4_mixed"

local layout_map = {
  diff1_plain = Diff1,
  diff1_plain_pinned = Diff1Pinned,
  diff1_inline = Diff1Inline,
  diff1_inline_pinned = Diff1InlinePinned,
  diff1_raw = Diff1Raw,
  diff2_horizontal = Diff2Hor,
  diff2_horizontal_pinned = Diff2HorPinned,
  diff2_vertical = Diff2Ver,
  diff2_vertical_pinned = Diff2VerPinned,
  diff3_horizontal = Diff3Hor,
  diff3_vertical = Diff3Ver,
  diff3_mixed = Diff3Mixed,
  diff4_mixed = Diff4Mixed,
}

---@param layout_name LayoutName
---@return Layout
function M.name_to_layout(layout_name)
  assert(layout_map[layout_name], "Invalid layout name: " .. layout_name)

  return layout_map[layout_name].__get()
end

---@param layout Layout
---@return table?
function M.get_layout_keymaps(layout)
  -- Check Diff1Inline before Diff1 since it's a subclass.
  if layout:instanceof(Diff1Inline.__get()) then
    return M._config.keymaps.diff1_inline
  elseif layout:instanceof(Diff1.__get()) then
    return M._config.keymaps.diff1
  elseif layout:instanceof(Diff2.__get()) then
    return M._config.keymaps.diff2
  elseif layout:instanceof(Diff3.__get()) then
    return M._config.keymaps.diff3
  elseif layout:instanceof(Diff4.__get()) then
    return M._config.keymaps.diff4
  end
end

function M.find_option_keymap(t)
  for _, mapping in ipairs(t) do
    if mapping[3] and mapping[3] == actions.options then
      return mapping
    end
  end
end

function M.find_help_keymap(t)
  for _, mapping in ipairs(t) do
    if type(mapping[4]) == "table" and mapping[4].desc == "Open the help panel" then
      return mapping
    end
  end
end

---@param values vector
---@param no_quote? boolean
---@return string
local function fmt_enum(values, no_quote)
  return table.concat(
    vim.tbl_map(function(v)
      return (not no_quote and type(v) == "string") and ("'" .. v .. "'") or v
    end, values),
    "|"
  )
end

-- Validation helpers used by `setup()`. Each helper reads `t[key]`,
-- substitutes a fallback when invalid, and emits a single `utils.warn`
-- with a uniform message. Conventions:
--
--   * `opts.path`   overrides the displayed key path (e.g. "view.inline.style").
--   * `opts.nilable` allows `nil` without warning or substitution.
--   * Tables and lists are deep-cloned from the fallback so config
--     instances never alias `M.defaults`.

---@param val any
---@param path string
---@param expected string
local function warn_invalid(val, path, expected)
  -- For non-primitive values, omit the literal value: `tostring` on a table
  -- prints "table: 0x..." which only adds noise.
  local t = type(val)
  if t == "table" or t == "function" or t == "userdata" or t == "thread" then
    utils.warn(("Invalid value for '%s'. Must be %s."):format(path, expected))
  else
    utils.warn(("Invalid value '%s' for '%s'. Must be %s."):format(tostring(val), path, expected))
  end
end

---@param fallback any
---@return any
local function fallback_value(fallback)
  return type(fallback) == "table" and utils.tbl_deep_clone(fallback) or fallback
end

local validate = {}

---@param t table
---@param key any
---@param valid_values vector
---@param fallback any
---@param opts? { nilable?: boolean, path?: string }
function validate.enum(t, key, valid_values, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  if not vim.tbl_contains(valid_values, v) then
    warn_invalid(
      v,
      opts.path or tostring(key),
      ("one of (%s)%s"):format(fmt_enum(valid_values), opts.nilable and " or nil" or "")
    )
    t[key] = fallback_value(fallback)
  end
end

---@param t table
---@param key any
---@param fallback any
---@param opts? { min?: number, max?: number, nilable?: boolean, path?: string }
function validate.integer(t, key, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  local n = tonumber(v)
  if not n or n % 1 ~= 0 or (opts.min and n < opts.min) or (opts.max and n > opts.max) then
    local expected
    if opts.min and opts.max then
      expected = ("an integer between %s and %s"):format(opts.min, opts.max)
    elseif opts.min then
      expected = ("an integer >= %s"):format(opts.min)
    elseif opts.max then
      expected = ("an integer <= %s"):format(opts.max)
    else
      expected = "an integer"
    end
    warn_invalid(v, opts.path or tostring(key), expected .. (opts.nilable and ", or nil" or ""))
    t[key] = fallback_value(fallback)
  else
    -- Persist the coerced numeric form (e.g. "40" -> 40).
    t[key] = n
  end
end

-- Common boolean-like spellings, case-insensitive for strings. Configs
-- migrated from other languages frequently use these forms, and pre-validator
-- diffview accepted any truthy value via Lua's truthiness rules; coercing
-- preserves those setups while still rejecting genuinely wrong types.
local boolean_coercion = {
  ["true"] = true,
  ["yes"] = true,
  ["on"] = true,
  ["false"] = false,
  ["no"] = false,
  ["off"] = false,
}

---@param t table
---@param key any
---@param fallback any
---@param opts? { nilable?: boolean, path?: string }
function validate.boolean(t, key, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  if type(v) == "boolean" then
    return
  end
  if type(v) == "string" then
    local coerced = boolean_coercion[v:lower()]
    if coerced ~= nil then
      t[key] = coerced
      return
    end
  elseif type(v) == "number" then
    if v == 1 then
      t[key] = true
      return
    elseif v == 0 then
      t[key] = false
      return
    end
  end
  warn_invalid(v, opts.path or tostring(key), "a boolean" .. (opts.nilable and " or nil" or ""))
  t[key] = fallback_value(fallback)
end

---@param t table
---@param key any
---@param fallback any
---@param opts? { nilable?: boolean, path?: string }
function validate.string(t, key, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  if type(v) ~= "string" then
    warn_invalid(v, opts.path or tostring(key), "a string" .. (opts.nilable and " or nil" or ""))
    t[key] = fallback_value(fallback)
  end
end

---@param t table
---@param key any
---@param fallback any
---@param opts? { nilable?: boolean, path?: string }
function validate.table(t, key, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  if type(v) ~= "table" then
    warn_invalid(v, opts.path or tostring(key), "a table" .. (opts.nilable and " or nil" or ""))
    t[key] = fallback_value(fallback)
  end
end

---@param t table
---@param key any
---@param fallback any
---@param opts? { nilable?: boolean, path?: string }
function validate.list(t, key, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  if type(v) ~= "table" or not utils.islist(v) then
    warn_invalid(v, opts.path or tostring(key), "a list" .. (opts.nilable and " or nil" or ""))
    t[key] = fallback_value(fallback)
  end
end

-- For list helpers below: the container itself is validated strictly (a
-- non-list falls back to the default), but invalid *elements* are filtered
-- out (with a per-element warning) rather than nuking the user's whole list.
-- This preserves the user's good entries when they typo one of many.

---@param t table
---@param key any
---@param fallback any
---@param opts? { nilable?: boolean, path?: string }
function validate.string_list(t, key, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  if type(v) ~= "table" or not utils.islist(v) then
    warn_invalid(
      v,
      opts.path or tostring(key),
      "a list of strings" .. (opts.nilable and " or nil" or "")
    )
    t[key] = fallback_value(fallback)
    return
  end
  local filtered = {}
  for i, item in ipairs(v) do
    if type(item) == "string" then
      filtered[#filtered + 1] = item
    else
      warn_invalid(item, ("%s[%d]"):format(opts.path or tostring(key), i), "a string")
    end
  end
  t[key] = filtered
end

---@param t table
---@param key any
---@param valid_values vector
---@param fallback any
---@param opts? { nilable?: boolean, path?: string }
function validate.enum_list(t, key, valid_values, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  if type(v) ~= "table" or not utils.islist(v) then
    warn_invalid(v, opts.path or tostring(key), "a list" .. (opts.nilable and " or nil" or ""))
    t[key] = fallback_value(fallback)
    return
  end
  local filtered = {}
  for i, item in ipairs(v) do
    if vim.tbl_contains(valid_values, item) then
      filtered[#filtered + 1] = item
    else
      warn_invalid(
        item,
        ("%s[%d]"):format(opts.path or tostring(key), i),
        ("one of (%s)"):format(fmt_enum(valid_values))
      )
    end
  end
  t[key] = filtered
end

---@param t table
---@param key any
---@param allowed_types string[]
---@param fallback any
---@param opts? { nilable?: boolean, path?: string }
function validate.any_of(t, key, allowed_types, fallback, opts)
  opts = opts or {}
  local v = t[key]
  if v == nil then
    if not opts.nilable then
      t[key] = fallback_value(fallback)
    end
    return
  end
  if not vim.tbl_contains(allowed_types, type(v)) then
    warn_invalid(
      v,
      opts.path or tostring(key),
      ("of type (%s)%s"):format(table.concat(allowed_types, "|"), opts.nilable and ", or nil" or "")
    )
    t[key] = fallback_value(fallback)
  end
end

---@param ... table
---@return table
function M.extend_keymaps(...)
  local argc = select("#", ...)
  local argv = { ... }
  local contexts = {}

  for i = 1, argc do
    local cur = argv[i]
    if type(cur) == "table" then
      contexts[#contexts + 1] = { subject = cur, expanded = {} }
    end
  end

  for _, ctx in ipairs(contexts) do
    -- Expand the normal mode maps
    for lhs, rhs in pairs(ctx.subject) do
      if type(lhs) == "string" then
        ctx.expanded["n " .. lhs] = {
          "n",
          lhs,
          rhs,
          { silent = true, nowait = true },
        }
      end
    end

    for _, map in ipairs(ctx.subject) do
      for _, mode in ipairs(type(map[1]) == "table" and map[1] or { map[1] }) do
        ctx.expanded[mode .. " " .. map[2]] = utils.vec_join(mode, map[2], utils.vec_slice(map, 3))
      end
    end
  end

  local merged = vim.tbl_extend(
    "force",
    unpack(vim.tbl_map(function(v)
      return v.expanded
    end, contexts))
  )

  return vim.tbl_values(merged)
end

---@param user_config? DiffviewConfig.user
function M.setup(user_config)
  user_config = user_config or {}

  M._config = vim.tbl_deep_extend("force", utils.tbl_deep_clone(M.defaults), user_config)
  ---@type EventEmitter
  M.user_emitter = EventEmitter()

  -- Coarse table guards for containers the deprecation block below indexes
  -- into. Without these, a malformed `file_panel`/`file_history_panel` (e.g.
  -- a boolean or number) would crash before per-field validation could fall
  -- back to defaults.
  validate.table(M._config, "file_panel", M.defaults.file_panel)
  validate.table(M._config, "file_history_panel", M.defaults.file_history_panel)

  --#region DEPRECATION NOTICES

  ---@diagnostic disable-next-line: undefined-field -- Deprecated legacy key, kept for warning-only detection.
  if type(M._config.file_panel.use_icons) ~= "nil" then
    utils.warn("'file_panel.use_icons' has been deprecated. See ':h diffview.changelog-64'.")
  end

  -- Move old panel preoperties to win_config
  local old_win_config_spec = { "position", "width", "height" }
  for _, panel_name in ipairs({ "file_panel", "file_history_panel" }) do
    local panel_config = M._config[panel_name]
    ---@cast panel_config table
    local notified = false

    for _, option in ipairs(old_win_config_spec) do
      if panel_config[option] ~= nil then
        if not notified then
          utils.warn(
            ("'%s.{%s}' has been deprecated. See ':h diffview.changelog-136'."):format(
              panel_name,
              fmt_enum(old_win_config_spec, true)
            )
          )
          notified = true
        end
        -- `win_config` may legitimately be a function (validated below); only
        -- migrate into it when it's still the table shape the old keys
        -- expected. Otherwise drop the deprecated value silently.
        if type(panel_config.win_config) == "table" then
          panel_config.win_config[option] = panel_config[option]
        end
        panel_config[option] = nil
      end
    end
  end

  -- Move old keymaps
  ---@diagnostic disable: undefined-field, inject-field -- `key_bindings` is a deprecated legacy key; the block migrates it onto `keymaps` and clears it.
  if user_config.key_bindings then
    M._config.keymaps = vim.tbl_deep_extend("force", M._config.keymaps, user_config.key_bindings)
    user_config.keymaps = user_config.key_bindings
    M._config.key_bindings = nil
  end
  ---@diagnostic enable: undefined-field, inject-field

  -- `utils.tbl_access` walks the user config directly and would error on
  -- non-table intermediate values like `file_history_panel = 0`, so check
  -- the shape explicitly before reading the deprecated keys.
  local user_log_options
  if
    type(user_config.file_history_panel) == "table"
    and type(user_config.file_history_panel.log_options) == "table"
  then
    user_log_options = user_config.file_history_panel.log_options
  end
  if user_log_options then
    local top_options = {
      "single_file",
      "multi_file",
    }
    for _, name in ipairs(top_options) do
      if user_log_options[name] ~= nil then
        utils.warn(
          "Global config of 'file_panel.log_options' has been deprecated. See ':h diffview.changelog-271'."
        )
        break
      end
    end

    local option_names = {
      "max_count",
      "follow",
      "all",
      "merges",
      "no_merges",
      "reverse",
    }
    for _, name in ipairs(option_names) do
      if user_log_options[name] ~= nil then
        utils.warn(
          ("'file_history_panel.log_options.{%s}' has been deprecated. See ':h diffview.changelog-151'."):format(
            fmt_enum(option_names, true)
          )
        )
        break
      end
    end
  end

  --#endregion

  -- ============================================================================
  -- Validation
  -- ============================================================================
  -- Each option is validated against its declared shape and falls back to the
  -- value declared in `M.defaults` (with `utils.warn`) when invalid. See the
  -- `validate.*` helpers near the top of this file for conventions.

  local c = M._config
  local d = M.defaults

  -- Top-level scalars and command lists.
  validate.boolean(c, "diff_binaries", d.diff_binaries)
  validate.boolean(c, "enhanced_diff_hl", d.enhanced_diff_hl)
  validate.string_list(c, "git_cmd", d.git_cmd)
  validate.string_list(c, "hg_cmd", d.hg_cmd)
  validate.string_list(c, "jj_cmd", d.jj_cmd)
  validate.string_list(c, "p4_cmd", d.p4_cmd)
  -- An empty command list would not be usable; substitute the default so the
  -- adapter detection logic later in setup can still pick an executable.
  for _, cmd_key in ipairs({ "git_cmd", "hg_cmd", "jj_cmd", "p4_cmd" }) do
    if #c[cmd_key] == 0 then
      c[cmd_key] = utils.tbl_deep_clone(d[cmd_key])
    end
  end
  validate.enum(c, "preferred_adapter", { "git", "hg", "jj", "p4" }, d.preferred_adapter, {
    nilable = true,
  })
  validate.integer(c, "rename_threshold", d.rename_threshold, {
    min = 0,
    max = 100,
    nilable = true,
  })
  validate.boolean(c, "use_icons", d.use_icons)
  validate.boolean(c, "show_help_hints", d.show_help_hints)
  validate.boolean(c, "show_root_path", d.show_root_path)
  validate.boolean(c, "watch_index", d.watch_index)
  validate.boolean(c, "hide_merge_artifacts", d.hide_merge_artifacts)
  validate.boolean(c, "auto_close_on_empty", d.auto_close_on_empty)
  validate.boolean(c, "wrap_entries", d.wrap_entries)
  validate.integer(c, "large_file_threshold", d.large_file_threshold, { min = 0 })
  validate.table(c, "diffopt", d.diffopt)
  validate.boolean(c, "clean_up_buffers", d.clean_up_buffers)
  validate.boolean(c, "restore_session", d.restore_session)

  -- persist_selections
  validate.table(c, "persist_selections", d.persist_selections)
  validate.boolean(c.persist_selections, "enabled", d.persist_selections.enabled, {
    path = "persist_selections.enabled",
  })
  validate.string(c.persist_selections, "path", d.persist_selections.path, {
    path = "persist_selections.path",
    nilable = true,
  })

  -- icons (folder icons)
  validate.table(c, "icons", d.icons)
  validate.string(c.icons, "folder_closed", d.icons.folder_closed, {
    path = "icons.folder_closed",
  })
  validate.string(c.icons, "folder_open", d.icons.folder_open, {
    path = "icons.folder_open",
  })

  -- status_icons: keys are git status codes (single chars like "A", "?"),
  -- values are display strings.
  validate.table(c, "status_icons", d.status_icons)
  for status_key in pairs(d.status_icons) do
    validate.string(c.status_icons, status_key, d.status_icons[status_key], {
      path = ("status_icons[%q]"):format(status_key),
    })
  end

  -- signs
  validate.table(c, "signs", d.signs)
  for sign_key in pairs(d.signs) do
    validate.string(c.signs, sign_key, d.signs[sign_key], {
      path = "signs." .. sign_key,
    })
  end

  -- view
  validate.table(c, "view", d.view)
  local view = c.view
  -- Concrete layout names. `view.*.layout` additionally accepts the `-1`
  -- "infer from diffopt" sentinel; `view.cycle_layouts.*` does not, since
  -- cycling needs concrete layouts to rotate through (`cycle_layout` drops
  -- any unresolvable entry).
  local standard_concrete = { "diff1_plain", "diff1_inline", "diff2_horizontal", "diff2_vertical" }
  local merge_concrete =
    { "diff1_plain", "diff3_horizontal", "diff3_vertical", "diff3_mixed", "diff4_mixed" }
  local standard_layouts = utils.vec_join(standard_concrete, -1)
  local merge_layouts = utils.vec_join(merge_concrete, -1)
  local layouts_for_kind = {
    default = standard_layouts,
    merge_tool = merge_layouts,
    file_history = standard_layouts,
  }
  for _, kind in ipairs({ "default", "merge_tool", "file_history" }) do
    validate.table(view, kind, d.view[kind], { path = "view." .. kind })
    validate.enum(view[kind], "layout", layouts_for_kind[kind], d.view[kind].layout, {
      path = ("view.%s.layout"):format(kind),
    })
    for _, flag in ipairs({ "disable_diagnostics", "winbar_info", "focus_diff" }) do
      validate.boolean(view[kind], flag, d.view[kind][flag], {
        path = ("view.%s.%s"):format(kind, flag),
      })
    end
  end
  -- `pin_local` is documented and defaulted only on `file_history`.
  validate.boolean(view.file_history, "pin_local", d.view.file_history.pin_local, {
    path = "view.file_history.pin_local",
  })

  validate.integer(view, "foldlevel", d.view.foldlevel, {
    min = 0,
    path = "view.foldlevel",
  })

  validate.enum(view, "one_sided_layout", { "default", "raw" }, d.view.one_sided_layout, {
    path = "view.one_sided_layout",
  })

  validate.table(view, "cycle_layouts", d.view.cycle_layouts, { path = "view.cycle_layouts" })
  validate.enum_list(
    view.cycle_layouts,
    "default",
    standard_concrete,
    d.view.cycle_layouts.default,
    { path = "view.cycle_layouts.default" }
  )
  validate.enum_list(
    view.cycle_layouts,
    "merge_tool",
    merge_concrete,
    d.view.cycle_layouts.merge_tool,
    { path = "view.cycle_layouts.merge_tool" }
  )
  -- Ensure each view's configured layout is in its corresponding cycle list,
  -- so `cycle_layout` (g<C-x>) can always rotate back to the starting layout.
  -- The sentinel `-1` ("infer from diffopt") is skipped since the concrete
  -- layout is not known at setup time. Iterate in a fixed order so shared
  -- cycle lists (e.g. `default` is used by both `default` and `file_history`)
  -- get deterministic entries.
  for _, item in ipairs({
    { kind = "default", cycle_key = "default" },
    { kind = "file_history", cycle_key = "default" },
    { kind = "merge_tool", cycle_key = "merge_tool" },
  }) do
    local layout = view[item.kind].layout
    local list = view.cycle_layouts[item.cycle_key]
    if layout and layout ~= -1 and not vim.tbl_contains(list, layout) then
      table.insert(list, layout)
    end
  end

  validate.table(view, "inline", d.view.inline, { path = "view.inline" })
  validate.enum(view.inline, "style", { "unified", "overleaf" }, d.view.inline.style, {
    path = "view.inline.style",
  })
  validate.enum(
    view.inline,
    "deletion_highlight",
    { "text", "full_width", "hanging" },
    d.view.inline.deletion_highlight,
    { path = "view.inline.deletion_highlight" }
  )
  validate.boolean(view.inline, "deletion_treesitter", d.view.inline.deletion_treesitter, {
    path = "view.inline.deletion_treesitter",
  })

  -- file_panel
  validate.table(c, "file_panel", d.file_panel)
  local file_panel = c.file_panel
  validate.enum(file_panel, "listing_style", { "tree", "list" }, d.file_panel.listing_style, {
    path = "file_panel.listing_style",
  })
  validate.any_of(file_panel, "sort_file", { "function" }, d.file_panel.sort_file, {
    nilable = true,
    path = "file_panel.sort_file",
  })
  validate.table(file_panel, "tree_options", d.file_panel.tree_options, {
    path = "file_panel.tree_options",
  })
  validate.boolean(
    file_panel.tree_options,
    "flatten_dirs",
    d.file_panel.tree_options.flatten_dirs,
    { path = "file_panel.tree_options.flatten_dirs" }
  )
  validate.enum(
    file_panel.tree_options,
    "folder_statuses",
    { "never", "only_folded", "always" },
    d.file_panel.tree_options.folder_statuses,
    { path = "file_panel.tree_options.folder_statuses" }
  )
  validate.enum(
    file_panel.tree_options,
    "folder_count_style",
    { "grouped", "simple", "none" },
    d.file_panel.tree_options.folder_count_style,
    { path = "file_panel.tree_options.folder_count_style" }
  )
  validate.boolean(
    file_panel.tree_options,
    "folder_trailing_slash",
    d.file_panel.tree_options.folder_trailing_slash,
    { path = "file_panel.tree_options.folder_trailing_slash" }
  )
  validate.table(file_panel, "list_options", d.file_panel.list_options, {
    path = "file_panel.list_options",
  })
  validate.enum(
    file_panel.list_options,
    "path_style",
    { "basename", "full" },
    d.file_panel.list_options.path_style,
    { path = "file_panel.list_options.path_style" }
  )
  validate.any_of(
    file_panel,
    "win_config",
    { "table", "function" },
    d.file_panel.win_config,
    { path = "file_panel.win_config" }
  )
  validate.boolean(file_panel, "show", d.file_panel.show, { path = "file_panel.show" })
  validate.boolean(
    file_panel,
    "always_show_sections",
    d.file_panel.always_show_sections,
    { path = "file_panel.always_show_sections" }
  )
  validate.boolean(file_panel, "always_show_marks", d.file_panel.always_show_marks, {
    path = "file_panel.always_show_marks",
  })
  validate.enum(
    file_panel,
    "mark_placement",
    { "inline", "sign_column" },
    d.file_panel.mark_placement,
    { path = "file_panel.mark_placement" }
  )
  validate.boolean(file_panel, "show_branch_name", d.file_panel.show_branch_name, {
    path = "file_panel.show_branch_name",
  })

  -- file_history_panel
  validate.table(c, "file_history_panel", d.file_history_panel)
  local fhp = c.file_history_panel
  validate.enum(
    fhp,
    "stat_style",
    { "number", "bar", "both" },
    d.file_history_panel.stat_style,
    { path = "file_history_panel.stat_style" }
  )
  validate.enum(
    fhp,
    "subject_highlight",
    { "ref_aware", "merge_aware", "plain" },
    d.file_history_panel.subject_highlight,
    { path = "file_history_panel.subject_highlight" }
  )
  validate.enum_list(
    fhp,
    "commit_format",
    { "status", "files", "stats", "hash", "reflog", "ref", "subject", "author", "date" },
    d.file_history_panel.commit_format,
    { path = "file_history_panel.commit_format" }
  )
  -- An empty `commit_format` would render commits with no info, so fall back
  -- to the default whether the user explicitly passed `{}` or filtering
  -- dropped every element.
  if #fhp.commit_format == 0 then
    utils.warn("Invalid value for 'file_history_panel.commit_format'. Must be a non-empty list.")
    fhp.commit_format = utils.tbl_deep_clone(d.file_history_panel.commit_format)
  end
  validate.table(fhp, "log_options", d.file_history_panel.log_options, {
    path = "file_history_panel.log_options",
  })
  -- Validate each per-VCS branch and its `single_file`/`multi_file` children
  -- before the merge loop below indexes and extends them. Without these,
  -- a config like `log_options = { git = 0 }` would crash setup.
  for _, vcs in ipairs({ "git", "hg", "jj", "p4" }) do
    validate.table(fhp.log_options, vcs, d.file_history_panel.log_options[vcs], {
      path = ("file_history_panel.log_options.%s"):format(vcs),
    })
    for _, name in ipairs({ "single_file", "multi_file" }) do
      validate.table(
        fhp.log_options[vcs],
        name,
        d.file_history_panel.log_options[vcs][name],
        { path = ("file_history_panel.log_options.%s.%s"):format(vcs, name) }
      )
    end
  end
  validate.any_of(
    fhp,
    "win_config",
    { "table", "function" },
    d.file_history_panel.win_config,
    { path = "file_history_panel.win_config" }
  )
  validate.boolean(fhp, "show", d.file_history_panel.show, { path = "file_history_panel.show" })
  validate.integer(
    fhp,
    "commit_subject_max_length",
    d.file_history_panel.commit_subject_max_length,
    { min = 0, path = "file_history_panel.commit_subject_max_length" }
  )
  validate.enum(
    fhp,
    "date_format",
    { "auto", "relative", "iso" },
    d.file_history_panel.date_format,
    { path = "file_history_panel.date_format" }
  )

  -- commit_log_panel
  validate.table(c, "commit_log_panel", d.commit_log_panel)
  validate.any_of(
    c.commit_log_panel,
    "win_config",
    { "table", "function" },
    d.commit_log_panel.win_config,
    { path = "commit_log_panel.win_config" }
  )

  -- default_args
  validate.table(c, "default_args", d.default_args)
  validate.string_list(c.default_args, "DiffviewOpen", d.default_args.DiffviewOpen, {
    path = "default_args.DiffviewOpen",
  })
  validate.string_list(
    c.default_args,
    "DiffviewFileHistory",
    d.default_args.DiffviewFileHistory,
    { path = "default_args.DiffviewFileHistory" }
  )

  -- hooks and keymaps. Only the containers are validated here (plus
  -- `keymaps.disable_defaults`, which is branched on below); individual hook
  -- callbacks and keymap entries are type-checked where they are consumed.
  validate.table(c, "hooks", d.hooks)
  validate.table(c, "keymaps", d.keymaps)
  validate.boolean(c.keymaps, "disable_defaults", d.keymaps.disable_defaults, {
    path = "keymaps.disable_defaults",
  })

  for _, name in ipairs({ "single_file", "multi_file" }) do
    for _, vcs in ipairs({ "git", "hg", "jj", "p4" }) do
      local t = M._config.file_history_panel.log_options[vcs]
      t[name] = vim.tbl_extend("force", utils.tbl_deep_clone(M.log_option_defaults[vcs]), t[name])
      for k, _ in pairs(t[name]) do
        if t[name][k] == "" then
          t[name][k] = nil
        end
      end
    end
  end

  for event, callback in pairs(M._config.hooks) do
    if type(callback) == "function" then
      M.user_emitter:on(event, function(_, ...)
        callback(...)
      end)
    end
  end

  -- `M._config.keymaps` is validated to a table above, but the merge below
  -- reads the user's overrides from `user_config` directly. Index that
  -- through a shape-checked local: `utils.tbl_access` would error when
  -- `user_config.keymaps` is a truthy non-table (e.g. a number).
  local user_keymaps = type(user_config.keymaps) == "table" and user_config.keymaps or {}

  if M._config.keymaps.disable_defaults then
    for name, _ in pairs(M._config.keymaps) do
      if name ~= "disable_defaults" then
        M._config.keymaps[name] = user_keymaps[name] or {}
      end
    end
  else
    M._config.keymaps = utils.tbl_clone(M.defaults.keymaps)
  end

  -- Merge default and user keymaps
  for name, keymap in pairs(M._config.keymaps) do
    if type(name) == "string" and type(keymap) == "table" then
      M._config.keymaps[name] = M.extend_keymaps(keymap, user_keymaps[name] or {})
    end
  end

  -- Disable keymaps set to `false`
  for name, keymaps in pairs(M._config.keymaps) do
    if type(name) == "string" and type(keymaps) == "table" then
      for i = #keymaps, 1, -1 do
        local v = keymaps[i]
        if type(v) == "table" and not v[3] then
          table.remove(keymaps, i)
        end
      end
    end
  end

  setup_done = true
end

M.actions = actions
return M
