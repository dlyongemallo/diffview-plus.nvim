local actions = require("diffview.actions")
local async = require("diffview.async")
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")

local DiffView = require("diffview.scene.views.diff.diff_view").DiffView
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local Diff2Ver = require("diffview.scene.layouts.diff_2_ver").Diff2Ver
local EventEmitter = require("diffview.events").EventEmitter
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType

local await = async.await
local run = helpers.run
local cleanup_repo = helpers.cleanup_repo
local close_view = helpers.close_view

-- Repo with a single modified file so a `DiffView` on STAGE..LOCAL yields
-- exactly one Diff2 entry to cycle.
local function make_repo()
  local repo = helpers.init_repo()
  local path = repo .. "/file.txt"

  local f = assert(io.open(path, "w"))
  f:write("line one\n")
  f:close()
  run({ "git", "add", "file.txt" }, repo)
  run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" }, repo)

  f = assert(io.open(path, "a"))
  f:write("line two\n")
  f:close()

  return repo
end

-- Count windows in the tabpage that aren't owned by the view's current
-- layout or its panel. Any surplus points at a leak from the swap.
local function count_orphans(view)
  local tabpage = view.tabpage
  local owned = {}
  for _, win in ipairs(view.cur_layout.windows) do
    owned[win.id] = true
  end
  if view.panel.winid then
    owned[view.panel.winid] = true
  end

  local orphans = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if not owned[w] then
      orphans = orphans + 1
    end
  end
  return orphans
end

describe("cycle_layout with view.winfixbuf (integration)", function()
  local orig_emitter, original_config

  before_each(function()
    orig_emitter = DiffviewGlobal.emitter
    DiffviewGlobal.emitter = EventEmitter()
    original_config = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    DiffviewGlobal.emitter = orig_emitter
    config.setup(original_config)
  end)

  -- Regression test for #336. With `view.winfixbuf = true`, every surviving
  -- diff window during the swap holds `winfixbuf`. `pivot_producer` used to
  -- build the pivot via `:1windo aboveleft vsp`, which under that condition
  -- creates two windows instead of one (`:windo` spawns a scratch alongside
  -- the vsplit when the target window is `winfixbuf`-locked). `create_wins`
  -- then closes only the pivot it was handed, leaving the scratch window
  -- orphaned next to the newly built layout.
  it(
    "leaves no orphan windows after `g<C-x>` with winfixbuf enabled",
    helpers.async_test(function()
      config.setup({
        use_icons = false,
        view = {
          winfixbuf = true,
          default = { layout = "diff2_horizontal", focus_diff = false },
          cycle_layouts = { default = { "diff2_horizontal", "diff2_vertical" } },
        },
      })

      local repo = make_repo()
      local view

      local ok, err = pcall(function()
        local adapter = GitAdapter({ toplevel = repo, cpath = repo, path_args = {} })
        view = DiffView({
          adapter = adapter,
          rev_arg = nil,
          path_args = {},
          left = GitRev(RevType.STAGE, 0),
          right = GitRev(RevType.LOCAL),
          options = {},
        })
        assert.is_true(view:is_valid())

        view:open()
        local loaded = vim.wait(3000, function()
          return view.initialized
        end, 10)
        assert.is_true(loaded, "view did not finish loading within 3s")

        if view._set_file_in_flight then
          await(view._set_file_in_flight)
        end

        assert.equals(Diff2Hor, view.cur_layout.class)
        assert.equals(0, count_orphans(view), "pre-cycle tabpage already had orphan windows")

        actions.cycle_layout()
        if view._set_file_in_flight then
          await(view._set_file_in_flight)
        end

        assert.equals(Diff2Ver, view.cur_layout.class)
        assert.equals(0, count_orphans(view), "cycle_layout left orphan windows behind (#336)")
      end)

      close_view(view)
      cleanup_repo(repo)
      if not ok then
        error(err)
      end
    end)
  )
end)
