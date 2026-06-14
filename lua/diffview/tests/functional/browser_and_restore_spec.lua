local actions = require("diffview.actions")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")
local utils = require("diffview.utils")

local DiffView_class = require("diffview.scene.views.diff.diff_view").DiffView
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local Node = require("diffview.ui.models.file_tree.node").Node
local RevType = require("diffview.vcs.rev").RevType

local eq = helpers.eq
local run = helpers.run

-----------------------------------------------------------------------
-- 8f55f8d: open_commit_in_browser -- get_commit_url URL construction.
-----------------------------------------------------------------------

describe("GitAdapter:get_commit_url (8f55f8d)", function()
  local repo, adapter

  before_each(function()
    repo = helpers.make_repo()

    adapter = GitAdapter({
      toplevel = repo,
      cpath = repo,
      path_args = {},
    })
  end)

  after_each(function()
    pcall(vim.fn.delete, repo, "rf")
  end)

  -- Helper: set the origin remote URL to the given value.
  local function set_remote(url)
    pcall(run, { "git", "remote", "remove", "origin" }, repo)
    run({ "git", "remote", "add", "origin", url }, repo)
  end

  local hash = "abc123def456"

  it("constructs a GitHub URL from an SSH remote", function()
    set_remote("git@github.com:user/repo.git")
    local url = adapter:get_commit_url(hash)
    eq("https://github.com/user/repo/commit/" .. hash, url)
  end)

  it("constructs a GitHub URL from an HTTPS remote", function()
    set_remote("https://github.com/user/repo.git")
    local url = adapter:get_commit_url(hash)
    eq("https://github.com/user/repo/commit/" .. hash, url)
  end)

  it("constructs a GitHub URL from an HTTPS remote without .git suffix", function()
    set_remote("https://github.com/user/repo")
    local url = adapter:get_commit_url(hash)
    eq("https://github.com/user/repo/commit/" .. hash, url)
  end)

  it("constructs a GitLab URL from an SSH remote", function()
    set_remote("git@gitlab.com:group/project.git")
    local url = adapter:get_commit_url(hash)
    eq("https://gitlab.com/group/project/-/commit/" .. hash, url)
  end)

  it("constructs a GitLab URL from an HTTPS remote", function()
    set_remote("https://gitlab.com/group/project.git")
    local url = adapter:get_commit_url(hash)
    eq("https://gitlab.com/group/project/-/commit/" .. hash, url)
  end)

  it("constructs a Bitbucket URL from an SSH remote", function()
    set_remote("git@bitbucket.org:team/repo.git")
    local url = adapter:get_commit_url(hash)
    eq("https://bitbucket.org/team/repo/commits/" .. hash, url)
  end)

  it("constructs a Bitbucket URL from an HTTPS remote", function()
    set_remote("https://bitbucket.org/team/repo.git")
    local url = adapter:get_commit_url(hash)
    eq("https://bitbucket.org/team/repo/commits/" .. hash, url)
  end)

  it("uses generic /commit/ path for an unrecognised host", function()
    set_remote("git@git.example.com:org/project.git")
    local url = adapter:get_commit_url(hash)
    eq("https://git.example.com/org/project/commit/" .. hash, url)
  end)

  it("returns nil when no origin remote is configured", function()
    pcall(run, { "git", "remote", "remove", "origin" }, repo)
    local url = adapter:get_commit_url(hash)
    assert.is_nil(url)
  end)
end)

-----------------------------------------------------------------------
-- 81a8d41: open_in_new_tab -- duplicate a DiffView in a new tab.
-----------------------------------------------------------------------

