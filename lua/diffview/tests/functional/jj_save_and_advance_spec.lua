-- End-to-end: `s`/`-` on a jj working-copy conflict resolves the current
-- entry and either advances or drains the `conflicting` bucket. Exercises
-- the full listener chain (refresh, callback, advance) that unit tests
-- in `actions_spec.lua` / `jj_adapter_spec.lua` do not cover.
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")

local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local EventEmitter = require("diffview.events").EventEmitter
local JjAdapter = require("diffview.vcs.adapters.jj").JjAdapter

local function jj_available()
  return vim.fn.executable("jj") == 1
end

local function run(cmd, cwd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert.equals(0, res.code, (table.concat(cmd, " ") .. "\n" .. (res.stderr or "")))
  return vim.trim(res.stdout or "")
end

-- Build a 2-parent merge that conflicts on every path in `filenames`. Returns
-- the workspace directory and a `write(relpath, content)` helper.
local function make_conflict_repo(filenames)
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  run({ "jj", "git", "init" }, repo)
  run({ "jj", "config", "set", "--repo", "user.name", "Test" }, repo)
  run({ "jj", "config", "set", "--repo", "user.email", "test@test.com" }, repo)

  local function write(relpath, content)
    local dir = vim.fn.fnamemodify(repo .. "/" .. relpath, ":h")
    vim.fn.mkdir(dir, "p")
    local f = assert(io.open(repo .. "/" .. relpath, "w"))
    f:write(content)
    f:close()
  end

  for _, name in ipairs(filenames) do
    write(name, "base\n")
  end
  run({ "jj", "describe", "-m", "initial" }, repo)
  local base_id = run({ "jj", "log", "-r", "@", "--no-graph", "-T", "change_id.short()" }, repo)

  run({ "jj", "new", "-m", "left" }, repo)
  for _, name in ipairs(filenames) do
    write(name, "left\n")
  end
  local ours_id = run({ "jj", "log", "-r", "@", "--no-graph", "-T", "change_id.short()" }, repo)

  run({ "jj", "new", base_id, "-m", "right" }, repo)
  for _, name in ipairs(filenames) do
    write(name, "right\n")
  end
  local theirs_id = run({ "jj", "log", "-r", "@", "--no-graph", "-T", "change_id.short()" }, repo)

  run({ "jj", "new", ours_id, theirs_id, "-m", "merge" }, repo)

  return repo, write
end

describe("`toggle_stage_entry` on a jj working-copy conflict", function()
  local orig_emitter, original_config, saved_bootstrap

  before_each(function()
    if not jj_available() then
      pending("jj not installed")
      return
    end
    orig_emitter = DiffviewGlobal.emitter
    DiffviewGlobal.emitter = EventEmitter()
    original_config = vim.deepcopy(config.get_config())
    config.get_config().use_icons = false
    -- Disable auto-close so the tab survives long enough for post-resolve assertions.
    config.get_config().auto_close_on_empty = false
    saved_bootstrap = vim.deepcopy(JjAdapter.bootstrap)
    JjAdapter.bootstrap.done = true
    JjAdapter.bootstrap.ok = true
  end)

  after_each(function()
    if orig_emitter then
      DiffviewGlobal.emitter = orig_emitter
    end
    if original_config then
      config.setup(original_config)
    end
    if saved_bootstrap then
      JjAdapter.bootstrap = saved_bootstrap
    end
  end)

  local function open_view(repo)
    local adapter = JjAdapter({ toplevel = repo, path_args = {} })
    local left, right = adapter:parse_revs(nil, {})
    assert.is_not_nil(left)
    assert.is_not_nil(right)

    local view = DiffView({
      adapter = adapter,
      rev_arg = nil,
      path_args = {},
      left = left,
      right = right,
      options = {},
    })
    view:open()
    return view
  end

  it("drains the `conflicting` bucket after the sole conflict is resolved", function()
    local repo, write = make_conflict_repo({ "file.txt" })
    local view

    local ok, err = pcall(function()
      view = open_view(repo)
      -- `view.ready` flips after the initial `post_open` dispatch, not after
      -- `update_files` populates the panel. Wait for the conflict entries
      -- (which arrive via the async `tracked_files` -> `_query_merge_context`
      -- pipeline) before asserting on them.
      assert.is_true(
        vim.wait(5000, function()
          return view.ready and #view.files.conflicting > 0
        end),
        "view never surfaced conflict entries"
      )
      assert.is_not_nil(view.cur_entry)
      assert.is_not_nil(view.merge_ctx)
      assert.equals(1, #view.files.conflicting)
      assert.equals("file.txt", view.files.conflicting[1].path)
      assert.equals("conflicting", view.cur_entry.kind)

      -- Resolve on disk; MERGED buffer stays unmodified so this covers the
      -- "already clean" branch where refresh alone must drop the entry.
      write("file.txt", "resolved\n")

      view.emitter:emit("toggle_stage_entry")

      local drained = vim.wait(5000, function()
        return #view.files.conflicting == 0
      end)
      assert.is_true(drained, "conflicting bucket did not drain after `toggle_stage_entry`")
      assert.is_nil(view.merge_ctx)
    end)

    helpers.close_view(view)
    vim.schedule(function()
      pcall(vim.fn.delete, repo, "rf")
    end)
    if not ok then
      error(err)
    end
  end)

  it("resolves a propagated conflict where `@` is a linear descendant of the merge", function()
    local repo, write = make_conflict_repo({ "file.txt" })
    -- Step off the merge so `@` inherits the conflict via a single parent.
    -- This is the shape produced by `jj rebase` or a manual `jj new` after a
    -- merge, and the case that regressed `merge_ctx` detection before the
    -- nearest-ancestor-merge lookup landed.
    run({ "jj", "new", "-m", "child" }, repo)
    local view

    local ok, err = pcall(function()
      view = open_view(repo)
      -- `view.ready` flips after the initial `post_open` dispatch, not after
      -- `update_files` populates the panel. Wait for the conflict entries
      -- (which arrive via the async `tracked_files` -> `_query_merge_context`
      -- pipeline) before asserting on them.
      assert.is_true(
        vim.wait(5000, function()
          return view.ready and #view.files.conflicting > 0
        end),
        "view never surfaced conflict entries"
      )
      assert.is_not_nil(
        view.merge_ctx,
        "merge_ctx must resolve for a propagated conflict on a single-parent working copy"
      )
      assert.equals(1, #view.files.conflicting)
      assert.equals("file.txt", view.files.conflicting[1].path)
      assert.equals("conflicting", view.cur_entry.kind)

      write("file.txt", "resolved\n")
      view.emitter:emit("toggle_stage_entry")

      local drained = vim.wait(5000, function()
        return #view.files.conflicting == 0
      end)
      assert.is_true(drained, "conflicting bucket did not drain after `toggle_stage_entry`")
    end)

    helpers.close_view(view)
    vim.schedule(function()
      pcall(vim.fn.delete, repo, "rf")
    end)
    if not ok then
      error(err)
    end
  end)

  it("advances `cur_entry` to the remaining conflict after resolving one of two", function()
    local repo, write = make_conflict_repo({ "a.txt", "b.txt" })
    local view

    local ok, err = pcall(function()
      view = open_view(repo)
      -- `view.ready` flips after the initial `post_open` dispatch, not after
      -- `update_files` populates the panel. Wait for the conflict entries
      -- (which arrive via the async `tracked_files` -> `_query_merge_context`
      -- pipeline) before asserting on them.
      assert.is_true(
        vim.wait(5000, function()
          return view.ready and #view.files.conflicting > 0
        end),
        "view never surfaced conflict entries"
      )
      assert.is_not_nil(view.cur_entry)
      assert.equals(2, #view.files.conflicting)

      -- Resolve whichever entry `cur_entry` picked; avoids depending on FileDict order.
      local resolved_path = view.cur_entry.path
      local other_path = (resolved_path == "a.txt") and "b.txt" or "a.txt"
      write(resolved_path, "resolved\n")

      view.emitter:emit("toggle_stage_entry")

      local drained = vim.wait(5000, function()
        if #view.files.conflicting ~= 1 then
          return false
        end
        return view.files.conflicting[1].path == other_path
      end)
      assert.is_true(drained, "resolved entry did not leave the conflicting bucket")

      -- `set_file` is async, so poll for the advance rather than asserting synchronously.
      local advanced = vim.wait(2000, function()
        return view.cur_entry ~= nil and view.cur_entry.path == other_path
      end)
      assert.is_true(advanced, "cur_entry did not advance to the remaining conflict")
    end)

    helpers.close_view(view)
    vim.schedule(function()
      pcall(vim.fn.delete, repo, "rf")
    end)
    if not ok then
      error(err)
    end
  end)
end)
