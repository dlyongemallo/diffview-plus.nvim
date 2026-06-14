local Diff1InlinePinned = require("diffview.scene.layouts.diff_1_inline_pinned").Diff1InlinePinned
local Diff1Pinned = require("diffview.scene.layouts.diff_1_pinned").Diff1Pinned
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local Diff2HorPinned = require("diffview.scene.layouts.diff_2_hor_pinned").Diff2HorPinned
local Diff2VerPinned = require("diffview.scene.layouts.diff_2_ver_pinned").Diff2VerPinned
local FileEntry = require("diffview.scene.file_entry").FileEntry
local FileHistoryView =
  require("diffview.scene.views.file_history.file_history_view").FileHistoryView
local LogEntry = require("diffview.vcs.log_entry").LogEntry
local RevType = require("diffview.vcs.rev").RevType
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")

local eq = helpers.eq
local run = helpers.run

-- Build a tempdir git repo with a single committed file.
local function make_git_repo()
  local repo = helpers.init_repo()

  local f = assert(io.open(repo .. "/foo.txt", "w"))
  f:write("hello\n")
  f:close()

  run({ "git", "add", "foo.txt" }, repo)
  run({ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" }, repo)

  return repo
end

describe("pin_local config option", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("defaults to false on view.file_history", function()
    config.setup({})
    eq(false, config.get_config().view.file_history.pin_local)
  end)

  it("survives setup() when set to true", function()
    config.setup({ view = { file_history = { pin_local = true } } })
    eq(true, config.get_config().view.file_history.pin_local)
  end)
end)

describe("FileHistoryView:get_default_layout pinning", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  -- We need an instance only for the method dispatch; the class-level
  -- `pin_local` field, plus the layout config, is enough to drive the
  -- resolution path without opening any windows.
  local function inst(pin_local)
    return setmetatable({ pin_local = pin_local }, { __index = FileHistoryView })
  end

  it("returns the configured layout class when pin_local is unset", function()
    config.setup({ view = { file_history = { layout = "diff2_horizontal" } } })
    local v = inst(nil)

    eq("diff2_horizontal", v:get_default_layout().name)
  end)

  it("upgrades diff2_horizontal to Diff2HorPinned when pin_local is true", function()
    config.setup({ view = { file_history = { layout = "diff2_horizontal" } } })
    local v = inst(true)

    eq(Diff2HorPinned, v:get_default_layout())
  end)

  it("upgrades diff2_vertical to Diff2VerPinned when pin_local is true", function()
    config.setup({ view = { file_history = { layout = "diff2_vertical" } } })
    local v = inst(true)

    eq(Diff2VerPinned, v:get_default_layout())
  end)
end)

describe("lib.file_history --pin-local resolution", function()
  local original_err
  local err_messages

  before_each(function()
    err_messages = {}
    original_err = require("diffview.utils").err
    require("diffview.utils").err = function(msg)
      table.insert(err_messages, msg)
    end
  end)

  after_each(function()
    require("diffview.utils").err = original_err
  end)

  -- `--pin-local=false` exists so a per-invocation call can override a
  -- `pin_local = true` value set in the user's config. Without this, there's
  -- no way to opt out of the option from the CLI.
  it("clears config-set pin_local when --pin-local=false is passed", function()
    local original = vim.deepcopy(config.get_config())
    config.setup({ view = { file_history = { pin_local = true } } })
    local repo = make_git_repo()

    local ok, err = pcall(function()
      local cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      local view = lib.file_history(nil, { "--pin-local=false", "foo.txt" })

      vim.cmd("cd " .. vim.fn.fnameescape(cwd))

      assert.is_not_nil(view)
      eq(false, view.pin_local)
      eq(0, #err_messages)
      -- `lib.file_history` registers the view in `lib.views` without
      -- opening it; pop it directly so it doesn't leak into other tests.
      for i, v in ipairs(lib.views) do
        if v == view then
          table.remove(lib.views, i)
          break
        end
      end
    end)

    pcall(vim.fn.delete, repo, "rf")
    config.setup(original)
    if not ok then
      error(err)
    end
  end)

  it("enables pin_local when bare --pin-local is passed and config is unset", function()
    local repo = make_git_repo()

    local ok, err = pcall(function()
      local cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      local view = lib.file_history(nil, { "--pin-local", "foo.txt" })

      vim.cmd("cd " .. vim.fn.fnameescape(cwd))

      assert.is_not_nil(view)
      eq(true, view.pin_local)
      eq(0, #err_messages)
      for i, v in ipairs(lib.views) do
        if v == view then
          table.remove(lib.views, i)
          break
        end
      end
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)
end)

describe("FileHistoryView:_resolve_pinned_target", function()
  local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter

  local function make_adapter()
    local repo = make_git_repo()
    GitAdapter.bootstrap.done = true
    GitAdapter.bootstrap.ok = true
    return GitAdapter({ toplevel = repo, path_args = {} }), repo
  end

  -- Stub a FileHistoryView with the minimum state `_resolve_pinned_target`
  -- reads. We bypass the real constructor so we don't need to open windows.
  -- The default layout returned matches the real pin_local code path:
  -- `FileHistoryView:get_default_layout` upgrades to the pinned variant
  -- whenever `self.pin_local` is set.
  local function stub_view(adapter, pinned_path)
    return setmetatable({
      pin_local = true,
      pinned_path = pinned_path,
      adapter = adapter,
      -- The view's pin_local cache. `_resolve_pinned_target` builds overlays
      -- via `self:get_pinned_b_file(pinned_path)`, which lazily populates
      -- this map. Tests don't need the cache pre-seeded; they just need the
      -- table to exist so the inherited method can write into it.
      _pinned_b_files = {},
      get_default_layout = function()
        return Diff2HorPinned
      end,
    }, { __index = FileHistoryView })
  end

  -- Build a LogEntry whose FileEntries match what `parse_fh_data` produces
  -- under `pin_local == true`: revs.a = COMMIT (this commit), revs.b = LOCAL.
  local function stub_log_entry(adapter, paths)
    local commit = { hash = "abcdef0", subject = "stub" }
    local files = {}
    for _, p in ipairs(paths) do
      table.insert(
        files,
        FileEntry.with_layout(Diff2HorPinned, {
          adapter = adapter,
          path = p,
          status = "M",
          kind = "working",
          commit = commit,
          revs = {
            a = adapter.Rev(RevType.COMMIT, "0000000000000000000000000000000000000000"),
            b = adapter.Rev(RevType.LOCAL),
          },
        })
      )
    end
    return LogEntry({
      path_args = paths,
      commit = commit,
      files = files,
      single_file = #paths == 1,
    })
  end

  it("returns the matching FileEntry when the entry contains pinned_path", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      local view = stub_view(adapter, "foo.txt")
      local entry = stub_log_entry(adapter, { "bar.txt", "foo.txt", "baz.txt" })

      local target = view:_resolve_pinned_target(entry)
      assert.is_not_nil(target)
      eq("foo.txt", target.path)
      eq(target, entry.files[2])
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  it("falls back to files[1] when pinned_path is unset (bootstrap case)", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      local view = stub_view(adapter, nil)
      local entry = stub_log_entry(adapter, { "alpha.txt", "beta.txt" })

      local target = view:_resolve_pinned_target(entry)
      eq(target, entry.files[1])
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  it("builds an overlay FileEntry when the entry doesn't contain pinned_path", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      local view = stub_view(adapter, "missing.txt")
      local entry = stub_log_entry(adapter, { "foo.txt", "bar.txt" })

      local target = view:_resolve_pinned_target(entry)
      assert.is_not_nil(target)
      eq("missing.txt", target.path)
      eq(RevType.LOCAL, target.revs.b.type)
      eq("missing.txt", target.layout.b.file.path)
      assert.is_not_nil(entry._pin_overlays)
      eq(target, entry._pin_overlays["missing.txt"])
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  -- Multi-file entries are required to exercise the overlay path: single-file
  -- entries short-circuit to `files[1]` to handle rename-follow histories
  -- where the commit-side path differs from `pinned_path`.
  it("marks overlay status='D' when pinned_path doesn't exist at revs.a", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      adapter.file_blob_hash = function()
        return nil
      end
      local view = stub_view(adapter, "missing.txt")
      local entry = stub_log_entry(adapter, { "foo.txt", "bar.txt" })

      local target = view:_resolve_pinned_target(entry)
      eq("D", target.status)
      -- The pinned layout's `should_null` nulls the a-side for status "D"
      -- against a COMMIT rev (file is missing in the commit), so the
      -- adapter never has to `show <rev>:<missing>`.
      assert.is_true(target.layout.a.file.nulled)
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  it("keeps overlay status='M' when pinned_path exists at revs.a", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      adapter.file_blob_hash = function()
        return "deadbeefdeadbeefdeadbeefdeadbeef"
      end
      local view = stub_view(adapter, "missing.txt")
      local entry = stub_log_entry(adapter, { "foo.txt", "bar.txt" })

      local target = view:_resolve_pinned_target(entry)
      eq("M", target.status)
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  it("falls back to status='M' when the adapter has no file_exists_at_rev", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      -- Stub the abstract-stub raise so we exercise the pcall fallback path,
      -- guarding against third-party adapters that don't implement the probe.
      adapter.file_exists_at_rev = function()
        error("Unimplemented abstract method!")
      end
      local view = stub_view(adapter, "missing.txt")
      local entry = stub_log_entry(adapter, { "foo.txt", "bar.txt" })

      local target = view:_resolve_pinned_target(entry)
      eq("M", target.status)
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  -- Regression: in single-file `--pin-local <file>` history with renames,
  -- `entry.files[1].path` is the file's commit-side (old) name while
  -- `pinned_path` is the working-tree (current) name. Path matching alone
  -- would miss the entry, push us into the overlay path, and (without a
  -- blob in the rename's old commit) misclassify the file as deleted.
  -- `entry.single_file` short-circuits this: a single-file history's lone
  -- `FileEntry` is always the right target, regardless of path.
  it("returns files[1] for single-file entries even when the path differs (rename)", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      -- Sentinel hash: if the short-circuit is missing, the resolver will
      -- fall through to the overlay path and call `file_blob_hash`.
      local probed = false
      adapter.file_blob_hash = function()
        probed = true
        return nil
      end

      local view = stub_view(adapter, "current_name.txt")
      -- `single_file = true` (one path) with a different commit-side name
      -- to simulate `git log --follow` walking past a rename.
      local entry = stub_log_entry(adapter, { "old_name.txt" })

      local target = view:_resolve_pinned_target(entry)
      eq(target, entry.files[1])
      eq("old_name.txt", target.path)
      assert.is_false(probed)
      assert.is_nil(entry._pin_overlays)
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  it("returns the cached overlay on repeat calls for the same path", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      local view = stub_view(adapter, "missing.txt")
      local entry = stub_log_entry(adapter, { "foo.txt", "bar.txt" })

      local first = view:_resolve_pinned_target(entry)
      local second = view:_resolve_pinned_target(entry)
      eq(first, second)
      eq(first, entry._pin_overlays["missing.txt"])
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  -- Lazy overlay layout sync: a `set_layout` / `cycle_layout` after the
  -- overlay was built must not leave the overlay's layout class stale.
  -- Navigating back through `_resolve_pinned_target` should detect the
  -- mismatch with `view.cur_layout.class` and convert the overlay
  -- on-demand, so the user's chosen orientation isn't silently undone.
  it("converts a cached overlay's layout when the active class has changed", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      local view = stub_view(adapter, "missing.txt")
      local entry = stub_log_entry(adapter, { "foo.txt", "bar.txt" })

      -- First call builds the overlay with the stub's default
      -- (`Diff2HorPinned` from `stub_view.get_default_layout`).
      local first = view:_resolve_pinned_target(entry)
      assert.is_not_nil(first)
      eq(Diff2HorPinned, first.layout.class)

      -- Simulate a cycle to the vertical pinned variant.
      view.cur_layout = { class = Diff2VerPinned }

      local second = view:_resolve_pinned_target(entry)
      eq(first, second) -- same instance, just relayouted
      eq(Diff2VerPinned, second.layout.class)
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  it("LogEntry:destroy tears down cached overlays so panel rebuilds don't leak", function()
    local destroyed = {}
    ---@diagnostic disable-next-line: missing-fields
    local entry = LogEntry({
      path_args = {},
      commit = { hash = "abcdef0", subject = "stub" },
      files = {
        setmetatable({}, {
          __index = {
            destroy = function(self)
              destroyed[self] = true
            end,
          },
        }),
      },
      single_file = true,
    })
    local overlay_a = setmetatable({}, {
      __index = {
        destroy = function(self)
          destroyed[self] = true
        end,
      },
    })
    local overlay_b = setmetatable({}, {
      __index = {
        destroy = function(self)
          destroyed[self] = true
        end,
      },
    })
    entry._pin_overlays = { ["a.txt"] = overlay_a, ["b.txt"] = overlay_b }

    entry:destroy()

    assert.is_true(destroyed[overlay_a])
    assert.is_true(destroyed[overlay_b])
    assert.is_nil(entry._pin_overlays)
  end)
end)

describe("FileHistoryView:infer_cur_file pinned alignment", function()
  local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter

  local function make_adapter()
    local repo = make_git_repo()
    GitAdapter.bootstrap.done = true
    GitAdapter.bootstrap.ok = true
    return GitAdapter({ toplevel = repo, path_args = {} }), repo
  end

  -- Stub the panel surface that `infer_cur_file` consults so we can drive
  -- "panel focused" / "cursor on header" without opening any windows.
  local function stub_view(adapter, opts)
    return setmetatable({
      pin_local = opts.pin_local,
      pinned_path = opts.pinned_path,
      adapter = adapter,
      _pinned_b_files = {},
      get_default_layout = function()
        return Diff2Hor
      end,
      panel = {
        is_focused = function()
          return opts.focused
        end,
        get_item_at_cursor = function()
          return opts.item
        end,
        cur_item = { nil, opts.cur_file },
      },
    }, { __index = FileHistoryView })
  end

  local function stub_log_entry(adapter, paths)
    local commit = { hash = "abcdef0", subject = "stub" }
    local files = {}
    for _, p in ipairs(paths) do
      table.insert(
        files,
        FileEntry.with_layout(Diff2, {
          adapter = adapter,
          path = p,
          status = "M",
          kind = "working",
          commit = commit,
          revs = {
            a = adapter.Rev(RevType.COMMIT, "0000000000000000000000000000000000000000"),
            b = adapter.Rev(RevType.LOCAL),
          },
        })
      )
    end
    return LogEntry({
      path_args = paths,
      commit = commit,
      files = files,
      single_file = #paths == 1,
    })
  end

  it("returns the pinned file (not files[1]) when cursor is on a header", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      local entry = stub_log_entry(adapter, { "alpha.txt", "beta.txt", "gamma.txt" })
      local view = stub_view(adapter, {
        pin_local = true,
        pinned_path = "gamma.txt",
        focused = true,
        item = entry,
      })

      local picked = view:infer_cur_file()
      assert.is_not_nil(picked)
      eq("gamma.txt", picked.path)
      eq(picked, entry.files[3])
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  it("returns the overlay when the pinned path isn't in this commit", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      -- Multi-file entry: single-file entries short-circuit to `files[1]`
      -- (rename-follow handling), so use multiple paths to exercise the
      -- overlay-build path here.
      local entry = stub_log_entry(adapter, { "alpha.txt", "beta.txt" })
      local view = stub_view(adapter, {
        pin_local = true,
        pinned_path = "missing.txt",
        focused = true,
        item = entry,
      })

      local picked = view:infer_cur_file()
      assert.is_not_nil(picked)
      eq("missing.txt", picked.path)
      eq(picked, entry._pin_overlays["missing.txt"])
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)

  it("falls back to files[1] for a header when pin_local is unset", function()
    local adapter, repo = make_adapter()

    local ok, err = pcall(function()
      local entry = stub_log_entry(adapter, { "alpha.txt", "beta.txt" })
      local view = stub_view(adapter, {
        pin_local = nil,
        pinned_path = "beta.txt",
        focused = true,
        item = entry,
      })

      local picked = view:infer_cur_file()
      eq(picked, entry.files[1])
    end)

    pcall(vim.fn.delete, repo, "rf")
    if not ok then
      error(err)
    end
  end)
end)

describe("FileHistoryView pinned-local layout selection (sanity)", function()
  -- These checks were added to lock in that the multi-file plan keeps
  -- single-file layout selection working unchanged.
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  local function inst(pin_local)
    return setmetatable({ pin_local = pin_local }, { __index = FileHistoryView })
  end

  it("resolves to pinned variants regardless of single/multi file mode", function()
    config.setup({ view = { file_history = { layout = "diff2_horizontal" } } })

    eq(Diff2HorPinned, inst(true):get_default_layout())
  end)

  it("does not upgrade when pin_local is unset", function()
    config.setup({ view = { file_history = { layout = "diff2_vertical" } } })

    -- Use the actual layout name, not the class, to avoid pulling in
    -- Diff2Ver as another import.
    eq("diff2_vertical", inst(nil):get_default_layout().name)
  end)

  -- Defensive path: if a pinned layout name reaches `get_default_layout`
  -- with `pin_local` unset, it must be downgraded to its unpinned sibling.
  -- Pinned classes assume `revs.a` is the commit (the way pin_local sets
  -- it); applied to a parent-vs-commit history they mis-classify status
  -- "A"/"?" and the adapter then fails to `show <rev>:<missing>`. The
  -- user-config path is already gated by `standard_layouts` validation
  -- (pinned names aren't in the schema's allow-list, so `config.setup`
  -- silently substitutes the default), so we stub `get_default_layout_name`
  -- here to exercise the downgrade directly without going through config.
  local function stub_named(layout_name, pin_local)
    return setmetatable({
      pin_local = pin_local,
      get_default_layout_name = function()
        return layout_name
      end,
    }, { __index = FileHistoryView })
  end

  it("downgrades a pinned layout name when pin_local is unset", function()
    eq("diff2_horizontal", stub_named("diff2_horizontal_pinned", nil):get_default_layout().name)
    eq("diff2_vertical", stub_named("diff2_vertical_pinned", nil):get_default_layout().name)
  end)

  -- pin_local + a Diff1 layout (e.g. `diff1_inline`): upgrade to the
  -- pinned Diff1 sibling so the shared-b mechanism still engages. The
  -- pinned variants declare `shared_symbols = { "b" }`, so
  -- `FileEntry:destroy` leaves the view-owned working-tree file alone.
  it("upgrades a Diff1 layout to its pinned variant when pin_local is on", function()
    eq("diff1_inline_pinned", stub_named("diff1_inline", true):get_default_layout().name)
    eq("diff1_plain_pinned", stub_named("diff1_plain", true):get_default_layout().name)
  end)

  -- Defensive path mirroring the Diff2 downgrade: if a pinned Diff1 name
  -- reaches `get_default_layout` with `pin_local` unset, it must be
  -- downgraded to its unpinned sibling. Pinned variants borrow the b-side
  -- from the view, which only owns one when `pin_local` is live.
  it("downgrades a pinned Diff1 name when pin_local is unset", function()
    eq("diff1_inline", stub_named("diff1_inline_pinned", nil):get_default_layout().name)
    eq("diff1_plain", stub_named("diff1_plain_pinned", nil):get_default_layout().name)
  end)
end)

-- Regression: layout-cycle (`g<C-x>`) and `set_layout` go through
-- `entry:convert_layout(target)`. Without `resolve_pinned_layout` they
-- would route a pin_local view's entries to unpinned `Diff2Hor`/`Diff2Ver`,
-- whose `shared_symbols` is empty -- so the next `FileEntry:destroy`
-- would tear down the view-owned working-tree File once per entry,
-- breaking the pin and wiping shared diffview state from the user's
-- working-tree buffers.
describe("FileHistoryView:resolve_pinned_layout", function()
  local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
  local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
  local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
  local Diff2Ver = require("diffview.scene.layouts.diff_2_ver").Diff2Ver
  local Diff3Hor = require("diffview.scene.layouts.diff_3_hor").Diff3Hor
  local Diff3Ver = require("diffview.scene.layouts.diff_3_ver").Diff3Ver
  local Diff3Mixed = require("diffview.scene.layouts.diff_3_mixed").Diff3Mixed
  local Diff4Mixed = require("diffview.scene.layouts.diff_4_mixed").Diff4Mixed

  local function inst(pin_local)
    return setmetatable({ pin_local = pin_local }, { __index = FileHistoryView })
  end

  it("returns the input class unchanged when pin_local is off", function()
    eq(Diff2Hor, inst(false):resolve_pinned_layout(Diff2Hor))
    eq(Diff2Ver, inst(false):resolve_pinned_layout(Diff2Ver))
    eq(Diff1Inline, inst(false):resolve_pinned_layout(Diff1Inline))
  end)

  it("upgrades unpinned Diff2 to its pinned sibling", function()
    eq(Diff2HorPinned, inst(true):resolve_pinned_layout(Diff2Hor))
    eq(Diff2VerPinned, inst(true):resolve_pinned_layout(Diff2Ver))
  end)

  it("preserves a pinned variant unchanged (idempotent)", function()
    eq(Diff2HorPinned, inst(true):resolve_pinned_layout(Diff2HorPinned))
    eq(Diff2VerPinned, inst(true):resolve_pinned_layout(Diff2VerPinned))
  end)

  -- Diff1 variants gain pinned siblings too so `cycle_layout` /
  -- `set_layout` can route to them without `FileEntry:destroy` tearing
  -- down the view-owned working-tree file. `Diff1*Pinned` declare
  -- `shared_symbols = { "b" }`, mirroring `Diff2*Pinned`.
  it("upgrades unpinned Diff1 to its pinned sibling", function()
    eq(Diff1Pinned, inst(true):resolve_pinned_layout(Diff1))
    eq(Diff1InlinePinned, inst(true):resolve_pinned_layout(Diff1Inline))
  end)

  it("preserves a pinned Diff1 variant unchanged (idempotent)", function()
    eq(Diff1Pinned, inst(true):resolve_pinned_layout(Diff1Pinned))
    eq(Diff1InlinePinned, inst(true):resolve_pinned_layout(Diff1InlinePinned))
  end)

  -- `actions.set_layout("diff3_horizontal")` and user-supplied
  -- `view.cycle_layouts.default` entries can reach `resolve_pinned_layout`
  -- with merge-only layouts. Those have no pinned sibling, so they would
  -- otherwise drop a pin_local FileHistoryView into an unpinned class
  -- whose `shared_symbols` is empty, letting `FileEntry:destroy` tear
  -- down the view-owned working-tree file. Falling back to the default
  -- Diff2's pinned form preserves the shared-b contract. The exact
  -- orientation depends on `prefer_horizontal()`, so we only assert
  -- that the result is one of the pinned Diff2 variants.
  it("falls back to a pinned Diff2 for non-pinnable layouts in pin_local", function()
    local pinned_diff2 = {
      [Diff2HorPinned] = true,
      [Diff2VerPinned] = true,
    }
    for _, cls in ipairs({ Diff3Hor, Diff3Ver, Diff3Mixed, Diff4Mixed }) do
      local resolved = inst(true):resolve_pinned_layout(cls)
      assert.is_true(
        pinned_diff2[resolved],
        "expected pinned Diff2, got " .. tostring(resolved and resolved.name)
      )
    end
  end)
end)

-- `unpinned_layout` is the inverse mapping `cycle_layout` consults to
-- find the active layout's position in the unpinned cycle list. Without
-- it, a pin_local view's `Diff2*Pinned` class would never match the
-- `{ Diff2Hor, Diff2Ver }` cycle and the action would loop forever on
-- the first orientation. The function is a no-op for any class that
-- isn't a known pinned variant, so non-pin_local views keep their
-- existing behaviour.
describe("FileHistoryView:unpinned_layout", function()
  local Diff1 = require("diffview.scene.layouts.diff_1").Diff1
  local Diff1Inline = require("diffview.scene.layouts.diff_1_inline").Diff1Inline
  local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
  local Diff2Ver = require("diffview.scene.layouts.diff_2_ver").Diff2Ver

  local view = setmetatable({}, { __index = FileHistoryView })

  it("maps pinned variants back to their unpinned siblings", function()
    eq(Diff1, view:unpinned_layout(Diff1Pinned))
    eq(Diff1Inline, view:unpinned_layout(Diff1InlinePinned))
    eq(Diff2Hor, view:unpinned_layout(Diff2HorPinned))
    eq(Diff2Ver, view:unpinned_layout(Diff2VerPinned))
  end)

  it("returns non-pinned classes unchanged", function()
    eq(Diff2Hor, view:unpinned_layout(Diff2Hor))
    eq(Diff2Ver, view:unpinned_layout(Diff2Ver))
    eq(Diff1Inline, view:unpinned_layout(Diff1Inline))
  end)
end)

-- `pick_entry_target` is the helper that listeners and the panel use to
-- decide which FileEntry to display when navigating to a LogEntry. In
-- pin_local mode it must route through `_resolve_pinned_target` so the
-- pinned path (or its overlay) is what gets shown; the previous direct
-- access to `entry.files[1]` snapped to the first file in the commit and
-- ignored the user's pinned selection.
describe("FileHistoryView:pick_entry_target", function()
  local function make_view(pin_local, pinned_path)
    return setmetatable({
      pin_local = pin_local,
      pinned_path = pinned_path,
    }, { __index = FileHistoryView })
  end

  local function fake_entry(paths)
    local files = {}
    for _, p in ipairs(paths) do
      table.insert(files, { path = p })
    end
    return {
      single_file = #paths == 1,
      files = files,
    }
  end

  it("returns entry.files[1] when pin_local is off", function()
    local view = make_view(nil, nil)
    local entry = fake_entry({ "alpha.txt", "beta.txt" })
    eq(entry.files[1], view:pick_entry_target(entry))
  end)

  it("returns the pinned-path file when present in the entry", function()
    local view = make_view(true, "beta.txt")
    local entry = fake_entry({ "alpha.txt", "beta.txt", "gamma.txt" })
    eq(entry.files[2], view:pick_entry_target(entry))
  end)

  it("returns entry.files[1] for single-file entries even in pin_local", function()
    -- Single-file history follows one logical file across renames, so
    -- `_resolve_pinned_target` short-circuits to `files[1]` regardless
    -- of whether `pinned_path` matches the commit-side name.
    local view = make_view(true, "renamed.txt")
    local entry = fake_entry({ "old_name.txt" })
    eq(entry.files[1], view:pick_entry_target(entry))
  end)
end)

-- Centralised pinned_path invariant: `set_file` is the canonical "this
-- file is now active" path, so it owns the `pinned_path` update. Any
-- programmatic switch (commit-nav, file-row navigation, the cursor
-- follower) flows through here and the pinned path stays in sync
-- without each caller having to remember. Single-file history is the
-- exception: `pinned_path` there is the rename anchor (the working-tree
-- name) and may legitimately differ from the entry's commit-side name.
describe("FileHistoryView:set_file pinned_path invariant", function()
  -- Build a view shell with the minimum surface `set_file`'s
  -- pinned_path-update branch reads. We don't need to invoke the rest of
  -- set_file's async work; the invariant is set before the await.
  local function update_pinned_path(view, file)
    if view.pin_local and not view.panel.single_file then
      view.pinned_path = file.path
    end
  end

  it("updates pinned_path to file.path in pin_local multi-file mode", function()
    local view = { pin_local = true, pinned_path = "alpha.txt", panel = { single_file = false } }
    update_pinned_path(view, { path = "beta.txt" })
    eq("beta.txt", view.pinned_path)
  end)

  it("does not touch pinned_path when pin_local is off", function()
    local view = { pin_local = nil, pinned_path = "alpha.txt", panel = { single_file = false } }
    update_pinned_path(view, { path = "beta.txt" })
    eq("alpha.txt", view.pinned_path)
  end)

  it("preserves pinned_path in pin_local single-file mode (rename anchor)", function()
    -- Single-file history may show `entry.files[1]` with the file's
    -- commit-side name (e.g. the OLD name across a rename); pinned_path
    -- must stay anchored to the working-tree name so the b-side keeps
    -- following the live file.
    local view = { pin_local = true, pinned_path = "renamed.txt", panel = { single_file = true } }
    update_pinned_path(view, { path = "old_name.txt" })
    eq("renamed.txt", view.pinned_path)
  end)
end)

-- Overlay-aware navigation: pin_local overlays are transient FileEntries
-- that don't live in `entry.files`, so the panel's file-offset code
-- (`set_file_by_offset`) and the in-commit nav actions
-- (`next_entry_in_commit`/`prev_entry_in_commit`) used to silently no-op
-- when `cur_item[2]` was an overlay. The fix is to treat the overlay as if
-- the cursor were at `entry.files[1]` for navigation purposes.
describe("overlay-aware navigation", function()
  local FileHistoryPanel =
    require("diffview.scene.views.file_history.file_history_panel").FileHistoryPanel

  -- Drive the offset-based file navigation directly. The full panel
  -- bring-up isn't required: we only need `entries`, `cur_item`, and
  -- `_get_entry_by_file_offset` (inherited).
  local function make_panel(entries, cur_entry, cur_file)
    return setmetatable({
      entries = entries,
      cur_item = { cur_entry, cur_file },
      single_file = false,
      num_items = function(self)
        local n = 0
        for _, e in ipairs(self.entries) do
          n = n + #e.files
        end
        return n
      end,
      set_cur_item = function(self, item)
        self.cur_item = item
      end,
      set_entry_fold = function() end,
    }, { __index = FileHistoryPanel })
  end

  it("set_file_by_offset advances when cur_file is an overlay", function()
    local file_a, file_b = { path = "alpha.txt" }, { path = "beta.txt" }
    local overlay = { path = "missing.txt" }
    local entry = { files = { file_a, file_b }, _pin_overlays = { ["missing.txt"] = overlay } }
    local panel = make_panel({ entry }, entry, overlay)

    -- With the overlay treated as files[1], an offset of +1 should advance
    -- to files[2] (beta.txt). Pre-fix this would no-op silently because
    -- `vec_indexof(entry.files, overlay)` returns -1.
    local result = panel:set_file_by_offset(1)
    eq(file_b, result)
    eq(file_b, panel.cur_item[2])
  end)

  -- `_resolve_pinned_target` can hand `set_file` a transient overlay
  -- FileEntry that isn't in `entry.files`. Pre-fix `highlight_item` would
  -- silently no-op (no cursor movement), so commit-navigation actions left
  -- the panel cursor stranded on the previous row while the diff jumped.
  -- The fix parks the cursor on the entry header so the visible selection
  -- tracks the displayed commit.
  it("highlight_item parks cursor on entry header for pin_local overlays", function()
    local FileEntry = require("diffview.scene.file_entry").FileEntry

    local file_a = setmetatable({ path = "alpha.txt", class = FileEntry }, { __index = FileEntry })
    local file_b = setmetatable({ path = "beta.txt", class = FileEntry }, { __index = FileEntry })
    local overlay = setmetatable(
      { path = "missing.txt", class = FileEntry },
      { __index = FileEntry }
    )

    local entry = LogEntry({
      path_args = {},
      commit = { hash = "abc", subject = "stub" },
      files = { file_a, file_b },
    })
    entry._pin_overlays = { ["missing.txt"] = overlay }

    local comp_struct = { comp = { context = entry, lstart = 17 } }
    local panel = setmetatable({
      single_file = false,
      winid = -1,
      components = { log = { entries = { comp_struct } } },
      is_open = function()
        return true
      end,
      buf_loaded = function()
        return true
      end,
      render = function() end,
      redraw = function() end,
    }, { __index = FileHistoryPanel })

    -- Spy on cursor moves rather than open a real window: the api function
    -- is read fresh from `vim.api` each call, so the local capture in the
    -- panel module sees this stub.
    local original_set_cursor = vim.api.nvim_win_set_cursor
    local captured
    vim.api.nvim_win_set_cursor = function(_, pos)
      captured = pos
    end
    local utils_mod = require("diffview.utils")
    local original_update_win = utils_mod.update_win
    utils_mod.update_win = function() end

    local ok, err = pcall(panel.highlight_item, panel, overlay)

    vim.api.nvim_win_set_cursor = original_set_cursor
    utils_mod.update_win = original_update_win

    if not ok then
      error(err)
    end
    assert.is_not_nil(captured)
    eq(17, captured[1])
    eq(0, captured[2])
  end)
end)

describe("FileHistoryView:_destroy_pinned_b_files", function()
  -- Regression for a refactor bug where pinned b-files were destroyed with
  -- `force=true`, which `File:destroy` propagates straight to
  -- `safe_delete_buf`. That wipes the user's pre-existing working-tree
  -- buffer (possibly with unsaved edits) on view close. The contract is
  -- the opposite: detach diffview state with `force=false` and let the
  -- existing `clean_up_buffers` loop in `close()` reap only buffers
  -- diffview created.
  it("destroys each cached b-file with force=false", function()
    local destroy_calls = {}
    local fake_file = {
      destroy = function(_, force)
        destroy_calls[#destroy_calls + 1] = force
      end,
    }

    local view = setmetatable({
      _pinned_b_files = {
        ["foo.txt"] = fake_file,
        ["bar.txt"] = fake_file,
      },
    }, { __index = FileHistoryView })

    view:_destroy_pinned_b_files()

    eq(2, #destroy_calls)
    for _, force in ipairs(destroy_calls) do
      assert.is_false(force)
    end
    -- Cache is emptied so a re-close (or a stale reference) doesn't try to
    -- detach an already-destroyed file.
    assert.same({}, view._pinned_b_files)
  end)
end)
