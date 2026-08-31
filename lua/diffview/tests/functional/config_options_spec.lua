local config = require("diffview.config")
local hl = require("diffview.hl")

-- Helper: run setup() with the given overrides and return the live config.
local function setup_with(overrides)
  config.setup(overrides or {})
  return config.get_config()
end

describe("always_show_sections", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("defaults to false", function()
    local conf = setup_with({})
    assert.is_false(conf.file_panel.always_show_sections)
  end)

  it("survives setup() when set to true", function()
    local conf = setup_with({ file_panel = { always_show_sections = true } })
    assert.is_true(conf.file_panel.always_show_sections)
  end)
end)

describe("auto_close_on_empty", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("defaults to false", function()
    local conf = setup_with({})
    assert.is_false(conf.auto_close_on_empty)
  end)

  it("survives setup() when set to true", function()
    local conf = setup_with({ auto_close_on_empty = true })
    assert.is_true(conf.auto_close_on_empty)
  end)
end)

describe("commit_subject_max_length", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("defaults to 72", function()
    local conf = setup_with({})
    assert.equals(72, conf.file_history_panel.commit_subject_max_length)
  end)

  it("survives setup() with a custom value", function()
    local conf = setup_with({ file_history_panel = { commit_subject_max_length = 50 } })
    assert.equals(50, conf.file_history_panel.commit_subject_max_length)
  end)
end)

describe("status_icons", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("default table contains expected status keys", function()
    local conf = setup_with({})
    local expected_keys = { "A", "?", "M", "R", "C", "T", "U", "X", "D", "B", "!" }
    for _, key in ipairs(expected_keys) do
      assert.not_nil(conf.status_icons[key], "missing status_icons key: " .. key)
    end
  end)

  it("hl.get_status_icon() returns the configured icon for a known status", function()
    setup_with({ status_icons = { ["M"] = "~" } })
    assert.equals("~", hl.get_status_icon("M"))
  end)

  it("hl.get_status_icon() falls back to the raw status letter for unknown statuses", function()
    setup_with({})
    assert.equals("Z", hl.get_status_icon("Z"))
  end)
end)

describe("mark_placement", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("defaults to 'inline'", function()
    local conf = setup_with({})
    assert.equals("inline", conf.file_panel.mark_placement)
  end)

  it("survives setup() when set to 'sign_column'", function()
    local conf = setup_with({ file_panel = { mark_placement = "sign_column" } })
    assert.equals("sign_column", conf.file_panel.mark_placement)
  end)
end)

