-- Regression: `View:open` waits for the scheduled entry setup so typeahead
-- after `:DiffviewOpen` on a conflict reaches the real file buffer with its
-- `Ndo` keymap attached (issue #262). Mirrors the `FileMergeView` case in
-- `file_merge_view_spec.lua` from the `DiffView` / git-adapter side.
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")

local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local EventEmitter = require("diffview.events").EventEmitter
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType

local run = helpers.run

local function make_conflict_repo()
  local repo = helpers.init_repo()
  local path = repo .. "/file.txt"
  local function write(content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  write("a\n")
  run({ "git", "add", "file.txt" }, repo)
  run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base" }, repo)

  -- `init.defaultBranch` may be `main` or `master`; read it back.
  local base_branch = run({ "git", "symbolic-ref", "--short", "HEAD" }, repo)

  run({ "git", "checkout", "-q", "-b", "ours" }, repo)
  write("c\n")
  run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-am", "ours" }, repo)
  run({ "git", "checkout", "-q", base_branch }, repo)
  run({ "git", "checkout", "-q", "-b", "theirs" }, repo)
  write("e\n")
  run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-am", "theirs" }, repo)
  run({ "git", "checkout", "-q", "ours" }, repo)
  run({ "git", "merge", "theirs" }, repo, { allow_nonzero = true })

  return repo
end

describe("DiffView:open (issue #262 race guard)", function()
  local orig_emitter, original_config

  before_each(function()
    orig_emitter = DiffviewGlobal.emitter
    DiffviewGlobal.emitter = EventEmitter()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
  end)

  after_each(function()
    DiffviewGlobal.emitter = orig_emitter
    config.setup(original_config)
  end)

  it("populates `cur_entry` and `ready` before returning on a git conflict", function()
    local repo = make_conflict_repo()
    local view

    local ok, err = pcall(function()
      view = DiffView({
        adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} }),
        rev_arg = nil,
        path_args = {},
        left = GitRev(RevType.STAGE, 0),
        right = GitRev(RevType.LOCAL),
        options = {},
      })
      view:open()
      assert.is_true(view.ready)
      assert.is_not_nil(view.cur_entry)
    end)

    helpers.close_view(view)
    helpers.cleanup_repo(repo)
    if not ok then
      error(err)
    end
  end)
end)
