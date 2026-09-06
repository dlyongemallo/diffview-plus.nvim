local helpers = require("diffview.tests.helpers")
local FileEntry = require("diffview.scene.file_entry").FileEntry
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local RevType = require("diffview.vcs.rev").RevType
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev

local eq = helpers.eq

describe("diffview.scene.file_entry", function()
  it("convert_layout skips null entries without error (#612)", function()
    local adapter = { ctx = { toplevel = vim.uv.cwd() } }
    local entry = FileEntry.new_null_entry(adapter)
    local original_layout = entry.layout

    -- Must not error; null entries have no revs.
    assert.has_no.errors(function()
      entry:convert_layout(Diff2Hor)
    end)

    assert.are.equal(original_layout, entry.layout)
  end)

  it("convert_layout calls teardown_render on the outgoing layout", function()
    local teardown_calls = 0
    local rev = GitRev(RevType.STAGE, 0)
    local file_b = { bufnr = -1 }
    local old_layout = {
      files = function()
        return { file_b }
      end,
      owned_files = function()
        return { file_b }
      end,
      get_file_for = function(_, sym)
        return sym == "b" and file_b or nil
      end,
      teardown_render = function()
        teardown_calls = teardown_calls + 1
      end,
    }

    local entry = FileEntry({
      adapter = { ctx = { toplevel = vim.uv.cwd() } },
      path = "README.md",
      oldpath = nil,
      revs = { a = rev, b = rev },
      layout = old_layout,
      status = "M",
      stats = {},
      kind = "working",
    })

    local new_layout = {}
    setmetatable(new_layout, {
      __call = function()
        return {
          files = function()
            return {}
          end,
        }
      end,
    })

    entry:convert_layout(new_layout)
    eq(1, teardown_calls)
  end)

  it("does not treat should_null errors as truthy null markers", function()
    local captured
    local layout_class = setmetatable({
      should_null = function()
        error("boom")
      end,
    }, {
      __call = function(_, opt)
        captured = opt
        return {
          files = function()
            return { opt.b }
          end,
        }
      end,
    })

    local rev = GitRev(RevType.STAGE, 0)
    local adapter = { ctx = { toplevel = vim.uv.cwd() } }

    FileEntry.with_layout(layout_class, {
      adapter = adapter,
      path = "README.md",
      status = "M",
      kind = "working",
      revs = { a = rev, b = rev },
    })

    assert.is_not_nil(captured)
    assert.False(captured.b.nulled)
  end)

  describe("update_merge_context", function()
    local function make_entry_with_layout()
      local file_stubs = {}
      local layout = {}
      for _, key in ipairs({ "a", "b", "c", "d" }) do
        file_stubs[key] = { winbar = nil }
        layout[key] = { file = file_stubs[key] }
      end

      local entry = FileEntry({
        adapter = { ctx = { toplevel = "/tmp" } },
        path = "a.txt",
        oldpath = nil,
        revs = {},
        layout = layout,
        status = "M",
        stats = {},
        kind = "working",
      })

      return entry, layout, file_stubs
    end

    it("does not error when merge context entries have nil hashes", function()
      local entry, _, file_stubs = make_entry_with_layout()

      assert.has_no.errors(function()
        entry:update_merge_context({
          ours = {},
          theirs = {},
          base = {},
        })
      end)

      -- Winbars for ours/theirs/base should remain unset.
      assert.is_nil(file_stubs.a.winbar)
      assert.is_nil(file_stubs.c.winbar)
      assert.is_nil(file_stubs.d.winbar)
      -- LOCAL winbar is always set.
      eq(" LOCAL (Working tree)", file_stubs.b.winbar)
    end)

    it("sets winbars correctly when hashes are present", function()
      local entry, _, file_stubs = make_entry_with_layout()
      local hash = "abc123def456"

      entry:update_merge_context({
        ours = { hash = hash, ref_names = "main" },
        theirs = { hash = hash, ref_names = "feature" },
        base = { hash = hash },
      })

      assert.is_not_nil(file_stubs.a.winbar)
      assert.truthy(file_stubs.a.winbar:find("OURS"))
      assert.truthy(file_stubs.a.winbar:find("main"))
      assert.truthy(file_stubs.c.winbar:find("THEIRS"))
      assert.truthy(file_stubs.c.winbar:find("feature"))
      assert.truthy(file_stubs.d.winbar:find("BASE"))
      assert.truthy(file_stubs.d.winbar:find(hash:sub(1, 10)))
      eq(" LOCAL (Working tree)", file_stubs.b.winbar)
    end)

    it("handles a mix of present and missing hashes", function()
      local entry, _, file_stubs = make_entry_with_layout()

      assert.has_no.errors(function()
        entry:update_merge_context({
          ours = { hash = "abc123def456" },
          theirs = {},
          base = { hash = "def789abc012" },
        })
      end)

      assert.truthy(file_stubs.a.winbar:find("OURS"))
      assert.is_nil(file_stubs.c.winbar)
      assert.truthy(file_stubs.d.winbar:find("BASE"))
    end)
  end)

  -- Identity contract: when an adapter passes a pre-built `pinned_b_file`,
  -- `with_layout` reuses that exact `vcs.File` instance for the b-side
  -- instead of constructing a new one from `opt.path`/`opt.pinned_path`.
  -- This is what lets every pinned-mode FileEntry across the view share
  -- the same working-tree File (see `Diff2*Pinned.shared_symbols`).
  it("with_layout reuses the supplied pinned_b_file for the b-side", function()
    local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned

    local shared = { path = "foo.txt" } --[[@as vcs.File ]]
    local fake_adapter = { ctx = { toplevel = "/" } }
    -- Real Rev would require adapter wiring; mock just the method `vcs.File`
    -- pulls during winbar construction (`object_name`).
    local rev_a = {
      type = RevType.COMMIT,
      commit = "abc1234567",
      object_name = function(_, n)
        return ("abc1234567"):sub(1, n or 10)
      end,
    }
    local rev_b = { type = RevType.LOCAL }

    local entry = FileEntry.with_layout(Diff2HorPinned, {
      adapter = fake_adapter,
      path = "old/foo.txt",
      oldpath = nil,
      status = "M",
      kind = "working",
      revs = { a = rev_a, b = rev_b },
      pinned_b_file = shared,
    })

    assert.equals(shared, entry.layout.b.file)
    assert.is_not_nil(entry.layout.a.file)
    assert.are_not.equal(shared, entry.layout.a.file)
  end)

  -- Carve-out: a status="D" entry whose working-tree path is also missing
  -- must not reuse the shared `pinned_b_file`, otherwise the b-side opens
  -- an empty/editable buffer for the missing path. `with_layout` falls back
  -- to a fresh nulled file; the shared instance is preserved for entries
  -- where the LOCAL path still exists (e.g. overlay against a commit that
  -- predates the file's introduction).
  it("with_layout falls back to a nulled b-file when the LOCAL path is missing", function()
    local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned

    local missing_path = vim.fn.tempname() .. "-does-not-exist"
    local shared = {
      path = "foo.txt",
      absolute_path = missing_path,
    } --[[@as vcs.File ]]
    local fake_adapter = { ctx = { toplevel = "/" } }
    local rev_a = {
      type = RevType.COMMIT,
      commit = "abc1234567",
      object_name = function(_, n)
        return ("abc1234567"):sub(1, n or 10)
      end,
    }
    -- Mock `object_name` on the LOCAL rev too: when the fall-through builds
    -- a fresh nulled b-file, `vcs.File:init` evaluates the winbar's
    -- `object_path` regardless of rev type (the value is unused for LOCAL,
    -- but the table-construction happens up front).
    local rev_b = {
      type = RevType.LOCAL,
      object_name = function(_, n)
        return ("0"):rep(n or 10)
      end,
    }

    local entry = FileEntry.with_layout(Diff2HorPinned, {
      adapter = fake_adapter,
      path = "foo.txt",
      oldpath = nil,
      status = "D",
      kind = "working",
      revs = { a = rev_a, b = rev_b },
      pinned_b_file = shared,
    })

    assert.are_not.equal(shared, entry.layout.b.file)
    assert.is_true(entry.layout.b.file.nulled)
  end)

  -- Overlay: pinned_path exists in the working tree but isn't in this
  -- commit. `_resolve_pinned_target` marks status="D" so the layout nulls
  -- the a-side (file absent from the commit), but the b-side must still
  -- show the LOCAL working-tree file. The disk check in `with_layout` is
  -- what preserves this case.
  it("with_layout reuses pinned_b_file on status=D when the LOCAL path exists", function()
    local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned

    local existing_path = vim.fn.tempname()
    local f = assert(io.open(existing_path, "w"))
    f:write("present\n")
    f:close()

    local shared = {
      path = "foo.txt",
      absolute_path = existing_path,
    } --[[@as vcs.File ]]
    local fake_adapter = { ctx = { toplevel = "/" } }
    local rev_a = {
      type = RevType.COMMIT,
      commit = "abc1234567",
      object_name = function(_, n)
        return ("abc1234567"):sub(1, n or 10)
      end,
    }
    local rev_b = { type = RevType.LOCAL }

    local ok, err = pcall(function()
      local entry = FileEntry.with_layout(Diff2HorPinned, {
        adapter = fake_adapter,
        path = "foo.txt",
        oldpath = nil,
        status = "D",
        kind = "working",
        revs = { a = rev_a, b = rev_b },
        pinned_b_file = shared,
      })

      assert.equals(shared, entry.layout.b.file)
    end)

    pcall(vim.fn.delete, existing_path)
    if not ok then
      error(err)
    end
  end)

  -- The fallback nulled file built by `with_layout` for a status="D"
  -- entry whose LOCAL path is gone is constructed for a window whose
  -- symbol is in `Diff2*Pinned.shared_symbols`. `Layout:owned_files()`
  -- intentionally skips shared symbols (the view owns them), so without
  -- explicit per-FileEntry tracking these one-off fallbacks would never
  -- be destroyed -- a slow buffer/Lua-object leak for any history
  -- containing deleted-and-removed paths. `with_layout` now tracks them
  -- in `_extra_owned` so `FileEntry:destroy` can release them.
  it("with_layout tracks the fallback nulled b-file as an extra-owned file", function()
    local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned

    local missing_path = vim.fn.tempname() .. "-does-not-exist"
    local shared = {
      path = "foo.txt",
      absolute_path = missing_path,
    } --[[@as vcs.File ]]
    local fake_adapter = { ctx = { toplevel = "/" } }
    local rev_a = {
      type = RevType.COMMIT,
      commit = "abc1234567",
      object_name = function(_, n)
        return ("abc1234567"):sub(1, n or 10)
      end,
    }
    local rev_b = {
      type = RevType.LOCAL,
      object_name = function(_, n)
        return ("0"):rep(n or 10)
      end,
    }

    local entry = FileEntry.with_layout(Diff2HorPinned, {
      adapter = fake_adapter,
      path = "foo.txt",
      oldpath = nil,
      status = "D",
      kind = "working",
      revs = { a = rev_a, b = rev_b },
      pinned_b_file = shared,
    })

    -- Fallback created (so the b-window doesn't reuse the shared instance).
    assert.are_not.equal(shared, entry.layout.b.file)
    -- Fallback is tracked so destroy() can release it; the layout's
    -- owned_files() would otherwise skip it via shared_symbols.
    eq(1, #entry._extra_owned)
    eq(entry.layout.b.file, entry._extra_owned[1])
  end)

  -- Identity case: when the b-side reuses the supplied `pinned_b_file`,
  -- the FileEntry must NOT track it -- the view owns the shared instance
  -- and destroying it from a per-entry teardown would wipe state out
  -- from under every other entry.
  it("with_layout does not track the shared pinned_b_file as extra-owned", function()
    local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned

    local shared = { path = "foo.txt" } --[[@as vcs.File ]]
    local fake_adapter = { ctx = { toplevel = "/" } }
    local rev_a = {
      type = RevType.COMMIT,
      commit = "abc1234567",
      object_name = function(_, n)
        return ("abc1234567"):sub(1, n or 10)
      end,
    }
    local rev_b = { type = RevType.LOCAL }

    local entry = FileEntry.with_layout(Diff2HorPinned, {
      adapter = fake_adapter,
      path = "old/foo.txt",
      oldpath = nil,
      status = "M",
      kind = "working",
      revs = { a = rev_a, b = rev_b },
      pinned_b_file = shared,
    })

    eq(shared, entry.layout.b.file)
    eq(0, #entry._extra_owned)
  end)

  -- Lifecycle: `FileEntry:destroy` must reach the extra-owned fallbacks
  -- (the layout's `owned_files()` doesn't expose them).
  it("destroy() releases extra-owned fallback files", function()
    local destroyed_extra = false
    local extra = {
      destroy = function()
        destroyed_extra = true
      end,
    }
    local layout_destroyed = false
    local layout = {
      owned_files = function()
        return {}
      end,
      destroy = function()
        layout_destroyed = true
      end,
    }

    local entry = FileEntry({
      adapter = { ctx = { toplevel = "/tmp" } },
      path = "a.txt",
      oldpath = nil,
      revs = {},
      layout = layout,
      status = "M",
      stats = {},
      kind = "working",
      _extra_owned = { extra },
    })

    entry:destroy()

    assert.is_true(destroyed_extra)
    assert.is_true(layout_destroyed)
    eq(0, #entry._extra_owned)
  end)

  it("forwards force to non-LOCAL files but guards LOCAL when destroyed", function()
    local seen = {}
    local layout_destroyed = false

    -- LOCAL files stand in for the user's real working-tree buffer, which
    -- may be visible in other tabs; `FileEntry:destroy` must never propagate
    -- `force=true` to them. Non-LOCAL sides (STAGE/COMMIT) remain forced so
    -- `refresh_files({ force = true })` still discards their virtual buffers.
    local files_list = {
      {
        rev = { type = RevType.STAGE },
        destroy = function(_, force)
          seen[#seen + 1] = force
        end,
      },
      {
        rev = { type = RevType.LOCAL },
        destroy = function(_, force)
          seen[#seen + 1] = force
        end,
      },
      {
        rev = { type = RevType.COMMIT },
        destroy = function(_, force)
          seen[#seen + 1] = force
        end,
      },
    }
    local layout = {
      files = function()
        return files_list
      end,
      owned_files = function()
        return files_list
      end,
      destroy = function()
        layout_destroyed = true
      end,
    }

    local entry = FileEntry({
      adapter = { ctx = { toplevel = "/tmp" } },
      path = "a.txt",
      oldpath = nil,
      revs = {},
      layout = layout,
      status = "M",
      stats = {},
      kind = "working",
    })

    entry:destroy(true)

    eq({ true, false, true }, seen)
    eq(true, layout_destroyed)
  end)

  it("passes force=false through unchanged regardless of rev type", function()
    local seen = {}

    local files_list = {
      {
        rev = { type = RevType.STAGE },
        destroy = function(_, force)
          seen[#seen + 1] = force
        end,
      },
      {
        rev = { type = RevType.LOCAL },
        destroy = function(_, force)
          seen[#seen + 1] = force
        end,
      },
    }
    local layout = {
      files = function()
        return files_list
      end,
      owned_files = function()
        return files_list
      end,
      destroy = function() end,
    }

    local entry = FileEntry({
      adapter = { ctx = { toplevel = "/tmp" } },
      path = "a.txt",
      oldpath = nil,
      revs = {},
      layout = layout,
      status = "M",
      stats = {},
      kind = "working",
    })

    entry:destroy(false)

    eq({ false, false }, seen)
  end)
end)