describe("view.inline.style", function()
  local original
  local utils = require("diffview.utils")
  local orig_err
  local orig_warn

  before_each(function()
    original = vim.deepcopy(config.get_config())
    orig_err = utils.err
    orig_warn = utils.warn
    utils.err = function() end
    utils.warn = function() end
  end)

  after_each(function()
    config.setup(original)
    utils.err = orig_err
    utils.warn = orig_warn
  end)

  it("defaults to 'unified'", function()
    local conf = setup_with({})
    assert.equals("unified", conf.view.inline.style)
  end)

  it("accepts 'overleaf'", function()
    local conf = setup_with({ view = { inline = { style = "overleaf" } } })
    assert.equals("overleaf", conf.view.inline.style)
  end)

  it("rejects unknown values and falls back to 'unified'", function()
    local conf = setup_with({ view = { inline = { style = "bogus" } } })
    assert.equals("unified", conf.view.inline.style)
  end)

  it("treats omitted style (e.g. view.inline = {}) as 'use default'", function()
    local err_called = false
    utils.err = function()
      err_called = true
    end

    local conf = setup_with({ view = { inline = {} } })

    assert.equals("unified", conf.view.inline.style)
    assert.is_false(err_called, "omitting style should not produce a validation error")
  end)

  it("warns and falls back when view.inline is a non-table value", function()
    local warned = false
    utils.warn = function()
      warned = true
    end

    -- A truthy non-table (e.g. user typo'd `view.inline = "overleaf"`) would
    -- crash on `view.inline.style` without the type guard.
    local conf = setup_with({ view = { inline = "overleaf" } })

    assert.is_true(warned, "expected a warning about non-table view.inline")
    assert.equals("unified", conf.view.inline.style)
  end)
end)

describe("view.inline.deletion_highlight", function()
  local original
  local utils = require("diffview.utils")
  local orig_err
  local orig_warn

  before_each(function()
    original = vim.deepcopy(config.get_config())
    orig_err = utils.err
    orig_warn = utils.warn
    utils.err = function() end
    utils.warn = function() end
  end)

  after_each(function()
    config.setup(original)
    utils.err = orig_err
    utils.warn = orig_warn
  end)

  it("defaults to 'text'", function()
    local conf = setup_with({})
    assert.equals("text", conf.view.inline.deletion_highlight)
  end)

  it("accepts 'full_width'", function()
    local conf = setup_with({ view = { inline = { deletion_highlight = "full_width" } } })
    assert.equals("full_width", conf.view.inline.deletion_highlight)
  end)

  it("accepts 'hanging'", function()
    local conf = setup_with({ view = { inline = { deletion_highlight = "hanging" } } })
    assert.equals("hanging", conf.view.inline.deletion_highlight)
  end)

  it("rejects unknown values and falls back to the default", function()
    local conf = setup_with({ view = { inline = { deletion_highlight = "bogus" } } })
    assert.equals("text", conf.view.inline.deletion_highlight)
  end)
end)

describe("view.inline.deletion_treesitter", function()
  local original
  local utils = require("diffview.utils")
  local orig_err
  local orig_warn

  before_each(function()
    original = vim.deepcopy(config.get_config())
    orig_err = utils.err
    orig_warn = utils.warn
    utils.err = function() end
    utils.warn = function() end
  end)

  after_each(function()
    config.setup(original)
    utils.err = orig_err
    utils.warn = orig_warn
  end)

  it("defaults to true", function()
    local conf = setup_with({})
    assert.equals(true, conf.view.inline.deletion_treesitter)
  end)

  it("accepts false", function()
    local conf = setup_with({ view = { inline = { deletion_treesitter = false } } })
    assert.equals(false, conf.view.inline.deletion_treesitter)
  end)

  it("rejects non-boolean values and falls back to the default", function()
    local conf = setup_with({ view = { inline = { deletion_treesitter = "yes" } } })
    assert.equals(true, conf.view.inline.deletion_treesitter)
  end)
end)

describe("view.inline.fold_unchanged", function()
  local original
  local utils = require("diffview.utils")
  local orig_err
  local orig_warn

  before_each(function()
    original = vim.deepcopy(config.get_config())
    orig_err = utils.err
    orig_warn = utils.warn
    utils.err = function() end
    utils.warn = function() end
  end)

  after_each(function()
    config.setup(original)
    utils.err = orig_err
    utils.warn = orig_warn
  end)

  it("defaults to false", function()
    local conf = setup_with({})
    assert.equals(false, conf.view.inline.fold_unchanged)
  end)

  it("accepts true", function()
    local conf = setup_with({ view = { inline = { fold_unchanged = true } } })
    assert.equals(true, conf.view.inline.fold_unchanged)
  end)

  it("rejects non-boolean values and falls back to the default", function()
    local conf = setup_with({ view = { inline = { fold_unchanged = "yep" } } })
    assert.equals(false, conf.view.inline.fold_unchanged)
  end)
end)

describe("file_history_panel.log_options.jj", function()
  local original

  before_each(function()
    original = vim.deepcopy(config.get_config())
  end)

  after_each(function()
    config.setup(original)
  end)

  it("exposes a jj sub-table with single_file and multi_file slots", function()
    local conf = setup_with({})
    local jj = conf.file_history_panel.log_options.jj
    assert.is_table(jj)
    assert.is_table(jj.single_file)
    assert.is_table(jj.multi_file)
  end)

  it("merges JjLogOptions defaults into empty single_file/multi_file", function()
    local conf = setup_with({})
    local defaults = require("diffview.config").log_option_defaults.jj
    assert.equals(defaults.limit, conf.file_history_panel.log_options.jj.single_file.limit)
    assert.equals(defaults.limit, conf.file_history_panel.log_options.jj.multi_file.limit)
    assert.equals(defaults.reversed, conf.file_history_panel.log_options.jj.single_file.reversed)
  end)

  it("preserves user overrides while filling in missing defaults", function()
    local conf = setup_with({
      file_history_panel = {
        log_options = {
          jj = {
            single_file = { limit = 100, revisions = "main..@" },
          },
        },
      },
    })
    local sf = conf.file_history_panel.log_options.jj.single_file
    assert.equals(100, sf.limit) -- user value preserved
    assert.equals("main..@", sf.revisions) -- user value preserved
    assert.equals(false, sf.reversed) -- default filled in
  end)

  it("get_log_options returns merged single_file options for jj", function()
    setup_with({
      file_history_panel = {
        log_options = {
          jj = { single_file = { limit = 42 } },
        },
      },
    })
    local opts = config.get_log_options(true, {}, "jj")
    assert.equals(42, opts.limit)
    assert.equals(false, opts.reversed)
  end)

  it("get_log_options merges per-call overrides on top of config", function()
    setup_with({
      file_history_panel = {
        log_options = {
          jj = { multi_file = { limit = 50 } },
        },
      },
    })
    local opts = config.get_log_options(false, { limit = 7 }, "jj")
    assert.equals(7, opts.limit) -- call-site wins over config
  end)

  it("get_log_options returns a deep copy callers can mutate", function()
    setup_with({})
    local opts = config.get_log_options(true, {}, "jj")
    table.insert(opts.path_args, "scratch")
    local conf = config.get_config()
    -- The stored defaults must not have been mutated through the alias.
    assert.equals(0, #conf.file_history_panel.log_options.jj.single_file.path_args)
  end)

  it("get_log_options tolerates a nil overrides table", function()
    setup_with({})
    local opts = config.get_log_options(true, nil, "jj")
    assert.is_table(opts)
    assert.equals(256, opts.limit)
  end)

  it("setup gives single_file and multi_file independent list defaults", function()
    local conf = setup_with({})
    local sf = conf.file_history_panel.log_options.jj.single_file
    local mf = conf.file_history_panel.log_options.jj.multi_file
    -- The shared default `path_args = {}` must not alias across slots or back
    -- to `log_option_defaults`.
    assert.is_false(rawequal(sf.path_args, mf.path_args))
    assert.is_false(rawequal(sf.path_args, config.log_option_defaults.jj.path_args))
  end)
end)

-- Helper context for tests that drive bad config through setup. Mocks
-- `utils.warn` so the validator's notifications don't bleed into the test
-- runner's stdout.
local function with_silent_warn(fn)
  local utils = require("diffview.utils")
  local orig_warn = utils.warn
  local warned = {}
  utils.warn = function(msg)
    warned[#warned + 1] = msg
  end
  local original = vim.deepcopy(config.get_config())
  local ok, err = pcall(fn, warned)
  config.setup(original)
  utils.warn = orig_warn
  if not ok then
    error(err)
  end
end

describe("config validation: boolean coverage", function()
  it("rejects a value that is not boolean-like and falls back to the default", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ auto_close_on_empty = "yep" })
      assert.is_false(conf.auto_close_on_empty)
      assert.is_true(#warned > 0)
    end)
  end)

  it("accepts explicit true and false unchanged", function()
    with_silent_warn(function()
      assert.is_true(setup_with({ wrap_entries = true }).wrap_entries)
      assert.is_false(setup_with({ wrap_entries = false }).wrap_entries)
    end)
  end)

  it("rejects a non-boolean-like view sub-field value", function()
    with_silent_warn(function()
      local conf = setup_with({ view = { default = { disable_diagnostics = {} } } })
      assert.is_false(conf.view.default.disable_diagnostics)
    end)
  end)
end)

describe("config validation: boolean coercion", function()
  it("coerces 'yes'/'no' to true/false", function()
    with_silent_warn(function(warned)
      assert.is_true(setup_with({ auto_close_on_empty = "yes" }).auto_close_on_empty)
      assert.is_false(setup_with({ auto_close_on_empty = "no" }).auto_close_on_empty)
      assert.equals(0, #warned, "no warnings expected for coerced values")
    end)
  end)

  it("coerces 'true'/'false' strings (case-insensitive)", function()
    with_silent_warn(function()
      assert.is_true(setup_with({ auto_close_on_empty = "true" }).auto_close_on_empty)
      assert.is_true(setup_with({ auto_close_on_empty = "True" }).auto_close_on_empty)
      assert.is_false(setup_with({ auto_close_on_empty = "FALSE" }).auto_close_on_empty)
    end)
  end)

  it("coerces 'on'/'off' to true/false", function()
    with_silent_warn(function()
      assert.is_true(setup_with({ auto_close_on_empty = "on" }).auto_close_on_empty)
      assert.is_false(setup_with({ auto_close_on_empty = "off" }).auto_close_on_empty)
    end)
  end)

  it("coerces numeric 1/0 to true/false", function()
    with_silent_warn(function()
      assert.is_true(setup_with({ auto_close_on_empty = 1 }).auto_close_on_empty)
      assert.is_false(setup_with({ auto_close_on_empty = 0 }).auto_close_on_empty)
    end)
  end)

  it("rejects numeric values other than 1/0", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ auto_close_on_empty = 2 })
      assert.is_false(conf.auto_close_on_empty)
      assert.is_true(#warned > 0)
    end)
  end)
end)

