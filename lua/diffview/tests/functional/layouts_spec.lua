local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local Diff2Ver = require("diffview.scene.layouts.diff_2_ver").Diff2Ver
local Diff3 = require("diffview.scene.layouts.diff_3").Diff3
local Diff3Mixed = require("diffview.scene.layouts.diff_3_mixed").Diff3Mixed
local Diff4 = require("diffview.scene.layouts.diff_4").Diff4
local Diff4Mixed = require("diffview.scene.layouts.diff_4_mixed").Diff4Mixed
local Layout = require("diffview.scene.layout").Layout
local RevType = require("diffview.vcs.rev").RevType
local async = require("diffview.async")
local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("diffview.layout null detection", function()
  it("treats COMMIT-side deletions as null in window b for Diff2", function()
    local rev = { type = RevType.COMMIT }

    assert.True(Diff2.should_null(rev, "D", "b"))
    assert.False(Diff2.should_null(rev, "M", "b"))
    assert.True(Diff2.should_null(rev, "A", "a"))
  end)

  it("keeps merge stages non-null in Diff3 and Diff4", function()
    local stage2 = { type = RevType.STAGE, stage = 2 }

    assert.False(Diff3.should_null(stage2, "U", "a"))
    assert.False(Diff4.should_null(stage2, "U", "a"))
  end)

  it("handles LOCAL/COMMIT nulling consistently in Diff3 and Diff4", function()
    local local_rev = { type = RevType.LOCAL }
    local commit_rev = { type = RevType.COMMIT }

    assert.True(Diff3.should_null(local_rev, "D", "b"))
    assert.True(Diff4.should_null(local_rev, "D", "b"))
    assert.True(Diff3.should_null(commit_rev, "D", "c"))
    assert.True(Diff4.should_null(commit_rev, "D", "d"))
    assert.True(Diff3.should_null(commit_rev, "A", "a"))
    assert.True(Diff4.should_null(commit_rev, "A", "a"))
  end)
end)

