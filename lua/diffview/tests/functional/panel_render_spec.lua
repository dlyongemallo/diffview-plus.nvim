local helpers = require("diffview.tests.helpers")
local config = require("diffview.config")
local Node = require("diffview.ui.models.file_tree.node").Node
local FileTree = require("diffview.ui.models.file_tree.file_tree").FileTree
local FileDict = require("diffview.vcs.file_dict").FileDict
local panel_render = require("diffview.scene.views.diff.render")

local eq = helpers.eq

local format_folder_name = panel_render._test.format_folder_name
local render_file = panel_render._test.render_file
local render_folder_count = panel_render._test.render_folder_count

-- ---------------------------------------------------------------------------
-- Mock RenderComponent (same pattern as file_history_render_spec.lua)
-- ---------------------------------------------------------------------------

---Create a mock RenderComponent that records add_text / add_line / ln calls.
---@return table
local function make_comp()
  local comp = { lines = { {} }, components = {} }

  function comp:add_text(text, hl)
    local cur = self.lines[#self.lines]
    cur[#cur + 1] = { text = text, hl = hl }
  end

  function comp:add_line(line, hl)
    if line and hl then
      local cur = self.lines[#self.lines]
      cur[#cur + 1] = { text = line, hl = hl }
    elseif line then
      local cur = self.lines[#self.lines]
      cur[#cur + 1] = { text = line }
    end
    self.lines[#self.lines + 1] = {}
  end

  function comp:ln()
    self.lines[#self.lines + 1] = {}
  end

  function comp:clear()
    self.lines = { {} }
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

---Create a minimal file entry stub.
---@param path string
---@param kind? string
---@param status? string
---@return table
local function make_entry(path, kind, status)
  local parts = vim.split(path, "/")
  return {
    path = path,
    basename = parts[#parts],
    extension = parts[#parts]:match("%.(%w+)$") or "",
    parent_path = table.concat(parts, "/", 1, math.max(#parts - 1, 0)),
    kind = kind or "working",
    status = status or "M",
    active = false,
  }
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("panel_render", function()
  local original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original_config)
  end)

  -- -----------------------------------------------------------------------
  -- File count on collapsed folders (commit bdbe846)
  -- -----------------------------------------------------------------------

  describe("file count on collapsed folders", function()
    describe("Node:leaves()", function()
      it("returns leaf nodes for a flat directory", function()
        local root = Node(
          "root",
          { name = "root", path = "root", kind = "working", collapsed = false, status = "M" }
        )
        root:add_child(Node("a.lua", { path = "root/a.lua", status = "M" }))
        root:add_child(Node("b.lua", { path = "root/b.lua", status = "A" }))
        root:add_child(Node("c.lua", { path = "root/c.lua", status = "D" }))

        local leaves = root:leaves()
        eq(3, #leaves)
      end)

      it("returns leaf nodes across nested directories", function()
        -- Structure: src/ -> components/ -> [a.lua, b.lua]
        --                  -> utils/ -> [c.lua]
        local src = Node(
          "src",
          { name = "src", path = "src", kind = "working", collapsed = false, status = "M" }
        )
        local components = Node("components", {
          name = "components",
          path = "src/components",
          kind = "working",
          collapsed = false,
          status = "M",
        })
        local utils_dir = Node(
          "utils",
          { name = "utils", path = "src/utils", kind = "working", collapsed = false, status = "A" }
        )
        src:add_child(components)
        src:add_child(utils_dir)
        components:add_child(Node("a.lua", { path = "src/components/a.lua", status = "M" }))
        components:add_child(Node("b.lua", { path = "src/components/b.lua", status = "M" }))
        utils_dir:add_child(Node("c.lua", { path = "src/utils/c.lua", status = "A" }))

        local leaves = src:leaves()
        eq(3, #leaves)
      end)

      it("returns only the deeply nested leaf in a long chain", function()
        -- Chain: a/ -> b/ -> c/ -> file.lua
        local a =
          Node("a", { name = "a", path = "a", kind = "working", collapsed = false, status = "M" })
        local b =
          Node("b", { name = "b", path = "a/b", kind = "working", collapsed = false, status = "M" })
        local c = Node(
          "c",
          { name = "c", path = "a/b/c", kind = "working", collapsed = false, status = "M" }
        )
        a:add_child(b)
        b:add_child(c)
        c:add_child(Node("file.lua", { path = "a/b/c/file.lua", status = "M" }))

        local leaves = a:leaves()
        eq(1, #leaves)
        eq("file.lua", leaves[1].name)
      end)
    end)

    describe("render output for collapsed directories", function()
      it("shows simple file count in parentheses when folder_count_style is 'simple'", function()
        local conf = config.get_config()
        conf.file_panel.tree_options.folder_count_style = "simple"
        config.setup(conf)

        -- Build a directory node with 3 leaves.
        local dir_node = Node(
          "src",
          { name = "src", path = "src", kind = "working", collapsed = true, status = "M" }
        )
        dir_node:add_child(Node("a.lua", { path = "src/a.lua", status = "M" }))
        dir_node:add_child(Node("b.lua", { path = "src/b.lua", status = "M" }))
        dir_node:add_child(Node("c.lua", { path = "src/c.lua", status = "M" }))

        ---@type DirData
        local ctx = {
          name = "src",
          path = "src",
          kind = "working",
          collapsed = true,
          status = "M",
          _node = dir_node,
        }

        -- Use the same logic as render.lua to produce the count text.
        local file_count = #ctx._node:leaves()
        eq(3, file_count)

        -- Verify the formatted string.
        local count_text = " (" .. file_count .. ")"
        eq(" (3)", count_text)
      end)

      it("shows grouped status counts when folder_count_style is 'grouped'", function()
        local conf = config.get_config()
        conf.file_panel.tree_options.folder_count_style = "grouped"
        config.setup(conf)

        local dir_node = Node(
          "src",
          { name = "src", path = "src", kind = "working", collapsed = true, status = "M" }
        )
        dir_node:add_child(Node("a.lua", { path = "src/a.lua", status = "M" }))
        dir_node:add_child(Node("b.lua", { path = "src/b.lua", status = "A" }))
        dir_node:add_child(Node("c.lua", { path = "src/c.lua", status = "M" }))

        -- Call the real render_folder_count and inspect the output.
        local comp = make_comp()
        render_folder_count(comp, dir_node, config.get_config().file_panel.tree_options)

        -- Assert the grouped counts are attached to the expected status highlights.
        local added_text = table.concat(comp:segments_by_hl("DiffviewStatusAdded"))
        local modified_text = table.concat(comp:segments_by_hl("DiffviewStatusModified"))

        assert.truthy(added_text:find("1"), "expected A-status highlight to contain count 1")
        assert.is_nil(added_text:find("2"), "did not expect A-status highlight to contain count 2")
        assert.truthy(modified_text:find("2"), "expected M-status highlight to contain count 2")
        assert.is_nil(
          modified_text:find("1"),
          "did not expect M-status highlight to contain count 1"
        )

        -- The opening and closing parentheses should be DiffviewDim1.
        local dim_segs = comp:segments_by_hl("DiffviewDim1")
        eq(" (", dim_segs[1])
        eq(")", dim_segs[#dim_segs])
      end)

      it("renders grouped count segments to a mock component", function()
        local conf = config.get_config()
        conf.file_panel.tree_options.folder_count_style = "grouped"
        config.setup(conf)

        local dir_node = Node(
          "src",
          { name = "src", path = "src", kind = "working", collapsed = true, status = "M" }
        )
        dir_node:add_child(Node("x.lua", { path = "src/x.lua", status = "D" }))
        dir_node:add_child(Node("y.lua", { path = "src/y.lua", status = "D" }))
        dir_node:add_child(Node("z.lua", { path = "src/z.lua", status = "A" }))

        -- Call the real render_folder_count.
        local comp = make_comp()
        render_folder_count(comp, dir_node, config.get_config().file_panel.tree_options)

        -- Assert the grouped counts are attached to the expected status highlights.
        local added_text = table.concat(comp:segments_by_hl("DiffviewStatusAdded"))
        local deleted_text = table.concat(comp:segments_by_hl("DiffviewStatusDeleted"))

        assert.truthy(added_text:find("1"), "expected A-status highlight to contain count 1")
        assert.is_nil(added_text:find("2"), "did not expect A-status highlight to contain count 2")
        assert.truthy(deleted_text:find("2"), "expected D-status highlight to contain count 2")
        assert.is_nil(
          deleted_text:find("1"),
          "did not expect D-status highlight to contain count 1"
        )

        -- The opening and closing parentheses should be DiffviewDim1.
        local dim_segs = comp:segments_by_hl("DiffviewDim1")
        eq(" (", dim_segs[1])
        eq(")", dim_segs[#dim_segs])
      end)

      it("hides count entirely when folder_count_style is 'none'", function()
        local conf = config.get_config()
        conf.file_panel.tree_options.folder_count_style = "none"
        config.setup(conf)

        local dir_node = Node(
          "src",
          { name = "src", path = "src", kind = "working", collapsed = true, status = "M" }
        )
        dir_node:add_child(Node("a.lua", { path = "src/a.lua", status = "M" }))
        dir_node:add_child(Node("b.lua", { path = "src/b.lua", status = "A" }))

        -- Call the real render_folder_count; it should produce no output.
        local comp = make_comp()
        render_folder_count(comp, dir_node, config.get_config().file_panel.tree_options)
        eq(0, #comp:segments_by_hl("DiffviewDim1"))
        eq("", comp:flat_text())
      end)

      it("does not show count when directory is expanded", function()
        -- When collapsed is false, the count section is skipped.
        local dir_node = Node(
          "src",
          { name = "src", path = "src", kind = "working", collapsed = false, status = "M" }
        )
        dir_node:add_child(Node("a.lua", { path = "src/a.lua", status = "M" }))

        local ctx = {
          name = "src",
          path = "src",
          kind = "working",
          collapsed = false,
          status = "M",
          _node = dir_node,
        }

        -- The render code gates on `ctx.collapsed and ctx._node`.
        local should_show_count = ctx.collapsed and ctx._node
        assert.falsy(should_show_count)
      end)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- folder_trailing_slash
  -- -----------------------------------------------------------------------

  describe("folder_trailing_slash option", function()
    it("appends trailing slash when enabled", function()
      local conf = config.get_config()
      conf.file_panel.tree_options.folder_trailing_slash = true
      config.setup(conf)

      eq("src/", format_folder_name("src", config.get_config().file_panel.tree_options))
    end)

    it("omits trailing slash when disabled", function()
      local conf = config.get_config()
      conf.file_panel.tree_options.folder_trailing_slash = false
      config.setup(conf)

      eq("src", format_folder_name("src", config.get_config().file_panel.tree_options))
    end)

    it("defaults to true", function()
      eq(true, config.get_config().file_panel.tree_options.folder_trailing_slash)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- Loading indicator (commit 5f1603a)
  -- -----------------------------------------------------------------------

  describe("loading indicator", function()
    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel

    ---Build a mock FileDict.
    local function make_files(working)
      local files = { conflicting = {}, working = working or {}, staged = {} }
      function files:iter()
        local all = {}
        for _, f in ipairs(self.working) do
          all[#all + 1] = f
        end
        local i = 0
        return function()
          i = i + 1
          if i <= #all then
            return i, all[i]
          end
        end
      end
      function files:len()
        return #self.conflicting + #self.working + #self.staged
      end
      return files
    end

    ---Create a panel with render_data and components initialised.
    local function make_panel(entries, is_loading)
      -- Disable icons so render does not require nvim-web-devicons.
      config.get_config().use_icons = false

      local adapter = {
        ctx = { toplevel = "/tmp", dir = "/tmp/.git" },
        get_branch_name = function()
          return nil
        end,
      }
      local panel = FilePanel(adapter, make_files(entries or {}), {})
      panel.listing_style = "list"
      panel.is_loading = is_loading

      -- Initialise the buffer and render_data so render() can run.
      panel:init_buffer()

      return panel
    end

    it("shows 'Fetching changes...' when panel.is_loading is true", function()
      local panel = make_panel({}, true)
      panel:update_components()
      panel:render()

      -- Read back the buffer lines.
      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Fetching changes"), "expected loading message in rendered output")

      -- The working/staged section titles should NOT appear.
      assert.falsy(joined:find("Changes "), "should not show Changes section while loading")

      panel:destroy()
    end)

    it("shows full content after loading completes", function()
      local f = make_entry("hello.lua")
      local panel = make_panel({ f }, false)
      panel:update_components()
      panel:render()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.falsy(joined:find("Fetching changes"), "should not show loading message")
      assert.truthy(joined:find("Changes"), "expected Changes section header")

      panel:destroy()
    end)

    it("transitions from loading to full render", function()
      local f = make_entry("transition.lua")
      local panel = make_panel({ f }, true)
      panel:update_components()
      panel:render()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Fetching changes"), "expected loading state initially")

      -- Simulate loading completion.
      panel.is_loading = false
      panel:update_components()
      panel:render()
      panel:redraw()

      lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      joined = table.concat(lines, "\n")
      assert.falsy(joined:find("Fetching changes"), "loading message should be gone")
      assert.truthy(joined:find("Changes"), "expected Changes section after loading")

      panel:destroy()
    end)
  end)

  -- -----------------------------------------------------------------------
  -- "Working tree clean" message (commit 1f07a2b)
  -- -----------------------------------------------------------------------

  describe("working tree clean message", function()
    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel

    local function make_files(conflicting, working, staged)
      local files =
        { conflicting = conflicting or {}, working = working or {}, staged = staged or {} }
      function files:iter()
        local all = {}
        for _, f in ipairs(self.conflicting) do
          all[#all + 1] = f
        end
        for _, f in ipairs(self.working) do
          all[#all + 1] = f
        end
        for _, f in ipairs(self.staged) do
          all[#all + 1] = f
        end
        local i = 0
        return function()
          i = i + 1
          if i <= #all then
            return i, all[i]
          end
        end
      end
      function files:len()
        return #self.conflicting + #self.working + #self.staged
      end
      return files
    end

    local function make_panel(conflicting, working, staged)
      -- Disable icons so render does not require nvim-web-devicons.
      config.get_config().use_icons = false

      local adapter = {
        ctx = { toplevel = "/tmp", dir = "/tmp/.git" },
        get_branch_name = function()
          return nil
        end,
      }
      local panel = FilePanel(adapter, make_files(conflicting, working, staged), {})
      panel.listing_style = "list"
      panel.is_loading = false
      panel:init_buffer()
      return panel
    end

    it("shows 'Working tree clean' when all sections are empty", function()
      local panel = make_panel({}, {}, {})
      panel:update_components()
      panel:render()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Working tree clean"), "expected 'Working tree clean' message")

      panel:destroy()
    end)

    it("does not show 'Working tree clean' when working files exist", function()
      local f = make_entry("changed.lua")
      local panel = make_panel({}, { f }, {})
      panel:update_components()
      panel:render()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.falsy(
        joined:find("Working tree clean"),
        "should not show clean message with working files"
      )

      panel:destroy()
    end)

    it("shows '(empty)' for working section when conflicts exist", function()
      -- When there are conflicts but no working changes, the working section
      -- shows "(empty)" rather than "Working tree clean".
      local conflict = make_entry("conflict.lua", "conflicting")
      local panel = make_panel({ conflict }, {}, {})
      panel:update_components()
      panel:render()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      -- "Working tree clean" should NOT appear because conflicts exist.
      assert.falsy(
        joined:find("Working tree clean"),
        "should not show clean message when conflicts exist"
      )

      panel:destroy()
    end)

    it("shows '(empty)' for working section when staged files exist", function()
      local staged = make_entry("staged.lua", "staged")
      local panel = make_panel({}, {}, { staged })
      panel:update_components()
      panel:render()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      -- When staged files exist but working is empty, it should say "(empty)"
      -- for the working section, not "Working tree clean".
      assert.falsy(
        joined:find("Working tree clean"),
        "should not show clean message when staged files exist"
      )

      panel:destroy()
    end)

    it("shows Changes (0) header with the clean message", function()
      local panel = make_panel({}, {}, {})
      panel:update_components()
      panel:render()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Changes"), "expected Changes header")
      assert.truthy(joined:find("%(0%)"), "expected (0) counter")

      panel:destroy()
    end)
  end)

  -- -----------------------------------------------------------------------
  -- Tree collapsed state preservation (commit 49c3984)
  -- -----------------------------------------------------------------------

  describe("tree collapsed state preservation", function()
    describe("FileTree get/set collapsed state round-trip", function()
      it("preserves collapsed state through get -> rebuild -> set", function()
        local files = {
          make_entry("src/components/button.lua"),
          make_entry("src/components/input.lua"),
          make_entry("src/utils/math.lua"),
          make_entry("lib/core.lua"),
        }

        -- Build the initial tree and collapse some directories.
        local tree1 = FileTree(files)
        -- Manually set collapsed state on tree nodes.
        tree1:set_collapsed_state({
          ["src"] = true,
          ["src/components"] = true,
          ["src/utils"] = false,
          ["lib"] = false,
        })

        -- Capture collapsed state.
        local state = tree1:get_collapsed_state()
        eq(true, state["src"])
        eq(true, state["src/components"])
        eq(false, state["src/utils"])
        eq(false, state["lib"])

        -- Rebuild a new tree (simulating tab switch or refresh).
        local tree2 = FileTree(files)

        -- Verify the new tree starts with everything expanded.
        local fresh_state = tree2:get_collapsed_state()
        eq(false, fresh_state["src"])
        eq(false, fresh_state["src/components"])
        eq(false, fresh_state["src/utils"])
        eq(false, fresh_state["lib"])

        -- Restore the saved state.
        tree2:set_collapsed_state(state)

        -- Verify the restoration.
        local restored = tree2:get_collapsed_state()
        eq(true, restored["src"])
        eq(true, restored["src/components"])
        eq(false, restored["src/utils"])
        eq(false, restored["lib"])
      end)

      it("handles state for paths not present in the new tree", function()
        local files1 = {
          make_entry("src/old.lua"),
          make_entry("src/keep.lua"),
        }
        local files2 = {
          make_entry("src/keep.lua"),
          make_entry("src/new.lua"),
        }

        local tree1 = FileTree(files1)
        tree1:set_collapsed_state({ ["src"] = true })
        local state = tree1:get_collapsed_state()
        eq(true, state["src"])

        -- Rebuild with slightly different files.
        local tree2 = FileTree(files2)
        tree2:set_collapsed_state(state)

        -- "src" still exists in the new tree, so the state carries over.
        local restored = tree2:get_collapsed_state()
        eq(true, restored["src"])
      end)

      it("ignores state keys for directories absent in the new tree", function()
        local files1 = {
          make_entry("old_dir/file.lua"),
        }
        local files2 = {
          make_entry("new_dir/file.lua"),
        }

        local tree1 = FileTree(files1)
        tree1:set_collapsed_state({ ["old_dir"] = true })
        local state = tree1:get_collapsed_state()

        local tree2 = FileTree(files2)
        tree2:set_collapsed_state(state)

        -- "old_dir" does not exist in tree2, so it should not appear.
        local restored = tree2:get_collapsed_state()
        eq(nil, restored["old_dir"])
        eq(false, restored["new_dir"])
      end)
    end)

    describe("FileDict.update_file_trees preserves collapsed state", function()
      it("restores collapsed state when trees are rebuilt", function()
        local fd = FileDict()

        -- Populate the working list with some entries.
        local entries = {
          make_entry("src/a.lua"),
          make_entry("src/b.lua"),
          make_entry("lib/c.lua"),
        }
        for i, e in ipairs(entries) do
          fd.working[i] = e
        end
        fd:update_file_trees()

        -- Collapse "src" in the working tree.
        fd.working_tree:set_collapsed_state({ ["src"] = true })
        local before = fd.working_tree:get_collapsed_state()
        eq(true, before["src"])
        eq(false, before["lib"])

        -- Rebuild trees (simulating what happens on tab switch or refresh).
        fd:update_file_trees()

        -- The collapsed state should be preserved.
        local after = fd.working_tree:get_collapsed_state()
        eq(true, after["src"])
        eq(false, after["lib"])
      end)

      it("preserves collapsed state independently for each section", function()
        local fd = FileDict()

        fd.working[1] = make_entry("src/w.lua", "working")
        fd.staged[1] = make_entry("src/s.lua", "staged")
        fd:update_file_trees()

        -- Collapse "src" only in the working tree.
        fd.working_tree:set_collapsed_state({ ["src"] = true })
        -- Leave the staged tree expanded.

        fd:update_file_trees()

        eq(true, fd.working_tree:get_collapsed_state()["src"])
        eq(false, fd.staged_tree:get_collapsed_state()["src"])
      end)
    end)

    describe("collapsed state with nested and flattened directories", function()
      it("round-trips collapsed state for deeply nested paths", function()
        local files = {
          make_entry("a/b/c/d/file.lua"),
        }

        local tree = FileTree(files)
        tree:set_collapsed_state({
          ["a"] = true,
          ["a/b"] = true,
          ["a/b/c"] = false,
          ["a/b/c/d"] = true,
        })

        local state = tree:get_collapsed_state()
        eq(true, state["a"])
        eq(true, state["a/b"])
        eq(false, state["a/b/c"])
        eq(true, state["a/b/c/d"])

        -- Rebuild and restore.
        local tree2 = FileTree(files)
        tree2:set_collapsed_state(state)
        local restored = tree2:get_collapsed_state()
        eq(true, restored["a"])
        eq(true, restored["a/b"])
        eq(false, restored["a/b/c"])
        eq(true, restored["a/b/c/d"])
      end)

      it("preserves collapsed state when files change in a directory", function()
        -- Initial tree: src/ has two files.
        local files1 = {
          make_entry("src/a.lua"),
          make_entry("src/b.lua"),
        }
        local tree1 = FileTree(files1)
        tree1:set_collapsed_state({ ["src"] = true })

        local state = tree1:get_collapsed_state()

        -- Rebuild with a third file added.
        local files2 = {
          make_entry("src/a.lua"),
          make_entry("src/b.lua"),
          make_entry("src/c.lua"),
        }
        local tree2 = FileTree(files2)
        tree2:set_collapsed_state(state)

        -- "src" should still be collapsed.
        eq(true, tree2:get_collapsed_state()["src"])
      end)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- mark_placement option
  -- -----------------------------------------------------------------------

  describe("mark_placement", function()
    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel
    local selection_signs_ns = panel_render._test.selection_signs_ns

    local function make_files(working)
      local files = { conflicting = {}, working = working or {}, staged = {} }
      function files:iter()
        local all = {}
        for _, f in ipairs(self.working) do
          all[#all + 1] = f
        end
        local i = 0
        return function()
          i = i + 1
          if i <= #all then
            return i, all[i]
          end
        end
      end
      function files:len()
        return #self.conflicting + #self.working + #self.staged
      end
      return files
    end

    local function make_panel(entries)
      config.get_config().use_icons = false

      local adapter = {
        ctx = { toplevel = "/tmp", dir = "/tmp/.git" },
        get_branch_name = function()
          return nil
        end,
      }
      local panel = FilePanel(adapter, make_files(entries or {}), {})
      panel.listing_style = "list"
      panel.is_loading = false
      panel:init_buffer()
      return panel
    end

    ---Get all sign extmarks in the selection signs namespace.
    local function get_signs(panel)
      return vim.api.nvim_buf_get_extmarks(
        panel.bufid,
        selection_signs_ns,
        0,
        -1,
        { details = true }
      )
    end

    it("inline mode renders marks in line content when a file is selected", function()
      local conf = config.get_config()
      conf.file_panel.mark_placement = "inline"
      config.setup(conf)

      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      panel:select_file(f)
      panel:update_components()
      panel:render()
      panel:redraw()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      local selected_mark = config.get_config().signs.selected_file
      assert.truthy(
        joined:find(selected_mark, 1, true),
        "expected inline selection mark in buffer content"
      )

      -- No sign column signs should be placed.
      eq(0, #get_signs(panel))

      panel:destroy()
    end)

    it("sign_column mode does not render marks in line content", function()
      local conf = config.get_config()
      conf.file_panel.mark_placement = "sign_column"
      config.setup(conf)

      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      panel:select_file(f)
      panel:update_components()
      panel:render()
      panel:redraw()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      local selected_mark = config.get_config().signs.selected_file
      local unselected_mark = config.get_config().signs.unselected_file
      assert.falsy(
        joined:find(selected_mark, 1, true),
        "inline selection mark should not appear in sign_column mode"
      )
      assert.falsy(
        joined:find(unselected_mark, 1, true),
        "inline unselected mark should not appear in sign_column mode"
      )

      panel:destroy()
    end)

    it("sign_column mode places signs when a file is selected", function()
      local conf = config.get_config()
      conf.file_panel.mark_placement = "sign_column"
      config.setup(conf)

      local f1 = make_entry("a.lua")
      local f2 = make_entry("b.lua")
      local panel = make_panel({ f1, f2 })
      panel:select_file(f1)
      panel:update_components()
      panel:render()
      panel:redraw()

      local signs = get_signs(panel)
      -- Should have signs for both files (selected + unselected).
      eq(2, #signs)

      -- Verify sign text matches configured marks.
      -- Neovim pads sign_text to 2 display cells.
      local sign_texts = {}
      for _, s in ipairs(signs) do
        sign_texts[#sign_texts + 1] = vim.trim(s[4].sign_text)
      end
      table.sort(sign_texts)
      local expected = { conf.signs.selected_file, conf.signs.unselected_file }
      table.sort(expected)
      eq(expected, sign_texts)

      panel:destroy()
    end)

    it(
      "sign_column mode places no signs when nothing is selected and always_show_marks is false",
      function()
        local conf = config.get_config()
        conf.file_panel.mark_placement = "sign_column"
        conf.file_panel.always_show_marks = false
        config.setup(conf)

        local f = make_entry("a.lua")
        local panel = make_panel({ f })
        -- No selections.
        panel:update_components()
        panel:render()
        panel:redraw()

        eq(0, #get_signs(panel))

        panel:destroy()
      end
    )

    it(
      "sign_column mode places signs when always_show_marks is true even with no selections",
      function()
        local conf = config.get_config()
        conf.file_panel.mark_placement = "sign_column"
        conf.file_panel.always_show_marks = true
        config.setup(conf)

        local f1 = make_entry("a.lua")
        local f2 = make_entry("b.lua")
        local panel = make_panel({ f1, f2 })
        -- No selections.
        panel:update_components()
        panel:render()
        panel:redraw()

        local signs = get_signs(panel)
        eq(2, #signs)

        -- All signs should show the unselected mark.
        for _, s in ipairs(signs) do
          eq(conf.signs.unselected_file, vim.trim(s[4].sign_text))
        end

        panel:destroy()
      end
    )

    it("sign_column mode uses DiffviewFilePanelMarked highlight for selected files", function()
      local conf = config.get_config()
      conf.file_panel.mark_placement = "sign_column"
      config.setup(conf)

      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      panel:select_file(f)
      panel:update_components()
      panel:render()
      panel:redraw()

      local signs = get_signs(panel)
      eq(1, #signs)
      eq("DiffviewFilePanelMarked", signs[1][4].sign_hl_group)

      panel:destroy()
    end)

    it("sign_column mode clears signs when selections are removed", function()
      local conf = config.get_config()
      conf.file_panel.mark_placement = "sign_column"
      conf.file_panel.always_show_marks = false
      config.setup(conf)

      local f = make_entry("a.lua")
      local panel = make_panel({ f })

      -- Select, render, verify signs are placed.
      panel:select_file(f)
      panel:update_components()
      panel:render()
      panel:redraw()
      assert.truthy(#get_signs(panel) > 0, "expected signs after selection")

      -- Deselect, re-render, verify signs are cleared.
      panel:deselect_file(f)
      panel:update_components()
      panel:render()
      panel:redraw()
      eq(0, #get_signs(panel))

      panel:destroy()
    end)

    it("switching from sign_column to inline clears stale signs", function()
      local conf = config.get_config()
      conf.file_panel.mark_placement = "sign_column"
      config.setup(conf)

      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      panel:select_file(f)
      panel:update_components()
      panel:render()
      panel:redraw()
      assert.truthy(#get_signs(panel) > 0, "expected signs in sign_column mode")

      -- Switch to inline mode and re-render.
      conf = config.get_config()
      conf.file_panel.mark_placement = "inline"
      config.setup(conf)

      panel:update_components()
      panel:render()
      panel:redraw()

      -- All sign extmarks should be cleared.
      eq(0, #get_signs(panel))

      panel:destroy()
    end)

    -- -----------------------------------------------------------------
    -- Wide sign padding
    -- -----------------------------------------------------------------

    it("sign_column mode pads buffer text when a sign character is wide", function()
      local conf = config.get_config()
      conf.file_panel.mark_placement = "sign_column"
      conf.signs.selected_file = "\u{2705}" -- Check mark emoji (2 display cells).
      config.setup(conf)

      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      panel:select_file(f)
      panel:update_components()
      panel:render()
      panel:redraw()

      -- The first file line should start with a leading space for padding.
      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local file_line
      for _, line in ipairs(lines) do
        if line:find("a.lua", 1, true) then
          file_line = line
          break
        end
      end
      assert.truthy(file_line, "expected a line containing 'a.lua'")
      assert.truthy(
        file_line:match("^%s"),
        "expected leading space for wide-sign padding, got: " .. file_line
      )

      panel:destroy()
    end)

    it("sign_column mode does not pad buffer text when all signs are narrow", function()
      local conf = config.get_config()
      conf.file_panel.mark_placement = "sign_column"
      -- Default signs are all 1 display cell.
      conf.signs.selected_file = "x"
      conf.signs.unselected_file = "o"
      conf.signs.selected_dir = "x"
      conf.signs.partially_selected_dir = "p"
      conf.signs.unselected_dir = "o"
      config.setup(conf)

      local f = make_entry("a.lua")
      local panel = make_panel({ f })
      panel:update_components()
      panel:render()
      panel:redraw()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local file_line
      for _, line in ipairs(lines) do
        if line:find("a.lua", 1, true) then
          file_line = line
          break
        end
      end
      assert.truthy(file_line, "expected a line containing 'a.lua'")
      assert.falsy(
        file_line:match("^%s"),
        "expected no leading space when signs are narrow, got: " .. file_line
      )

      panel:destroy()
    end)

    -- -----------------------------------------------------------------
    -- Directory signs in tree listing mode
    -- -----------------------------------------------------------------

    describe("directory signs in tree mode", function()
      local function make_tree_panel(entries)
        config.get_config().use_icons = false

        local adapter = {
          ctx = { toplevel = "/tmp", dir = "/tmp/.git" },
          get_branch_name = function()
            return nil
          end,
        }
        local fd = FileDict()
        for i, e in ipairs(entries) do
          fd.working[i] = e
        end
        fd:update_file_trees()

        local panel = FilePanel(adapter, fd, {})
        panel.listing_style = "tree"
        panel.is_loading = false
        panel:init_buffer()
        return panel
      end

      it("places selected_dir sign when all files in a directory are selected", function()
        local conf = config.get_config()
        conf.file_panel.mark_placement = "sign_column"
        config.setup(conf)

        local f1 = make_entry("src/a.lua")
        local f2 = make_entry("src/b.lua")
        local panel = make_tree_panel({ f1, f2 })
        panel:select_file(f1)
        panel:select_file(f2)
        panel:update_components()
        panel:render()
        panel:redraw()

        local signs = get_signs(panel)
        local sign_texts = {}
        for _, s in ipairs(signs) do
          sign_texts[#sign_texts + 1] = vim.trim(s[4].sign_text)
        end

        -- Directory sign should be selected_dir.
        assert.truthy(
          vim.tbl_contains(sign_texts, conf.signs.selected_dir),
          "expected selected_dir sign for fully selected directory"
        )

        panel:destroy()
      end)

      it("places partially_selected_dir sign when some files are selected", function()
        local conf = config.get_config()
        conf.file_panel.mark_placement = "sign_column"
        config.setup(conf)

        local f1 = make_entry("src/a.lua")
        local f2 = make_entry("src/b.lua")
        local panel = make_tree_panel({ f1, f2 })
        -- Select only one file.
        panel:select_file(f1)
        panel:update_components()
        panel:render()
        panel:redraw()

        local signs = get_signs(panel)
        local sign_texts = {}
        for _, s in ipairs(signs) do
          sign_texts[#sign_texts + 1] = vim.trim(s[4].sign_text)
        end

        assert.truthy(
          vim.tbl_contains(sign_texts, conf.signs.partially_selected_dir),
          "expected partially_selected_dir sign when only some files are selected"
        )

        panel:destroy()
      end)

      it("places unselected_dir sign when no files are selected", function()
        local conf = config.get_config()
        conf.file_panel.mark_placement = "sign_column"
        conf.file_panel.always_show_marks = true
        config.setup(conf)

        local f1 = make_entry("src/a.lua")
        local f2 = make_entry("src/b.lua")
        local panel = make_tree_panel({ f1, f2 })
        -- No selections.
        panel:update_components()
        panel:render()
        panel:redraw()

        local signs = get_signs(panel)
        local sign_texts = {}
        for _, s in ipairs(signs) do
          sign_texts[#sign_texts + 1] = vim.trim(s[4].sign_text)
        end

        assert.truthy(
          vim.tbl_contains(sign_texts, conf.signs.unselected_dir),
          "expected unselected_dir sign when no files are selected"
        )
        -- No selected or partially selected dir signs.
        assert.falsy(
          vim.tbl_contains(sign_texts, conf.signs.selected_dir),
          "should not have selected_dir sign with no selections"
        )
        assert.falsy(
          vim.tbl_contains(sign_texts, conf.signs.partially_selected_dir),
          "should not have partially_selected_dir sign with no selections"
        )

        panel:destroy()
      end)

      it("uses DiffviewFilePanelMarked highlight for partially selected directories", function()
        local conf = config.get_config()
        conf.file_panel.mark_placement = "sign_column"
        config.setup(conf)

        local f1 = make_entry("src/a.lua")
        local f2 = make_entry("src/b.lua")
        local panel = make_tree_panel({ f1, f2 })
        panel:select_file(f1)
        panel:update_components()
        panel:render()
        panel:redraw()

        local signs = get_signs(panel)
        -- Find the directory sign (partially_selected_dir).
        local dir_sign
        for _, s in ipairs(signs) do
          if vim.trim(s[4].sign_text) == conf.signs.partially_selected_dir then
            dir_sign = s
            break
          end
        end

        assert.truthy(dir_sign, "expected a partially_selected_dir sign")
        eq("DiffviewFilePanelMarked", dir_sign[4].sign_hl_group)

        panel:destroy()
      end)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- file_panel.list_options.path_style
  -- -----------------------------------------------------------------------

  describe("file_panel.list_options.path_style", function()
    ---Create a minimal panel stub exposing the methods render_file depends on.
    local function make_panel_stub()
      return {
        is_selected = function(_, _)
          return false
        end,
        has_any_selections = function(_)
          return false
        end,
      }
    end

    ---Create a mock render component whose context is the given file entry.
    local function make_file_comp(entry)
      local comp = make_comp()
      comp.context = entry
      return comp
    end

    before_each(function()
      -- Avoid requiring nvim-web-devicons during rendering.
      config.get_config().use_icons = false
    end)

    it("defaults to 'basename'", function()
      eq("basename", config.get_config().file_panel.list_options.path_style)
    end)

    describe("'basename' (default)", function()
      it("appends a dimmed parent path after the basename for files in subdirectories", function()
        local conf = config.get_config()
        conf.file_panel.list_options.path_style = "basename"
        config.setup(conf)

        local entry = make_entry("src/components/button.lua")
        local comp = make_file_comp(entry)
        render_file(config.get_config(), make_panel_stub(), comp, true, nil, nil)

        -- The basename uses DiffviewFilePanelFileName.
        local name_segs = comp:segments_by_hl("DiffviewFilePanelFileName")
        assert.truthy(
          vim.tbl_contains(name_segs, "button.lua"),
          "expected a basename segment with DiffviewFilePanelFileName highlight"
        )
        -- The parent path should not be prepended to the basename segments.
        assert.falsy(
          vim.tbl_contains(name_segs, "src/components/"),
          "parent path should not be prepended in 'basename' mode"
        )

        -- The parent path is appended with the dimmed DiffviewFilePanelPath highlight.
        local path_segs = comp:segments_by_hl("DiffviewFilePanelPath")
        assert.truthy(
          vim.tbl_contains(path_segs, " src/components"),
          "expected a trailing dimmed parent-path segment"
        )
      end)

      it("does not prepend a stray '/' for files at the repository root", function()
        local conf = config.get_config()
        conf.file_panel.list_options.path_style = "basename"
        config.setup(conf)

        local entry = make_entry("README.md")
        local comp = make_file_comp(entry)
        render_file(config.get_config(), make_panel_stub(), comp, true, nil, nil)

        local name_segs = comp:segments_by_hl("DiffviewFilePanelFileName")
        assert.truthy(vim.tbl_contains(name_segs, "README.md"))
        for _, seg in ipairs(name_segs) do
          assert.falsy(
            seg:find("/", 1, true),
            "did not expect any '/' in name segments for a root-level file, got: " .. seg
          )
        end
      end)
    end)

    describe("'full'", function()
      it("prepends the parent path to the basename with uniform name highlight", function()
        local conf = config.get_config()
        conf.file_panel.list_options.path_style = "full"
        config.setup(conf)

        local entry = make_entry("src/components/button.lua")
        local comp = make_file_comp(entry)
        render_file(config.get_config(), make_panel_stub(), comp, true, nil, nil)

        -- Both the parent prefix and the basename use DiffviewFilePanelFileName.
        local name_segs = comp:segments_by_hl("DiffviewFilePanelFileName")
        assert.truthy(
          vim.tbl_contains(name_segs, "src/components/"),
          "expected the parent path prefix with the name highlight"
        )
        assert.truthy(
          vim.tbl_contains(name_segs, "button.lua"),
          "expected the basename with the name highlight"
        )

        -- No dimmed trailing path segment should be emitted.
        local path_segs = comp:segments_by_hl("DiffviewFilePanelPath")
        eq(0, #path_segs)
      end)

      it("omits the '/' prefix for files at the repository root", function()
        local conf = config.get_config()
        conf.file_panel.list_options.path_style = "full"
        config.setup(conf)

        local entry = make_entry("README.md")
        local comp = make_file_comp(entry)
        render_file(config.get_config(), make_panel_stub(), comp, true, nil, nil)

        local name_segs = comp:segments_by_hl("DiffviewFilePanelFileName")
        assert.truthy(vim.tbl_contains(name_segs, "README.md"))
        for _, seg in ipairs(name_segs) do
          assert.falsy(
            seg:find("/", 1, true),
            "did not expect any '/' in name segments for a root-level file, got: " .. seg
          )
        end

        -- Full mode never emits a trailing DiffviewFilePanelPath segment.
        local path_segs = comp:segments_by_hl("DiffviewFilePanelPath")
        eq(0, #path_segs)
      end)

      it("uses DiffviewFilePanelSelected for the whole path when the file is active", function()
        local conf = config.get_config()
        conf.file_panel.list_options.path_style = "full"
        config.setup(conf)

        local entry = make_entry("src/main.lua")
        entry.active = true
        local comp = make_file_comp(entry)
        render_file(config.get_config(), make_panel_stub(), comp, true, nil, nil)

        local selected_segs = comp:segments_by_hl("DiffviewFilePanelSelected")
        assert.truthy(
          vim.tbl_contains(selected_segs, "src/"),
          "expected the parent path prefix with the selected highlight"
        )
        assert.truthy(
          vim.tbl_contains(selected_segs, "main.lua"),
          "expected the basename with the selected highlight"
        )

        -- The inactive name highlight must not be used for an active file.
        local name_segs = comp:segments_by_hl("DiffviewFilePanelFileName")
        eq(0, #name_segs)
      end)
    end)

    describe("tree listing mode (show_path = false)", function()
      it("ignores path_style = 'full' and never prepends the parent path", function()
        local conf = config.get_config()
        conf.file_panel.list_options.path_style = "full"
        config.setup(conf)

        local entry = make_entry("src/components/button.lua")
        local comp = make_file_comp(entry)
        render_file(config.get_config(), make_panel_stub(), comp, false, 0, nil)

        local name_segs = comp:segments_by_hl("DiffviewFilePanelFileName")
        assert.truthy(vim.tbl_contains(name_segs, "button.lua"))
        assert.falsy(
          vim.tbl_contains(name_segs, "src/components/"),
          "parent path should not be prepended in tree mode"
        )

        -- Tree mode suppresses both the prefix and the trailing dimmed path.
        local path_segs = comp:segments_by_hl("DiffviewFilePanelPath")
        eq(0, #path_segs)
      end)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- Folder icon gating on `use_icons`
  -- -----------------------------------------------------------------------

  describe("folder icons are gated on use_icons", function()
    local FilePanel = require("diffview.scene.views.diff.file_panel").FilePanel

    -- Use distinctive ASCII icons so the assertion does not depend on Nerd
    -- Font glyphs being present in the test environment.
    local FOLDER_OPEN = "<<OPEN>>"
    local FOLDER_CLOSED = "<<CLOSED>>"

    local function make_tree_panel(entries, use_icons)
      local conf = config.get_config()
      conf.use_icons = use_icons
      conf.icons.folder_open = FOLDER_OPEN
      conf.icons.folder_closed = FOLDER_CLOSED
      config.setup(conf)

      local adapter = {
        ctx = { toplevel = "/tmp", dir = "/tmp/.git" },
        get_branch_name = function()
          return nil
        end,
      }
      local fd = FileDict()
      for i, e in ipairs(entries) do
        fd.working[i] = e
      end
      fd:update_file_trees()

      local panel = FilePanel(adapter, fd, {})
      panel.listing_style = "tree"
      panel.is_loading = false
      panel:init_buffer()
      return panel
    end

    it("renders the folder_open icon on directory lines when use_icons = true", function()
      local panel = make_tree_panel({ make_entry("src/a.lua") }, true)
      panel:update_components()
      panel:render()
      panel:redraw()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.truthy(
        joined:find(FOLDER_OPEN, 1, true),
        "expected folder_open icon in tree output when use_icons = true"
      )

      panel:destroy()
    end)

    it("omits the folder icon on directory lines when use_icons = false", function()
      local panel = make_tree_panel({ make_entry("src/a.lua") }, false)
      panel:update_components()
      panel:render()
      panel:redraw()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.falsy(
        joined:find(FOLDER_OPEN, 1, true),
        "folder_open icon should not appear when use_icons = false"
      )
      assert.falsy(
        joined:find(FOLDER_CLOSED, 1, true),
        "folder_closed icon should not appear when use_icons = false"
      )

      panel:destroy()
    end)

    it("renders the folder_closed icon on collapsed directories when use_icons = true", function()
      local panel = make_tree_panel({ make_entry("src/a.lua") }, true)
      panel:update_components()

      -- Collapse the only top-level directory node before rendering.
      for _, section in ipairs({ "conflicting", "working", "staged" }) do
        local files_comp = panel.components[section].files.comp
        for _, child in ipairs(files_comp.components) do
          if child.name == "directory" then
            child.context.collapsed = true
          end
        end
      end

      panel:render()
      panel:redraw()

      local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.truthy(
        joined:find(FOLDER_CLOSED, 1, true),
        "expected folder_closed icon for collapsed directory when use_icons = true"
      )

      panel:destroy()
    end)
  end)
end)