describe("config validation: integer coverage", function()
  it("large_file_threshold rejects negative integers", function()
    with_silent_warn(function()
      local conf = setup_with({ large_file_threshold = -1 })
      assert.equals(0, conf.large_file_threshold)
    end)
  end)

  it("large_file_threshold rejects non-integer numbers", function()
    with_silent_warn(function()
      local conf = setup_with({ large_file_threshold = 1.5 })
      assert.equals(0, conf.large_file_threshold)
    end)
  end)

  it("large_file_threshold coerces a numeric string", function()
    with_silent_warn(function()
      local conf = setup_with({ large_file_threshold = "100" })
      assert.equals(100, conf.large_file_threshold)
    end)
  end)

  it("commit_subject_max_length defaults and validates a custom value", function()
    with_silent_warn(function()
      local conf = setup_with({ file_history_panel = { commit_subject_max_length = -5 } })
      assert.equals(72, conf.file_history_panel.commit_subject_max_length)
    end)
  end)
end)

describe("config validation: enum coverage", function()
  it("file_panel.listing_style rejects unknown values", function()
    with_silent_warn(function()
      local conf = setup_with({ file_panel = { listing_style = "treee" } })
      assert.equals("tree", conf.file_panel.listing_style)
    end)
  end)

  it("file_history_panel.stat_style accepts each valid value", function()
    with_silent_warn(function()
      for _, v in ipairs({ "number", "bar", "both" }) do
        local conf = setup_with({ file_history_panel = { stat_style = v } })
        assert.equals(v, conf.file_history_panel.stat_style)
      end
    end)
  end)

  it("file_history_panel.date_format rejects unknown values", function()
    with_silent_warn(function()
      local conf = setup_with({ file_history_panel = { date_format = "yesterday" } })
      assert.equals("auto", conf.file_history_panel.date_format)
    end)
  end)

  it("file_panel.tree_options.folder_statuses rejects unknown values", function()
    with_silent_warn(function()
      local conf = setup_with({ file_panel = { tree_options = { folder_statuses = "sometimes" } } })
      assert.equals("only_folded", conf.file_panel.tree_options.folder_statuses)
    end)
  end)
end)

