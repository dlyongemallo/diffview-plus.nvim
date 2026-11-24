local helpers = require("diffview.tests.helpers")
local FileTree = require("diffview.ui.models.file_tree.file_tree").FileTree
local Node = require("diffview.ui.models.file_tree.node").Node

local eq = helpers.eq

---Create a minimal file entry stub.
---@param path string
---@param status? string
---@return table
local function make_entry(path, status)
  local parts = vim.split(path, "/")
  return {
    path = path,
    basename = parts[#parts],
    parent_path = table.concat(parts, "/", 1, math.max(#parts - 1, 0)),
    kind = "working",
    status = status or "M",
  }
end

---Collect `{ name = comp.name, context = comp.context }` for every leaf
---and directory component in a schema, depth first.
---@param schema table
---@param out? table
---@return table
local function flatten_schema(schema, out)
  out = out or {}
  for _, comp in ipairs(schema) do
    if comp.name == "file" then
      out[#out + 1] = { name = "file", context = comp.context }
    elseif comp.name == "directory" then
      out[#out + 1] = { name = "directory", context = comp.context }
      flatten_schema(comp[2], out)
    end
  end
  return out
end

describe("diffview.ui.models.file_tree.file_tree", function()
  describe("Node lookup key", function()
    it("defaults to the node name", function()
      local node = Node("foo")
      eq("foo", node.key)
    end)

    it("lets siblings share a name when their keys differ", function()
      local root = Node("__ROOT__")
      local file = root:add_child(Node("foo", { path = "foo" }))
      local dir = root:add_child(Node("foo", { name = "foo", path = "foo" }, "foo/"))

      assert.are_not.equal(file, dir)
      eq(2, #root.children)
      eq(file, root.children["foo"])
      eq(dir, root.children["foo/"])
    end)
  end)

  describe("file and directory with the same name", function()
    -- A diff can list both a path and entries below it. This happens e.g. when
    -- a directory is replaced by a symlink while the files it used to contain
    -- are deleted:
    --
    --   A  .claude/commands
    --   D  .claude/commands/commit.md
    --
    -- Previously the file node was reused as the parent of `commit.md`, so the
    -- renderer received a FileEntry where it expected DirData and crashed on
    -- `ctx.name` (resolving to the `Object:name()` class method).

    local orders = {
      ["file first"] = {
        make_entry(".claude/commands", "A"),
        make_entry(".claude/commands/commit.md", "D"),
      },
      ["directory first"] = {
        make_entry(".claude/commands/commit.md", "D"),
        make_entry(".claude/commands", "A"),
      },
    }

    for label, files in pairs(orders) do
      describe(label, function()
        it("keeps a separate leaf and directory node", function()
          local tree = FileTree(files)
          local claude = tree.root.children[".claude/"]
          assert.is_not_nil(claude)
          eq(2, #claude.children)

          local file = claude.children["commands"]
          local dir = claude.children["commands/"]
          assert.is_not_nil(file)
          assert.is_not_nil(dir)
          eq(false, file:has_children())
          eq(files[1].path == ".claude/commands" and files[1] or files[2], file.data)
          eq(true, dir:has_children())
          eq("commands", dir.data.name)
          eq(".claude/commands", dir.data.path)
          eq("commit.md", dir.children[1].name)
        end)

        it("builds a component schema with the expected contexts", function()
          local tree = FileTree(files)
          tree:update_statuses()
          local comps = flatten_schema(tree:create_comp_schema({ flatten_dirs = false }))

          local kinds = vim.tbl_map(function(c)
            return c.name
          end, comps)
          -- Directories sort before files: .claude/, commands/, commit.md, commands
          eq({ "directory", "directory", "file", "file" }, kinds)

          for _, c in ipairs(comps) do
            if c.name == "directory" then
              eq("string", type(c.context.name))
              eq("string", type(c.context.status))
            else
              eq("string", type(c.context.path))
            end
          end

          eq(".claude", comps[1].context.name)
          eq("commands", comps[2].context.name)
          eq(".claude/commands/commit.md", comps[3].context.path)
          eq(".claude/commands", comps[4].context.path)
        end)

        it("derives directory statuses from their children only", function()
          local tree = FileTree(files)
          tree:update_statuses()
          local claude = tree.root.children[".claude/"]
          eq("D", claude.children["commands/"].data.status)
          eq("M", claude.data.status)
        end)

        it("flattens through the directory without touching the file", function()
          local tree = FileTree(files)
          local comps = flatten_schema(tree:create_comp_schema({ flatten_dirs = true }))
          -- `.claude` has two children, so nothing is flattened at that level,
          -- and `commands/` has a single leaf child, which is never flattened.
          eq(".claude", comps[1].context.name)
          eq("commands", comps[2].context.name)
        end)
      end)
    end
  end)

  describe("regular trees", function()
    it("still deduplicates intermediate directories", function()
      local tree = FileTree({
        make_entry("src/a.lua"),
        make_entry("src/b.lua"),
        make_entry("src/sub/c.lua"),
      })
      local src = tree.root.children["src/"]
      eq(1, #tree.root.children)
      eq(3, #src.children)
      eq("c.lua", src.children["sub/"].children[1].name)
    end)

    it("ignores a duplicate file path", function()
      local tree = FileTree({ make_entry("a.lua"), make_entry("a.lua") })
      eq(1, #tree.root.children)
    end)
  end)
end)
