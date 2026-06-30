local actions = require("diffview.actions")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")
local Diff3Hor = require("diffview.scene.layouts.diff_3_hor").Diff3Hor
local Diff4Mixed = require("diffview.scene.layouts.diff_4_mixed").Diff4Mixed
local FileMergeView = require("diffview.scene.views.diff.file_merge_view").FileMergeView
local NullAdapter = require("diffview.vcs.adapters.null").NullAdapter
local RevType = require("diffview.vcs.rev").RevType

local eq = helpers.eq

local function tmpfile(content)
  local path = vim.fn.tempname()
  local f = io.open(path, "w")
  f:write(content)
  f:close()
  return path
end

describe("diffview.scene.views.diff.file_merge_view", function()
  describe("FileMergeView constructor", function()
    local output_path, base_path, left_path, right_path

    before_each(function()
      output_path = tmpfile("output\n")
      base_path = tmpfile("base\n")
      left_path = tmpfile("left\n")
      right_path = tmpfile("right\n")
    end)

    after_each(function()
      for _, p in ipairs({ output_path, base_path, left_path, right_path }) do
        os.remove(p)
      end
    end)

    it("creates a valid view in 4-way mode when base is provided", function()
      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output_path,
        base_path = base_path,
        left_path = left_path,
        right_path = right_path,
      })

      assert.True(view:is_valid())
      eq(output_path, view.output_path)
      eq(base_path, view.base_path)
      eq(left_path, view.left_path)
      eq(right_path, view.right_path)
    end)

    it("creates a 3-way layout when base is omitted", function()
      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output_path,
        left_path = left_path,
        right_path = right_path,
      })

      assert.True(view:is_valid())
      assert.is_nil(view.base_path)
      assert.True(view.files.conflicting[1].layout:instanceof(Diff3Hor))
    end)

    it("uses Diff4Mixed when base is provided", function()
      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output_path,
        base_path = base_path,
        left_path = left_path,
        right_path = right_path,
      })

      assert.True(view.files.conflicting[1].layout:instanceof(Diff4Mixed))
    end)

    it("populates conflicting (not working) with a single entry", function()
      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output_path,
        base_path = base_path,
        left_path = left_path,
        right_path = right_path,
      })

      eq(1, view.files:len())
      eq(0, #view.files.working)
      eq(0, #view.files.staged)
      eq(1, #view.files.conflicting)
      eq("conflicting", view.files.conflicting[1].kind)
    end)

    it("binds the output side to a LOCAL rev (editable, real file)", function()
      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output_path,
        base_path = base_path,
        left_path = left_path,
        right_path = right_path,
      })

      -- b is the editable middle window, bound to $output.
      eq(RevType.LOCAL, view.files.conflicting[1].revs.b.type)
    end)

    it("uses CUSTOM revs for the read-only inputs", function()
      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output_path,
        base_path = base_path,
        left_path = left_path,
        right_path = right_path,
      })

      local revs = view.files.conflicting[1].revs
      eq(RevType.CUSTOM, revs.a.type) -- left/OURS
      eq(RevType.CUSTOM, revs.c.type) -- right/THEIRS
      eq(RevType.CUSTOM, revs.d.type) -- base
    end)

    it("binds each window's file to the matching on-disk path", function()
      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output_path,
        base_path = base_path,
        left_path = left_path,
        right_path = right_path,
      })

      local layout = view.files.conflicting[1].layout
      eq(left_path, layout.a.file.path) -- OURS
      eq(output_path, layout.b.file.path) -- OUTPUT (editable)
      eq(right_path, layout.c.file.path) -- THEIRS
      eq(base_path, layout.d.file.path) -- BASE
    end)

    it("populates `merge_ctx` so `merge_only` keymaps show in the help panel", function()
      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output_path,
        left_path = left_path,
        right_path = right_path,
      })

      assert.is_not_nil(view.merge_ctx)
      assert.is_true(actions._is_applicable(actions.conflict_choose("ours"), view))
      assert.is_true(actions._is_applicable(actions.conflict_choose_all("ours"), view))
    end)
  end)

  describe("lib.diffview_merge_files", function()
    it("returns nil when given fewer than three args", function()
      assert.is_nil(lib.diffview_merge_files({}))
      assert.is_nil(lib.diffview_merge_files({ "a" }))
      assert.is_nil(lib.diffview_merge_files({ "a", "b" }))
    end)

    it("returns nil when given more than four args", function()
      assert.is_nil(lib.diffview_merge_files({ "a", "b", "c", "d", "e" }))
    end)

    it("returns nil when the output file does not exist", function()
      local left = tmpfile("l\n")
      local right = tmpfile("r\n")
      local view = lib.diffview_merge_files({ "/nonexistent/output", left, right })
      assert.is_nil(view)
      os.remove(left)
      os.remove(right)
    end)

    it("creates a 3-way FileMergeView for three existing paths", function()
      local output = tmpfile("o\n")
      local left = tmpfile("l\n")
      local right = tmpfile("r\n")

      local view = lib.diffview_merge_files({ output, left, right })
      assert.is_not_nil(view)
      assert.True(view:is_valid())
      assert.is_nil(view.base_path)
      eq(1, view.files:len())

      for i, v in ipairs(lib.views) do
        if v == view then
          table.remove(lib.views, i)
          break
        end
      end

      os.remove(output)
      os.remove(left)
      os.remove(right)
    end)

    it("creates a 4-way FileMergeView when base is provided", function()
      local output = tmpfile("o\n")
      local base = tmpfile("b\n")
      local left = tmpfile("l\n")
      local right = tmpfile("r\n")

      local view = lib.diffview_merge_files({ output, base, left, right })
      assert.is_not_nil(view)
      assert.True(view:is_valid())
      eq(base, view.base_path)
      eq(1, view.files:len())

      for i, v in ipairs(lib.views) do
        if v == view then
          table.remove(lib.views, i)
          break
        end
      end

      for _, p in ipairs({ output, base, left, right }) do
        os.remove(p)
      end
    end)
  end)

  describe("FileMergeView:update_files", function()
    it("is a no-op", function()
      local output = tmpfile("o\n")
      local left = tmpfile("l\n")
      local right = tmpfile("r\n")

      local adapter = NullAdapter.create({ toplevel = "/tmp" })
      local view = FileMergeView({
        adapter = adapter,
        output_path = output,
        left_path = left,
        right_path = right,
      })

      assert.has_no.errors(function()
        view:update_files()
      end)
      eq(1, view.files:len())

      os.remove(output)
      os.remove(left)
      os.remove(right)
    end)
  end)
end)
