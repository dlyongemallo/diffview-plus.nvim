local async = require("diffview.async")
local debounce = require("diffview.debounce")
local lazy = require("diffview.lazy")
local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
local Layout = require("diffview.scene.layout").Layout

local await, pawait = async.await, async.pawait
local oop = require("diffview.oop")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local inline_diff = lazy.require("diffview.scene.inline_diff") ---@module "diffview.scene.inline_diff"

local api = vim.api
local M = {}

---Parse the currently-effective `vim.opt.diffopt` (after Diffview's
---`apply_diffopt` has merged any `view.diffopt` overrides) into the subset of
---options the inline renderer cares about. Reading the global option means the
---inline view honours both the user's existing `'diffopt'` and the per-view
---overrides applied by `scene/view.lua:apply_diffopt`.
---
---`indent_heuristic` is always set to an explicit boolean so its absence from
---`'diffopt'` forces `vim.diff` to disable the heuristic instead of falling
---back to whatever default the vim.diff implementation currently uses.
---
---`linematch` defaults to 60 (git's default) so a single modify-hunk whose
---old and new sides differ in length is split into properly-aligned
---sub-hunks. Without it, the renderer pairs lines positionally inside the
---one large hunk, so e.g., commenting-out a block (8 old lines vs 9 new
---lines: a new TEMP header plus 8 lines each gaining a `-- ` prefix) pairs
---every `vim.api.nvim_set_hl(...)` line with the wrong commented copy,
---producing > `INTRALINE_MAX_HUNKS` per pair and falling back to whole-line
---add+delete instead of showing only the `-- ` insertion. The user's
---`'diffopt'` `linematch:N` entry overrides this default (including `0` to
---opt back into positional pairing).
---@return InlineDiffOpts
local function effective_diffopt()
  local out = { indent_heuristic = false, linematch = 60 }
  local diffopt = vim.opt.diffopt --[[@as vim.Option]]
  for _, v in
    ipairs(diffopt:get() --[[@as string[] ]])
  do
    local key, val = v:match("^([%w_-]+):(.+)$")
    if key == "algorithm" then
      out.algorithm = val
    elseif key == "linematch" then
      out.linematch = tonumber(val)
    elseif v == "indent-heuristic" then
      out.indent_heuristic = true
    elseif v == "iwhite" then
      out.ignore_whitespace_change = true
    elseif v == "iwhiteall" then
      out.ignore_whitespace = true
    elseif v == "iwhiteeol" then
      out.ignore_whitespace_change_at_eol = true
    elseif v == "iblank" then
      out.ignore_blank_lines = true
    end
  end
  return out
end

---The autocmd group for buffer-local repaint hooks. Shared across all
---Diff1Inline instances; individual buffers are cleaned up by clearing
---autocmds scoped to `{ group = ..., buffer = bufnr }`.
local repaint_augroup = api.nvim_create_augroup("diffview_inline_repaint", { clear = false })

---Debounce delay (ms) for `TextChangedI`-driven repaints. Long enough to
---coalesce bursts of keystrokes into a single diff pass, short enough that
---the deletion markers feel responsive while the user is still typing.
local INSERT_REPAINT_DEBOUNCE_MS = 150

---Debounce delay (ms) for `WinResized`/`VimResized`-driven repaints.
---Coalesces a drag-resize burst (the events can fire many times per second)
---into a single re-emit so the per-resize-step diff cost doesn't pile up.
local RESIZE_REPAINT_DEBOUNCE_MS = 100

---@class Diff1Inline : Diff1
---@field a_file vcs.File? Old-side file used only to compute the diff (never rendered in a window).
---@field _cached_old_lines string[]? Old-side content captured on first render; reused by repaints so each keystroke-level refresh doesn't re-fetch from disk.
---@field _render_generation integer Bumped on every state transition that invalidates in-flight render work: file swap (`use_entry`), render teardown (`teardown_render`, which covers `destroy` and `FileEntry:convert_layout`), and recreate (`create`). Async passes capture the value at entry and bail when it changes mid-flight, so a stale `_load_old_lines` callback can't overwrite `_cached_old_lines` for a file the user has navigated past or render onto a buffer the view no longer owns. Also covers cached-instance reuse: `StandardView` keeps one layout per class and re-runs `create` on the same instance after a prior `destroy`, so a sticky destroyed flag would block reuse; the monotonic counter does not.
---@field _repaint_bufnr integer? Buffer id the repaint autocmds are attached to (nil when no autocmds are installed).
---@field _repaint_debounced CancellableFn? Trailing-edge debounced `_repaint` used for the insert-mode `TextChangedI` hook.
---@field _suppress_repaint boolean? Set by batched buffer edits (e.g. a multi-hunk `diffget`) to turn `_repaint` into a no-op so a single trailing call covers the whole batch.
---@field _resize_autocmd integer? Autocmd id for the global WinResized/VimResized handler that re-emits `full_width` deletion padding when the window dimensions change.
---@field _resize_debounced CancellableFn? Trailing-edge debounced `_repaint` used by the resize handler so a drag-resize burst coalesces into one re-emit.
local Diff1Inline = oop.create_class("Diff1Inline", Diff1)

---@class Diff1Inline.init.Opt : Diff1.init.Opt
---@field a vcs.File?

Diff1Inline.name = "diff1_inline"
Diff1Inline.symbols = { "b" }

---@param opt Diff1Inline.init.Opt
function Diff1Inline:init(opt)
  self:super(opt)
  self:_set_a_file(opt and opt.a or nil)
  -- Start at 0 so every call site can do a plain `+ 1` without a nil
  -- check, and so capture-then-yield sequences always compare two
  -- numbers (a nil-vs-number compare reads `true` on swap but would
  -- read `false` on the very first render before any bump).
  self._render_generation = 0
end

---Assign the old-side file, tagging `symbol = "a"` so `vcs.File:produce_data()`
---resolves the left position when invoking a `get_data` producer.
---@param file vcs.File?
function Diff1Inline:_set_a_file(file)
  self.a_file = file
  if file then
    file.symbol = "a"
  end
end

---@override
---@return Diff1Inline
function Diff1Inline:clone()
  local clone = Layout.clone(self) --[[@as Diff1Inline ]]
  clone.a_file = self.a_file
  return clone
end

---True iff an in-flight async render pass started at `generation` is still
---the current one. Used as the post-yield guard in `_prerender`,
---`_render_inline`, and the surrounding `create`/`use_entry` paths so a
---racing file swap or view-close cannot resume into a stale write of
---`_cached_old_lines` or a render against a disposed window. Teardown is
---detected the same way: `teardown_render` bumps the generation (covering
---both `destroy` and `FileEntry:convert_layout`), so any pass that
---captured the pre-teardown value fails this check on resume.
---@param generation integer The value of `_render_generation` captured at
---the start of the pass.
---@return boolean
function Diff1Inline:_is_active_render(generation)
  return self._render_generation == generation
end

---@override
---@param self Diff1Inline
---@param pivot integer?
Diff1Inline.create = async.void(function(self, pivot)
  -- Bump and capture so a previous lifecycle's straggler (`StandardView`
  -- keeps one layout per class and re-runs `create` on the same instance
  -- after `destroy`) bails on its post-yield guard via a generation
  -- mismatch. Capturing AFTER the bump means this lifecycle's own awaits
  -- compare equal as long as nothing intervenes.
  self._render_generation = self._render_generation + 1
  local generation = self._render_generation
  -- See `_prerender` for rationale.
  await(self:_prerender())
  -- `_prerender` yields on the b-side load and on the a-side `produce_data`
  -- fetch. If the view was closed or the layout swapped in the meantime,
  -- `destroy` / `use_entry` will have bumped `_render_generation`; calling
  -- `create_wins` against a disposed layout would build orphaned windows.
  if not self:_is_active_render(generation) then
    return
  end
  await(self:create_wins(pivot, {
    { "b", "aboveleft vsp" },
  }, { "b" }))
  if not self:_is_active_render(generation) then
    return
  end
  -- `_prerender` already laid down the extmarks; only the window-scoped
  -- state remains.
  self:_install_window_hooks()
end)