describe("config validation: enum_list filtering", function()
  it("file_history_panel.commit_format drops invalid elements but keeps valid ones", function()
    with_silent_warn(function(warned)
      local conf = setup_with({
        file_history_panel = { commit_format = { "subject", "bogus", "date" } },
      })
      assert.same({ "subject", "date" }, conf.file_history_panel.commit_format)
      assert.is_true(#warned > 0)
    end)
  end)

  it("falls back to default when commit_format is not a list", function()
    with_silent_warn(function()
      local conf = setup_with({ file_history_panel = { commit_format = "subject" } })
      assert.same(
        { "status", "files", "stats", "hash", "reflog", "ref", "subject", "author", "date" },
        conf.file_history_panel.commit_format
      )
    end)
  end)

  it("falls back to default when commit_format is explicitly empty", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ file_history_panel = { commit_format = {} } })
      assert.same(
        { "status", "files", "stats", "hash", "reflog", "ref", "subject", "author", "date" },
        conf.file_history_panel.commit_format
      )
      assert.is_true(#warned > 0)
    end)
  end)

  it("falls back to default when all commit_format elements are filtered out", function()
    with_silent_warn(function()
      local conf = setup_with({ file_history_panel = { commit_format = { "bogus", "alsobogus" } } })
      assert.same(
        { "status", "files", "stats", "hash", "reflog", "ref", "subject", "author", "date" },
        conf.file_history_panel.commit_format
      )
    end)
  end)
end)