describe("diffview.layout symbols", function()
  it("Diff1 declares symbols { 'b' }", function()
    eq({ "b" }, Diff1.symbols)
  end)

  it("Diff1Inline inherits Diff1 and keeps symbols { 'b' }", function()
    -- Class-level relationship check avoids relying on the constructor's
    -- handling of empty/missing init args.
    local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
    eq({ "b" }, Diff1Inline.symbols)
    eq(Diff1, Diff1Inline.super_class)
  end)

  it("Diff1Inline exposes a_file via owned_files and get_file_for('a')", function()
    local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline

    -- Drive the methods directly on a bare instance so we don't exercise the
    -- full constructor (see other Diff1Inline tests for rationale).
    local inst = setmetatable({}, { __index = Diff1Inline })
    inst.windows = { { file = { id = "b_file" } } }
    inst.a_file = { id = "a_file" }
    inst.b = inst.windows[1]

    eq(inst.a_file, inst:get_file_for("a"))
    eq(inst.b.file, inst:get_file_for("b"))
    eq({ inst.b.file, inst.a_file }, inst:owned_files())

    inst.a_file = nil
    eq({ inst.b.file }, inst:owned_files())
    assert.is_nil(inst:get_file_for("a"))
  end)

  it("Diff1Inline:teardown_render clears inline-diff extmarks from the b buffer", function()
    local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
    local inline_diff = require("diffview.scene.inline_diff")
    local api = vim.api

    local bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { "added", "context" })
    inline_diff.render(bufnr, { "context" }, { "added", "context" })
    assert.is_true(#api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {}) > 0)

    local inst = setmetatable({}, { __index = Diff1Inline })
    inst.b = { file = { bufnr = bufnr } }
    inst:teardown_render()

    eq(0, #api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {}))
    pcall(api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("Diff1Inline:teardown_render closes the repaint debounce", function()
    local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline

    local closed = false
    local debounced = setmetatable({}, {
      __call = function() end,
      __index = {
        close = function()
          closed = true
        end,
        cancel = function() end,
      },
    })

    local inst = setmetatable({}, { __index = Diff1Inline })
    inst._repaint_debounced = debounced
    inst._repaint_bufnr = nil
    inst:teardown_render()

    assert.is_true(closed)
    assert.is_nil(inst._repaint_debounced)
  end)

  it(
    "Diff1Inline InsertLeave cancels a pending debounced repaint",
    helpers.async_test(function()
      local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
      local api = vim.api

      -- Shadow `_repaint` on the instance so we count calls without mutating
      -- the class method shared with concurrent tests.
      local repaint_count = 0

      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new content" })
      local winid = api.nvim_get_current_win()

      local inst = setmetatable({}, { __index = Diff1Inline })
      inst.b = {
        file = {
          bufnr = bufnr,
          is_valid = function()
            return true
          end,
        },
        is_valid = function()
          return true
        end,
        id = winid,
      }
      inst._cached_old_lines = { "old content" }
      inst._repaint = function()
        repaint_count = repaint_count + 1
      end

      async.await(inst:_render_inline())

      -- `TextChangedI` schedules a debounced repaint; `InsertLeave` should
      -- cancel it and fire the immediate repaint exactly once.
      api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
      api.nvim_exec_autocmds("InsertLeave", { buffer = bufnr })

      eq(1, repaint_count)

      -- Wait past the debounce window (150ms). If the debounce hadn't been
      -- cancelled, the trailing call would bump the counter to 2.
      async.await(async.timeout(200))
      async.await(async.scheduler())

      eq(1, repaint_count)

      inst:teardown_render()
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)
  )

  it(
    "Diff1Inline TextChangedI coalesces rapid edits into one repaint",
    helpers.async_test(function()
      local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
      local api = vim.api

      local repaint_count = 0

      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new content" })
      local winid = api.nvim_get_current_win()

      local inst = setmetatable({}, { __index = Diff1Inline })
      inst.b = {
        file = {
          bufnr = bufnr,
          is_valid = function()
            return true
          end,
        },
        is_valid = function()
          return true
        end,
        id = winid,
      }
      inst._cached_old_lines = { "old content" }
      inst._repaint = function()
        repaint_count = repaint_count + 1
      end

      async.await(inst:_render_inline())

      for _ = 1, 5 do
        api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
      end

      -- Wait past the debounce window so the trailing fire has a chance to
      -- run (or not, if coalescing is broken).
      async.await(async.timeout(200))
      async.await(async.scheduler())

      eq(1, repaint_count)

      inst:teardown_render()
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)
  )

  it(
    "Diff1Inline VimResized triggers a debounced repaint when full_width",
    helpers.async_test(function()
      local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
      local config = require("diffview.config")
      local api = vim.api

      local original_config = vim.deepcopy(config.get_config())
      config.setup({ view = { inline = { deletion_highlight = "full_width" } } })

      local repaint_count = 0

      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new content" })
      local winid = api.nvim_get_current_win()

      local inst = setmetatable({}, { __index = Diff1Inline })
      inst.b = {
        file = {
          bufnr = bufnr,
          is_valid = function()
            return true
          end,
        },
        is_valid = function()
          return true
        end,
        id = winid,
      }
      inst._cached_old_lines = { "old content" }
      inst._repaint = function()
        repaint_count = repaint_count + 1
      end

      async.await(inst:_render_inline())

      -- A drag-resize burst fires VimResized many times; the trailing-edge
      -- debounce should coalesce them into a single repaint.
      for _ = 1, 5 do
        api.nvim_exec_autocmds("VimResized", {})
      end

      -- Wait past the resize debounce window (100ms) so the trailing fire
      -- has a chance to run.
      async.await(async.timeout(200))
      async.await(async.scheduler())

      local ok, err = pcall(eq, 1, repaint_count)

      inst:teardown_render()
      pcall(api.nvim_buf_delete, bufnr, { force = true })
      config.setup(original_config)

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "Diff1Inline VimResized is a no-op when the extent doesn't depend on width",
    helpers.async_test(function()
      local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
      local config = require("diffview.config")
      local api = vim.api

      local original_config = vim.deepcopy(config.get_config())
      -- Default extent: only the deleted characters get highlighted, so a
      -- resize doesn't change the rendered output and the handler must
      -- early-return without a repaint.
      config.setup({ view = { inline = { deletion_highlight = "text" } } })

      local repaint_count = 0

      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new content" })
      local winid = api.nvim_get_current_win()

      local inst = setmetatable({}, { __index = Diff1Inline })
      inst.b = {
        file = {
          bufnr = bufnr,
          is_valid = function()
            return true
          end,
        },
        is_valid = function()
          return true
        end,
        id = winid,
      }
      inst._cached_old_lines = { "old content" }
      inst._repaint = function()
        repaint_count = repaint_count + 1
      end

      async.await(inst:_render_inline())

      api.nvim_exec_autocmds("VimResized", {})

      async.await(async.timeout(200))
      async.await(async.scheduler())

      local ok, err = pcall(eq, 0, repaint_count)

      inst:teardown_render()
      pcall(api.nvim_buf_delete, bufnr, { force = true })
      config.setup(original_config)

      if not ok then
        error(err)
      end
    end)
  )

  it(
    "Diff1Inline:teardown_render removes the global resize autocmd",
    helpers.async_test(function()
      local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
      local config = require("diffview.config")
      local api = vim.api

      local original_config = vim.deepcopy(config.get_config())
      config.setup({ view = { inline = { deletion_highlight = "full_width" } } })

      local repaint_count = 0

      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new content" })
      local winid = api.nvim_get_current_win()

      local inst = setmetatable({}, { __index = Diff1Inline })
      inst.b = {
        file = {
          bufnr = bufnr,
          is_valid = function()
            return true
          end,
        },
        is_valid = function()
          return true
        end,
        id = winid,
      }
      inst._cached_old_lines = { "old content" }
      inst._repaint = function()
        repaint_count = repaint_count + 1
      end

      async.await(inst:_render_inline())

      -- Sanity: the global resize autocmd is installed.
      assert.is_truthy(inst._resize_autocmd)

      inst:teardown_render()

      -- After teardown the autocmd id and debounced fn must be cleared so a
      -- subsequent resize doesn't call into a destroyed instance.
      assert.is_nil(inst._resize_autocmd)
      assert.is_nil(inst._resize_debounced)

      api.nvim_exec_autocmds("VimResized", {})
      async.await(async.timeout(200))
      async.await(async.scheduler())

      local ok, err = pcall(eq, 0, repaint_count)

      pcall(api.nvim_buf_delete, bufnr, { force = true })
      config.setup(original_config)

      if not ok then
        error(err)
      end
    end)
  )

  describe("Diff1Inline:diffget", function()
    local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
    local inline_diff = require("diffview.scene.inline_diff")
    local api = vim.api

    -- Build a stub Diff1Inline instance with a live buffer whose old-side
    -- lines are cached and whose inline diff has been rendered, so the
    -- renderer's hunk cache mirrors the vim.diff output.
    ---@param old string[]
    ---@param new string[]
    ---@return table inst, integer bufnr
    local function prepare(old, new)
      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, new)
      inline_diff.render(bufnr, old, new)

      local win_mock = {
        file = {
          bufnr = bufnr,
          is_valid = function()
            return true
          end,
        },
        is_valid = function()
          return true
        end,
      }
      local inst = setmetatable({
        b = win_mock,
        a_file = {},
        _cached_old_lines = old,
      }, { __index = Diff1Inline })
      return inst, bufnr
    end

    it("reverts a change hunk at the cursor line back to the old content", function()
      local inst, bufnr = prepare({ "alpha", "beta", "gamma" }, { "alpha", "BETA", "gamma" })

      eq(1, inst:diffget(2, 2))
      eq({ "alpha", "beta", "gamma" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("drops added lines when the hunk under cursor is a pure addition", function()
      local inst, bufnr = prepare({ "alpha", "gamma" }, { "alpha", "beta", "gamma" })

      eq(1, inst:diffget(2, 2))
      eq({ "alpha", "gamma" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("re-inserts deleted lines when the cursor sits on the anchor line", function()
      local inst, bufnr = prepare({ "alpha", "beta", "gamma" }, { "alpha", "gamma" })

      -- Pure deletion is anchored on the line preceding the gap, i.e. line 1
      -- ("alpha") since `new_start == 1` for the hole between the two lines.
      eq(1, inst:diffget(1, 1))
      eq({ "alpha", "beta", "gamma" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("handles a BOF pure deletion by inserting at the top of the buffer", function()
      local inst, bufnr = prepare({ "alpha", "beta", "gamma" }, { "beta", "gamma" })

      -- Deletion at BOF has `new_start == 0`; the anchor is line 1.
      eq(1, inst:diffget(1, 1))
      eq({ "alpha", "beta", "gamma" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("returns 0 when the cursor is not on a hunk", function()
      local inst, bufnr = prepare({ "alpha", "beta", "gamma" }, { "alpha", "BETA", "gamma" })

      eq(0, inst:diffget(1, 1))
      -- Buffer is unchanged.
      eq({ "alpha", "BETA", "gamma" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("applies every hunk inside a multi-line visual range in one pass", function()
      local inst, bufnr = prepare(
        { "one", "two", "three", "four", "five" },
        { "ONE", "two", "THREE", "four", "FIVE" }
      )

      -- Range covers the first two change hunks (lines 1 and 3) but not
      -- the third (line 5), which should remain modified.
      eq(2, inst:diffget(1, 3))
      eq({ "one", "two", "three", "four", "FIVE" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("applies hunks bottom-up so earlier splices don't shift later offsets", function()
      local inst, bufnr = prepare({ "a", "b", "c" }, { "a", "X", "Y", "b", "Z", "c" })

      -- Two pure-addition hunks: { "X", "Y" } at line 2 and { "Z" } at
      -- line 5. A visual range covering both must drop all three added
      -- lines, which only works if the later hunk is applied first.
      eq(2, inst:diffget(2, 5))
      eq({ "a", "b", "c" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("returns 0 when the cached old-side lines are missing", function()
      local inst, bufnr = prepare({ "alpha" }, { "beta" })
      inst._cached_old_lines = nil

      eq(0, inst:diffget(1, 1))
      eq({ "beta" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)

    it(
      "coalesces TextChanged repaints across a multi-hunk diffget into one",
      helpers.async_test(function()
        -- Install the real `TextChanged` autocmd via `_render_inline`, then
        -- spy on `inline_diff.render` to count how many repaints the batch
        -- triggers. Without suppression, each `nvim_buf_set_lines` call
        -- inside `diffget` fires `TextChanged` -> `_repaint` -> `render`,
        -- producing one render per hunk. With suppression, the batch is
        -- followed by a single trailing `_repaint` instead.
        local bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          "ONE",
          "two",
          "THREE",
          "four",
          "five",
        })
        local winid = api.nvim_get_current_win()

        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            is_valid = function()
              return true
            end,
          },
          is_valid = function()
            return true
          end,
          id = winid,
        }
        inst._cached_old_lines = { "one", "two", "three", "four", "five" }

        async.await(inst:_render_inline())

        local original_render = inline_diff.render
        local render_count = 0
        inline_diff.render = function(...)
          render_count = render_count + 1
          return original_render(...)
        end

        local ok, err = pcall(function()
          -- Range covers both change hunks (lines 1 and 3); two splices.
          eq(2, inst:diffget(1, 3))
          eq(1, render_count)
        end)

        inline_diff.render = original_render
        inst:teardown_render()
        pcall(api.nvim_buf_delete, bufnr, { force = true })
        if not ok then
          error(err)
        end
      end)
    )
  end)

  -- Regression suite for issue #172: the b buffer must not be shown without
  -- inline-diff extmarks. The fix renders the extmarks onto the b buffer
  -- BEFORE `open_files` switches the window to that buffer, so the first
  -- redraw that shows the new buffer also shows its highlights.
  describe("Diff1Inline:_prerender", function()
    local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
    local inline_diff = require("diffview.scene.inline_diff")
    local api = vim.api
    -- Mirrors `WIN_SCOPE_SUPPORTED` in `inline_diff.lua`: the namespace
    -- scoping APIs landed in 0.11 (`nvim__ns_set`) / 0.12
    -- (`nvim_win_add_ns`); on older Neovim `attach_to_window` is a
    -- one-shot warning and never populates `_scoped_wins_by_buf`.
    -- Bracket-index `nvim__ns_set` to keep type-check-tests clean.
    local scope_supported = (api.nvim_win_add_ns ~= nil and api.nvim_win_remove_ns ~= nil)
      or api["nvim__ns_set"] ~= nil

    it(
      "renders extmarks on the b buffer before it is opened in a window",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "TWO", "three" })

        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            active = true,
            is_valid = function()
              return true
            end,
          },
        }
        inst.a_file = { nulled = false, binary = false }
        inst._cached_old_lines = { "one", "two", "three" }

        async.await(inst:_prerender())

        -- The mismatch on line 2 should produce at least one extmark.
        local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
        assert.is_true(#marks > 0)

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    it(
      "is a no-op when b.file is missing",
      helpers.async_test(function()
        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {}
        async.await(inst:_prerender())
        -- No exception; nothing else to assert.
      end)
    )

    -- A deleted file still needs its old-side content rendered as deletion
    -- virt_lines. `_prerender` substitutes `new_lines = {}` for the nulled
    -- buffer so `vim.diff(content, "")` yields a pure deletion, dodging the
    -- spurious "1 added empty line" hunk from issue #172.
    it(
      "renders deletion virt_lines when b.file is nulled but a-side has content",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            nulled = true,
            binary = false,
            active = true,
            is_valid = function()
              return true
            end,
          },
        }
        inst.a_file = { nulled = false, binary = false }
        inst._cached_old_lines = { "removed-1", "removed-2" }

        async.await(inst:_prerender())

        local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
        assert.is_true(#marks > 0)

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- Temp layout (a-side and b-side both nulled) has no content on either
    -- side: `vim.diff("", "")` returns no hunks, so the render is a true
    -- no-op. This is the path that produced the green sliver before #172.
    it(
      "is a no-op when both a- and b-side are nulled",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            nulled = true,
            binary = false,
            active = true,
            is_valid = function()
              return true
            end,
          },
        }
        inst.a_file = { nulled = true, binary = false }

        async.await(inst:_prerender())

        local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
        eq(0, #marks)

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    it(
      "is a no-op when b.file is binary",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            nulled = false,
            binary = true,
            active = true,
            is_valid = function()
              return true
            end,
          },
        }
        inst.a_file = { nulled = false, binary = true }

        async.await(inst:_prerender())

        local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
        eq(0, #marks)

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- The render call happens before `open_files` yields, so without
    -- scoping the redraw triggered by that yield would expose extmarks
    -- in any other window already displaying the same buffer (#156).
    -- `_prerender` scopes the namespace synchronously after the render.
    it(
      "scopes the inline namespace to self.b.id after rendering",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "TWO", "three" })
        local winid = api.nvim_get_current_win()

        -- Clear any prior scope state for this buffer so we're asserting
        -- the attach made by `_prerender`, not lingering state.
        inline_diff.detach(bufnr)

        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            active = true,
            is_valid = function()
              return true
            end,
          },
          id = winid,
        }
        inst.a_file = { nulled = false, binary = false }
        inst._cached_old_lines = { "one", "two", "three" }

        async.await(inst:_prerender())

        if scope_supported then
          local set = inline_diff._scoped_wins_by_buf[bufnr]
          assert.is_not_nil(set)
          assert.is_true(set[winid])
        else
          -- `attach_to_window` is a no-op on this Neovim; just confirm
          -- `_prerender` didn't error and left the scope table empty.
          assert.is_nil(inline_diff._scoped_wins_by_buf[bufnr])
        end

        inline_diff.detach(bufnr)
        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- The `create` path runs `_prerender` before `create_wins`, so the
    -- b window doesn't exist yet. The attach call must early-return
    -- rather than error on a nil/invalid winid; `create_post` handles
    -- the create-path scoping separately.
    it(
      "skips scoping (no error) when self.b.id is not a real window",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "TWO", "three" })

        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            active = true,
            is_valid = function()
              return true
            end,
          },
          -- No `id`: the create path runs `_prerender` before `create_wins`.
        }
        inst.a_file = { nulled = false, binary = false }
        inst._cached_old_lines = { "one", "two", "three" }

        async.await(inst:_prerender())

        local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
        assert.is_true(#marks > 0)

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- A racing newer `use_entry` bumps `_render_generation` while the older
    -- `_prerender` is awaiting `_load_old_lines`. When the old fetch
    -- finishes, it must not overwrite `_cached_old_lines` (the newer pass
    -- may already have populated it, or be about to).
    it(
      "bails out when _render_generation changes mid-flight",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, { "current" })

        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            nulled = false,
            binary = false,
            active = true,
            is_valid = function()
              return true
            end,
          },
        }
        inst.a_file = { nulled = false, binary = false }
        inst._render_generation = 1

        -- A stub `_load_old_lines` that bumps the generation while it is
        -- "in flight" so the post-yield guard fires.
        inst._load_old_lines = async.wrap(function(self, callback)
          self._render_generation = self._render_generation + 1
          callback({ "stale-old" })
        end, 2)

        async.await(inst:_prerender())

        -- The stale fetch must NOT have written its lines into the cache.
        assert.is_nil(inst._cached_old_lines)
        local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
        eq(0, #marks)

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- The view closes (layout is destroyed) while `_prerender` is awaiting
    -- a git fetch. On resume, `_prerender` must not render extmarks (would
    -- leak into the LOCAL working-tree buffer that outlives the view) and
    -- the surrounding `create`/`use_entry` must not run `create_wins` /
    -- `open_files` against the disposed layout. `destroy` bumps
    -- `_render_generation`, so this is structurally the same check as the
    -- swap test above; exercising it through the real `destroy` entry
    -- point pins the contract that teardown invalidates in-flight passes.
    it(
      "bails out when the layout is destroyed mid-flight",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, { "current" })

        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            nulled = false,
            binary = false,
            active = true,
            is_valid = function()
              return true
            end,
          },
        }
        inst.a_file = { nulled = false, binary = false }
        inst._render_generation = 0
        inst.windows = {}

        inst._load_old_lines = async.wrap(function(self, callback)
          -- Real `destroy`: bumps the render generation, runs
          -- `teardown_render`, and iterates `self.windows` (empty here, so
          -- the iteration is a no-op).
          self:destroy()
          callback({ "old-content" })
        end, 2)

        async.await(inst:_prerender())

        assert.is_nil(inst._cached_old_lines)
        local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
        eq(0, #marks)

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- `FileEntry:convert_layout` tears down the outgoing layout's render
    -- state via `teardown_render` (not `destroy`) before reusing the
    -- buffer in the new layout. An in-flight `_prerender` whose
    -- `_load_old_lines` callback resumes after the teardown must not
    -- repopulate `_cached_old_lines` or stamp extmarks onto a buffer the
    -- outgoing layout no longer owns.
    it(
      "bails out when teardown_render fires mid-flight (convert_layout path)",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, { "current" })

        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = {
            bufnr = bufnr,
            nulled = false,
            binary = false,
            active = true,
            is_valid = function()
              return true
            end,
          },
        }
        inst.a_file = { nulled = false, binary = false }
        inst._render_generation = 0

        inst._load_old_lines = async.wrap(function(self, callback)
          -- Stand-in for `FileEntry:convert_layout`, which calls
          -- `teardown_render` on the outgoing layout without going
          -- through `destroy`.
          self:teardown_render()
          callback({ "old-content" })
        end, 2)

        async.await(inst:_prerender())

        assert.is_nil(inst._cached_old_lines)
        local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
        eq(0, #marks)

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- `StandardView` caches one layout per class and re-runs `create` on
    -- the same instance after a prior `destroy` when the user navigates
    -- back to that class. A sticky destroyed flag would make the
    -- post-`_prerender` guard bail forever; the monotonic generation
    -- token must let the reused create proceed.
    it(
      "create proceeds on a cached instance after a prior destroy",
      helpers.async_test(function()
        local inst = setmetatable({}, { __index = Diff1Inline })
        inst._render_generation = 0
        inst.windows = {}

        local steps = { prerender = 0, wins = 0, hooks = 0 }
        inst._prerender = async.void(function()
          steps.prerender = steps.prerender + 1
        end)
        inst.create_wins = async.void(function()
          steps.wins = steps.wins + 1
        end)
        inst._install_window_hooks = function()
          steps.hooks = steps.hooks + 1
        end

        async.await(inst:create())
        eq(1, steps.prerender)
        eq(1, steps.wins)
        eq(1, steps.hooks)

        inst:destroy()

        async.await(inst:create())
        eq(2, steps.prerender)
        eq(2, steps.wins)
        eq(2, steps.hooks)
      end)
    )
  end)

  -- `create_post` runs between `create_wins` (which created `self.b.id`)
  -- and `open_files` (which yields, allowing a redraw). `_prerender`
  -- already wrote the extmarks, so the override must scope the
  -- namespace before the yield to prevent leakage (#156).
  describe("Diff1Inline.create_post", function()
    local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
    local inline_diff = require("diffview.scene.inline_diff")
    local api = vim.api
    -- See the `_prerender` block's note: on pre-0.11 Neovim there's no
    -- scoping API, so `attach_to_window` (and by extension `create_post`)
    -- can't populate `_scoped_wins_by_buf`.
    local scope_supported = (api.nvim_win_add_ns ~= nil and api.nvim_win_remove_ns ~= nil)
      or api["nvim__ns_set"] ~= nil

    it(
      "scopes the inline namespace to self.b.id before open_files runs",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        local winid = api.nvim_get_current_win()
        inline_diff.detach(bufnr)

        local scope_at_open_files
        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = { bufnr = bufnr, binary = false },
          id = winid,
          is_valid = function()
            return true
          end,
        }
        inst.state = { save_equalalways = vim.o.equalalways }
        inst.open_null = function() end
        inst.open_files = async.void(function()
          local set = inline_diff._scoped_wins_by_buf[bufnr]
          scope_at_open_files = set ~= nil and set[winid] == true
        end)

        async.await(inst:create_post())

        if scope_supported then
          assert.is_true(
            scope_at_open_files,
            "expected inline namespace to be scoped to self.b.id when open_files starts"
          )
        else
          -- Without the scoping API, `attach_to_window` is a no-op; the
          -- override still ran without erroring, which is the most we
          -- can check.
          assert.is_false(scope_at_open_files)
        end

        inline_diff.detach(bufnr)
        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- A binary b-file has no extmarks to scope; skipping the attach
    -- mirrors the binary skip in `_prerender` and `_install_window_hooks`.
    it(
      "skips scoping when b.file is binary",
      helpers.async_test(function()
        local bufnr = api.nvim_create_buf(false, true)
        local winid = api.nvim_get_current_win()
        inline_diff.detach(bufnr)

        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = { bufnr = bufnr, binary = true },
          id = winid,
          is_valid = function()
            return true
          end,
        }
        inst.state = { save_equalalways = vim.o.equalalways }
        inst.open_null = function() end
        inst.open_files = async.void(function() end)

        async.await(inst:create_post())

        assert.is_nil(inline_diff._scoped_wins_by_buf[bufnr])

        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end)
    )

    -- The `create` path runs `_prerender` before `create_wins`, so the b
    -- window doesn't exist yet and `full_width_target` can't size the
    -- pad against it. After `open_files` displays the buffer, `create_post`
    -- fires a follow-up `_repaint` so the deletion virt_lines pick up the
    -- now-known window width.
    it(
      "fires a follow-up _repaint after open_files when full_width is configured",
      helpers.async_test(function()
        local config = require("diffview.config")
        local original_config = vim.deepcopy(config.get_config())
        config.setup({ view = { inline = { deletion_highlight = "full_width" } } })

        local bufnr = api.nvim_create_buf(false, true)
        local winid = api.nvim_get_current_win()
        inline_diff.detach(bufnr)

        local repaint_count = 0
        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = { bufnr = bufnr, binary = false },
          id = winid,
          is_valid = function()
            return true
          end,
        }
        inst.state = { save_equalalways = vim.o.equalalways }
        inst.open_null = function() end
        inst.open_files = async.void(function() end)
        inst._repaint = function()
          repaint_count = repaint_count + 1
        end

        local ok, err = pcall(function()
          async.await(inst:create_post())
          eq(1, repaint_count)
        end)

        inline_diff.detach(bufnr)
        pcall(api.nvim_buf_delete, bufnr, { force = true })
        config.setup(original_config)

        if not ok then
          error(err)
        end
      end)
    )

    -- For `text` / `hanging` deletion extents the pad isn't a function of
    -- the window width, so the create-path follow-up `_repaint` would be
    -- a redundant render. The override gates it on `full_width` to keep
    -- the render-once invariant for the other styles.
    it(
      "skips the follow-up _repaint when deletion_highlight isn't full_width",
      helpers.async_test(function()
        local config = require("diffview.config")
        local original_config = vim.deepcopy(config.get_config())
        config.setup({ view = { inline = { deletion_highlight = "text" } } })

        local bufnr = api.nvim_create_buf(false, true)
        local winid = api.nvim_get_current_win()
        inline_diff.detach(bufnr)

        local repaint_count = 0
        local inst = setmetatable({}, { __index = Diff1Inline })
        inst.b = {
          file = { bufnr = bufnr, binary = false },
          id = winid,
          is_valid = function()
            return true
          end,
        }
        inst.state = { save_equalalways = vim.o.equalalways }
        inst.open_null = function() end
        inst.open_files = async.void(function() end)
        inst._repaint = function()
          repaint_count = repaint_count + 1
        end

        local ok, err = pcall(function()
          async.await(inst:create_post())
          eq(0, repaint_count)
        end)

        inline_diff.detach(bufnr)
        pcall(api.nvim_buf_delete, bufnr, { force = true })
        config.setup(original_config)

        if not ok then
          error(err)
        end
      end)
    )
  end)

  it(
    "Diff1Inline:_render_inline renders deletion virt_lines when b.file is nulled",
    helpers.async_test(function()
      local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
      local inline_diff = require("diffview.scene.inline_diff")
      local api = vim.api

      local bufnr = api.nvim_create_buf(false, true)
      local winid = api.nvim_get_current_win()

      local inst = setmetatable({}, { __index = Diff1Inline })
      inst.b = {
        file = {
          bufnr = bufnr,
          nulled = true,
          binary = false,
          is_valid = function()
            return true
          end,
        },
        is_valid = function()
          return true
        end,
        id = winid,
      }
      inst.a_file = { nulled = false, binary = false }
      inst._cached_old_lines = { "removed-1", "removed-2" }

      async.await(inst:_render_inline())

      local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
      assert.is_true(#marks > 0)

      inst:teardown_render()
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)
  )

  -- `_repaint` is invoked by the `create_post` full_width follow-up
  -- (among other places). Without the nulled handling it would feed
  -- `inline_diff.render` the NULL_FILE buffer's lone empty line, which
  -- `vim.diff` reports as a modification (and the "1 added empty line"
  -- green sliver from issue #172) instead of a pure deletion.
  it("Diff1Inline:_repaint emits no DiffChange/DiffAdd row hl when b.file is nulled", function()
    local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
    local inline_diff = require("diffview.scene.inline_diff")
    local api = vim.api

    local bufnr = api.nvim_create_buf(false, true)
    local winid = api.nvim_get_current_win()

    local inst = setmetatable({}, { __index = Diff1Inline })
    inst.b = {
      file = {
        bufnr = bufnr,
        nulled = true,
        binary = false,
        is_valid = function()
          return true
        end,
      },
      is_valid = function()
        return true
      end,
      id = winid,
    }
    inst.a_file = { nulled = false, binary = false }
    inst._cached_old_lines = { "removed-1", "removed-2" }

    inst:_repaint()

    local marks = api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      local hl = m[4] and m[4].line_hl_group
      assert(
        hl ~= "DiffviewDiffChange" and hl ~= "DiffviewDiffAdd",
        "unexpected line_hl_group: " .. tostring(hl)
      )
    end

    inst:teardown_render()
    pcall(api.nvim_buf_delete, bufnr, { force = true })
  end)

  it(
    "Diff1Inline.use_entry renders extmarks before open_files displays the buffer",
    helpers.async_test(function()
      -- The fix guarantees that by the time `open_files` (which displays
      -- the b buffer) starts running, the inline-diff extmarks are already
      -- on the b buffer. Drive `use_entry` against a real `Diff1Inline`
      -- instance whose `open_files` records the extmark count at entry,
      -- then assert it is greater than zero.
      local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
      local inline_diff = require("diffview.scene.inline_diff")
      local api = vim.api

      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "TWO", "three" })

      local marks_at_open_files
      local b_file = {
        bufnr = bufnr,
        active = true,
        is_valid = function()
          return true
        end,
        symbol = "b",
      }
      local a_file = { nulled = true, binary = false }
      local inst = Diff1Inline({ b = b_file, a = a_file })
      inst.b.is_valid = function()
        return true
      end
      inst.is_valid = function()
        return true
      end
      -- Override `_load_old_lines` to return a fixed old side synchronously
      -- so `_prerender` doesn't depend on a real adapter.
      inst._load_old_lines = async.wrap(function(_, callback)
        callback({ "one", "two", "three" })
      end, 2)
      inst.open_files = async.void(function()
        marks_at_open_files = #api.nvim_buf_get_extmarks(bufnr, inline_diff.ns, 0, -1, {})
      end)
      inst._install_window_hooks = function() end

      local entry = { layout = Diff1Inline({ b = b_file, a = a_file }) }

      async.await(inst:use_entry(entry))

      assert.is_not_nil(marks_at_open_files)
      assert.is_true(
        marks_at_open_files > 0,
        "expected extmarks already on buffer when open_files starts"
      )

      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end)
  )

  it("Diff2 declares symbols { 'a', 'b' }", function()
    eq({ "a", "b" }, Diff2.symbols)
  end)

  it("Diff3 declares symbols { 'a', 'b', 'c' }", function()
    eq({ "a", "b", "c" }, Diff3.symbols)
  end)

  it("Diff4 declares symbols { 'a', 'b', 'c', 'd' }", function()
    eq({ "a", "b", "c", "d" }, Diff4.symbols)
  end)
end)

describe("diffview.scene.layouts.diff_2_*_pinned class structure", function()
  local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned
  local Diff2VerPinned = require("diffview.scene.layouts.diff_2_ver_pinned").Diff2VerPinned

  it("Diff2HorPinned inherits Diff2Hor and keeps symbols { 'a', 'b' }", function()
    eq({ "a", "b" }, Diff2HorPinned.symbols)
    eq(Diff2Hor, Diff2HorPinned.super_class)
    eq("diff2_horizontal_pinned", Diff2HorPinned.name)
  end)

  it("Diff2VerPinned inherits Diff2Ver and keeps symbols { 'a', 'b' }", function()
    eq({ "a", "b" }, Diff2VerPinned.symbols)
    eq(Diff2Ver, Diff2VerPinned.super_class)
    eq("diff2_vertical_pinned", Diff2VerPinned.name)
  end)

  it("config.name_to_layout resolves the pinned layout names", function()
    local config = require("diffview.config")
    eq(Diff2HorPinned, config.name_to_layout("diff2_horizontal_pinned"))
    eq(Diff2VerPinned, config.name_to_layout("diff2_vertical_pinned"))
  end)
end)

describe("diffview.scene.layouts.diff_2_*_pinned should_null", function()
  local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned
  local Diff2VerPinned = require("diffview.scene.layouts.diff_2_ver_pinned").Diff2VerPinned

  -- pin_local sets revs.a to the commit itself (not its parent), so the
  -- standard parent-vs-commit semantics don't apply on the a-side: the
  -- file is missing iff it doesn't exist in this commit, i.e. status "D".
  -- (sym "b" defers to `Diff2.should_null`; `with_layout` consults it only
  -- to decide whether to fall back from the shared `pinned_b_file` when
  -- the LOCAL path is missing on disk.)
  it("nulls window a only when the file is absent from the commit (status D)", function()
    local commit = { type = RevType.COMMIT }
    for _, cls in ipairs({ Diff2HorPinned, Diff2VerPinned }) do
      assert.True(cls.should_null(commit, "D", "a"))
      assert.False(cls.should_null(commit, "A", "a"))
      assert.False(cls.should_null(commit, "M", "a"))
      assert.False(cls.should_null(commit, "R", "a"))
      assert.False(cls.should_null(commit, "?", "a"))
    end
  end)

  -- The synthetic top-of-history entry built by `build_local_log_entry`
  -- has `revs.a = HEAD` (parent of the working tree, not the changeset
  -- being browsed) with statuses from `diff HEAD`, so standard
  -- parent-vs-child semantics apply: an added file nulls the a-side
  -- because HEAD doesn't have it; a deleted file does NOT null the a-side
  -- because HEAD still has it. The adapter tags `revs.a` with
  -- `pin_local_synthetic` so the pinned override defers to `Diff2.should_null`.
  it("defers to Diff2 for the synthetic working-tree entry (pin_local_synthetic)", function()
    local synthetic = { type = RevType.COMMIT, pin_local_synthetic = true }
    for _, cls in ipairs({ Diff2HorPinned, Diff2VerPinned }) do
      assert.True(cls.should_null(synthetic, "A", "a"))
      assert.True(cls.should_null(synthetic, "?", "a"))
      assert.False(cls.should_null(synthetic, "D", "a"))
      assert.False(cls.should_null(synthetic, "M", "a"))
      assert.False(cls.should_null(synthetic, "R", "a"))
    end
  end)
end)

describe("diffview.scene.layouts.diff_2_*_pinned ownership", function()
  local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned
  local Diff2VerPinned = require("diffview.scene.layouts.diff_2_ver_pinned").Diff2VerPinned

  -- The b-side `vcs.File` is owned by the FileHistoryView (its pin_local
  -- cache), not by individual FileEntries. `shared_symbols` is the contract
  -- that tells `Layout:owned_files()` to exclude that window from the
  -- destruction set in `FileEntry:destroy` and `FileEntry:set_active`.
  it("declares 'b' as a shared symbol so entry teardown skips it", function()
    eq({ "b" }, Diff2HorPinned.shared_symbols)
    eq({ "b" }, Diff2VerPinned.shared_symbols)
  end)

  -- Concrete check of the filter: a fully-constructed pinned layout's
  -- `owned_files()` must return only the a-side file, even though both
  -- windows are populated. This is what protects the view-owned b-file
  -- from being destroyed when the LogEntry tree is torn down on refresh.
  it("owned_files() excludes the b-side file", function()
    for _, cls in ipairs({ Diff2HorPinned, Diff2VerPinned }) do
      local a_file = { path = "old/foo.txt" }
      local b_file = { path = "foo.txt" }
      local inst = setmetatable({
        a = { file = a_file },
        b = { file = b_file },
        windows = {},
        symbols = cls.symbols,
        shared_symbols = cls.shared_symbols,
      }, { __index = cls })

      eq({ a_file }, inst:owned_files())
    end
  end)
end)

describe("diffview.scene.layouts.diff_2_*_pinned detach_files_for_swap", function()
  local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned
  local Diff2VerPinned = require("diffview.scene.layouts.diff_2_ver_pinned").Diff2VerPinned

  -- The swap variant is what `_set_file` calls between log entries; it
  -- skips the pinned b so the LOCAL buffer's keymaps/edits survive the
  -- swap when the b-file stays the same instance (single-file pinning,
  -- and same-row navigation in multi-file). The full `detach_files()` is
  -- left to the base Layout so tab-leave/view-close still tear everything
  -- down (no diffview state leaks into the user's normal editing windows).
  it("detaches window a but not window b when next entry's b matches", function()
    for _, cls in ipairs({ Diff2HorPinned, Diff2VerPinned }) do
      local detached = {}
      local shared_b_file = { path = "live.txt" }
      local inst = setmetatable({
        a = {
          detach_file = function()
            detached.a = true
          end,
        },
        b = {
          file = shared_b_file,
          detach_file = function()
            detached.b = true
          end,
        },
      }, { __index = cls })

      -- Stub the next FileEntry so its layout's b-side points at the same
      -- shared instance: that's the single-file pin case (and the
      -- same-path row-stay case in multi-file).
      local next_entry = { layout = { b = { file = shared_b_file } } }
      inst:detach_files_for_swap(next_entry)

      assert.True(detached.a)
      assert.is_nil(detached.b)
    end
  end)

  -- Multi-file pinning: each path has its own view-owned working-tree
  -- File. Crossing rows changes the b-side instance, and the OLD b's
  -- buffer must be detached so it doesn't keep diffview keymaps and
  -- buffer-local overrides after navigation. Without this, plugins
  -- attached via diffview's per-buffer setup would persist on the user's
  -- previous working-tree buffer indefinitely.
  it("detaches window b when the next entry's b is a different File instance", function()
    for _, cls in ipairs({ Diff2HorPinned, Diff2VerPinned }) do
      local detached = {}
      local cur_b_file = { path = "alpha.txt" }
      local next_b_file = { path = "beta.txt" }
      local inst = setmetatable({
        a = {
          detach_file = function()
            detached.a = true
          end,
        },
        b = {
          file = cur_b_file,
          detach_file = function()
            detached.b = true
          end,
        },
      }, { __index = cls })

      local next_entry = { layout = { b = { file = next_b_file } } }
      inst:detach_files_for_swap(next_entry)

      assert.True(detached.a)
      assert.True(detached.b)
    end
  end)

  -- Defensive: when the caller doesn't pass a next entry (e.g. legacy
  -- callers, or any non-FH view that hasn't migrated), we don't know the
  -- upcoming b-file. Treat that as "nothing to compare against" and skip
  -- detaching b, mirroring the pre-fix behaviour for those code paths.
  it("skips detaching b when no next_entry is passed", function()
    for _, cls in ipairs({ Diff2HorPinned, Diff2VerPinned }) do
      local detached = {}
      local inst = setmetatable({
        a = {
          detach_file = function()
            detached.a = true
          end,
        },
        b = {
          file = { path = "live.txt" },
          detach_file = function()
            detached.b = true
          end,
        },
      }, { __index = cls })

      inst:detach_files_for_swap()

      assert.True(detached.a)
      assert.is_nil(detached.b)
    end
  end)

  -- Sanity-check that the pinned layouts still inherit the base
  -- `detach_files()` (i.e. they no longer override it). On tab-leave /
  -- view-close, both windows must be detached.
  it("inherits detach_files() that detaches every window", function()
    for _, cls in ipairs({ Diff2HorPinned, Diff2VerPinned }) do
      local detached = {}
      local win_a = {
        detach_file = function()
          detached.a = true
        end,
      }
      local win_b = {
        detach_file = function()
          detached.b = true
        end,
      }
      local inst = setmetatable({
        a = win_a,
        b = win_b,
        windows = { win_a, win_b },
      }, { __index = cls })

      inst:detach_files()

      assert.True(detached.a)
      assert.True(detached.b)
    end
  end)
end)

describe("diffview.scene.layouts.diff_1_*_pinned ownership", function()
  local Diff1Pinned = require("diffview.scene.layouts.diff_1_pinned").Diff1Pinned
  local Diff1InlinePinned = require("diffview.scene.layouts.diff_1_inline_pinned").Diff1InlinePinned

  -- The b-side `vcs.File` is owned by the FileHistoryView (its pin_local
  -- cache), not by individual FileEntries. `shared_symbols` is the contract
  -- that tells `Layout:owned_files()` to exclude that window from the
  -- destruction set in `FileEntry:destroy` and `FileEntry:set_active`.
  it("declares 'b' as a shared symbol so entry teardown skips it", function()
    eq({ "b" }, Diff1Pinned.shared_symbols)
    eq({ "b" }, Diff1InlinePinned.shared_symbols)
  end)

  -- Concrete check of the filter: `Diff1Pinned:owned_files()` must return
  -- nothing (its only window is the shared b). For `Diff1InlinePinned` the
  -- `a_file` is per-entry-owned and stays in the destruction set; the
  -- shared `b` does not. This is what protects the view-owned b-file from
  -- being torn down on entry refresh in pin_local mode.
  it("owned_files() excludes the b-side file", function()
    do
      local b_file = { path = "foo.txt" }
      local inst = setmetatable({
        b = { file = b_file },
        windows = {},
        symbols = Diff1Pinned.symbols,
        shared_symbols = Diff1Pinned.shared_symbols,
      }, { __index = Diff1Pinned })

      eq({}, inst:owned_files())
    end

    do
      local a_file = { path = "old/foo.txt" }
      local b_file = { path = "foo.txt" }
      local inst = setmetatable({
        b = { file = b_file },
        a_file = a_file,
        windows = { { file = b_file } },
        symbols = Diff1InlinePinned.symbols,
        shared_symbols = Diff1InlinePinned.shared_symbols,
      }, { __index = Diff1InlinePinned })

      eq({ a_file }, inst:owned_files())
    end
  end)
end)

describe("diffview.scene.layouts.diff_1_*_pinned detach_files_for_swap", function()
  local Diff1Pinned = require("diffview.scene.layouts.diff_1_pinned").Diff1Pinned
  local Diff1InlinePinned = require("diffview.scene.layouts.diff_1_inline_pinned").Diff1InlinePinned

  -- The swap variant is what `_set_file` calls between log entries; it
  -- skips the pinned b so the LOCAL buffer's keymaps/edits survive the
  -- swap when the b-file stays the same instance. The full `detach_files()`
  -- is left to the base Layout so tab-leave/view-close still tear
  -- everything down.
  it("does not detach window b when next entry's b matches", function()
    for _, cls in ipairs({ Diff1Pinned, Diff1InlinePinned }) do
      local detached = {}
      local shared_b_file = { path = "live.txt" }
      local inst = setmetatable({
        b = {
          file = shared_b_file,
          detach_file = function()
            detached.b = true
          end,
        },
      }, { __index = cls })

      local next_entry = { layout = { b = { file = shared_b_file } } }
      inst:detach_files_for_swap(next_entry)

      assert.is_nil(detached.b)
    end
  end)

  -- Multi-file pinning: each path has its own view-owned working-tree File.
  -- Crossing rows changes the b-side instance, and the OLD b's buffer
  -- must be detached so it doesn't keep diffview keymaps and buffer-local
  -- overrides after navigation.
  it("detaches window b when the next entry's b is a different File instance", function()
    for _, cls in ipairs({ Diff1Pinned, Diff1InlinePinned }) do
      local detached = {}
      local cur_b_file = { path = "alpha.txt" }
      local next_b_file = { path = "beta.txt" }
      local inst = setmetatable({
        b = {
          file = cur_b_file,
          detach_file = function()
            detached.b = true
          end,
        },
      }, { __index = cls })

      local next_entry = { layout = { b = { file = next_b_file } } }
      inst:detach_files_for_swap(next_entry)

      assert.True(detached.b)
    end
  end)

  -- Defensive: when the caller doesn't pass a next entry, treat it as
  -- "nothing to compare against" and skip detaching b, mirroring the
  -- Diff2 pinned variants.
  it("skips detaching b when no next_entry is passed", function()
    for _, cls in ipairs({ Diff1Pinned, Diff1InlinePinned }) do
      local detached = {}
      local inst = setmetatable({
        b = {
          file = { path = "live.txt" },
          detach_file = function()
            detached.b = true
          end,
        },
      }, { __index = cls })

      inst:detach_files_for_swap()

      assert.is_nil(detached.b)
    end
  end)
end)

describe("diffview.scene.layouts.diff_2_*_pinned use_entry inheritance", function()
  local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned
  local Diff2VerPinned = require("diffview.scene.layouts.diff_2_ver_pinned").Diff2VerPinned

  ---Build a mock layout-like object that satisfies the `instanceof` check
  ---inside `Layout.use_entry` without needing a fully constructed Diff2.
  local function mock_layout(cls, a_file, b_file)
    return setmetatable({
      class = cls,
      a = { file = a_file },
      b = { file = b_file },
    }, { __index = cls })
  end

  ---Build a mock pinned-layout instance whose `set_file_for` records the
  ---swap. `is_valid` is forced to false so `use_entry` returns before the
  ---`await(self:open_files())` branch.
  local function mock_pinned(cls, set_files, b_file)
    return setmetatable({
      class = cls,
      a = { file = nil },
      b = { file = b_file },
      symbols = cls.symbols,
      set_file_for = function(_, sym, file)
        set_files[sym] = file
      end,
      is_valid = function()
        return false
      end,
    }, { __index = cls })
  end

  -- The pinned variants no longer override `use_entry`: with the view-owned
  -- shared b-file, every entry's `layout.b.file` already IS the same
  -- instance the cur_layout is holding, so the inherited
  -- `Layout.use_entry` is a no-op assignment for b. Confirm the inherited
  -- behaviour writes both symbols (the b-write is harmless because it's
  -- the same File).
  it("inherits Layout.use_entry which writes both symbols", function()
    for _, cls in ipairs({ Diff2HorPinned, Diff2VerPinned }) do
      local set_files = {}
      local shared_b_file = { path = "foo/bar.txt" }
      local new_a_file = { path = "old/foo/bar.txt" }

      local entry = { layout = mock_layout(cls, new_a_file, shared_b_file) }
      local inst = mock_pinned(cls, set_files, shared_b_file)

      inst:use_entry(entry)

      assert.equals(new_a_file, set_files.a)
      assert.equals(shared_b_file, set_files.b)
    end
  end)
end)

describe("diffview.scene.layouts.diff_1_inline diffopt forwarding", function()
  local Diff1Inline_mod = require("diffview.scene.layouts.diff_1_inline")
  local effective_diffopt = Diff1Inline_mod._test.effective_diffopt
  local inline_diff = require("diffview.scene.inline_diff")
  local api = vim.api

  local orig_diffopt

  before_each(function()
    orig_diffopt = vim.deepcopy(vim.opt.diffopt:get())
  end)

  after_each(function()
    vim.opt.diffopt = vim.deepcopy(orig_diffopt)
  end)

  ---Reset `'diffopt'` to a fixed baseline so each test starts from the same
  ---state regardless of what the Neovim default (or a prior test) left behind.
  ---@param entries string[]
  local function set_diffopt(entries)
    vim.opt.diffopt = entries
  end

  it("maps iwhite to ignore_whitespace_change", function()
    set_diffopt({ "iwhite" })
    eq(true, effective_diffopt().ignore_whitespace_change)
  end)

  it("maps iwhiteall to ignore_whitespace", function()
    set_diffopt({ "iwhiteall" })
    eq(true, effective_diffopt().ignore_whitespace)
  end)

  it("maps iwhiteeol to ignore_whitespace_change_at_eol", function()
    set_diffopt({ "iwhiteeol" })
    eq(true, effective_diffopt().ignore_whitespace_change_at_eol)
  end)

  it("maps iblank to ignore_blank_lines", function()
    set_diffopt({ "iblank" })
    eq(true, effective_diffopt().ignore_blank_lines)
  end)

  it("does not forward icase (vim.diff has no case-insensitive option)", function()
    set_diffopt({ "icase" })
    local opts = effective_diffopt()
    assert.is_nil(opts.ignore_case)
  end)

  it("maps algorithm:<name> to algorithm", function()
    set_diffopt({ "algorithm:patience" })
    eq("patience", effective_diffopt().algorithm)
  end)

  it("sets indent_heuristic to false when absent from 'diffopt'", function()
    set_diffopt({ "internal" })
    eq(false, effective_diffopt().indent_heuristic)
  end)

  it("sets indent_heuristic to true when 'indent-heuristic' is in 'diffopt'", function()
    set_diffopt({ "indent-heuristic" })
    eq(true, effective_diffopt().indent_heuristic)
  end)

  it("defaults linematch to 60 when absent from 'diffopt'", function()
    set_diffopt({ "internal" })
    eq(60, effective_diffopt().linematch)
  end)

  it("forwards linematch:N from 'diffopt'", function()
    set_diffopt({ "linematch:30", "iblank" })
    local opts = effective_diffopt()
    eq(30, opts.linematch)
    -- Sanity-check that other entries still parse (confirms the loop ran).
    eq(true, opts.ignore_blank_lines)
  end)

  it("honours an explicit linematch:0 to opt out of line-matching", function()
    set_diffopt({ "linematch:0" })
    eq(0, effective_diffopt().linematch)
  end)

  it("leaves ignore flags nil when 'diffopt' has no corresponding entry", function()
    set_diffopt({ "internal" })
    local opts = effective_diffopt()
    assert.is_nil(opts.ignore_whitespace)
    assert.is_nil(opts.ignore_whitespace_change)
    assert.is_nil(opts.ignore_whitespace_change_at_eol)
    assert.is_nil(opts.ignore_blank_lines)
  end)

  it("changes inline diff output when iwhiteall is enabled", function()
    local bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { "foo  bar" })

    set_diffopt({ "internal" })
    inline_diff.render(bufnr, { "foo bar" }, { "foo  bar" }, effective_diffopt())
    assert.is_true(#(inline_diff.get_hunks(bufnr) or {}) > 0)

    set_diffopt({ "internal", "iwhiteall" })
    inline_diff.render(bufnr, { "foo bar" }, { "foo  bar" }, effective_diffopt())
    eq(0, #(inline_diff.get_hunks(bufnr) or {}))

    pcall(api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

describe("diffview.layout.set_file_for", function()
  it("sets the file on the window and tags it with the symbol", function()
    local stored_file
    local mock_win = {
      set_file = function(_, f)
        stored_file = f
      end,
    }
    local mock_layout = { a = mock_win, windows = {}, symbols = { "a" } }
    setmetatable(mock_layout, { __index = Layout })

    local file = { path = "test.lua" }
    mock_layout:set_file_for("a", file)

    eq(file, stored_file)
    eq("a", file.symbol)
  end)
end)

describe("diffview.layout.create_wins", function()
  -- Mock vim.api and vim.cmd to verify the window creation sequence
  -- without needing real Neovim windows.
  local orig_win_call, orig_win_close, orig_get_cur_win, orig_win_is_valid, orig_cmd

  local cmds_recorded
  local next_win_id

  before_each(function()
    orig_win_call = vim.api.nvim_win_call
    orig_win_close = vim.api.nvim_win_close
    orig_get_cur_win = vim.api.nvim_get_current_win
    orig_win_is_valid = vim.api.nvim_win_is_valid
    orig_cmd = vim.cmd

    cmds_recorded = {}
    next_win_id = 100

    -- Execute the callback immediately (simulating nvim_win_call).
    vim.api.nvim_win_call = function(_, fn)
      fn()
    end
    vim.api.nvim_win_close = function() end
    vim.api.nvim_get_current_win = function()
      next_win_id = next_win_id + 1
      return next_win_id
    end
    vim.api.nvim_win_is_valid = function()
      return true
    end
    vim.cmd = function(c)
      cmds_recorded[#cmds_recorded + 1] = c
    end
  end)

  after_each(function()
    vim.api.nvim_win_call = orig_win_call
    vim.api.nvim_win_close = orig_win_close
    vim.api.nvim_get_current_win = orig_get_cur_win
    vim.api.nvim_win_is_valid = orig_win_is_valid
    vim.cmd = orig_cmd
  end)

  ---Build a mock layout with the given symbol-keyed windows.
  ---@param syms string[]
  ---@return table
  local function mock_layout(syms)
    local layout = {
      windows = {},
      state = {},
      create_pre = function(self)
        self.state.save_equalalways = vim.o.equalalways
      end,
      create_post = async.void(function() end),
      find_pivot = function()
        return 1
      end,
    }
    for _, s in ipairs(syms) do
      layout[s] = {
        set_id = function(self, id)
          self.id = id
        end,
        close = function() end,
        id = nil,
      }
    end
    setmetatable(layout, { __index = Layout })
    return layout
  end

  it(
    "issues vim.cmd calls in spec order",
    helpers.async_test(function()
      local layout = mock_layout({ "b", "a", "c" })
      async.await(layout:create_wins(1, {
        { "b", "belowright sp" },
        { "a", "aboveleft vsp" },
        { "c", "aboveleft vsp" },
      }, { "a", "b", "c" }))

      eq({ "belowright sp", "aboveleft vsp", "aboveleft vsp" }, cmds_recorded)
    end)
  )

  it(
    "builds self.windows in win_order, not creation order",
    helpers.async_test(function()
      local layout = mock_layout({ "a", "b", "c" })
      async.await(layout:create_wins(1, {
        { "b", "belowright sp" },
        { "a", "aboveleft vsp" },
        { "c", "aboveleft vsp" },
      }, { "a", "b", "c" }))

      -- Windows should be ordered a, b, c regardless of creation order.
      eq(layout.a, layout.windows[1])
      eq(layout.b, layout.windows[2])
      eq(layout.c, layout.windows[3])
    end)
  )

  it(
    "Diff4Mixed uses different creation order than window order",
    helpers.async_test(function()
      -- Diff4Mixed creates b, a, d, c but windows should be a, b, c, d.
      local layout = mock_layout({ "a", "b", "c", "d" })
      async.await(layout:create_wins(1, {
        { "b", "belowright sp" },
        { "a", "aboveleft vsp" },
        { "d", "aboveleft vsp" },
        { "c", "aboveleft vsp" },
      }, { "a", "b", "c", "d" }))

      eq(layout.a, layout.windows[1])
      eq(layout.b, layout.windows[2])
      eq(layout.c, layout.windows[3])
      eq(layout.d, layout.windows[4])
      eq({ "belowright sp", "aboveleft vsp", "aboveleft vsp", "aboveleft vsp" }, cmds_recorded)
    end)
  )

  it(
    "assigns window IDs from nvim_get_current_win to each symbol",
    helpers.async_test(function()
      local layout = mock_layout({ "a", "b" })
      async.await(layout:create_wins(1, {
        { "a", "aboveleft vsp" },
        { "b", "aboveleft vsp" },
      }, { "a", "b" }))

      -- IDs should be 101 and 102 (starting from next_win_id = 100 + 1).
      eq(101, layout.a.id)
      eq(102, layout.b.id)
    end)
  )
end)

describe("diffview.layout.create_wins integration", function()
  -- Test with real Neovim windows to verify splits actually work.

  ---Build a layout that stubs create_post so we only test window creation.
  local function real_layout(syms)
    local layout = {
      windows = {},
      state = {},
      emitter = require("diffview.events").EventEmitter(),
    }
    setmetatable(layout, { __index = Layout })
    for _, s in ipairs(syms) do
      layout[s] = {
        set_id = function(self, id)
          self.id = id
        end,
        close = function() end,
        id = nil,
      }
    end
    -- Override create_post to skip file loading (no files to open).
    layout.create_post = async.void(function(self)
      vim.opt.equalalways = self.state.save_equalalways
    end)
    return layout
  end

  it(
    "creates real window splits and produces valid window IDs",
    helpers.async_test(function()
      local pivot = vim.api.nvim_get_current_win()
      assert.True(vim.api.nvim_win_is_valid(pivot))

      local layout = real_layout({ "a", "b" })
      async.await(layout:create_wins(pivot, {
        { "a", "aboveleft vsp" },
        { "b", "aboveleft vsp" },
      }, { "a", "b" }))

      -- The pivot should have been closed.
      assert.False(vim.api.nvim_win_is_valid(pivot))

      -- Both windows should be valid and distinct.
      assert.True(vim.api.nvim_win_is_valid(layout.a.id))
      assert.True(vim.api.nvim_win_is_valid(layout.b.id))
      assert.are_not.equal(layout.a.id, layout.b.id)

      eq(layout.a, layout.windows[1])
      eq(layout.b, layout.windows[2])
      eq(2, #layout.windows)

      -- Clean up: close extra windows, keeping at least one.
      local wins = vim.api.nvim_tabpage_list_wins(0)
      for i = 2, #wins do
        if vim.api.nvim_win_is_valid(wins[i]) then
          vim.api.nvim_win_close(wins[i], true)
        end
      end
    end)
  )

  it(
    "Diff3Mixed-style split: creation order differs from window order",
    helpers.async_test(function()
      local pivot = vim.api.nvim_get_current_win()
      local layout = real_layout({ "a", "b", "c" })

      async.await(layout:create_wins(pivot, {
        { "b", "belowright sp" },
        { "a", "aboveleft vsp" },
        { "c", "aboveleft vsp" },
      }, { "a", "b", "c" }))

      for _, sym in ipairs({ "a", "b", "c" }) do
        assert.True(vim.api.nvim_win_is_valid(layout[sym].id), sym .. " should be valid")
      end

      eq(layout.a, layout.windows[1])
      eq(layout.b, layout.windows[2])
      eq(layout.c, layout.windows[3])

      local wins = vim.api.nvim_tabpage_list_wins(0)
      for i = 2, #wins do
        if vim.api.nvim_win_is_valid(wins[i]) then
          vim.api.nvim_win_close(wins[i], true)
        end
      end
    end)
  )
end)