---@override
---Scope the inline namespace to the b window before `open_files` yields,
---closing the redraw window that would otherwise leak `_prerender`'s
---extmarks into other windows showing the same buffer (issue #156).
---
---For `full_width` deletions, follow up with a `_repaint` after the buffer
---is on screen: the create-path `_prerender` ran before `self.b.id` existed,
---so the pad target wasn't sized to the window. Gated on `full_width` to
---keep the render-once invariant for other styles.
---@param self Diff1Inline
Diff1Inline.create_post = async.void(function(self)
  self:open_null()
  -- `self.b:is_valid()` covers both `self.b.id` being set and the underlying
  -- window still existing; without it, a torn-down layout would feed `nil`
  -- into `nvim_win_is_valid` inside `attach_to_window` and throw.
  if
    self.b
    and self.b:is_valid()
    and self.b.file
    and self.b.file.bufnr
    and api.nvim_buf_is_valid(self.b.file.bufnr)
    and not self.b.file.binary
  then
    inline_diff.attach_to_window(self.b.file.bufnr --[[@as integer ]], self.b.id)
  end
  await(self:open_files())
  vim.opt.equalalways = self.state.save_equalalways
  local inline_opt = config.get_config().view.inline or {}
  if inline_opt.deletion_highlight == "full_width" then
    self:_repaint()
  end
end)

---@override
---@param self Diff1Inline
---@param entry FileEntry
Diff1Inline.use_entry = async.void(function(self, entry)
  local src = entry.layout
  assert(src:instanceof(self.class))
  ---@cast src Diff1Inline

  self:set_file_for("b", src.b.file)
  self:_set_a_file(src.a_file)
  -- File swap: invalidate cached old content so the next render re-fetches,
  -- and bump the render generation so a still-in-flight `_prerender` from
  -- a previous swap bails when its `_load_old_lines` callback finally fires
  -- (would otherwise overwrite `_cached_old_lines` with stale content for
  -- a file the user has already navigated past).
  self._cached_old_lines = nil
  self._render_generation = self._render_generation + 1
  local generation = self._render_generation

  if self:is_valid() then
    -- See `_prerender` for rationale.
    await(self:_prerender())
    if not self:_is_active_render(generation) or not self:is_valid() then
      return
    end
    await(self:open_files())
    if not self:_is_active_render(generation) then
      return
    end
    self:_install_window_hooks()
  end
end)

---Fetch the raw lines of the old-side file for diff computation.
---@param self Diff1Inline
---@param callback fun(lines: string[])
Diff1Inline._load_old_lines = async.wrap(function(self, callback)
  -- For a deletion (nulled b-side) resolve binary-ness from the a-side, where
  -- the file still exists; else a deleted binary file's bytes would render as
  -- virt_lines. Skipped for a non-nulled (modified) b-side.
  if
    self.a_file
    and self.a_file.binary == nil
    and self.b
    and self.b.file
    and self.b.file.nulled
    and not config.get_config().diff_binaries
  then
    self.a_file.binary = self.a_file.adapter:is_binary(self.a_file.path, self.a_file.rev)
  end
  if not self.a_file or self.a_file.nulled or self.a_file.binary then
    callback({})
    return
  end

  if self.a_file:is_valid() then
    callback(api.nvim_buf_get_lines(self.a_file.bufnr --[[@as integer ]], 0, -1, false))
    return
  end

  ---@diagnostic disable-next-line: invisible -- `produce_data` is internal to `vcs.File`, but the inline renderer needs to pre-fetch the old side without creating a buffer.
  local ok, err, data = pawait(self.a_file.produce_data, self.a_file)
  if not ok or err or not data then
    callback({})
    return
  end

  callback(data)
end)

---Build the options table forwarded to `inline_diff.render`. Merges the
---effective global `'diffopt'` with the configured inline style.
---
---`winid` is forwarded as the `full_width` pad-target hint so `_prerender`
---can size deletion padding before the b buffer is displayed.
---@param winid integer?
---@return InlineDiffOpts
local function render_opts(winid)
  local opts = effective_diffopt()
  local inline_opt = config.get_config().view.inline or {}
  opts.style = inline_opt.style
  opts.deletion_highlight = inline_opt.deletion_highlight
  opts.deletion_treesitter = inline_opt.deletion_treesitter
  if winid and api.nvim_win_is_valid(winid) then
    opts.winid = winid
  end
  return opts
end

---Render the inline diff onto the b-side buffer BEFORE it becomes visible
---in the window so the first redraw that shows the buffer also shows its
---highlights. See issue #172.
---
---The `async.scheduler()` step escapes the fast event context that
---`produce_data` callbacks land in; without it, the caller's next `await`
---(`open_files` running `vim.cmd("diffoff!")`) would hit `E5560`.
---@param self Diff1Inline
Diff1Inline._prerender = async.void(function(self)
  if not (self.b and self.b.file) then
    return
  end
  -- Skip binary outright (nothing textual to diff). Nulled b-files are not
  -- skipped: a deletion still needs the old-side content rendered as
  -- virt_lines (the "1 added empty line" overshoot from issue #172 is
  -- suppressed below by feeding `render` an empty `new_lines`).
  if self.b.file.binary then
    return
  end
  -- Capture the generation before any yield so we can detect a concurrent
  -- file swap or layout teardown on resumption.
  local generation = self._render_generation
  if not self.b.file:is_valid() then
    if not self.b.file.active then
      return
    end
    await(self.b:load_file())
  end

  if not self:_is_active_render(generation) then
    return
  end
  if not (self.b and self.b.file and self.b.file:is_valid()) then
    return
  end
  -- `binary` may have been nil before `load_file` ran; `create_buffer`
  -- resolves it lazily and points `bufnr` at the shared NULL buffer when
  -- the file turns out to be binary. Re-check before rendering so we don't
  -- lay extmarks onto NULL_FILE.
  if self.b.file.binary then
    return
  end
  local bufnr = self.b.file.bufnr --[[@as integer ]]
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  if self._cached_old_lines == nil then
    local old_lines = await(self:_load_old_lines())
    await(async.scheduler())
    if not self:_is_active_render(generation) then
      return
    end
    -- Bail if the b-side file was swapped (bufnr differs) or the buffer
    -- was destroyed while awaiting; otherwise we'd render onto a stale
    -- buffer that no longer matches `self.b.file`.
    if
      not (self.b and self.b.file and self.b.file.bufnr == bufnr and api.nvim_buf_is_valid(bufnr))
    then
      return
    end
    self._cached_old_lines = old_lines
  end

  -- A nulled b-file shares the empty `NULL_FILE` buffer; reading its lines
  -- yields `{""}` which `vim.diff` would treat as "one added empty line".
  -- Pass `{}` instead so the diff is a pure deletion of the old content.
  local new_lines = self.b.file.nulled and {} or api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- `self.b.id` is the `full_width` pad-target hint: valid in `use_entry`,
  -- nil in `create` (where `create_post` fires a follow-up `_repaint` once
  -- the window exists).
  inline_diff.render(bufnr, self._cached_old_lines, new_lines, render_opts(self.b.id))
  -- Scope the namespace synchronously so the caller's next yield can't
  -- redraw with `M.ns` global and leak the extmarks into other windows
  -- showing the same buffer (issue #156). The `create` path has no window
  -- yet; `create_post` does the equivalent scoping for it.
  if self.b.id and api.nvim_win_is_valid(self.b.id) then
    inline_diff.attach_to_window(bufnr, self.b.id)
  end
end)

---Re-paint extmarks against the buffer's current contents. Called from
---`InsertLeave`/`TextChanged` autocmds so edits are reflected without a
---full view rebuild: the old-side content is frozen (it comes from the
---diff's left revision) and is cached by the initial `_render_inline`,
---so a repaint only re-reads the new-side buffer and calls
---`inline_diff.render` again.
---@param self Diff1Inline
function Diff1Inline:_repaint()
  -- Batched buffer edits toggle this flag so each intermediate `TextChanged`
  -- doesn't trigger a full `vim.diff` + extmark pass; the batch owner fires
  -- a single repaint once all edits are applied.
  if self._suppress_repaint then
    return
  end
  if not (self.b and self.b:is_valid() and self.b.file and self.b.file:is_valid()) then
    return
  end
  local bufnr = self.b.file.bufnr --[[@as integer ]]
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- The cache is populated at the end of the initial `_render_inline`. If
  -- a repaint fires before that completes (e.g. a synthetic TextChanged
  -- during buffer setup), skip rather than double-fetch from disk.
  local old_lines = self._cached_old_lines
  if old_lines == nil then
    return
  end

  -- A nulled b-file feeds `render` an empty `new_lines` to suppress the
  -- spurious "1 added empty line" hunk from issue #172 (see `_prerender`).
  -- Needed here too because the `create_post` full_width follow-up calls
  -- `_repaint`.
  local new_lines = self.b.file.nulled and {} or api.nvim_buf_get_lines(bufnr, 0, -1, false)
  inline_diff.render(bufnr, old_lines, new_lines, render_opts(self.b.id))
end

---Install buffer-scoped autocmds that repaint on edits. Fires on any
---normal-mode text change (d/p/x/c/u/<C-r> …), on exit from insert mode,
---and on insert-mode changes via a trailing-edge debounced handler so
---bursts of keystrokes coalesce into a single diff pass instead of
---re-running the full diff on every character. The immediate
---`InsertLeave`/`TextChanged` handler drops any pending debounced call
---before repainting, so a `TextChangedI` followed promptly by
---`InsertLeave` doesn't queue a redundant second repaint. Idempotent:
---if autocmds are already installed for this buffer, this is a no-op.
---@param self Diff1Inline
---@param bufnr integer
local function register_repaint_autocmds(self, bufnr)
  if self._repaint_bufnr == bufnr then
    return
  end
  -- Different buffer than last time (or first install): clear any prior
  -- registration before attaching to the new one, and close any pending
  -- debounce timer so it doesn't fire against the old buffer.
  if self._repaint_bufnr and api.nvim_buf_is_valid(self._repaint_bufnr) then
    pcall(api.nvim_clear_autocmds, { group = repaint_augroup, buffer = self._repaint_bufnr })
  end
  if self._repaint_debounced then
    self._repaint_debounced:close()
  end
  self._repaint_bufnr = bufnr
  self._repaint_debounced = debounce.debounce_trailing(INSERT_REPAINT_DEBOUNCE_MS, false, function()
    self:_repaint()
  end)
  api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
    group = repaint_augroup,
    buffer = bufnr,
    callback = function()
      if self._repaint_debounced then
        self._repaint_debounced:cancel()
      end
      self:_repaint()
    end,
  })
  api.nvim_create_autocmd("TextChangedI", {
    group = repaint_augroup,
    buffer = bufnr,
    callback = function()
      self._repaint_debounced()
    end,
  })
  -- Resize handler: `full_width` deletion padding is sized to the displayed
  -- window width, so a width change requires re-emitting the virt_lines with
  -- the new pad target. Buffer-scoped autocmds don't see WinResized (it
  -- reports the resized window ids via `v:event.windows`), so this is
  -- registered globally and filters down to our buffer in the callback.
  -- Registered unconditionally (not gated on `deletion_highlight`) so a
  -- runtime switch to `"full_width"` takes effect on the next resize without
  -- needing a re-render to install the autocmd; the callback early-returns
  -- when the current extent doesn't depend on width. Debounced so a
  -- drag-resize burst coalesces into a single re-emit instead of one diff
  -- per intermediate width. Idempotent across re-registrations on the same
  -- instance.
  if not self._resize_autocmd then
    self._resize_debounced = debounce.debounce_trailing(
      RESIZE_REPAINT_DEBOUNCE_MS,
      false,
      function()
        self:_repaint()
      end
    )
    self._resize_autocmd = api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
      group = repaint_augroup,
      callback = function(args)
        local target = self._repaint_bufnr
        if not target or not api.nvim_buf_is_valid(target) then
          return
        end
        local inline_opt = config.get_config().view.inline or {}
        if inline_opt.deletion_highlight ~= "full_width" then
          return
        end
        if args.event == "VimResized" then
          self._resize_debounced()
          return
        end
        local resized = vim.v.event.windows
        if not resized then
          return
        end
        for _, winid in ipairs(resized) do
          if api.nvim_win_is_valid(winid) and api.nvim_win_get_buf(winid) == target then
            self._resize_debounced()
            return
          end
        end
      end,
    })
  end