describe("config validation: cycle_layouts excludes the -1 sentinel", function()
  -- `-1` ("infer from diffopt") is valid for `view.*.layout` but meaningless
  -- in a cycle list, where `cycle_layout` needs concrete layouts to rotate
  -- through. It must be filtered out (with a warning), not silently kept.
  it("drops -1 from cycle_layouts.default but keeps valid layouts", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ view = { cycle_layouts = { default = { "diff2_vertical", -1 } } } })
      local list = conf.view.cycle_layouts.default
      assert.is_false(vim.tbl_contains(list, -1))
      assert.is_true(vim.tbl_contains(list, "diff2_vertical"))
      assert.is_true(#warned > 0)
    end)
  end)

  it("drops -1 from cycle_layouts.merge_tool but keeps valid layouts", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ view = { cycle_layouts = { merge_tool = { "diff3_mixed", -1 } } } })
      local list = conf.view.cycle_layouts.merge_tool
      assert.is_false(vim.tbl_contains(list, -1))
      assert.is_true(vim.tbl_contains(list, "diff3_mixed"))
      assert.is_true(#warned > 0)
    end)
  end)

  -- The sentinel is still legitimate (and warning-free) on `view.*.layout`.
  it("still accepts -1 as a view.*.layout value", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ view = { default = { layout = -1 } } })
      assert.equals(-1, conf.view.default.layout)
      assert.equals(0, #warned, "no warning expected for a valid -1 view layout")
    end)
  end)
end)

describe("config validation: string_list filtering", function()
  it("default_args.DiffviewOpen drops non-string elements", function()
    with_silent_warn(function()
      local conf = setup_with({ default_args = { DiffviewOpen = { "--imply-local", 42, "--" } } })
      assert.same({ "--imply-local", "--" }, conf.default_args.DiffviewOpen)
    end)
  end)

  it("git_cmd substitutes the default when an empty list is supplied", function()
    with_silent_warn(function()
      local conf = setup_with({ git_cmd = {} })
      assert.same({ "git" }, conf.git_cmd)
    end)
  end)

  it("git_cmd substitutes the default after all non-string elements are filtered out", function()
    with_silent_warn(function()
      local conf = setup_with({ git_cmd = { 1, 2 } })
      assert.same({ "git" }, conf.git_cmd)
    end)
  end)
end)

describe("config validation: any_of (table or function)", function()
  it("accepts a table win_config", function()
    with_silent_warn(function()
      local cfg = { position = "right", width = 40 }
      local conf = setup_with({ file_panel = { win_config = cfg } })
      assert.equals("right", conf.file_panel.win_config.position)
    end)
  end)

  it("accepts a function win_config", function()
    with_silent_warn(function()
      local fn = function()
        return { position = "left", width = 30 }
      end
      local conf = setup_with({ file_panel = { win_config = fn } })
      assert.equals(fn, conf.file_panel.win_config)
    end)
  end)

  it("rejects a value that is neither a table nor a function", function()
    with_silent_warn(function()
      local conf = setup_with({ file_panel = { win_config = "left" } })
      assert.is_table(conf.file_panel.win_config)
      -- Falls back to the default table.
      assert.equals("left", conf.file_panel.win_config.position)
      assert.equals(35, conf.file_panel.win_config.width)
    end)
  end)
end)

describe("config validation: nilable", function()
  it("persist_selections.path defaults to nil and stays nil when omitted", function()
    with_silent_warn(function()
      local conf = setup_with({})
      assert.is_nil(conf.persist_selections.path)
    end)
  end)

  it("persist_selections.path accepts a string", function()
    with_silent_warn(function()
      local conf = setup_with({ persist_selections = { path = "/tmp/sel.json" } })
      assert.equals("/tmp/sel.json", conf.persist_selections.path)
    end)
  end)

  it("persist_selections.path rejects a non-string non-nil value", function()
    with_silent_warn(function()
      local conf = setup_with({ persist_selections = { path = 42 } })
      assert.is_nil(conf.persist_selections.path)
    end)
  end)

  it("file_panel.sort_file accepts a function", function()
    with_silent_warn(function()
      local fn = function()
        return true
      end
      local conf = setup_with({ file_panel = { sort_file = fn } })
      assert.equals(fn, conf.file_panel.sort_file)
    end)
  end)

  it("file_panel.sort_file rejects a non-function value", function()
    with_silent_warn(function()
      local conf = setup_with({ file_panel = { sort_file = "asc" } })
      assert.is_nil(conf.file_panel.sort_file)
    end)
  end)
end)