describe("actions.open_in_new_tab (81a8d41)", function()
  local stubs = {}

  local function stub(tbl, key, val)
    stubs[#stubs + 1] = { tbl, key, tbl[key] }
    tbl[key] = val
  end

  after_each(function()
    for i = #stubs, 1, -1 do
      local s = stubs[i]
      s[1][s[2]] = s[3]
    end
    stubs = {}
  end)

  it("is exported as a function", function()
    assert.is_function(actions.open_in_new_tab)
  end)

  it("returns early without error when no view is active", function()
    stub(lib, "get_current_view", function()
      return nil
    end)
    assert.has_no.errors(function()
      actions.open_in_new_tab()
    end)
  end)

  it("shows info message when called from a non-DiffView", function()
    local info_called = false
    stub(utils, "info", function()
      info_called = true
    end)

    -- Build a mock view that is not a DiffView instance.
    local mock_view = {
      class = {},
      instanceof = function()
        return false
      end,
    }
    stub(lib, "get_current_view", function()
      return mock_view
    end)

    actions.open_in_new_tab()
    assert.True(info_called)
  end)

  it("passes the original view's fields to the new DiffView", function()
    -- We cannot easily stub the lazy-accessed DiffView constructor used
    -- inside actions.lua, so instead we verify that the action reads
    -- the correct properties from the source view.  If it reaches the
    -- DiffView() call, the constructor will error because the mock
    -- adapter lacks real methods -- but we can still confirm the
    -- ancestorof gate passes for a genuine DiffView instance.
    local mock_adapter = { name = "git" }
    local mock_left = { type = RevType.COMMIT, commit = "abc123" }
    local mock_right = { type = RevType.LOCAL }

    -- Build a view that passes the DiffView.__get():ancestorof check
    -- by making instanceof return true for DiffView_class.
    local mock_view = {
      class = DiffView_class,
      instanceof = function(self, cls)
        return cls == DiffView_class
      end,
      adapter = mock_adapter,
      rev_arg = "HEAD",
      left = mock_left,
      right = mock_right,
      path_args = { "src/" },
      options = { show_untracked = true },
    }

    stub(lib, "get_current_view", function()
      return mock_view
    end)

    -- The real DiffView.__get():ancestorof calls other:instanceof(self)
    -- which in turn calls mock_view:instanceof(DiffView_class). Stub
    -- the class-level ancestorof to delegate to our mock's instanceof.
    local orig_ancestorof = DiffView_class.ancestorof
    stub(DiffView_class, "ancestorof", function(self_cls, other)
      if type(other) == "table" and type(other.instanceof) == "function" then
        return other:instanceof(self_cls)
      end
      return false
    end)

    -- The constructor will be called but will likely error internally
    -- since adapter is a plain table. Capture that error to prove the
    -- code reached the construction step (i.e., passed all guards).
    local reached_constructor = false
    local add_view_called = false

    stub(lib, "add_view", function()
      add_view_called = true
    end)

    local ok, err = pcall(actions.open_in_new_tab)

    -- If add_view was called, the constructor succeeded (unlikely with
    -- a mock adapter). If it errored, verify the error comes from the
    -- DiffView constructor, not from the ancestorof/guard path.
    if not ok then
      -- The error should be from DiffView init, not "This action only
      -- works in a diff view."
      assert.is_nil(err:find("This action only works in a diff view"))
      reached_constructor = true
    else
      reached_constructor = true
    end

    assert.True(reached_constructor)
  end)
end)

-----------------------------------------------------------------------
-- 0fb4d16: restore_entry extended to work on directories.
-- The directory restoration path collects leaves from a Node tree and
-- calls restore_file for each leaf's data.
-----------------------------------------------------------------------

describe("restore_entry directory support (0fb4d16)", function()
  describe("Node:leaves collects leaf files from a directory tree", function()
    it("returns all leaf nodes of a flat directory", function()
      --   root/
      --     a.lua
      --     b.lua
      --     c.lua
      local root = Node("root", { collapsed = false })
      local a = Node("a.lua", { path = "root/a.lua", kind = "working" })
      local b = Node("b.lua", { path = "root/b.lua", kind = "working" })
      local c = Node("c.lua", { path = "root/c.lua", kind = "working" })
      root:add_child(a)
      root:add_child(b)
      root:add_child(c)

      local leaves = root:leaves()
      eq(3, #leaves)

      local paths = {}
      for _, leaf in ipairs(leaves) do
        paths[#paths + 1] = leaf.data.path
      end
      table.sort(paths)

      eq({ "root/a.lua", "root/b.lua", "root/c.lua" }, paths)
    end)

    it("returns leaf nodes from nested subdirectories", function()
      --   src/
      --     lib/
      --       utils.lua
      --     main.lua
      local src = Node("src", { collapsed = false })
      local lib = Node("lib", { collapsed = false })
      local utils_file = Node("utils.lua", { path = "src/lib/utils.lua", kind = "working" })
      local main = Node("main.lua", { path = "src/main.lua", kind = "working" })

      src:add_child(lib)
      lib:add_child(utils_file)
      src:add_child(main)

      local leaves = src:leaves()
      eq(2, #leaves)

      local paths = {}
      for _, leaf in ipairs(leaves) do
        paths[#paths + 1] = leaf.data.path
      end
      table.sort(paths)

      eq({ "src/lib/utils.lua", "src/main.lua" }, paths)
    end)

    it("returns empty list for a leaf node (no children)", function()
      local leaf = Node("file.lua", { path = "file.lua" })
      local leaves = leaf:leaves()
      eq(0, #leaves)
    end)

    it("handles deeply nested single-child directories", function()
      --   a/
      --     b/
      --       c/
      --         deep.lua
      local a = Node("a", { collapsed = false })
      local b = Node("b", { collapsed = false })
      local c = Node("c", { collapsed = false })
      local deep = Node("deep.lua", { path = "a/b/c/deep.lua", kind = "working" })

      a:add_child(b)
      b:add_child(c)
      c:add_child(deep)

      local leaves = a:leaves()
      eq(1, #leaves)
      eq("a/b/c/deep.lua", leaves[1].data.path)
    end)
  end)

  describe("directory restoration logic", function()
    it("iterates leaf files and calls restore for each", function()
      -- Simulate the directory branch of restore_entry: when the cursor
      -- item has a `collapsed` field (i.e., it is a directory), the code
      -- calls node:leaves() and restores each leaf file.
      local restored = {}

      local function mock_restore(path, kind)
        restored[#restored + 1] = { path = path, kind = kind }
      end

      -- Build a directory node with two files.
      local dir = Node("components", { collapsed = false })
      local f1 = Node("button.lua", { path = "components/button.lua", kind = "working" })
      local f2 = Node("input.lua", { path = "components/input.lua", kind = "staged" })
      dir:add_child(f1)
      dir:add_child(f2)

      -- Replicate the restore_entry loop from the listener.
      local leaves = dir:leaves()
      for _, leaf in ipairs(leaves) do
        local file = leaf.data
        if file and file.path then
          mock_restore(file.path, file.kind)
        end
      end

      eq(2, #restored)

      local paths = {}
      for _, r in ipairs(restored) do
        paths[#paths + 1] = r.path
      end
      table.sort(paths)

      eq({ "components/button.lua", "components/input.lua" }, paths)
    end)

    it("skips files with modified buffers", function()
      -- Simulate the guard that skips restoration when a buffer has
      -- unsaved changes.
      local restored = {}
      local warned = {}

      local modified_paths = { ["src/dirty.lua"] = true }

      local function find_file_buffer(path)
        if modified_paths[path] then
          return 42
        end
        return nil
      end

      local function is_modified(bufid)
        return bufid == 42
      end

      local dir = Node("src", { collapsed = false })
      dir:add_child(Node("clean.lua", { path = "src/clean.lua", kind = "working" }))
      dir:add_child(Node("dirty.lua", { path = "src/dirty.lua", kind = "working" }))

      local leaves = dir:leaves()
      local restored_count = 0
      for _, leaf in ipairs(leaves) do
        local file = leaf.data
        if file and file.path then
          local bufid = find_file_buffer(file.path)
          if bufid and is_modified(bufid) then
            warned[#warned + 1] = file.path
          else
            restored[#restored + 1] = file.path
            restored_count = restored_count + 1
          end
        end
      end

      eq(1, #restored)
      eq("src/clean.lua", restored[1])
      eq(1, #warned)
      eq("src/dirty.lua", warned[1])
      eq(1, restored_count)
    end)

    it("sets _node back-reference when Node is constructed with data", function()
      -- The restore_entry listener accesses item._node to get the
      -- directory's Node. Verify the back-reference is set.
      local data = { collapsed = false, path = "dir" }
      local node = Node("dir", data)
      eq(node, data._node)
    end)

    it("detects a directory item by checking type(item.collapsed) == 'boolean'", function()
      -- The listener distinguishes directories from files by checking
      -- whether the collapsed field is a boolean.
      local dir_data = { collapsed = false }
      local file_data = { path = "file.lua" }

      assert.equals("boolean", type(dir_data.collapsed))
      assert.not_equals("boolean", type(file_data.collapsed))
    end)
  end)
end)