end

---Install window-scoped state once the b buffer is visible: turn off
---native diff mode (so it doesn't fight the extmark rendering), scope the
---namespace to this window (issue #156), and register repaint autocmds.
---Idempotent.
---@param self Diff1Inline
function Diff1Inline:_install_window_hooks()
  if not (self.b and self.b:is_valid() and self.b.file and self.b.file:is_valid()) then
    return
  end
  -- Binary files have no diff to scope or repaint; skip. Nulled files
  -- (deletions) still need the namespace scope and the winopts override.
  if self.b.file.binary then
    return
  end

  local bufnr = self.b.file.bufnr --[[@as integer ]]
  local winid = self.b.id

  -- Turn off native diff mode on this window so the unified extmark rendering
  -- isn't fighting with diff folds/scrollbind.
  pcall(api.nvim_set_option_value, "diff", false, { win = winid })
  pcall(api.nvim_set_option_value, "scrollbind", false, { win = winid })
  pcall(api.nvim_set_option_value, "cursorbind", false, { win = winid })
  pcall(api.nvim_set_option_value, "foldmethod", "manual", { win = winid })
  pcall(api.nvim_set_option_value, "foldenable", false, { win = winid })

  inline_diff.attach_to_window(bufnr, winid)
  register_repaint_autocmds(self, bufnr)
end

---Apply inline-view winopts on the displayed window and render the unified
---diff as extmarks on the new-side buffer.
---@param self Diff1Inline
Diff1Inline._render_inline = async.void(function(self)
  if not (self.b and self.b:is_valid() and self.b.file and self.b.file:is_valid()) then
    return
  end
  -- See `_prerender` for why only `binary` is skipped here; the nulled
  -- case is handled by passing `new_lines = {}` to `inline_diff.render`.
  if self.b.file.binary then
    return
  end
  local generation = self._render_generation
  local bufnr = self.b.file.bufnr --[[@as integer ]]

  local old_lines = self._cached_old_lines
  if old_lines == nil then
    old_lines = await(self:_load_old_lines())
    await(async.scheduler())
    if not self:_is_active_render(generation) then
      return
    end
    -- Bail if the b-side file was swapped (bufnr differs) or the buffer
    -- was destroyed while awaiting; otherwise we'd render onto a stale
    -- buffer that no longer matches `self.b.file`.
    if
      not (
        self.b
        and self.b:is_valid()
        and self.b.file
        and self.b.file.bufnr == bufnr
        and api.nvim_buf_is_valid(bufnr)
      )
    then
      return
    end
    self._cached_old_lines = old_lines
  end

  local new_lines = self.b.file.nulled and {} or api.nvim_buf_get_lines(bufnr, 0, -1, false)
  inline_diff.render(bufnr, old_lines, new_lines, render_opts(self.b.id))
  self:_install_window_hooks()
end)

---Replace the new-side content of every hunk overlapping `[first, last]`
---(1-indexed, inclusive) with the corresponding old-side content from the
---cached diff. For a single-line range this matches vim's built-in `do`
---on a 2-way diff; for a multi-line visual range it applies every
---overlapping hunk in one pass.
---
---A hunk counts as overlapping when its new-side line range intersects
---`[first, last]`, or (for a pure deletion, where `new_count == 0`) when
---its anchor line is inside the range. Matches are applied bottom-up so
---earlier splices don't shift the anchor positions of later hunks.
---
---Returns the number of hunks applied. `TextChanged` repaints are
---suppressed during the splice and a single `_repaint` is fired at the
---end, so the extmarks are refreshed once regardless of hunk count.
---@param self Diff1Inline
---@param first integer
---@param last integer
---@return integer
function Diff1Inline:diffget(first, last)
  if not (self.b and self.b:is_valid() and self.b.file and self.b.file:is_valid()) then
    return 0
  end
  local bufnr = self.b.file.bufnr --[[@as integer ]]
  if not api.nvim_buf_is_valid(bufnr) then
    return 0
  end

  local old_lines = self._cached_old_lines
  if old_lines == nil then
    return 0
  end

  local hunks = inline_diff.get_hunks(bufnr)
  if not hunks then
    return 0
  end

  local matches = {}
  for _, h in ipairs(hunks) do
    local new_start, new_count = h[3], h[4]
    local overlaps
    if new_count > 0 then
      overlaps = not (new_start + new_count - 1 < first or new_start > last)
    else
      -- Pure deletion: the virt_lines are anchored at line `new_start`
      -- (or line 1 when the deletion is at BOF).
      local anchor = new_start == 0 and 1 or new_start
      overlaps = first <= anchor and anchor <= last
    end
    if overlaps then
      matches[#matches + 1] = h
    end
  end

  if #matches == 0 then
    return 0
  end

  -- Suppress the per-edit `TextChanged` repaint so a multi-hunk batch
  -- doesn't trigger N full re-diffs; a single trailing repaint below
  -- refreshes the extmarks once.
  self._suppress_repaint = true
  local ok, err = pcall(function()
    for i = #matches, 1, -1 do
      local h = matches[i]
      local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
      local repl = {}
      for k = old_start, old_start + old_count - 1 do
        repl[#repl + 1] = old_lines[k] or ""
      end
      local s, e
      if new_count > 0 then
        -- Add or change hunk: replace the new-side block in place.
        s = new_start - 1
        e = new_start - 1 + new_count
      else
        -- Pure deletion: insert after `new_start`, or at BOF when
        -- `new_start == 0`.
        s = new_start
        e = new_start
      end
      api.nvim_buf_set_lines(bufnr, s, e, false, repl)
    end
  end)
  self._suppress_repaint = nil
  if not ok then
    error(err)
  end

  self:_repaint()

  return #matches
end

---@override
---Diff1Inline owns `a_file` even though it isn't attached to a window, so
---expose it through `owned_files()` so `FileEntry:destroy()` can tear it
---down alongside the windowed files. Defer to `Layout:owned_files` for the
---windowed slots so `shared_symbols` (e.g. `Diff1InlinePinned`'s borrowed
---b-side) is honoured in subclasses.
---@return vcs.File[]
function Diff1Inline:owned_files()
  local out = Layout.owned_files(self)
  if self.a_file and not vim.tbl_contains(out, self.a_file) then
    out[#out + 1] = self.a_file
  end
  return out
end

---@override
---`convert_layout` looks up the file for each symbol via this method; expose
---`a_file` under the `"a"` slot so converting to a 2-way layout reuses the
---existing file instead of creating a fresh one (which would orphan the
---old-side buffer).
---@param sym string
---@return vcs.File?
function Diff1Inline:get_file_for(sym)
  if sym == "a" then
    return self.a_file
  end
  return Layout.get_file_for(self, sym)
end

---@override
function Diff1Inline:teardown_render()
  -- Bump first so any in-flight async pass that captured the previous
  -- value (e.g. `_prerender` awaiting a git fetch) fails its post-yield
  -- guard on resume before it can re-populate `_cached_old_lines` or
  -- re-render extmarks onto a buffer the layout no longer owns. Covers
  -- both `destroy` (which calls this) and `FileEntry:convert_layout`,
  -- which tears down the outgoing layout's render state without calling
  -- `destroy`. The `or 0` keeps unit tests that drive `teardown_render`
  -- against a bare instance (no `init`) working; production instances
  -- always carry an integer here.
  self._render_generation = (self._render_generation or 0) + 1
  if self._repaint_bufnr and api.nvim_buf_is_valid(self._repaint_bufnr) then
    pcall(api.nvim_clear_autocmds, { group = repaint_augroup, buffer = self._repaint_bufnr })
  end
  if self._resize_autocmd then
    -- The resize handler is registered globally (not buffer-scoped), so the
    -- buffer-filtered `nvim_clear_autocmds` above doesn't catch it.
    pcall(api.nvim_del_autocmd, self._resize_autocmd)
    self._resize_autocmd = nil
  end
  if self._resize_debounced then
    self._resize_debounced:close()
    self._resize_debounced = nil
  end
  if self._repaint_debounced then
    self._repaint_debounced:close()
    self._repaint_debounced = nil
  end
  self._repaint_bufnr = nil
  self._cached_old_lines = nil
  if self.b and self.b.file and self.b.file.bufnr then
    inline_diff.detach(self.b.file.bufnr)
  end
end

---@override
function Diff1Inline:destroy()
  -- `teardown_render` bumps `_render_generation` so any in-flight async
  -- pass bails on its post-yield guard before `Layout.destroy` closes
  -- the windows.
  self:teardown_render()
  Layout.destroy(self)
end

M.Diff1Inline = Diff1Inline

M._test = {
  effective_diffopt = effective_diffopt,
  render_opts = render_opts,
}

return M
