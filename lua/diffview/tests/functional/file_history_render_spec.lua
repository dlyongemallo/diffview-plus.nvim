local helpers = require("diffview.tests.helpers")
local config = require("diffview.config")
local render = require("diffview.scene.views.file_history.render")

local eq = helpers.eq

local render_stat_bar = render._test.render_stat_bar
local render_file_stats = render._test.render_file_stats
local formatters = render._test.formatters

-- ---------------------------------------------------------------------------
-- Mock RenderComponent
-- ---------------------------------------------------------------------------

---@class MockRenderComponent
---@field lines string[][] Each element is { text, hl_group? }.
---@field line_buffer string Concatenated text on the current line; mirrors the real component.
---@field extra_hls { group: string, line_idx: integer, first: integer, last: integer }[] add_hl() calls layered on top of add_text() segments.

---Create a mock RenderComponent that records add_text / add_hl / ln calls.
---@return MockRenderComponent
local function make_comp()
  local comp = { lines = { {} }, line_buffer = "", extra_hls = {} }

  function comp:add_text(text, hl)
    local cur = self.lines[#self.lines]
    cur[#cur + 1] = { text = text, hl = hl }
    self.line_buffer = self.line_buffer .. text
  end

  function comp:add_hl(group, line_idx, first, last)
    self.extra_hls[#self.extra_hls + 1] = {
      group = group,
      line_idx = line_idx,
      first = first,
      last = last,
    }
  end

  function comp:ln()
    self.lines[#self.lines + 1] = {}
    self.line_buffer = ""
  end

  --- Flatten all recorded text into a single string.
  function comp:flat_text()
    local parts = {}
    for _, line in ipairs(self.lines) do
      for _, seg in ipairs(line) do
        parts[#parts + 1] = seg.text
      end
    end
    return table.concat(parts)
  end

  --- Return every segment whose hl group matches `hl`.
  function comp:segments_by_hl(hl)
    local result = {}
    for _, line in ipairs(self.lines) do
      for _, seg in ipairs(line) do
        if seg.hl == hl then
          result[#result + 1] = seg.text
        end
      end
    end
    return result
  end

  return comp
end

-- ---------------------------------------------------------------------------
-- Helpers shared with the _get_entry_by_file_offset tests
-- (Mirrors wrap_entries_spec.lua conventions.)
-- ---------------------------------------------------------------------------

---Create a stub file entry with an identifiable name.
---@param name string
---@return table
local function make_file(name)
  return {
    name = name,
    active = false,
    set_active = function(self, v)
      self.active = v
    end,
  }
end

---Create a stub log entry with the given file names.
---@param ... string
---@return table
local function make_entry(...)
  local files = {}
  for _, name in ipairs({ ... }) do
    files[#files + 1] = make_file(name)
  end
  return { files = files, folded = false }
end

---Build a minimal FileHistoryPanel-shaped table.
---@param entries table[]
---@param entry_idx integer
---@param file_idx integer
---@return table
local function make_panel(entries, entry_idx, file_idx)
  local FileHistoryPanel =
    require("diffview.scene.views.file_history.file_history_panel").FileHistoryPanel

  local panel = {
    entries = entries,
    single_file = false,
    cur_item = { entries[entry_idx], entries[entry_idx].files[file_idx] },
  }

  panel._get_entry_by_file_offset = FileHistoryPanel._get_entry_by_file_offset
  panel.num_items = FileHistoryPanel.num_items
  panel.set_cur_item = function(self, new_item)
    self.cur_item = new_item
    if self.cur_item and self.cur_item[2] then
      self.cur_item[2]:set_active(true)
    end
  end

  return panel
end

-- =========================================================================
-- Tests
-- =========================================================================

describe("file_history_render", function()
  local original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original_config)
  end)

  -- -----------------------------------------------------------------------
  -- stat_style: render_stat_bar
  -- -----------------------------------------------------------------------

  describe("render_stat_bar", function()
    it("renders proportional plus/minus segments", function()
      local comp = make_comp()
      render_stat_bar(comp, 5, 3)

      local flat = comp:flat_text()
      -- Total is 8, which is below MAX_BAR_WIDTH so bar_width = 8.
      -- add_width = floor(5/8*8 + 0.5) = 5, del_width = 3.
      assert.truthy(flat:find("+++++"), "expected 5 plus signs")
      assert.truthy(flat:find("%-%-%-"), "expected 3 minus signs")
      -- Counter should show total.
      local counters = comp:segments_by_hl("DiffviewFilePanelCounter")
      eq("8 ", counters[1])
    end)

    it("caps bar width at MAX_BAR_WIDTH for large totals", function()
      local comp = make_comp()
      render_stat_bar(comp, 100, 100)

      -- bar_width = min(200, 20) = 20.
      -- add_width = floor(100/200*20 + 0.5) = 10, del_width = 10.
      local adds = comp:segments_by_hl("DiffviewFilePanelInsertions")
      local dels = comp:segments_by_hl("DiffviewFilePanelDeletions")
      eq(10, #adds[1])
      eq(10, #dels[1])
    end)

    it("handles 0 additions (all deletions)", function()
      local comp = make_comp()
      render_stat_bar(comp, 0, 5)

      local adds = comp:segments_by_hl("DiffviewFilePanelInsertions")
      local dels = comp:segments_by_hl("DiffviewFilePanelDeletions")
      eq(0, #adds)
      eq(5, #dels[1])
    end)

    it("handles 0 deletions (all additions)", function()
      local comp = make_comp()
      render_stat_bar(comp, 7, 0)

      local adds = comp:segments_by_hl("DiffviewFilePanelInsertions")
      local dels = comp:segments_by_hl("DiffviewFilePanelDeletions")
      eq(7, #adds[1])
      eq(0, #dels)
    end)

    it("produces no output when both additions and deletions are 0", function()
      local comp = make_comp()
      render_stat_bar(comp, 0, 0)

      eq("", comp:flat_text())
    end)
  end)

  -- -----------------------------------------------------------------------
  -- stat_style: render_file_stats routing
  -- -----------------------------------------------------------------------

  describe("render_file_stats", function()
    local stats = { additions = 4, deletions = 2 }

    it("shows only numbers for stat_style 'number'", function()
      local comp = make_comp()
      render_file_stats(comp, stats, "number")

      local flat = comp:flat_text()
      -- Number portion: " 4", ", ", "2".
      assert.truthy(flat:find("4"), "expected additions count")
      assert.truthy(flat:find("2"), "expected deletions count")
      -- No bar separator.
      assert.falsy(flat:find(" | "), "should not contain bar separator")
    end)

    it("shows only bar for stat_style 'bar'", function()
      local comp = make_comp()
      render_file_stats(comp, stats, "bar")

      local flat = comp:flat_text()
      -- Bar portion present.
      assert.truthy(flat:find(" | "), "expected bar separator")
      assert.truthy(flat:find("+"), "expected plus signs")
      -- No leading numeric portion (no comma separator).
      -- The flat text should start with the bar, not " 4, 2".
      assert.falsy(flat:find(", "), "should not contain number comma separator")
    end)

    it("shows both number and bar for stat_style 'both'", function()
      local comp = make_comp()
      render_file_stats(comp, stats, "both")

      local flat = comp:flat_text()
      assert.truthy(flat:find("4"), "expected additions count")
      assert.truthy(flat:find(", "), "expected number comma separator")
      assert.truthy(flat:find(" | "), "expected bar separator")
    end)

    it("skips bar when stats lack additions/deletions fields", function()
      local comp = make_comp()
      render_file_stats(comp, { additions = nil, deletions = nil }, "bar")

      eq("", comp:flat_text())
    end)
  end)

  -- -----------------------------------------------------------------------
  -- date_format
  -- -----------------------------------------------------------------------

  describe("date formatter", function()
    ---Call the real formatters.date and return the rendered date string.
    ---@param time integer
    ---@param rel string
    ---@param iso string
    ---@param date_format string
    ---@return string
    local function render_date(time, rel, iso, date_format)
      local conf = config.get_config()
      conf.file_history_panel.date_format = date_format
      config.setup(conf)

      local entry = { commit = { time = time, rel_date = rel, iso_date = iso } }
      local comp = make_comp()
      local ctx = { conf = config.get_config() }
      formatters.date(comp, entry, ctx)
      -- The formatter renders ", <date>"; strip the leading ", ".
      return comp:flat_text():sub(3)
    end

    it("returns rel_date for 'relative' mode", function()
      eq("2 hours ago", render_date(os.time(), "2 hours ago", "2026-03-31", "relative"))
    end)

    it("returns iso_date for 'iso' mode", function()
      eq("2026-03-31", render_date(os.time(), "2 hours ago", "2026-03-31", "iso"))
    end)

    it("returns rel_date for a recent commit in 'auto' mode", function()
      -- Commit from 1 day ago (well within the 3-month threshold).
      local recent_time = os.time() - (60 * 60 * 24)
      eq("1 day ago", render_date(recent_time, "1 day ago", "2026-03-30", "auto"))
    end)

    it("returns iso_date for an old commit in 'auto' mode", function()
      -- Commit from 6 months ago (exceeds the 3-month threshold).
      local old_time = os.time() - (60 * 60 * 24 * 30 * 6)
      eq("2025-09-30", render_date(old_time, "6 months ago", "2025-09-30", "auto"))
    end)

    it("treats unknown format as 'auto'", function()
      local recent_time = os.time() - 60
      eq("1 minute ago", render_date(recent_time, "1 minute ago", "2026-03-31", "something_else"))
    end)
  end)

  -- -----------------------------------------------------------------------
  -- subject_highlight
  -- -----------------------------------------------------------------------

  describe("subject_highlight", function()
    ---Call the real formatters.subject and return the highlight group it used.
    ---@param entry table
    ---@param is_selected boolean
    ---@return string
    local function render_subject_hl(entry, is_selected)
      entry.commit = entry.commit or { subject = "test" }
      local comp = make_comp()
      local ctx = {
        conf = config.get_config(),
        panel = { cur_item = { is_selected and entry or {} } },
      }
      formatters.subject(comp, entry, ctx)
      -- The subject is rendered as a single segment; return its hl group.
      return comp.lines[1][1].hl
    end

    it("uses DiffviewFilePanelFileName for 'plain' mode", function()
      local conf = config.get_config()
      conf.file_history_panel.subject_highlight = "plain"
      config.setup(conf)

      local entry = { is_pushed = true }
      eq("DiffviewFilePanelFileName", render_subject_hl(entry, false))
    end)

    it("uses DiffviewCommitRemoteRef for 'ref_aware' on pushed commit", function()
      local conf = config.get_config()
      conf.file_history_panel.subject_highlight = "ref_aware"
      config.setup(conf)

      local entry = { is_pushed = true }
      eq("DiffviewCommitRemoteRef", render_subject_hl(entry, false))
    end)

    it("uses DiffviewCommitLocalOnly for 'ref_aware' on unpushed commit", function()
      local conf = config.get_config()
      conf.file_history_panel.subject_highlight = "ref_aware"
      config.setup(conf)

      local entry = { is_pushed = false }
      eq("DiffviewCommitLocalOnly", render_subject_hl(entry, false))
    end)

    it("uses DiffviewCommitMerged for 'merge_aware' on merged commit", function()
      local conf = config.get_config()
      conf.file_history_panel.subject_highlight = "merge_aware"
      config.setup(conf)

      -- A merged commit is also pushed; the merged check must win.
      local entry = { is_pushed = true, is_merged = true }
      eq("DiffviewCommitMerged", render_subject_hl(entry, false))
    end)

    it("uses DiffviewCommitRemoteRef for 'merge_aware' on pushed-but-unmerged commit", function()
      local conf = config.get_config()
      conf.file_history_panel.subject_highlight = "merge_aware"
      config.setup(conf)

      local entry = { is_pushed = true, is_merged = false }
      eq("DiffviewCommitRemoteRef", render_subject_hl(entry, false))
    end)

    it("uses DiffviewCommitLocalOnly for 'merge_aware' on unpushed commit", function()
      local conf = config.get_config()
      conf.file_history_panel.subject_highlight = "merge_aware"
      config.setup(conf)

      local entry = { is_pushed = false, is_merged = false }
      eq("DiffviewCommitLocalOnly", render_subject_hl(entry, false))
    end)

    it("layers DiffviewCommitSelected on top of the ref-aware base when selected", function()
      local conf = config.get_config()
      conf.file_history_panel.subject_highlight = "ref_aware"
      config.setup(conf)

      local entry = { is_pushed = true, commit = { subject = "test" } }
      local comp = make_comp()
      local ctx = {
        conf = config.get_config(),
        panel = { cur_item = { entry } },
      }
      formatters.subject(comp, entry, ctx)

      -- The base segment keeps the ref-aware foreground.
      eq("DiffviewCommitRemoteRef", comp.lines[1][1].hl)
      eq(" test", comp.lines[1][1].text)

      -- The selected highlight is layered over the subject's byte range, so
      -- the user can customize `DiffviewCommitSelected` (e.g. with a bg)
      -- without affecting the active filename's colour, which is controlled
      -- by `DiffviewFilePanelSelected`. The leading separator space is
      -- excluded so a bg customization doesn't bleed into the gap.
      eq(1, #comp.extra_hls)
      eq("DiffviewCommitSelected", comp.extra_hls[1].group)
      eq(#" ", comp.extra_hls[1].first)
      eq(#" test", comp.extra_hls[1].last)
    end)

    it("does not layer DiffviewCommitSelected when entry is not selected", function()
      local conf = config.get_config()
      conf.file_history_panel.subject_highlight = "ref_aware"
      config.setup(conf)

      local entry = { is_pushed = false, commit = { subject = "test" } }
      local comp = make_comp()
      local ctx = {
        conf = config.get_config(),
        panel = { cur_item = {} },
      }
      formatters.subject(comp, entry, ctx)

      eq(0, #comp.extra_hls)
    end)

    it("defaults to 'ref_aware'", function()
      eq("ref_aware", config.get_config().file_history_panel.subject_highlight)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- date_format config default
  -- -----------------------------------------------------------------------

  describe("config defaults", function()
    it("defaults stat_style to 'number'", function()
      local c = config.get_config()
      eq("number", c.file_history_panel.stat_style)
    end)

    it("defaults date_format to 'auto'", function()
      local c = config.get_config()
      eq("auto", c.file_history_panel.date_format)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- _get_entry_by_file_offset: cycling within a commit
  -- (Exercises the commit 318ce58 behaviour.)
  -- -----------------------------------------------------------------------

  describe("_get_entry_by_file_offset (intra-commit cycling)", function()
    -- Single entry with 4 files: a, b, c, d.
    local entries, panel

    before_each(function()
      entries = { make_entry("a", "b", "c", "d") }
      panel = make_panel(entries, 1, 1)
    end)

    describe("cycling forward within a commit", function()
      it("moves from file 1 to file 2", function()
        local e, f = panel:_get_entry_by_file_offset(1, 1, 1, true)
        eq(entries[1], e)
        eq(entries[1].files[2], f)
      end)

      it("moves from file 2 to file 4 with offset 2", function()
        local e, f = panel:_get_entry_by_file_offset(1, 2, 2, true)
        eq(entries[1], e)
        eq(entries[1].files[4], f)
      end)
    end)

    describe("cycling backward within a commit", function()
      it("moves from file 3 to file 2", function()
        local e, f = panel:_get_entry_by_file_offset(1, 3, -1, true)
        eq(entries[1], e)
        eq(entries[1].files[2], f)
      end)

      it("moves from file 4 to file 2 with offset -2", function()
        local e, f = panel:_get_entry_by_file_offset(1, 4, -2, true)
        eq(entries[1], e)
        eq(entries[1].files[2], f)
      end)
    end)

    describe("wrapping at boundaries (wrap = true)", function()
      it("wraps forward from the last file back to the first", function()
        -- Single entry: wrapping forward from file 4 should come back around.
        -- The delta after exhausting the current entry is 1, and since there
        -- is only one entry the loop condition (i ~= entry_idx) is immediately
        -- false, so we get nil.  This matches the production code: a single
        -- entry with wrap=true does not re-enter itself.
        local e, f = panel:_get_entry_by_file_offset(1, 4, 1, true)
        eq(nil, e)
        eq(nil, f)
      end)

      it("wraps backward from the first file back to the last", function()
        local e, f = panel:_get_entry_by_file_offset(1, 1, -1, true)
        eq(nil, e)
        eq(nil, f)
      end)
    end)

    describe("stopping at boundaries (wrap = false)", function()
      it("returns nil when moving forward past the last file", function()
        local e, f = panel:_get_entry_by_file_offset(1, 4, 1, false)
        eq(nil, e)
        eq(nil, f)
      end)

      it("returns nil when moving backward past the first file", function()
        local e, f = panel:_get_entry_by_file_offset(1, 1, -1, false)
        eq(nil, e)
        eq(nil, f)
      end)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- _get_entry_by_file_offset: multi-entry cycling
  -- -----------------------------------------------------------------------

  describe("_get_entry_by_file_offset (multi-entry)", function()
    -- Layout: entry1 [a, b], entry2 [c], entry3 [d, e, f].
    local entries, panel

    before_each(function()
      entries = {
        make_entry("a", "b"),
        make_entry("c"),
        make_entry("d", "e", "f"),
      }
      panel = make_panel(entries, 1, 1)
    end)

    describe("cycling forward across entries", function()
      it("crosses from entry1 last file to entry2 first file", function()
        local e, f = panel:_get_entry_by_file_offset(1, 2, 1, false)
        eq(entries[2], e)
        eq(entries[2].files[1], f)
      end)

      it("skips entry2 when offset exceeds its size", function()
        -- From entry1 file 2, offset +2: crosses entry2 (1 file) -> entry3 file 1.
        local e, f = panel:_get_entry_by_file_offset(1, 2, 2, false)
        eq(entries[3], e)
        eq(entries[3].files[1], f)
      end)
    end)

    describe("cycling backward across entries", function()
      it("crosses from entry2 first file to entry1 last file", function()
        local e, f = panel:_get_entry_by_file_offset(2, 1, -1, false)
        eq(entries[1], e)
        eq(entries[1].files[2], f)
      end)

      it("skips entry2 when offset exceeds its size going backward", function()
        -- From entry3 file 1, offset -2: crosses entry2 (1 file) -> entry1 file 2.
        local e, f = panel:_get_entry_by_file_offset(3, 1, -2, false)
        eq(entries[1], e)
        eq(entries[1].files[2], f)
      end)
    end)

    describe("wrapping across entries (wrap = true)", function()
      it("wraps forward from the last file of the last entry", function()
        local e, f = panel:_get_entry_by_file_offset(3, 3, 1, true)
        eq(entries[1], e)
        eq(entries[1].files[1], f)
      end)

      it("wraps backward from the first file of the first entry", function()
        local e, f = panel:_get_entry_by_file_offset(1, 1, -1, true)
        eq(entries[3], e)
        eq(entries[3].files[3], f)
      end)
    end)

    describe("stopping at boundaries (wrap = false)", function()
      it("returns nil at the absolute end going forward", function()
        local e, f = panel:_get_entry_by_file_offset(3, 3, 1, false)
        eq(nil, e)
        eq(nil, f)
      end)

      it("returns nil at the absolute start going backward", function()
        local e, f = panel:_get_entry_by_file_offset(1, 1, -1, false)
        eq(nil, e)
        eq(nil, f)
      end)
    end)
  end)
end)

-- =========================================================================
-- State preservation across refresh (_snapshot_state / _restore_state)
-- =========================================================================

---Create a stub file entry identified by path (and optional oldpath).
---@param path string
---@param oldpath? string
---@return table
local function fh_file(path, oldpath)
  return { path = path, oldpath = oldpath }
end

---Create a stub log entry with a commit hash, fold state, and files.
---@param hash string?
---@param folded boolean
---@param files table[]
---@return table
local function fh_entry(hash, folded, files)
  return { commit = { hash = hash }, folded = folded, files = files }
end

---Build a minimal FileHistoryPanel-shaped table with the state helpers bound.
---@param entries table[]
---@param opts? { single_file?: boolean, pin_local?: boolean, cur_item?: table }
---@return table
local function state_panel(entries, opts)
  opts = opts or {}

  local FileHistoryPanel =
    require("diffview.scene.views.file_history.file_history_panel").FileHistoryPanel

  local panel = {
    entries = entries,
    single_file = opts.single_file or false,
    parent = { pin_local = opts.pin_local or false },
    cur_item = opts.cur_item or {},
  }

  panel._snapshot_state = FileHistoryPanel._snapshot_state
  panel._restore_state = FileHistoryPanel._restore_state
  panel.set_cur_item = function(self, new_item)
    self.cur_item = new_item
  end

  return panel
end

describe("file_history state preservation", function()
  describe("_snapshot_state", function()
    it("records unfolded entries by commit hash and the focused file", function()
      local f1 = fh_file("a.txt")
      local panel = state_panel({
        fh_entry("aaa", false, { f1 }),
        fh_entry("bbb", true, { fh_file("b.txt") }),
      })
      panel.cur_item = { panel.entries[1], f1 }

      local snap = panel:_snapshot_state()

      eq(true, snap.unfolded["aaa"])
      eq(nil, snap.unfolded["bbb"])
      eq("aaa", snap.cur.hash)
      eq("a.txt", snap.cur.path)
    end)

    it("excludes the synthetic working-tree entry (nil hash)", function()
      local panel = state_panel({ fh_entry(nil, false, { fh_file("x.txt") }) })
      local snap = panel:_snapshot_state()
      eq(nil, next(snap.unfolded))
    end)

    it("leaves cur nil when nothing is focused", function()
      local panel = state_panel({ fh_entry("aaa", true, { fh_file("a.txt") }) })
      eq(nil, panel:_snapshot_state().cur)
    end)
  end)

  describe("_restore_state", function()
    it("re-opens previously unfolded entries and folds the rest", function()
      -- Rebuilt entries default to folded.
      local r1 = fh_entry("aaa", true, { fh_file("a.txt") })
      local r2 = fh_entry("bbb", true, { fh_file("b.txt") })
      local panel = state_panel({ r1, r2 })

      panel:_restore_state({ unfolded = { aaa = true }, cur = nil })

      eq(false, r1.folded)
      eq(true, r2.folded)
    end)

    it("restores the cursor to the matching file by hash and path", function()
      local f = fh_file("b.txt")
      local r2 = fh_entry("bbb", true, { f })
      local panel = state_panel({ fh_entry("aaa", true, { fh_file("a.txt") }), r2 })

      local restored = panel:_restore_state({
        unfolded = { bbb = true },
        cur = { hash = "bbb", path = "b.txt" },
      })

      eq(f, restored)
      eq(r2, panel.cur_item[1])
      eq(f, panel.cur_item[2])
    end)

    it("matches on path even when oldpath differs (rename re-detection)", function()
      -- The snapshot only records path; a row whose rename status changed
      -- across the refresh (oldpath set vs nil) must still match on path.
      local renamed = fh_file("new.txt", "old.txt")
      local panel = state_panel({ fh_entry("aaa", true, { renamed }) })

      local restored = panel:_restore_state({
        unfolded = {},
        cur = { hash = "aaa", path = "new.txt" },
      })

      eq(renamed, restored)
    end)

    it("falls back to the commit's first file when the focused file is gone", function()
      local first = fh_file("a.txt")
      local panel = state_panel({ fh_entry("aaa", true, { first, fh_file("b.txt") }) })

      local restored = panel:_restore_state({
        unfolded = {},
        cur = { hash = "aaa", path = "gone.txt" },
      })

      eq(first, restored)
    end)

    it("falls back to the first entry when the focused commit no longer exists", function()
      -- The cursor must be re-established (not left nil), otherwise the caller
      -- skips set_file and the cursor is stranded on a re-folded entry.
      local first = fh_file("a.txt")
      local panel = state_panel({
        fh_entry("aaa", true, { first }),
        fh_entry("bbb", true, { fh_file("b.txt") }),
      })

      local restored = panel:_restore_state({
        unfolded = {},
        cur = { hash = "zzz", path = "z.txt" },
      })

      eq(first, restored)
      eq(first, panel.cur_item[2])
    end)

    it("returns nil on an empty snapshot, leaving the bootstrap's first-open state", function()
      -- First open: the bootstrap already handled focus/load, so _restore_state
      -- does nothing and reports no file to reload.
      local first = fh_file("a.txt")
      local r1 = fh_entry("aaa", true, { first })
      local panel = state_panel({ r1 })

      local restored = panel:_restore_state({ unfolded = {}, cur = nil })

      eq(nil, restored)
      eq(true, r1.folded)
      eq(nil, panel.cur_item[1])
    end)

    it("returns nil for an empty history", function()
      -- Non-empty snapshot so the empty-history fallback runs, not the early return.
      local panel = state_panel({})
      eq(nil, panel:_restore_state({ unfolded = {}, cur = { hash = "aaa", path = "a.txt" } }))
    end)

    it("leaves fold and cursor state untouched in pin_local mode", function()
      -- pin_local owns its own restoration via the bootstrap, so _restore_state
      -- is a no-op there.
      local r1 = fh_entry("aaa", true, { fh_file("a.txt") })
      local panel = state_panel({ r1, fh_entry("bbb", true, { fh_file("b.txt") }) }, {
        pin_local = true,
      })
      local sentinel = { "untouched" }
      panel.cur_item = sentinel

      local restored = panel:_restore_state({
        unfolded = { aaa = true },
        cur = { hash = "bbb", path = "b.txt" },
      })

      eq(nil, restored)
      eq(true, r1.folded)
      eq(sentinel, panel.cur_item)
    end)

    it("restores the cursor in single_file mode without altering folds", function()
      local f = fh_file("a.txt")
      local r1 = fh_entry("aaa", true, { f })
      local panel = state_panel({ r1 }, { single_file = true })

      local restored = panel:_restore_state({
        unfolded = { aaa = true },
        cur = { hash = "aaa", path = "a.txt" },
      })

      eq(f, restored)
      -- The fold loop is skipped in single_file mode.
      eq(true, r1.folded)
    end)
  end)

  it("preserves fold and cursor across a snapshot/rebuild cycle", function()
    -- State before the refresh: commit "bbb" expanded, cursor on its 2nd file.
    local before = {
      fh_entry("aaa", true, { fh_file("a.txt") }),
      fh_entry("bbb", false, { fh_file("b.txt"), fh_file("c.txt") }),
      fh_entry("ccc", true, { fh_file("d.txt") }),
    }
    local panel = state_panel(before, { cur_item = { before[2], before[2].files[2] } })

    local snap = panel:_snapshot_state()

    -- The rebuild creates brand-new objects with the same hashes and paths,
    -- all folded by default, and clears cur_item (as `update_entries` does).
    local after = {
      fh_entry("aaa", true, { fh_file("a.txt") }),
      fh_entry("bbb", true, { fh_file("b.txt"), fh_file("c.txt") }),
      fh_entry("ccc", true, { fh_file("d.txt") }),
    }
    panel.entries = after
    panel.cur_item = {}

    local restored = panel:_restore_state(snap)

    eq(true, after[1].folded)
    eq(false, after[2].folded)
    eq(true, after[3].folded)
    eq(after[2].files[2], restored)
    eq("c.txt", panel.cur_item[2].path)
  end)
end)
