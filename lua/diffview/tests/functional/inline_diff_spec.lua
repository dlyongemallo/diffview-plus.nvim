local api = vim.api

describe("diffview.scene.inline_diff", function()
  local inline_diff = require("diffview.scene.inline_diff")
  local created_bufs

  local function fresh_buf(lines)
    local bufnr = api.nvim_create_buf(false, true)
    table.insert(created_bufs, bufnr)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  local function extmarks(bufnr)
    return api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, { details = true })
  end

  local function line_hls(marks)
    local out = {}
    for _, m in ipairs(marks) do
      if m[4] and m[4].line_hl_group then
        out[#out + 1] = { row = m[2], hl = m[4].line_hl_group }
      end
    end
    table.sort(out, function(a, b)
      return a.row < b.row
    end)
    return out
  end

  local function virt_line_counts(marks)
    local out = {}
    for _, m in ipairs(marks) do
      if m[4] and m[4].virt_lines then
        out[#out + 1] = {
          row = m[2],
          count = #m[4].virt_lines,
          above = m[4].virt_lines_above or false,
        }
      end
    end
    table.sort(out, function(a, b)
      return a.row < b.row
    end)
    return out
  end

  local function char_ranges(marks)
    local out = {}
    for _, m in ipairs(marks) do
      if m[4] and m[4].hl_group == "DiffviewDiffAddInline" then
        out[#out + 1] = { row = m[2], start = m[3], finish = m[4].end_col }
      end
    end
    table.sort(out, function(a, b)
      if a.row == b.row then
        return a.start < b.start
      end
      return a.row < b.row
    end)
    return out
  end

  local function inline_virt_texts(marks, hl)
    local out = {}
    for _, m in ipairs(marks) do
      local d = m[4]
      if d and d.virt_text and d.virt_text_pos == "inline" then
        local chunk = d.virt_text[1]
        if not hl or (chunk and chunk[2] == hl) then
          out[#out + 1] = { row = m[2], col = m[3], text = chunk and chunk[1] or "" }
        end
      end
    end
    table.sort(out, function(a, b)
      if a.row == b.row then
        return a.col < b.col
      end
      return a.row < b.row
    end)
    return out
  end

  local function virt_line_hls(marks)
    local out = {}
    for _, m in ipairs(marks) do
      if m[4] and m[4].virt_lines then
        for _, line in ipairs(m[4].virt_lines) do
          out[#out + 1] = line[1] and line[1][2] or nil
        end
      end
    end
    return out
  end

  local initial_winid

  local function virt_line_chunks(marks)
    local out = {}
    for _, m in ipairs(marks) do
      if m[4] and m[4].virt_lines then
        for _, line in ipairs(m[4].virt_lines) do
          out[#out + 1] = line
        end
      end
    end
    return out
  end

  before_each(function()
    created_bufs = {}
    initial_winid = api.nvim_get_current_win()
  end)

  after_each(function()
    for _, b in ipairs(created_bufs) do
      -- Detach explicitly: tests that bypass `render` never register
      -- the BufWipeout cleanup autocmd, so per-buffer module tables
      -- would otherwise survive the buf delete. Idempotent.
      pcall(inline_diff.detach, b)
      pcall(api.nvim_buf_delete, b, { force = true })
    end
    -- Close any windows the test opened so a leak (e.g. from a failing
    -- assertion before in-test cleanup) doesn't pollute later tests'
    -- current-window/widths/win_findbuf state. If the test invalidated
    -- `initial_winid` itself, fall back to keeping `wins[1]` so we don't
    -- attempt to close every window (which would error on the last one).
    local keep = api.nvim_win_is_valid(initial_winid) and initial_winid or nil
    for _, winid in ipairs(api.nvim_tabpage_list_wins(0)) do
      if keep == nil then
        keep = winid
      elseif winid ~= keep then
        pcall(api.nvim_win_close, winid, true)
      end
    end
  end)

  describe("render", function()
    it("marks pure-addition hunks with DiffviewDiffAdd", function()
      local bufnr = fresh_buf({ "line one", "line two", "line three", "line four" })
      inline_diff.render(bufnr, { "line one", "line four" }, {
        "line one",
        "line two",
        "line three",
        "line four",
      })

      local hls = line_hls(extmarks(bufnr))
      assert.are.same({
        { row = 1, hl = "DiffviewDiffAdd" },
        { row = 2, hl = "DiffviewDiffAdd" },
      }, hls)
      assert.are.same({}, virt_line_counts(extmarks(bufnr)))
    end)

    it("renders pure deletions as virt_lines attached to the right row", function()
      local bufnr = fresh_buf({ "a", "d" })
      inline_diff.render(bufnr, { "a", "b", "c", "d" }, { "a", "d" })

      local vls = virt_line_counts(extmarks(bufnr))
      -- Deletion between new line 1 ("a") and new line 2 ("d") -> row 0, below.
      assert.are.same({ { row = 0, count = 2, above = false } }, vls)
      -- No line highlights expected for pure deletion.
      assert.are.same({}, line_hls(extmarks(bufnr)))
    end)

    it("anchors top-of-file deletions above line 0", function()
      local bufnr = fresh_buf({ "x", "y" })
      inline_diff.render(bufnr, { "gone1", "gone2", "x", "y" }, { "x", "y" })

      local vls = virt_line_counts(extmarks(bufnr))
      assert.are.same({ { row = 0, count = 2, above = true } }, vls)
    end)

    it("anchors end-of-file deletions below the last line", function()
      -- Regression: without a trailing newline `vim.diff` treats the last
      -- new line as unterminated and reports this as a modification hunk
      -- (conflating the unchanged last line with the EOF deletion), which
      -- both hid the deletion and echoed the unchanged line as a spurious
      -- virt_line above. The EOF-deleted block should sit *below* the last
      -- new-side row.
      local bufnr = fresh_buf({ "a", "b" })
      inline_diff.render(bufnr, { "a", "b", "gone1", "gone2" }, { "a", "b" })

      local vls = virt_line_counts(extmarks(bufnr))
      assert.are.same({ { row = 1, count = 2, above = false } }, vls)
      -- No paired-modification line_hl — the last line is unchanged.
      assert.are.same({}, line_hls(extmarks(bufnr)))
    end)

    it("marks end-of-file additions with DiffviewDiffAdd", function()
      local bufnr = fresh_buf({ "a", "b", "added1", "added2" })
      inline_diff.render(bufnr, { "a", "b" }, { "a", "b", "added1", "added2" })

      local hls = line_hls(extmarks(bufnr))
      assert.are.same({
        { row = 2, hl = "DiffviewDiffAdd" },
        { row = 3, hl = "DiffviewDiffAdd" },
      }, hls)
      -- No virt_lines for a pure addition.
      assert.are.same({}, virt_line_counts(extmarks(bufnr)))
    end)

    it("marks modified lines with DiffChange and char-level DiffviewDiffAddInline", function()
      local bufnr = fresh_buf({ "hello wonderful world" })
      inline_diff.render(bufnr, { "hello world" }, { "hello wonderful world" })

      local hls = line_hls(extmarks(bufnr))
      assert.are.same({ { row = 0, hl = "DiffviewDiffChange" } }, hls)

      -- Expect at least one char-level DiffviewDiffAddInline range covering "wonderful ".
      local ranges = char_ranges(extmarks(bufnr))
      assert.is_true(#ranges > 0, "expected DiffviewDiffAddInline extmarks")

      -- Unified style echoes the old line above the modification.
      local vls = virt_line_counts(extmarks(bufnr))
      assert.are.same({ { row = 0, count = 1, above = true } }, vls)
    end)

    it("shows old lines as virt_lines above modification hunks", function()
      -- Pick a 1:1 modification so vim.diff doesn't split into separate
      -- modify + pure-delete hunks.
      local bufnr = fresh_buf({ "first changed", "second" })
      inline_diff.render(bufnr, { "first", "second" }, { "first changed", "second" })

      local hls = line_hls(extmarks(bufnr))
      local vls = virt_line_counts(extmarks(bufnr))

      assert.are.same({ { row = 0, hl = "DiffviewDiffChange" } }, hls)
      -- Old line "first" appears above the first paired row.
      assert.are.same({ { row = 0, count = 1, above = true } }, vls)
    end)

    it("handles overflow-addition within a modification hunk", function()
      local bufnr = fresh_buf({ "one changed", "extra" })
      inline_diff.render(bufnr, { "one" }, { "one changed", "extra" })

      local hls = line_hls(extmarks(bufnr))
      assert.are.same({
        { row = 0, hl = "DiffviewDiffChange" },
        { row = 1, hl = "DiffviewDiffAdd" },
      }, hls)
    end)

    it("treats an empty old side as pure addition across the whole buffer", function()
      local bufnr = fresh_buf({ "first", "second", "third" })
      inline_diff.render(bufnr, {}, { "first", "second", "third" })

      local hls = line_hls(extmarks(bufnr))
      assert.are.same({
        { row = 0, hl = "DiffviewDiffAdd" },
        { row = 1, hl = "DiffviewDiffAdd" },
        { row = 2, hl = "DiffviewDiffAdd" },
      }, hls)
      assert.are.same({}, virt_line_counts(extmarks(bufnr)))
    end)

    it("bails out cleanly on an empty buffer", function()
      -- fresh_buf({}) yields a buffer with no lines; Neovim's default empty
      -- buffer always has one empty line, but render should be safe either way.
      local bufnr = fresh_buf({})
      inline_diff.render(bufnr, { "old" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_table(extmarks(bufnr))
    end)

    it("clear() removes previously-rendered marks", function()
      local bufnr = fresh_buf({ "a", "b", "c" })
      inline_diff.render(bufnr, {}, { "a", "b", "c" })
      assert.is_true(#extmarks(bufnr) > 0)

      inline_diff.clear(bufnr)
      assert.are.equal(0, #extmarks(bufnr))
    end)

    it("is idempotent across repeated calls", function()
      local bufnr = fresh_buf({ "one", "two changed", "three" })
      inline_diff.render(bufnr, { "one", "two", "three" }, {
        "one",
        "two changed",
        "three",
      })
      local first = #extmarks(bufnr)

      inline_diff.render(bufnr, { "one", "two", "three" }, {
        "one",
        "two changed",
        "three",
      })
      local second = #extmarks(bufnr)

      assert.are.equal(first, second)
    end)
  end)

  describe("DiffviewDiffAddInline highlight", function()
    local hl = require("diffview.hl")
    local saved_diff_add, saved_diffview_groups

    -- `hl.setup()` mutates every `Diffview*` highlight group, so saving only
    -- the two groups the test explicitly touches would let the rest leak
    -- into later tests and make the suite order-dependent. Snapshot every
    -- `Diffview*` group before and fully restore them afterwards.
    local function snapshot_diffview_hl()
      local result = {}
      for name in pairs(api.nvim_get_hl(0, {})) do
        if name:match("^Diffview") then
          result[name] = api.nvim_get_hl(0, { name = name, link = true })
        end
      end
      return result
    end

    local function restore_diffview_hl(snapshot)
      -- Clear current `Diffview*` groups first so any new groups created by
      -- `hl.setup()` (and absent from the snapshot) are also wiped.
      for name in pairs(api.nvim_get_hl(0, {})) do
        if name:match("^Diffview") then
          api.nvim_set_hl(0, name, {})
        end
      end
      for name, h in pairs(snapshot) do
        api.nvim_set_hl(0, name, h)
      end
    end

    before_each(function()
      saved_diff_add = api.nvim_get_hl(0, { name = "DiffAdd", link = true })
      saved_diffview_groups = snapshot_diffview_hl()
      api.nvim_set_hl(0, "DiffAdd", { bg = "#004400", fg = "#cccccc" })
      api.nvim_set_hl(0, "DiffviewDiffAddInline", {})
      api.nvim_set_hl(0, "DiffviewDiffAdd", { link = "DiffAdd" })
      hl.setup()
    end)

    after_each(function()
      api.nvim_set_hl(0, "DiffAdd", saved_diff_add)
      restore_diffview_hl(saved_diffview_groups)
    end)

    it("inherits bg from DiffviewDiffAdd and omits fg", function()
      local got = api.nvim_get_hl(0, { name = "DiffviewDiffAddInline", link = false })
      local diff_add = api.nvim_get_hl(0, { name = "DiffviewDiffAdd", link = false })

      -- fg must be absent so tree-sitter foreground composes through the
      -- priority-200 extmark (otherwise it would stomp the syntax fg).
      assert.is_nil(got.fg)
      assert.are.equal(diff_add.bg, got.bg)
    end)

    it("strips reverse/standout but keeps fg-safe styles like bold/italic", function()
      -- Some colourschemes flag `DiffAdd` with `reverse` (and/or
      -- `standout`). Both swap fg/bg at render time, so leaving them in
      -- the inherited style would let the addition `bg` paint over the
      -- syntax `fg` and defeat the dropped-`fg` goal. Verify those two
      -- are filtered while fg-safe attrs like `bold`/`italic` carry over.
      -- The visible bg should track the source `fg` (post-swap), not the
      -- raw source `bg`, so the inline addition keeps the colour the
      -- colourscheme intended to show.
      api.nvim_set_hl(0, "DiffAdd", {
        bg = 0x004400,
        fg = 0xcccccc,
        bold = true,
        italic = true,
        reverse = true,
        standout = true,
      })
      api.nvim_set_hl(0, "DiffviewDiffAddInline", {})
      hl.setup()

      local got = api.nvim_get_hl(0, { name = "DiffviewDiffAddInline", link = false })
      assert.is_nil(got.fg)
      assert.are.equal(0xcccccc, got.bg)
      assert.is_true(got.bold)
      assert.is_true(got.italic)
      assert.is_nil(got.reverse)
      assert.is_nil(got.standout)
    end)

    it("derives bg from source fg for reverse-only colourschemes", function()
      -- Colourschemes that flag `DiffAdd` with only `reverse` (and a `fg`,
      -- no explicit `bg`) rely on the swap to paint the addition bg from
      -- the fg. After stripping `reverse`, falling back to the raw `bg`
      -- would yield `NONE` and lose the highlight entirely. Use the
      -- source `fg` as the effective bg instead.
      api.nvim_set_hl(0, "DiffAdd", { fg = 0x00cc00, reverse = true })
      api.nvim_set_hl(0, "DiffviewDiffAddInline", {})
      hl.setup()

      local got = api.nvim_get_hl(0, { name = "DiffviewDiffAddInline", link = false })
      assert.is_nil(got.fg)
      assert.are.equal(0x00cc00, got.bg)
      assert.is_nil(got.reverse)
    end)

    it("refreshes on re-setup instead of pinning the first colourscheme's value", function()
      -- Regression: the inline groups were defined with `default = true`, so
      -- once set they never tracked later `ColorScheme` events (a `default`
      -- highlight is a no-op when the group already exists). A colourscheme
      -- switch (modelled here as a new `DiffAdd` background plus a fresh
      -- `hl.setup()`, WITHOUT clearing the group first) must update the
      -- derived background rather than keep the stale one.
      assert.are.equal(
        0x004400,
        api.nvim_get_hl(0, { name = "DiffviewDiffAddInline", link = false }).bg
      )

      api.nvim_set_hl(0, "DiffAdd", { bg = "#88ccff" })
      api.nvim_set_hl(0, "DiffviewDiffAdd", { link = "DiffAdd" })
      hl.setup()

      assert.are.equal(
        0x88ccff,
        api.nvim_get_hl(0, { name = "DiffviewDiffAddInline", link = false }).bg
      )
    end)
  end)

  describe("overleaf style", function()
    it("emits inline virt_text for char-level deletions on paired lines", function()
      local bufnr = fresh_buf({ "hello world" })
      inline_diff.render(bufnr, { "hello brave world" }, { "hello world" }, { style = "overleaf" })

      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.is_true(#inlines > 0, "expected at least one inline deletion virt_text")
      -- The deleted run should be on the modified line and contain "brave".
      local any = false
      for _, v in ipairs(inlines) do
        if v.text:find("brave") then
          any = true
        end
      end
      assert.is_true(any, "expected deleted text to contain 'brave'")
    end)

    it("still emits DiffviewDiffAddInline hl on added chars in overleaf style", function()
      local bufnr = fresh_buf({ "hello brave new world" })
      inline_diff.render(
        bufnr,
        { "hello world" },
        { "hello brave new world" },
        { style = "overleaf" }
      )

      local ranges = char_ranges(extmarks(bufnr))
      assert.is_true(#ranges > 0, "expected DiffviewDiffAddInline extmarks on added chars")
    end)

    it("uses DiffviewDiffDeleteInline hl for whole-line deletions", function()
      local bufnr = fresh_buf({ "a", "c" })
      inline_diff.render(bufnr, { "a", "b", "c" }, { "a", "c" }, { style = "overleaf" })

      local hls = virt_line_hls(extmarks(bufnr))
      assert.are.same({ "DiffviewDiffDeleteInline" }, hls)
    end)

    it("uses DiffviewDiffDelete hl in default unified style", function()
      local bufnr = fresh_buf({ "a", "c" })
      inline_diff.render(bufnr, { "a", "b", "c" }, { "a", "c" })

      local hls = virt_line_hls(extmarks(bufnr))
      assert.are.same({ "DiffviewDiffDelete" }, hls)
    end)

    it("does NOT emit inline deletion virt_text in unified style", function()
      local bufnr = fresh_buf({ "hello world" })
      inline_diff.render(bufnr, { "hello brave world" }, { "hello world" })

      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.are.equal(0, #inlines)
    end)

    it("falls back to unified for unknown style values", function()
      local bufnr = fresh_buf({ "a", "c" })
      inline_diff.render(bufnr, { "a", "b", "c" }, { "a", "c" }, { style = "bogus" })

      local hls = virt_line_hls(extmarks(bufnr))
      assert.are.same({ "DiffviewDiffDelete" }, hls)
    end)

    it("does not echo old paired lines as virt_lines (no double-rendering)", function()
      local bufnr = fresh_buf({ "first changed", "second" })
      inline_diff.render(
        bufnr,
        { "first", "second" },
        { "first changed", "second" },
        { style = "overleaf" }
      )

      -- No block virt_lines for the paired modification in overleaf.
      assert.are.same({}, virt_line_counts(extmarks(bufnr)))
    end)

    it("does not apply DiffChange line_hl on paired modified rows", function()
      local bufnr = fresh_buf({ "first changed", "second" })
      inline_diff.render(
        bufnr,
        { "first", "second" },
        { "first changed", "second" },
        { style = "overleaf" }
      )

      local hls = line_hls(extmarks(bufnr))
      for _, h in ipairs(hls) do
        assert.are_not.equal("DiffviewDiffChange", h.hl)
      end
    end)

    it("still emits virt_lines for overflow old lines within a modification", function()
      -- Modification: 2 old paired with 1 new, so 1 unpaired old overflow.
      -- Use unrelated content to force a single 2:1 modification hunk rather
      -- than a 1:1 modify + pure-delete split.
      local bufnr = fresh_buf({ "alpha" })
      inline_diff.render(bufnr, { "xyz", "pqr" }, { "alpha" }, { style = "overleaf" })

      local hls = virt_line_hls(extmarks(bufnr))
      -- Whatever vim.diff produces, any virt_lines emitted must be in the
      -- overleaf deletion hl group.
      for _, h in ipairs(hls) do
        assert.are.equal("DiffviewDiffDeleteInline", h)
      end
    end)

    -- Commenting-out a block prepends `-- ` to N lines and inserts a header
    -- line above them, producing an N:N+1 modify hunk. With positional
    -- pairing inside one hunk the new header pairs with the first old line
    -- and every subsequent pair becomes a shifted, dissimilar pair — so the
    -- char-level diff fragments, returns `"skipped"`, and the block renders
    -- as a full add+delete instead of inline `-- ` insertions. Linematch
    -- splits the hunk into a pure-add for the header plus an aligned N:N
    -- modify, which the renderer can pair positionally without skipping.
    it("renders a commented-out block as inline `-- ` insertions with linematch", function()
      local bufnr = fresh_buf({
        "-- TEMP: disable overrides.",
        "-- vim.api.nvim_set_hl(0, 'A')",
        "-- vim.api.nvim_set_hl(0, 'B')",
      })
      inline_diff.render(bufnr, { "vim.api.nvim_set_hl(0, 'A')", "vim.api.nvim_set_hl(0, 'B')" }, {
        "-- TEMP: disable overrides.",
        "-- vim.api.nvim_set_hl(0, 'A')",
        "-- vim.api.nvim_set_hl(0, 'B')",
      }, { style = "overleaf", linematch = 60 })

      local marks = extmarks(bufnr)
      -- The header is a pure addition and should be the only row carrying a
      -- full `DiffviewDiffAdd` line highlight; the commented lines below
      -- must NOT pick up that backdrop (which is the symptom of the
      -- positional-pairing fallback).
      local add_rows = {}
      for _, h in ipairs(line_hls(marks)) do
        if h.hl == "DiffviewDiffAdd" then
          add_rows[#add_rows + 1] = h.row
        end
      end
      assert.are.same({ 0 }, add_rows)

      -- Each commented line carries a `DiffviewDiffAddInline` extmark over
      -- the inserted `-- ` prefix.
      local adds = char_ranges(marks, "DiffviewDiffAddInline")
      local rows_with_add = {}
      for _, a in ipairs(adds) do
        rows_with_add[a.row] = true
      end
      assert.is_true(rows_with_add[1], "expected inline add on row 1")
      assert.is_true(rows_with_add[2], "expected inline add on row 2")

      -- No paired old lines are echoed as deletion virt_lines (the
      -- skipped-fallback symptom): only the inline strikethrough virt_text
      -- representing the empty old prefix would appear, and even that is
      -- empty for a pure prefix insertion.
      assert.are.same({}, virt_line_counts(marks))
    end)
  end)

  describe("deletion_highlight", function()
    -- Mirrors `DELETION_HL_WIDTH_CAP` in `inline_diff.lua`. Kept as a literal
    -- so a drift in the source value is caught here.
    local FULL_WIDTH_CAP = 500

    it("'full_width' appends a padding chunk sized to the displayed window", function()
      -- Tab + "hi" with tabstop=4 = 6 display cells. The buffer is shown in a
      -- vsplit so the pad target is the window's text-area width.
      -- `nvim_buf_call` inside the renderer ensures `strdisplaywidth` reads
      -- the target buffer's tabstop even when the active buffer differs.
      local target = fresh_buf({ "tail" })
      vim.api.nvim_set_option_value("tabstop", 4, { buf = target })
      local other = fresh_buf({ "" })
      vim.api.nvim_set_option_value("tabstop", 8, { buf = other })
      api.nvim_win_set_buf(api.nvim_get_current_win(), other)
      vim.cmd("vsplit")
      local winid = api.nvim_get_current_win()
      api.nvim_win_set_buf(winid, target)
      local info = vim.fn.getwininfo(winid)[1]
      local textoff = (info and info.textoff) or 0
      local text_width = api.nvim_win_get_width(winid) - textoff

      inline_diff.render(
        target,
        { "\thi", "tail" },
        { "tail" },
        { deletion_highlight = "full_width" }
      )

      local lines = virt_line_chunks(extmarks(target))
      assert.are.equal(1, #lines)
      local chunks = lines[1]
      assert.are.equal(2, #chunks)
      assert.are.equal("DiffviewDiffDelete", chunks[1][2])
      assert.are.equal("DiffviewDiffDelete", chunks[2][2])
      assert.are.equal(math.min(text_width, FULL_WIDTH_CAP) - 6, #chunks[2][1])
    end)

    it("'full_width' pads to the displayed window's width, not vim.o.columns", function()
      -- Splitting vertically so the target window's width is independent of
      -- the surrounding test windowing also exercises the typical vsplit
      -- diff layout.
      local bufnr = fresh_buf({ "context" })
      vim.cmd("vsplit")
      local winid = api.nvim_get_current_win()
      api.nvim_win_set_buf(winid, bufnr)
      -- Mirror `full_width_target`: subtract `textoff` so number/sign/fold
      -- columns aren't double-counted in the expected pad width.
      local info = vim.fn.getwininfo(winid)[1]
      local textoff = (info and info.textoff) or 0
      local text_width = api.nvim_win_get_width(winid) - textoff

      inline_diff.render(
        bufnr,
        { "deleted", "context" },
        { "context" },
        { deletion_highlight = "full_width" }
      )

      local lines = virt_line_chunks(extmarks(bufnr))
      assert.are.equal(1, #lines)
      local chunks = lines[1]
      assert.are.equal(2, #chunks)
      -- "deleted" is 7 display cells; padding fills the rest of the window.
      assert.are.equal(math.min(text_width, FULL_WIDTH_CAP) - 7, #chunks[2][1])
    end)

    -- Simulates the `Diff1Inline._prerender` use_entry path: the b buffer
    -- isn't yet displayed in the target diffview window (that window is
    -- still showing the previous file's buffer), but the caller knows the
    -- winid and forwards it so the pad target can be computed against the
    -- eventual display target. Without the hint the bufnr wouldn't be in
    -- `win_findbuf` so the pad would resolve to 0 and no padding chunk
    -- would be emitted.
    it("'full_width' uses opts.winid when the buffer isn't displayed yet", function()
      local target = fresh_buf({ "tail" })
      vim.cmd("vsplit")
      local winid = api.nvim_get_current_win()
      -- Crucially, do NOT put `target` into `winid`; keep some other buffer
      -- there so `win_findbuf(target)` returns nothing.
      local other = fresh_buf({ "other" })
      api.nvim_win_set_buf(winid, other)
      assert.are.same({}, vim.fn.win_findbuf(target))
      local info = vim.fn.getwininfo(winid)[1]
      local textoff = (info and info.textoff) or 0
      local text_width = api.nvim_win_get_width(winid) - textoff

      inline_diff.render(
        target,
        { "deleted", "tail" },
        { "tail" },
        { deletion_highlight = "full_width", winid = winid }
      )

      local lines = virt_line_chunks(extmarks(target))
      assert.are.equal(1, #lines)
      local chunks = lines[1]
      assert.are.equal(2, #chunks)
      -- "deleted" is 7 display cells; padding fills the rest of the hint window.
      assert.are.equal(math.min(text_width, FULL_WIDTH_CAP) - 7, #chunks[2][1])
    end)

    -- Confirms the previous test isn't a false positive: with no hint and
    -- no window showing the buffer, the pad target is 0 and no padding
    -- chunk is emitted.
    it(
      "'full_width' emits no padding when the buffer is undisplayed and no winid hint is given",
      function()
        local target = fresh_buf({ "tail" })
        assert.are.same({}, vim.fn.win_findbuf(target))

        inline_diff.render(
          target,
          { "deleted", "tail" },
          { "tail" },
          { deletion_highlight = "full_width" }
        )

        local lines = virt_line_chunks(extmarks(target))
        assert.are.equal(1, #lines)
        -- Only the deletion text, no padding chunk.
        assert.are.equal(1, #lines[1])
        assert.are.equal("deleted", lines[1][1][1])
      end
    )

    it("'full_width' pads in overleaf style under the overleaf del_hl", function()
      local bufnr = fresh_buf({ "alpha" })
      vim.cmd("vsplit")
      local winid = api.nvim_get_current_win()
      api.nvim_win_set_buf(winid, bufnr)
      inline_diff.render(
        bufnr,
        { "xyz", "pqr" },
        { "alpha" },
        { style = "overleaf", deletion_highlight = "full_width" }
      )

      local lines = virt_line_chunks(extmarks(bufnr))
      assert.is_true(#lines > 0)
      for _, chunks in ipairs(lines) do
        -- Every virt_line must carry both a text chunk and a padding chunk
        -- under the overleaf del_hl so the background stays consistent.
        assert.are.equal(2, #chunks)
        for _, chunk in ipairs(chunks) do
          assert.are.equal("DiffviewDiffDeleteInline", chunk[2])
        end
      end
    end)

    it("'text' emits a single chunk covering only the deleted characters", function()
      local bufnr = fresh_buf({ "tail" })
      inline_diff.render(bufnr, { "deleted", "tail" }, { "tail" }, { deletion_highlight = "text" })

      local lines = virt_line_chunks(extmarks(bufnr))
      assert.are.equal(1, #lines)
      local chunks = lines[1]
      assert.are.equal(1, #chunks)
      assert.are.equal("deleted", chunks[1][1])
      assert.are.equal("DiffviewDiffDelete", chunks[1][2])
    end)

    it("'hanging' splits leading whitespace off the highlight", function()
      local bufnr = fresh_buf({ "tail" })
      inline_diff.render(
        bufnr,
        { "  indented", "tail" },
        { "tail" },
        { deletion_highlight = "hanging" }
      )

      local lines = virt_line_chunks(extmarks(bufnr))
      assert.are.equal(1, #lines)
      local chunks = lines[1]
      assert.are.equal(2, #chunks)
      -- Leading whitespace chunk: no hl_group set (single-element chunk).
      assert.are.equal("  ", chunks[1][1])
      assert.is_nil(chunks[1][2])
      -- Remainder gets the deletion highlight.
      assert.are.equal("indented", chunks[2][1])
      assert.are.equal("DiffviewDiffDelete", chunks[2][2])
    end)

    it("'hanging' on a non-indented line emits the whole text under del_hl", function()
      local bufnr = fresh_buf({ "tail" })
      inline_diff.render(bufnr, { "plain", "tail" }, { "tail" }, { deletion_highlight = "hanging" })

      local lines = virt_line_chunks(extmarks(bufnr))
      assert.are.equal(1, #lines)
      local chunks = lines[1]
      assert.are.equal(1, #chunks)
      assert.are.equal("plain", chunks[1][1])
      assert.are.equal("DiffviewDiffDelete", chunks[1][2])
    end)

    it("'hanging' on an all-whitespace line still highlights the row", function()
      -- Defensive fallback: a deleted blank/all-whitespace line must remain
      -- visible as a deletion rather than collapsing to a zero-chunk virt_line.
      local bufnr = fresh_buf({ "tail" })
      inline_diff.render(bufnr, { "   ", "tail" }, { "tail" }, { deletion_highlight = "hanging" })

      local lines = virt_line_chunks(extmarks(bufnr))
      assert.are.equal(1, #lines)
      local chunks = lines[1]
      assert.are.equal(1, #chunks)
      assert.are.equal("   ", chunks[1][1])
      assert.are.equal("DiffviewDiffDelete", chunks[1][2])
    end)
  end)

  describe("hunk navigation", function()
    -- Set up a buffer with three discontiguous hunks: pure add at top,
    -- change in the middle, and pure deletion at the end.
    local function buf_with_hunks()
      local new = {
        "added one",
        "added two",
        "context",
        "middle changed",
        "context",
        "context",
      }
      local old = {
        "context",
        "middle",
        "context",
        "context",
        "trailing-old",
      }
      local bufnr = fresh_buf(new)
      inline_diff.render(bufnr, old, new)
      return bufnr
    end

    it("returns anchor rows sorted, one per hunk", function()
      local bufnr = buf_with_hunks()
      local rows = inline_diff.hunk_anchor_rows(bufnr)
      assert.is_true(#rows >= 2, "expected multiple hunks")
      for i = 2, #rows do
        assert.is_true(rows[i] > rows[i - 1], "rows must be strictly increasing")
      end
    end)

    it("next_hunk_row returns the first row strictly after the cursor", function()
      local bufnr = buf_with_hunks()
      local rows = inline_diff.hunk_anchor_rows(bufnr)
      -- From the top, next_hunk from -1 should be the first anchor.
      assert.are.equal(rows[1], inline_diff.next_hunk_row(bufnr, -1))
      -- From row[1], next should be rows[2].
      if #rows >= 2 then
        assert.are.equal(rows[2], inline_diff.next_hunk_row(bufnr, rows[1]))
      end
    end)

    it("next_hunk_row returns nil past the last hunk", function()
      local bufnr = buf_with_hunks()
      local rows = inline_diff.hunk_anchor_rows(bufnr)
      assert.is_nil(inline_diff.next_hunk_row(bufnr, rows[#rows]))
    end)

    it("prev_hunk_row returns nil before the first hunk", function()
      local bufnr = buf_with_hunks()
      local rows = inline_diff.hunk_anchor_rows(bufnr)
      assert.is_nil(inline_diff.prev_hunk_row(bufnr, rows[1]))
    end)

    it("prev_hunk_row returns the last row strictly before the cursor", function()
      local bufnr = buf_with_hunks()
      local rows = inline_diff.hunk_anchor_rows(bufnr)
      if #rows >= 2 then
        assert.are.equal(rows[1], inline_diff.prev_hunk_row(bufnr, rows[2]))
        -- From well past the last hunk, prev is the last one.
        assert.are.equal(rows[#rows], inline_diff.prev_hunk_row(bufnr, rows[#rows] + 100))
      end
    end)

    it("clear() also drops the cached hunks", function()
      local bufnr = buf_with_hunks()
      assert.is_true(#inline_diff.hunk_anchor_rows(bufnr) > 0)
      inline_diff.clear(bufnr)
      assert.are.same({}, inline_diff.hunk_anchor_rows(bufnr))
    end)

    it("drops cached hunks when the buffer is wiped externally", function()
      local bufnr = buf_with_hunks()
      assert.is_not_nil(inline_diff._hunks_by_buf[bufnr])

      -- Simulate a foreign owner deleting the buffer without calling clear().
      api.nvim_buf_delete(bufnr, { force = true })

      -- The buffer id may be reused; just confirm the stale entry is gone.
      assert.is_nil(inline_diff._hunks_by_buf[bufnr])
    end)

    it("detach() removes the CursorMoved scroll-adjuster autocmd", function()
      local bufnr = buf_with_hunks()
      local before = api.nvim_get_autocmds({
        group = "diffview_inline_diff_scroll",
        buffer = bufnr,
      })
      assert.is_true(#before > 0, "render should have installed the scroll adjuster")

      inline_diff.detach(bufnr)

      local after = api.nvim_get_autocmds({
        group = "diffview_inline_diff_scroll",
        buffer = bufnr,
      })
      assert.are.equal(0, #after)
      assert.are.same({}, inline_diff.hunk_anchor_rows(bufnr))
      assert.are.equal(0, #extmarks(bufnr))
    end)

    it("detach() followed by render reinstalls the scroll-adjuster autocmd", function()
      local bufnr = buf_with_hunks()
      inline_diff.detach(bufnr)

      inline_diff.render(bufnr, { "a", "b" }, { "a", "b", "c" })

      local autocmds = api.nvim_get_autocmds({
        group = "diffview_inline_diff_scroll",
        buffer = bufnr,
      })
      assert.are.equal(1, #autocmds)
    end)

    it("detach() resets topfill on windows displaying the buffer", function()
      -- Regression: without resetting topfill, tearing down the inline layout
      -- (e.g. layout switch) while `ensure_bof_virt_lines_visible` had raised
      -- `topfill` leaves an empty filler band above line 1 in the viewport.
      local new_lines = { "line 1", "line 2", "line 3" }
      local old_lines = { "gone 1", "gone 2", "line 1", "line 2", "line 3" }
      local bufnr = fresh_buf(new_lines)
      inline_diff.render(bufnr, old_lines, new_lines)

      local win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, bufnr)
      api.nvim_win_set_cursor(win, { 1, 0 })
      vim.fn.winrestview({ topline = 1, topfill = 0 })
      inline_diff.ensure_bof_virt_lines_visible(bufnr, win)
      assert.are.equal(2, vim.fn.winsaveview().topfill or 0)

      inline_diff.detach(bufnr)

      assert.are.equal(0, vim.fn.winsaveview().topfill or 0)
    end)
  end)

  describe("helpers", function()
    local h = inline_diff._test

    it("split_chars decomposes multi-byte characters with byte ranges", function()
      local chars, m = h.split_chars("a\xc3\xa9b")
      assert.are.same({ "a", "\xc3\xa9", "b" }, chars)
      assert.are.equal(3, #m)
      assert.are.equal(0, m[1].byte)
      assert.are.equal(1, m[1].byte_len)
      assert.are.equal(1, m[2].byte)
      assert.are.equal(2, m[2].byte_len)
      assert.are.equal(3, m[3].byte)
      assert.are.equal(1, m[3].byte_len)
    end)

    it("tokenize groups word-char runs and splits non-word chars individually", function()
      local tokens, m = h.tokenize("hello, world!")
      assert.are.same({ "hello", ",", " ", "world", "!" }, tokens)
      assert.are.equal(5, #m)
      assert.are.equal(0, m[1].byte)
      assert.are.equal(5, m[1].byte_len)
      assert.are.equal(5, m[2].byte)
      assert.are.equal(1, m[2].byte_len)
      assert.are.equal(7, m[4].byte)
      assert.are.equal(5, m[4].byte_len)
    end)

    it("tokenize keeps multi-byte letters inside their word run", function()
      -- "café" = 'c','a','f','é' → one word token spanning 5 bytes.
      local tokens, m = h.tokenize("caf\xc3\xa9")
      assert.are.same({ "caf\xc3\xa9" }, tokens)
      assert.are.equal(0, m[1].byte)
      assert.are.equal(5, m[1].byte_len)
    end)

    it("tokenize splits PascalCase identifiers at lower→upper boundaries", function()
      local tokens, m = h.tokenize("OnEventStateOpen")
      assert.are.same({ "On", "Event", "State", "Open" }, tokens)
      -- Byte ranges line up with the split points in the original string.
      assert.are.equal(0, m[1].byte)
      assert.are.equal(2, m[1].byte_len)
      assert.are.equal(2, m[2].byte)
      assert.are.equal(5, m[2].byte_len)
      assert.are.equal(7, m[3].byte)
      assert.are.equal(5, m[3].byte_len)
      assert.are.equal(12, m[4].byte)
      assert.are.equal(4, m[4].byte_len)
    end)

    it("tokenize splits acronyms before the trailing word (XMLParser → XML, Parser)", function()
      assert.are.same({ "XML", "Parser" }, (h.tokenize("XMLParser")))
      assert.are.same({ "my", "XML", "Parser" }, (h.tokenize("myXMLParser")))
    end)

    it("tokenize keeps an all-uppercase run as one subword when no word follows", function()
      assert.are.same({ "XML" }, (h.tokenize("XML")))
      assert.are.same({ "foo", "_", "XML" }, (h.tokenize("foo_XML")))
    end)

    it("tokenize splits at digit↔letter boundaries", function()
      assert.are.same({ "error", "123", "abc" }, (h.tokenize("error123abc")))
      assert.are.same({ "0", "x", "DEADBEEF" }, (h.tokenize("0xDEADBEEF")))
    end)

    it("tokenize emits each underscore run as its own subword", function()
      assert.are.same({ "audio", "_", "preservation" }, (h.tokenize("audio_preservation")))
      assert.are.same({ "__", "init", "__" }, (h.tokenize("__init__")))
    end)

    it("tokenize handles non-Latin scripts: joins lowercase, splits at uppercase", function()
      -- 日本 = U+65E5 U+672C, 6 bytes; multi-byte chars bucket as "lower",
      -- so non-Latin scripts join with adjacent ASCII lowercase rather
      -- than splitting per-character.
      assert.are.same(
        { "type\xe6\x97\xa5\xe6\x9c\xac" },
        (h.tokenize("type\xe6\x97\xa5\xe6\x9c\xac"))
      )
      -- A following uppercase letter still triggers the lower→upper split.
      assert.are.same(
        { "\xe6\x97\xa5\xe6\x9c\xac", "Type" },
        (h.tokenize("\xe6\x97\xa5\xe6\x9c\xacType"))
      )
    end)

    it("tokenize coalesces a long single-case hex hash into one token", function()
      -- 40-char SHA-1, all-lowercase hex with mixed digit/letter runs:
      -- without the post-pass the run subword-splits into ~25 tokens,
      -- which fragment the diff against an unrelated hash and admit
      -- coincidental subword matches under `INTRALINE_MAX_HUNKS`.
      local s = "1c9dfb261b8be35f689c6d83dfd3e92b7f59ecf8"
      local tokens, m = h.tokenize(s)
      assert.are.same({ s }, tokens)
      assert.are.equal(0, m[1].byte)
      assert.are.equal(40, m[1].byte_len)
    end)

    it("tokenize coalesces uppercase hex with alternating digits too", function()
      -- All-uppercase run with frequent digit↔letter alternation passes
      -- the same predicate.
      assert.are.same({ "AB12CD34EF56AB78" }, (h.tokenize("AB12CD34EF56AB78")))
    end)

    it("tokenize leaves short hex-like runs subword-split", function()
      -- 7 chars, below `HEX_TOKEN_MIN_LEN`: stays subword-split so a
      -- short identifier suffix isn't collapsed into one opaque token.
      assert.are.same({ "abc", "1234" }, (h.tokenize("abc1234")))
    end)

    it("tokenize rejects pseudo-hex with low transition density", function()
      -- 1-2 transitions across 12-13 chars sit below `ceil(len/4)`, so
      -- word-prefixed patterns keep their split and `decade` /
      -- `1234567` stay diffable as semantic units.
      assert.are.same({ "decade", "1234567" }, (h.tokenize("decade1234567")))
      assert.are.same({ "cafebabe", "1234" }, (h.tokenize("cafebabe1234")))
      assert.are.same({ "face", "1234", "abcd" }, (h.tokenize("face1234abcd")))
    end)

    it("tokenize rejects pseudo-hex with a long letter run", function()
      -- 3 transitions hits `ceil(12/4)=3`, but `cafef` letter run = 5
      -- exceeds `HEX_TOKEN_MAX_LETTER_RUN`, so the predicate rejects.
      assert.are.same({ "cafef", "00", "d", "1234" }, (h.tokenize("cafef00d1234")))
    end)

    it("subword_class buckets ASCII and multi-byte chars correctly", function()
      assert.are.equal("lower", h.subword_class("a"))
      assert.are.equal("upper", h.subword_class("Z"))
      assert.are.equal("digit", h.subword_class("3"))
      assert.are.equal("under", h.subword_class("_"))
      assert.are.equal("lower", h.subword_class("\xc3\xa9")) -- é treated as lower
      -- Stray high byte from malformed UTF-8 (1-byte chunk with b >= 0x80)
      -- is bucketed as "lower" to match `is_word_byte`'s word-char treatment.
      assert.are.equal("lower", h.subword_class("\xc3"))
      assert.are.equal("lower", h.subword_class("\x80"))
      assert.is_nil(h.subword_class(" "))
      assert.is_nil(h.subword_class(","))
      assert.is_nil(h.subword_class(""))
    end)

    it("is_word_token distinguishes word runs from punctuation tokens", function()
      assert.is_true(h.is_word_token("foo"))
      assert.is_true(h.is_word_token("_x"))
      assert.is_true(h.is_word_token("\xc3\xa9"))
      assert.is_false(h.is_word_token(","))
      assert.is_false(h.is_word_token(" "))
      assert.is_false(h.is_word_token(""))
    end)

    it("is_hex_run accepts long single-case hex with high transition density", function()
      assert.is_true(h.is_hex_run("1c9dfb261b8be35f689c6d83dfd3e92b7f59ecf8"))
      assert.is_true(h.is_hex_run("AB12CD34EF56AB78"))
    end)

    it("is_hex_run rejects strings shorter than HEX_TOKEN_MIN_LEN", function()
      assert.is_false(h.is_hex_run("abc1234"))
      assert.is_false(h.is_hex_run(""))
    end)

    it("is_hex_run rejects mixed-case hex", function()
      -- `tokenize`'s upper→lower split already separates the cases, so a
      -- mixed-case merge candidate never reaches `is_hex_run` in practice;
      -- the predicate rejects defensively for correctness.
      assert.is_false(h.is_hex_run("AbCd1234"))
    end)

    it("is_hex_run rejects strings with non-hex chars", function()
      assert.is_false(h.is_hex_run("hello123abc"))
      assert.is_false(h.is_hex_run("1234567890_"))
    end)

    it("is_hex_run rejects low transition density", function()
      assert.is_false(h.is_hex_run("decade1234567"))
      assert.is_false(h.is_hex_run("cafebabe1234"))
    end)

    it("is_hex_run rejects long letter runs", function()
      -- `cafef` = 5-char letter run, exceeds `HEX_TOKEN_MAX_LETTER_RUN`.
      assert.is_false(h.is_hex_run("cafef00d1234"))
    end)

    it("is_hex_run rejects pure-digit and pure-letter runs", function()
      -- These can't reach the predicate from `coalesce_hex_runs` (their
      -- source word run is one subword token), but rejecting them on
      -- their own merits keeps the contract sharp: zero transitions.
      assert.is_false(h.is_hex_run("12345678"))
      assert.is_false(h.is_hex_run("abcdefab"))
    end)

    it("diff_units returns [] when either side is empty", function()
      assert.are.same({}, h.diff_units({}, { "a" }))
      assert.are.same({}, h.diff_units({ "a" }, {}))
    end)

    it("refinement_safe admits single-hunk sub-diffs regardless of overlap", function()
      -- One hunk cannot interleave, so even unrelated words (foo/bar) are safe.
      assert.is_true(h.refinement_safe({ "f", "o", "o" }, { "b", "a", "r" }, 1))
    end)

    it("refinement_safe admits multi-hunk sub-diffs with a shared prefix", function()
      -- "recieve" / "receive" share prefix "rec" and suffix "ve".
      assert.is_true(
        h.refinement_safe(
          { "r", "e", "c", "i", "e", "v", "e" },
          { "r", "e", "c", "e", "i", "v", "e" },
          2
        )
      )
    end)

    it("refinement_safe rejects multi-hunk sub-diffs with no substantial overlap", function()
      -- "param" / "return" share only a coincidental 'r'; refining would
      -- interleave the deleted and inserted chars.
      assert.is_false(
        h.refinement_safe({ "p", "a", "r", "a", "m" }, { "r", "e", "t", "u", "r", "n" }, 2)
      )
    end)

    it("refinement_safe rejects when hunk count exceeds the limit", function()
      assert.is_false(h.refinement_safe({ "a" }, { "b" }, h.INTRALINE_MAX_HUNKS + 1))
    end)
  end)

  describe("similarity gate", function()
    local function text_extmarks(bufnr)
      local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, { details = true })
      local out = { hl = 0, inline = 0 }
      for _, m in ipairs(marks) do
        local d = m[4]
        if d.hl_group == "DiffviewDiffAddInline" then
          out.hl = out.hl + 1
        end
        if d.virt_text and d.virt_text_pos == "inline" then
          out.inline = out.inline + 1
        end
      end
      return out
    end

    it("renders char-level highlights for similar paired lines", function()
      local bufnr = fresh_buf({ "hello brave world" })
      inline_diff.render(bufnr, { "hello world" }, { "hello brave world" })
      local t = text_extmarks(bufnr)
      assert.is_true(t.hl > 0, "expected DiffviewDiffAddInline on added chars for similar lines")
    end)

    it("skips char-level highlights when lines are too dissimilar (unified)", function()
      -- Two sentences sharing only the first clause; the divergent tails are
      -- completely different content that would otherwise produce fragmented
      -- char-level hunks.
      local old = "This is a plain, singular window. This is available in case"
      local new = "This is a plain, singular window with no diff rendering —"
      local bufnr = fresh_buf({ new })
      inline_diff.render(bufnr, { old }, { new })
      local t = text_extmarks(bufnr)
      assert.are.equal(0, t.hl, "expected no DiffviewDiffAddInline fragments on dissimilar pairing")
    end)

    it("skips inline deletions in overleaf for dissimilar pairings", function()
      local old = "This is a plain, singular window. This is available in case"
      local new = "This is a plain, singular window with no diff rendering —"
      local bufnr = fresh_buf({ new })
      inline_diff.render(bufnr, { old }, { new }, { style = "overleaf" })
      local t = text_extmarks(bufnr)
      assert.are.equal(0, t.inline, "expected no inline deletion virt_text on dissimilar pairing")
    end)

    it("falls back to block echo + DiffAdd line_hl in overleaf when char-level skips", function()
      -- When overleaf's char-level rendering is gated off, the paired
      -- modification would otherwise be invisible. Verify the fallback
      -- emits a `DiffviewDiffAdd` line_hl (not `DiffviewDiffChange` — see
      -- the `"skipped"` branch in `M.render`) and a virt_line under the
      -- overleaf `del_hl` (preserving the strikethrough on the echoed
      -- line, not silently downgrading to `DiffviewDiffDelete`).
      local old = "This is a plain, singular window. This is available in case"
      local new = "This is a plain, singular window with no diff rendering —"
      local bufnr = fresh_buf({ new })
      inline_diff.render(bufnr, { old }, { new }, { style = "overleaf" })

      local hls = line_hls(extmarks(bufnr))
      assert.are.same({ { row = 0, hl = "DiffviewDiffAdd" } }, hls)

      local vls = virt_line_hls(extmarks(bufnr))
      assert.are.same({ "DiffviewDiffDeleteInline" }, vls)
    end)

    it("renders a JSON commit-hash modification as one whole-token swap", function()
      -- A pair of lazy-lock.json-style lines differing only in a 40-char
      -- SHA. Without `coalesce_hex_runs`, the two unrelated hashes
      -- subword-split into ~17-19 alternating digit/lowercase tokens
      -- whose coincidental matches kept some pairs under
      -- `INTRALINE_MAX_HUNKS` and rendered as fragmented per-token
      -- highlights; after coalescing, the diff is a single 1:1 hash
      -- replacement covering exactly the new hash's byte range.
      local old_line = '  "x": { "commit": "ffa44ee9470743a7697d28df3a1a216fdfe2b09d" }'
      local new_line = '  "x": { "commit": "cf4c30892644f01ebfb1e248eeca9e259856f9dc" }'
      local bufnr = fresh_buf({ new_line })
      inline_diff.render(bufnr, { old_line }, { new_line })
      local cr = char_ranges(extmarks(bufnr))
      assert.are.equal(1, #cr)
      local hash_start = string.find(new_line, "cf4c3089", 1, true) - 1
      assert.are.equal(0, cr[1].row)
      assert.are.equal(hash_start, cr[1].start)
      assert.are.equal(hash_start + 40, cr[1].finish)
    end)

    it("emits the entire deleted hash as one inline virt_text in overleaf", function()
      local old_line = '  "x": { "commit": "ffa44ee9470743a7697d28df3a1a216fdfe2b09d" }'
      local new_line = '  "x": { "commit": "cf4c30892644f01ebfb1e248eeca9e259856f9dc" }'
      local bufnr = fresh_buf({ new_line })
      inline_diff.render(bufnr, { old_line }, { new_line }, { style = "overleaf" })
      local virts = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.are.equal(1, #virts)
      assert.are.equal("ffa44ee9470743a7697d28df3a1a216fdfe2b09d", virts[1].text)
    end)
  end)

  describe("intraline tokenization", function()
    -- Regression: per-character diffing matched coincidental letters
    -- ('t', 'e', 'm', 'i', '.') between "something." and "any tracked
    -- metric." and fragmented the change into interleaved per-char
    -- virt_text in overleaf. Word-level tokens keep the deleted word as
    -- a single strikethrough unit before the added phrase.
    it("renders multi-word replacements without char interleaving (overleaf)", function()
      local old = "# Print the log, showing only passes that changed something."
      local new = "# Print the log, showing only passes that changed any tracked metric."
      local bufnr = fresh_buf({ new })
      inline_diff.render(bufnr, { old }, { new }, { style = "overleaf" })

      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.are.equal(1, #inlines, "expected a single inline deletion virt_text")
      assert.are.equal("something", inlines[1].text)
      -- Anchor sits before "any" in the new line.
      local anchor_at = ("# Print the log, showing only passes that changed "):len()
      assert.are.equal(anchor_at, inlines[1].col)
    end)

    it("refines 1:1 word replacements with char-level precision", function()
      -- "recieve" → "receive" is one word-level 1:1 pair, so the sub-diff
      -- kicks in. DiffviewDiffAddInline highlights should cover only the moved letter
      -- rather than the whole word.
      local bufnr = fresh_buf({ "receive" })
      inline_diff.render(bufnr, { "recieve" }, { "receive" })

      local ranges = char_ranges(extmarks(bufnr))
      assert.is_true(#ranges > 0, "expected char-level DiffviewDiffAddInline inside the word")
      for _, r in ipairs(ranges) do
        assert.is_true(
          r.finish - r.start < #"receive",
          "each highlight should be narrower than the full word"
        )
      end
    end)

    it("emits char-level inline deletions inside a 1:1 word replacement (overleaf)", function()
      local bufnr = fresh_buf({ "receive" })
      inline_diff.render(bufnr, { "recieve" }, { "receive" }, { style = "overleaf" })

      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.is_true(#inlines >= 1, "expected inline deletion from char-level refinement")
      for _, v in ipairs(inlines) do
        assert.is_true(
          #v.text < #"recieve",
          "refined inline deletions must be sub-word, not the whole old word"
        )
      end
    end)

    it("treats multi-word replacements atomically (no intra-word refinement)", function()
      -- Replacing one word with multiple words is not a 1:1 pair, so the
      -- whole deleted word sits before the added tokens as a single
      -- strikethrough run rather than being split char-by-char.
      local bufnr = fresh_buf({ "any tracked metric" })
      inline_diff.render(bufnr, { "something" }, { "any tracked metric" }, { style = "overleaf" })

      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.are.equal(1, #inlines)
      assert.are.equal("something", inlines[1].text)
    end)

    it("keeps punctuation swaps as atomic token hunks", function()
      -- A single-char punctuation change (is_word_token=false) must not
      -- trigger char-level refinement — the hunk stays at token level.
      local bufnr = fresh_buf({ "a; b" })
      inline_diff.render(bufnr, { "a, b" }, { "a; b" }, { style = "overleaf" })

      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.are.equal(1, #inlines)
      assert.are.equal(",", inlines[1].text)
    end)

    it("renders PascalCase identifier replacements as whole-subword swaps (overleaf)", function()
      -- Regression: a 1:1 token replacement between identifiers sharing a
      -- structural prefix (`EventStateOpen` / `EventStateClose`) used to
      -- admit char-level refinement on the prefix gate, then `vim.diff`
      -- latched onto a coincidental `e` inside the differing tails and
      -- rendered interleaved per-char noise. With subword tokens the
      -- divergent subword pairs directly with its replacement.
      local old = "    EventStateOpen = 0,"
      local new = "    EventStateClose = 0,"
      local bufnr = fresh_buf({ new })
      inline_diff.render(bufnr, { old }, { new }, { style = "overleaf" })

      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.are.equal(1, #inlines, "expected a single inline deletion virt_text")
      assert.are.equal("Open", inlines[1].text)
      -- Anchor sits before "Close" in the new line.
      assert.are.equal(("    EventState"):len(), inlines[1].col)

      -- The DiffviewDiffAddInline hl on "Close" is one contiguous span, not
      -- interleaved per-char fragments.
      local ranges = char_ranges(extmarks(bufnr))
      assert.are.equal(
        1,
        #ranges,
        "expected one DiffviewDiffAddInline span over the inserted subword"
      )
      assert.are.equal(("    EventState"):len(), ranges[1].start)
      assert.are.equal(("    EventStateClose"):len(), ranges[1].finish)
    end)

    it("ensure_eof_virt_lines_visible bumps topline so trailing deletions fit", function()
      -- Build a buffer large enough that `G` lands line N at the bottom of
      -- the window with virt_lines_below clipped. After adjustment, topline
      -- must rise enough that the 3 trailing virt_lines fit below the cursor.
      local new_lines = {}
      for i = 1, 20 do
        new_lines[i] = "line " .. i
      end
      local old_lines = {}
      for i = 1, 23 do
        old_lines[i] = "line " .. i
      end

      local bufnr = fresh_buf(new_lines)
      inline_diff.render(bufnr, old_lines, new_lines)

      local win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, bufnr)
      pcall(api.nvim_win_set_height, win, 13)
      api.nvim_win_set_cursor(win, { 20, 0 })

      local height = api.nvim_win_get_height(win)
      -- Force an initial topline that clips the EOF virt_lines (cursor sits
      -- at the very bottom row).
      vim.fn.winrestview({ topline = 20 - height + 1 })
      local before = vim.fn.winsaveview().topline

      inline_diff.ensure_eof_virt_lines_visible(bufnr, win)
      local after = vim.fn.winsaveview().topline

      assert.is_true(after > before, "topline should have risen to reveal EOF virt_lines")
      -- 3 virt_lines below line 20 in a 13-row window: cursor must sit at
      -- row height - below = 10, so topline = 20 - 10 + 1 = 11.
      assert.are.equal(11, after)
    end)

    it(
      "ensure_eof_virt_lines_visible is a no-op when the cursor is not on the last line",
      function()
        local bufnr = fresh_buf({ "a", "b", "c" })
        inline_diff.render(bufnr, { "a", "b", "c", "d", "e" }, { "a", "b", "c" })

        local win = api.nvim_get_current_win()
        api.nvim_win_set_buf(win, bufnr)
        api.nvim_win_set_cursor(win, { 1, 0 })

        local before = vim.fn.winsaveview().topline
        inline_diff.ensure_eof_virt_lines_visible(bufnr, win)
        assert.are.equal(before, vim.fn.winsaveview().topline)
      end
    )

    it("ensure_eof_virt_lines_visible is a no-op when there are no EOF virt_lines", function()
      local bufnr = fresh_buf({ "a", "b", "c" })
      local win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, bufnr)
      api.nvim_win_set_cursor(win, { 3, 0 })

      local before = vim.fn.winsaveview().topline
      inline_diff.ensure_eof_virt_lines_visible(bufnr, win)
      assert.are.equal(before, vim.fn.winsaveview().topline)
    end)

    it("ensure_bof_virt_lines_visible sets topfill so leading deletions render", function()
      -- 3 deleted lines before the first surviving line. `virt_lines_above`
      -- on row 0 are clipped at `topline=1` unless `topfill` is set.
      local new_lines = { "line 1", "line 2", "line 3" }
      local old_lines = { "gone 1", "gone 2", "gone 3", "line 1", "line 2", "line 3" }
      local bufnr = fresh_buf(new_lines)
      inline_diff.render(bufnr, old_lines, new_lines)

      local win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, bufnr)
      api.nvim_win_set_cursor(win, { 1, 0 })
      vim.fn.winrestview({ topline = 1, topfill = 0 })
      assert.are.equal(0, vim.fn.winsaveview().topfill or 0)

      inline_diff.ensure_bof_virt_lines_visible(bufnr, win)
      assert.are.equal(3, vim.fn.winsaveview().topfill or 0)
    end)

    it("ensure_bof_virt_lines_visible is a no-op when topline is not 1", function()
      local new_lines = {}
      for i = 1, 10 do
        new_lines[i] = "line " .. i
      end
      local old_lines = { "gone 1", "gone 2" }
      for i = 1, 10 do
        old_lines[#old_lines + 1] = "line " .. i
      end
      local bufnr = fresh_buf(new_lines)
      inline_diff.render(bufnr, old_lines, new_lines)

      local win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, bufnr)
      api.nvim_win_set_cursor(win, { 5, 0 })
      vim.fn.winrestview({ topline = 3, topfill = 0 })

      inline_diff.ensure_bof_virt_lines_visible(bufnr, win)
      assert.are.equal(0, vim.fn.winsaveview().topfill or 0)
    end)

    it("ensure_bof_virt_lines_visible is a no-op when there are no BOF virt_lines", function()
      local bufnr = fresh_buf({ "a", "b", "c" })
      local win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, bufnr)
      api.nvim_win_set_cursor(win, { 1, 0 })

      local before = vim.fn.winsaveview().topfill or 0
      inline_diff.ensure_bof_virt_lines_visible(bufnr, win)
      assert.are.equal(before, vim.fn.winsaveview().topfill or 0)
    end)

    it("ensure_bof_virt_lines_visible clears stale topfill when BOF deletions go away", function()
      -- Regression: topfill is window state, so a render that previously set
      -- it (for BOF virt_lines above line 1) needs to clear it on a later
      -- render where those deletions are gone; otherwise the viewport shows
      -- an empty filler band above line 1.
      local new_lines = { "line 1", "line 2", "line 3" }
      local old_lines = { "gone 1", "gone 2", "line 1", "line 2", "line 3" }
      local bufnr = fresh_buf(new_lines)
      inline_diff.render(bufnr, old_lines, new_lines)

      local win = api.nvim_get_current_win()
      api.nvim_win_set_buf(win, bufnr)
      api.nvim_win_set_cursor(win, { 1, 0 })
      vim.fn.winrestview({ topline = 1, topfill = 0 })
      inline_diff.ensure_bof_virt_lines_visible(bufnr, win)
      assert.are.equal(2, vim.fn.winsaveview().topfill or 0)

      -- Re-render with no BOF deletions; topfill must fall back to 0.
      inline_diff.render(bufnr, new_lines, new_lines)
      vim.fn.winrestview({ topline = 1, topfill = 2 })
      inline_diff.ensure_bof_virt_lines_visible(bufnr, win)
      assert.are.equal(0, vim.fn.winsaveview().topfill or 0)
    end)

    it("does not spuriously mark the trailing token as deleted when paired line grows", function()
      -- Regression: a 3-line function collapsed to 1 line pairs the first
      -- old line with the new single-line version. The old line ends at
      -- `)`; the new line has `)` at the same position and a long tail
      -- appended. Without a trailing newline in `diff_units` input,
      -- vim.diff flagged `)` as deleted+reinserted, emitting a spurious
      -- `)` strikethrough virt_text on the paired row.
      local old = "function M.get_status_icon(status)"
      local new = "function M.get_status_icon(status) return "
        .. "config.get_config().status_icons[status] or status end"
      local bufnr = fresh_buf({ new })
      inline_diff.render(bufnr, { old }, { new }, { style = "overleaf" })

      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.are.equal(
        0,
        #inlines,
        "pure addition after a shared prefix should emit no inline deletions"
      )
      -- The appended tail is highlighted as added.
      local ranges = char_ranges(extmarks(bufnr))
      assert.is_true(#ranges > 0, "expected DiffviewDiffAddInline on the appended tail")
    end)

    it("refines a 1:N hunk where a word is split by inserted whitespace", function()
      -- Regression: `statusend` → `status end` was rendering as
      -- `[statusend]status end` (whole old word shown deleted, whole new
      -- phrase shown inserted), when the ideal display is a highlight on
      -- the inserted space — `status` and `end` are common substrings.
      -- The concat-based refinement path handles this as a single-hunk
      -- char-level insert.
      local bufnr = fresh_buf({ "status end" })
      inline_diff.render(bufnr, { "statusend" }, { "status end" }, { style = "overleaf" })

      -- No inline deletion virt_text — nothing was "deleted" at char level.
      local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
      assert.are.equal(0, #inlines)

      -- The single added character (the space) is highlighted.
      local ranges = char_ranges(extmarks(bufnr))
      assert.are.equal(1, #ranges)
      assert.are.equal(6, ranges[1].start)
      assert.are.equal(7, ranges[1].finish)
    end)

    it(
      "falls back to atomic word delete for 1:1 pairs with only a coincidental letter match",
      function()
        -- Regression: `param` and `return` share only a single `r`, so the
        -- char-level refinement produced two hunks whose fragments rendered
        -- as `---@[pa]r[am]eturn new stringboolean`. Multi-hunk refinement
        -- without a substantial shared prefix/suffix must fall back to
        -- word-level rendering so the old word stays intact.
        local old = "---@param new string"
        local new = "---@return boolean"
        local bufnr = fresh_buf({ new })
        inline_diff.render(bufnr, { old }, { new }, { style = "overleaf" })

        local inlines = inline_virt_texts(extmarks(bufnr), "DiffviewDiffDeleteInline")
        local texts = {}
        for _, v in ipairs(inlines) do
          texts[#texts + 1] = v.text
        end
        table.sort(texts)
        assert.are.same({ "new string", "param" }, texts)
      end
    )
  end)

  describe("treesitter captures", function()
    local captured_chunks = inline_diff._test.captured_chunks
    local compute_old_line_captures = inline_diff._test.compute_old_line_captures

    -- Probe whether the test environment has the `lua` parser; the end-to-end
    -- TS tests below need it. When unavailable, the parser-dependent
    -- assertions degrade to a no-op rather than fail the suite, since the
    -- production code path also degrades silently.
    local lua_parser_available = (function()
      local ok = pcall(vim.treesitter.get_string_parser, "local x = 1\n", "lua")
      return ok
    end)()

    it("captured_chunks falls back to a single chunk when no captures supplied", function()
      assert.are.same(
        { { "hello", "DiffviewDiffDelete" } },
        captured_chunks("hello", nil, "DiffviewDiffDelete")
      )
      assert.are.same(
        { { "hello", "DiffviewDiffDelete" } },
        captured_chunks("hello", {}, "DiffviewDiffDelete")
      )
    end)

    it("captured_chunks emits a single empty del_hl chunk for empty text", function()
      -- Preserve the pre-TS shape so a deleted blank line still produces a
      -- visible virt_line row (a zero-chunk list could be elided by Neovim's
      -- renderer). Captures past `#text` are simply ignored.
      assert.are.same(
        { { "", "DiffviewDiffDelete" } },
        captured_chunks("", { { 0, 5, "@string" } }, "DiffviewDiffDelete")
      )
    end)

    it("captured_chunks layers a single capture over del_hl as stacked hl groups", function()
      local chunks = captured_chunks("hello", { { 0, 5, "@string" } }, "DiffviewDiffDelete")
      assert.are.equal(1, #chunks)
      assert.are.equal("hello", chunks[1][1])
      assert.are.same({ "DiffviewDiffDelete", "@string" }, chunks[1][2])
    end)

    it("captured_chunks splits text into per-capture segments around uncovered runs", function()
      -- Cover only the middle "ll" so the outer "he"/"o" segments fall back
      -- to plain del_hl.
      local chunks = captured_chunks("hello", { { 2, 4, "@keyword" } }, "DiffviewDiffDelete")
      assert.are.equal(3, #chunks)
      assert.are.equal("he", chunks[1][1])
      assert.are.equal("DiffviewDiffDelete", chunks[1][2])
      assert.are.equal("ll", chunks[2][1])
      assert.are.same({ "DiffviewDiffDelete", "@keyword" }, chunks[2][2])
      assert.are.equal("o", chunks[3][1])
      assert.are.equal("DiffviewDiffDelete", chunks[3][2])
    end)

    it("captured_chunks stacks overlapping captures so each contributes attrs", function()
      -- The hl_group list forwarded to nvim_buf_set_extmark composes attrs in
      -- priority order (rightmost wins per-attribute, undefined attrs don't
      -- override), so passing the full stack lets Neovim's merger produce the
      -- same result as the on-buffer TS highlighter. Picking only the latest
      -- capture per byte would silently drop earlier captures' attrs — fatal
      -- when a later capture (e.g. `@spell`) defines no fg and an earlier one
      -- (`@comment`) does.
      local chunks = captured_chunks(
        "hello",
        { { 0, 5, "@variable" }, { 1, 3, "@string" } },
        "DiffviewDiffDelete"
      )
      -- Expect: [h:variable][el:variable+string][lo:variable]. The middle
      -- segment carries both captures in iteration order.
      assert.are.equal(3, #chunks)
      assert.are.equal("h", chunks[1][1])
      assert.are.same({ "DiffviewDiffDelete", "@variable" }, chunks[1][2])
      assert.are.equal("el", chunks[2][1])
      assert.are.same({ "DiffviewDiffDelete", "@variable", "@string" }, chunks[2][2])
      assert.are.equal("lo", chunks[3][1])
      assert.are.same({ "DiffviewDiffDelete", "@variable" }, chunks[3][2])
    end)

    it(
      "captured_chunks preserves an earlier capture's fg under a later attr-less capture",
      function()
        -- Lua/Go/JS highlights queries emit `@comment` and then `@spell` for
        -- every comment node; `@spell` typically defines only undercurl/sp, no
        -- fg. A "last wins" reduction would emit `{del_hl, @spell}`, so deleted
        -- comments would render with the default Normal fg. Stacking forwards
        -- both — the merger keeps `@comment`'s fg because `@spell` doesn't
        -- redefine it.
        local chunks = captured_chunks(
          "-- comment",
          { { 0, 10, "@comment" }, { 0, 10, "@spell" } },
          "DiffviewDiffDelete"
        )
        assert.are.equal(1, #chunks)
        assert.are.equal("-- comment", chunks[1][1])
        assert.are.same({ "DiffviewDiffDelete", "@comment", "@spell" }, chunks[1][2])
      end
    )

    it("captured_chunks clamps captures that extend past text end", function()
      -- Off-by-one or stale captures past `#text` must not generate a phantom
      -- chunk on the next iteration.
      local chunks = captured_chunks("hi", { { 0, 100, "@string" } }, "DiffviewDiffDelete")
      assert.are.equal(1, #chunks)
      assert.are.equal("hi", chunks[1][1])
      assert.are.same({ "DiffviewDiffDelete", "@string" }, chunks[1][2])
    end)

    it("captured_chunks bypasses per-byte resolution past the long-line cap", function()
      -- Pathologically long lines (e.g. minified bundles) skip the
      -- O(text_len) per-byte capture pass and fall back to a single
      -- plain del_hl chunk, regardless of any captures supplied.
      local long = string.rep("a", 5001)
      local chunks = captured_chunks(long, { { 0, 5001, "@string" } }, "DiffviewDiffDelete")
      assert.are.equal(1, #chunks)
      assert.are.equal(long, chunks[1][1])
      assert.are.equal("DiffviewDiffDelete", chunks[1][2])
    end)

    it("compute_old_line_captures returns empty table when filetype is unset", function()
      local bufnr = fresh_buf({ "local x = 1" })
      vim.api.nvim_set_option_value("filetype", "", { buf = bufnr })
      assert.are.same({}, compute_old_line_captures({ "local x = 1" }, bufnr))
    end)

    it("compute_old_line_captures returns empty table for empty old_lines", function()
      -- Empty `old_lines` short-circuits before any filetype/TS lookup, so the
      -- buffer's filetype is irrelevant. Leave it unset to avoid triggering
      -- ftplugins that might error out when their TS parser isn't installed.
      local bufnr = fresh_buf({ "" })
      assert.are.same({}, compute_old_line_captures({}, bufnr))
    end)

    it("compute_old_line_captures bails out past the source-size cap", function()
      -- Past the cap, the function returns `{}` before any parse work runs,
      -- so callers fall back to plain del_hl chunks rather than blocking
      -- the UI on a synchronous parse over a large generated/minified
      -- source. `noautocmd` keeps the bundled lua ftplugin (which calls
      -- `vim.treesitter.start`) out of this path so the test stays
      -- portable when the lua parser isn't installed in the runtime.
      local bufnr = fresh_buf({ "" })
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("noautocmd set filetype=lua")
      end)
      local oversized = string.rep("x", 100001)
      assert.are.same({}, compute_old_line_captures({ "x" }, bufnr, oversized))
    end)

    if lua_parser_available then
      it("compute_old_line_captures yields per-line captures for a known filetype", function()
        local bufnr = fresh_buf({ "" })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
        local result = compute_old_line_captures({ "local x = 1" }, bufnr)
        -- Lua highlights query is rich: at minimum we expect captures on
        -- line 1 (the only old line). Don't pin specific capture names —
        -- the TS query catalog evolves between Nvim versions.
        assert.is_table(result[1])
        assert.is_true(#result[1] > 0)
        for _, c in ipairs(result[1]) do
          assert.is_number(c[1])
          assert.is_number(c[2])
          assert.is_string(c[3])
          assert.is_truthy(c[3]:match("^@"))
        end
      end)

      it("render layers TS captures over the deletion background", function()
        local bufnr = fresh_buf({ "tail" })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
        inline_diff.render(bufnr, { "local x = 1", "tail" }, { "tail" })

        local lines = virt_line_chunks(extmarks(bufnr))
        assert.are.equal(1, #lines)
        local chunks = lines[1]
        -- At least one chunk must be a stacked-hl chunk (TS layered over
        -- del_hl). The plain-text fallback would emit a single chunk with
        -- a string hl_group; once captures kick in we get multiple chunks
        -- and at least one with a list-shaped hl_group.
        local saw_stacked = false
        for _, ch in ipairs(chunks) do
          if type(ch[2]) == "table" then
            assert.are.equal("DiffviewDiffDelete", ch[2][1])
            saw_stacked = true
          end
        end
        assert.is_true(saw_stacked, "expected at least one stacked TS+del_hl chunk")
      end)

      it("deletion_treesitter=false skips the TS layer", function()
        local bufnr = fresh_buf({ "tail" })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
        inline_diff.render(
          bufnr,
          { "local x = 1", "tail" },
          { "tail" },
          { deletion_treesitter = false }
        )

        local lines = virt_line_chunks(extmarks(bufnr))
        assert.are.equal(1, #lines)
        -- Without TS layering each line collapses to a single plain-text
        -- chunk under `del_hl`, with no stacked hl_group.
        for _, ch in ipairs(lines[1]) do
          assert.are.equal("string", type(ch[2]))
          assert.are.equal("DiffviewDiffDelete", ch[2])
        end
      end)

      it("'hanging' offsets TS captures past the leading indent", function()
        local bufnr = fresh_buf({ "tail" })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
        inline_diff.render(
          bufnr,
          { "  local x = 1", "tail" },
          { "tail" },
          { deletion_highlight = "hanging" }
        )

        local lines = virt_line_chunks(extmarks(bufnr))
        assert.are.equal(1, #lines)
        local chunks = lines[1]
        -- First chunk is the unhighlighted indent (no hl_group).
        assert.are.equal("  ", chunks[1][1])
        assert.is_nil(chunks[1][2])
        -- Subsequent chunks must concatenate to the rest of the line and
        -- carry stacked-hl groups for at least one of them.
        local rest_text = ""
        local saw_stacked = false
        for i = 2, #chunks do
          rest_text = rest_text .. chunks[i][1]
          if type(chunks[i][2]) == "table" then
            assert.are.equal("DiffviewDiffDelete", chunks[i][2][1])
            saw_stacked = true
          end
        end
        assert.are.equal("local x = 1", rest_text)
        assert.is_true(saw_stacked, "expected at least one stacked TS+del_hl chunk in the rest")
      end)

      it("reuses captures across renders when old_lines content is unchanged", function()
        -- _repaint flows re-call render with the same old-side content on
        -- every TextChanged; the captures cache lets the TS parse run once
        -- instead of per redraw. Cache key is content-based, so a fresh
        -- table with equal content also hits.
        local bufnr = fresh_buf({ "tail" })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
        inline_diff.render(bufnr, { "local x = 1", "tail" }, { "tail" })
        local first = inline_diff._captures_by_buf[bufnr]
        assert.is_not_nil(first)

        inline_diff.render(bufnr, { "local x = 1", "tail" }, { "tail" })
        local second = inline_diff._captures_by_buf[bufnr]
        assert.are.equal(first, second)
      end)

      it("recomputes captures when old_lines content changes", function()
        local bufnr = fresh_buf({ "tail" })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
        inline_diff.render(bufnr, { "local x = 1", "tail" }, { "tail" })
        local first = inline_diff._captures_by_buf[bufnr]
        assert.is_not_nil(first)

        inline_diff.render(bufnr, { "local y = 2", "tail" }, { "tail" })
        local second = inline_diff._captures_by_buf[bufnr]
        assert.is_not_nil(second)
        assert.are_not.equal(first, second)
      end)

      it("recomputes captures when old_lines is mutated in place", function()
        -- Reference-equality keying would incorrectly reuse stale captures
        -- when a caller mutates the same table between renders; the
        -- content-based key invalidates correctly.
        local bufnr = fresh_buf({ "tail" })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
        local old_lines = { "local x = 1", "tail" }
        inline_diff.render(bufnr, old_lines, { "tail" })
        local first = inline_diff._captures_by_buf[bufnr]
        assert.is_not_nil(first)

        old_lines[1] = "local y = 2"
        inline_diff.render(bufnr, old_lines, { "tail" })
        local second = inline_diff._captures_by_buf[bufnr]
        assert.is_not_nil(second)
        assert.are_not.equal(first, second)
      end)

      it("detach() drops the cached captures entry", function()
        local bufnr = fresh_buf({ "tail" })
        vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
        inline_diff.render(bufnr, { "local x = 1", "tail" }, { "tail" })
        assert.is_not_nil(inline_diff._captures_by_buf[bufnr])

        inline_diff.detach(bufnr)
        assert.is_nil(inline_diff._captures_by_buf[bufnr])
      end)
    end
  end)

  describe("window scoping", function()
    -- Mirror `WIN_SCOPE_SUPPORTED` exactly so the test gate doesn't
    -- disagree with the implementation on edge builds that ship only
    -- one half of the stable pair. The leak-warning path is covered
    -- by a separate test. Bracket-index `nvim__ns_set` to keep
    -- `type-check-tests` clean of `undefined-field`.
    local supported = (api.nvim_win_add_ns ~= nil and api.nvim_win_remove_ns ~= nil)
      or api["nvim__ns_set"] ~= nil

    if supported then
      it("attach_to_window records the scoped winid in _scoped_wins_by_buf", function()
        local bufnr = fresh_buf({ "a", "b" })
        inline_diff.attach_to_window(bufnr, initial_winid)
        local set = inline_diff._scoped_wins_by_buf[bufnr]
        assert.is_not_nil(set)
        assert.is_true(set[initial_winid])
      end)

      it("attach_to_window is idempotent across repeated calls", function()
        local bufnr = fresh_buf({ "a" })
        inline_diff.attach_to_window(bufnr, initial_winid)
        inline_diff.attach_to_window(bufnr, initial_winid)
        local set = inline_diff._scoped_wins_by_buf[bufnr]
        local count = 0
        for _ in pairs(set) do
          count = count + 1
        end
        assert.are.equal(1, count)
      end)

      it("detach() clears the scoped-windows entry", function()
        local bufnr = fresh_buf({ "a" })
        inline_diff.attach_to_window(bufnr, initial_winid)
        assert.is_not_nil(inline_diff._scoped_wins_by_buf[bufnr])

        inline_diff.detach(bufnr)
        assert.is_nil(inline_diff._scoped_wins_by_buf[bufnr])
      end)

      it("BufWipeout drops the scoped-windows entry via the cleanup autocmd", function()
        local bufnr = fresh_buf({ "a" })
        -- `inline_diff.render` registers the BufWipeout/BufDelete
        -- cleanup autocmd; the `attach_to_window` call seeds the
        -- scoped-windows entry so the cleanup has something to drop.
        inline_diff.render(bufnr, { "old" }, { "a" })
        inline_diff.attach_to_window(bufnr, initial_winid)
        assert.is_not_nil(inline_diff._scoped_wins_by_buf[bufnr])

        api.nvim_buf_delete(bufnr, { force = true })
        assert.is_nil(inline_diff._scoped_wins_by_buf[bufnr])
      end)

      it("a buffer shown in two windows only highlights the attached one", function()
        local bufnr = fresh_buf({ "old line" })
        api.nvim_win_set_buf(initial_winid, bufnr)
        vim.cmd("split")
        local other_winid = api.nvim_get_current_win()
        api.nvim_win_set_buf(other_winid, bufnr)
        api.nvim_set_current_win(initial_winid)

        inline_diff.render(bufnr, { "old line" }, { "new line" })
        inline_diff.attach_to_window(bufnr, initial_winid)

        -- The namespace is now scoped: only `initial_winid` should
        -- render the diff. We can't easily inspect rendered pixels, but
        -- we can assert that only the attached window is recorded.
        local set = inline_diff._scoped_wins_by_buf[bufnr]
        assert.is_true(set[initial_winid])
        assert.is_nil(set[other_winid])
      end)

      it("attach_to_window transfers winid ownership to the new bufnr", function()
        -- `diff1_inline` cycles entries through one window, so the
        -- latest attach must strip `winid` from the previous buffer's
        -- set; otherwise detaching that buffer would `win_remove_ns`
        -- a window the current one still relies on.
        local first = fresh_buf({ "a" })
        local second = fresh_buf({ "b" })
        inline_diff.attach_to_window(first, initial_winid)
        assert.is_true(inline_diff._scoped_wins_by_buf[first][initial_winid])

        inline_diff.attach_to_window(second, initial_winid)
        assert.is_nil(inline_diff._scoped_wins_by_buf[first])
        assert.is_true(inline_diff._scoped_wins_by_buf[second][initial_winid])

        -- Detaching the previous buffer must leave the current scope
        -- intact: this is the regression the transfer guards against.
        inline_diff.detach(first)
        assert.is_true(inline_diff._scoped_wins_by_buf[second][initial_winid])
      end)
    else
      it("attach_to_window is a no-op on Neovim < 0.11", function()
        local bufnr = fresh_buf({ "a" })
        inline_diff.attach_to_window(bufnr, initial_winid)
        assert.is_nil(inline_diff._scoped_wins_by_buf[bufnr])
      end)
    end

    -- Simulate Neovim < 0.11 by stripping the scope APIs from `vim.api`
    -- and re-loading the module so `WIN_SCOPE_SUPPORTED` is captured as
    -- false. Runs on every Neovim version so the fallback path is
    -- exercised even on builds where the scope API exists.
    it(
      "emits a one-shot warning when no scope API is available and the buffer is shared",
      function()
        local real_add = api.nvim_win_add_ns
        local real_remove = api.nvim_win_remove_ns
        -- Bracket-indexed so LuaLS doesn't flag the experimental field.
        local real_set = api["nvim__ns_set"]
        local real_notify = vim.notify
        local notifications = {}

        api.nvim_win_add_ns = nil
        api.nvim_win_remove_ns = nil
        api["nvim__ns_set"] = nil
        vim.notify = function(msg, level)
          notifications[#notifications + 1] = { msg = msg, level = level }
        end

        -- `pcall` so a mid-test failure still restores the patched
        -- globals; otherwise a leaked stub would cascade through the
        -- rest of the suite. Re-raised below.
        local ok, err = pcall(function()
          package.loaded["diffview.scene.inline_diff"] = nil
          local stripped = require("diffview.scene.inline_diff")

          -- Surface the buffer in a second window so the leak-warning
          -- guard (`win_findbuf` returns >1 entry) fires.
          local bufnr = fresh_buf({ "a" })
          api.nvim_win_set_buf(initial_winid, bufnr)
          vim.cmd("split")
          local other = api.nvim_get_current_win()
          api.nvim_win_set_buf(other, bufnr)
          api.nvim_set_current_win(initial_winid)

          stripped.attach_to_window(bufnr, initial_winid)
          assert.is_nil(stripped._scoped_wins_by_buf[bufnr])
          assert.are.equal(1, #notifications)
          assert.are.equal(vim.log.levels.WARN, notifications[1].level)
          assert.is_truthy(notifications[1].msg:find("diff1_inline", 1, true))

          -- Second attach must not re-warn.
          stripped.attach_to_window(bufnr, initial_winid)
          assert.are.equal(1, #notifications)
        end)

        -- Restore the API and put the *original* module instance back
        -- into `package.loaded` so subsequent tests' `inline_diff`
        -- upvalue (captured at file load time) keeps matching what
        -- `require` returns now. Without this, the stripped instance
        -- would linger in `package.loaded` and the autocmds re-registered
        -- against it would diverge from the upvalue's state tables.
        api.nvim_win_add_ns = real_add
        api.nvim_win_remove_ns = real_remove
        api["nvim__ns_set"] = real_set
        vim.notify = real_notify
        package.loaded["diffview.scene.inline_diff"] = inline_diff

        if not ok then
          error(err)
        end
      end
    )
  end)
end)