describe("config validation: table-shape guards", function()
  it("falls back to a default-cloned signs table when user passes a string", function()
    with_silent_warn(function()
      local conf = setup_with({ signs = "fold" })
      assert.is_table(conf.signs)
      assert.equals(config.defaults.signs.fold_closed, conf.signs.fold_closed)
    end)
  end)

  it("validates individual signs values are strings", function()
    with_silent_warn(function()
      local conf = setup_with({ signs = { fold_closed = 1 } })
      assert.equals(config.defaults.signs.fold_closed, conf.signs.fold_closed)
      -- Other sign keys are still the defaults.
      assert.equals(config.defaults.signs.fold_open, conf.signs.fold_open)
    end)
  end)

  it("status_icons rejects a non-string value at a known key", function()
    with_silent_warn(function()
      local conf = setup_with({ status_icons = { ["M"] = 0 } })
      assert.equals(config.defaults.status_icons["M"], conf.status_icons["M"])
    end)
  end)

  -- The deprecation block in `setup()` runs before per-field validation and
  -- dereferences these panel tables, so the early table guard must replace
  -- non-table values before they reach that block.
  it("falls back when file_panel is a non-table (boolean)", function()
    with_silent_warn(function()
      local conf = setup_with({ file_panel = false })
      assert.is_table(conf.file_panel)
      assert.equals(config.defaults.file_panel.listing_style, conf.file_panel.listing_style)
    end)
  end)

  it("falls back when file_history_panel is a non-table (number)", function()
    with_silent_warn(function()
      local conf = setup_with({ file_history_panel = 0 })
      assert.is_table(conf.file_history_panel)
      assert.equals(
        config.defaults.file_history_panel.stat_style,
        conf.file_history_panel.stat_style
      )
    end)
  end)

  it("ignores deprecated panel keys when win_config is a function", function()
    with_silent_warn(function()
      local fn = function()
        return { position = "left", width = 30 }
      end
      -- `width` is a deprecated panel key that the migration tries to write
      -- into `win_config`. When `win_config` is a function, the migration
      -- must skip the assignment instead of crashing.
      local conf = setup_with({ file_panel = { width = 30, win_config = fn } })
      assert.equals(fn, conf.file_panel.win_config)
    end)
  end)

  -- The merge loop at the end of `setup()` indexes
  -- `log_options[vcs][single_file|multi_file]`, so each level must be
  -- guarded against non-table user input.
  it("falls back when a per-VCS log_options branch is non-table", function()
    with_silent_warn(function()
      local conf = setup_with({ file_history_panel = { log_options = { git = 0 } } })
      assert.is_table(conf.file_history_panel.log_options.git)
      assert.equals("first-parent", conf.file_history_panel.log_options.git.single_file.diff_merges)
    end)
  end)

  it("falls back when a log_options[vcs].single_file branch is non-table", function()
    with_silent_warn(function()
      local conf =
        setup_with({ file_history_panel = { log_options = { git = { single_file = "nope" } } } })
      assert.is_table(conf.file_history_panel.log_options.git.single_file)
      assert.equals("first-parent", conf.file_history_panel.log_options.git.single_file.diff_merges)
    end)
  end)
end)

describe("config validation: hooks and keymaps", function()
  -- `setup()` iterates `pairs(hooks)` and indexes `keymaps.disable_defaults`,
  -- so a non-table value for either would crash setup before these guards
  -- were added.
  it("falls back when hooks is a non-table", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ hooks = "nope" })
      assert.is_table(conf.hooks)
      assert.is_true(#warned > 0)
    end)
  end)

  -- A number (rather than `false`) is used here because it is truthy: it
  -- exercises both the `keymaps.disable_defaults` index and the keymap merge,
  -- which reads `user_config.keymaps` and would otherwise error on a non-table.
  it("falls back when keymaps is a non-table", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ keymaps = 5 })
      assert.is_table(conf.keymaps)
      assert.is_false(conf.keymaps.disable_defaults)
      assert.is_table(conf.keymaps.view)
      assert.is_true(#warned > 0)
    end)
  end)

  it("coerces a boolean-like keymaps.disable_defaults", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ keymaps = { disable_defaults = "yes" } })
      assert.is_true(conf.keymaps.disable_defaults)
      assert.equals(0, #warned, "no warnings expected for a coerced value")
    end)
  end)

  it("rejects a non-boolean-like keymaps.disable_defaults", function()
    with_silent_warn(function(warned)
      local conf = setup_with({ keymaps = { disable_defaults = {} } })
      assert.is_false(conf.keymaps.disable_defaults)
      assert.is_true(#warned > 0)
    end)
  end)
end)
