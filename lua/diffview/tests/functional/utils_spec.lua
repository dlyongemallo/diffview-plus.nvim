local helpers = require("diffview.tests.helpers")
local utils = require("diffview.utils")

local eq = helpers.eq

describe("diffview.utils.job", function()
  it("returns stdout and exit code for a successful command", function()
    local stdout, code, stderr = utils.job({ "echo", "hello" })

    eq(0, code)
    assert.is_true(#stdout > 0)
    eq("hello", stdout[1])
  end)

  it("returns non-zero code for a failing command", function()
    local stdout, code, stderr = utils.job({ "false" })

    assert.is_true(code ~= 0)
  end)

  it("kills the process and returns non-zero code on timeout", function()
    local stdout, code, stderr = utils.job({ "sleep", "60" }, { timeout = 100 })

    eq(-1, code)
  end)

  it("captures output that arrives before a timeout", function()
    -- Use sh -c to echo then sleep, so some stdout is produced before timeout.
    local stdout, code, stderr = utils.job(
      { "sh", "-c", "echo partial; sleep 60" },
      { timeout = 500 }
    )

    eq(-1, code)
    assert.is_true(#stdout > 0)
    eq("partial", vim.trim(stdout[1]))
  end)

  it("respects the cwd option", function()
    local stdout, code = utils.job({ "pwd" }, { cwd = "/tmp" })

    eq(0, code)
    -- Resolve symlinks for comparison (e.g., /tmp -> /private/tmp on macOS).
    local expected = vim.fn.resolve("/tmp")
    local actual = vim.fn.resolve(stdout[1])
    eq(expected, actual)
  end)

  it("returns empty stdout for a command with no output", function()
    local stdout, code = utils.job({ "true" })

    eq(0, code)
    -- stdout is either empty or contains a single empty string.
    local text = table.concat(stdout)
    eq("", text)
  end)
end)

describe("diffview.utils.set_win_buf", function()
  it("does not retry when setting the window buffer succeeds", function()
    local original_set_win_buf = vim.api.nvim_win_set_buf
    local original_no_win_event_call = utils.no_win_event_call

    local calls = 0
    local ok, err = pcall(function()
      vim.api.nvim_win_set_buf = function()
        calls = calls + 1
      end
      utils.no_win_event_call = function()
        error("should not be called")
      end

      local success, msg, recovered = utils.set_win_buf(1, 1)

      eq(true, success)
      eq(nil, msg)
      eq(false, recovered)
      eq(1, calls)
    end)

    vim.api.nvim_win_set_buf = original_set_win_buf
    utils.no_win_event_call = original_no_win_event_call

    if not ok then
      error(err)
    end
  end)

  it("retries with ignored events when the first set fails", function()
    local original_set_win_buf = vim.api.nvim_win_set_buf
    local original_no_win_event_call = utils.no_win_event_call

    local calls = 0
    local no_event_calls = 0
    local ok, err = pcall(function()
      vim.api.nvim_win_set_buf = function()
        calls = calls + 1
        if calls == 1 then
          error(
            'BufEnter Autocommands for "*": Vim:E903: Process failed to start: too many open files'
          )
        end
      end
      utils.no_win_event_call = function(f)
        no_event_calls = no_event_calls + 1
        local success, inner_err = pcall(f)
        return success, inner_err
      end

      local success, msg, recovered = utils.set_win_buf(1, 1)

      eq(true, success)
      eq(true, recovered)
      eq(2, calls)
      eq(1, no_event_calls)
      assert.True(msg and msg:find("too many open files", 1, true) ~= nil)
    end)

    vim.api.nvim_win_set_buf = original_set_win_buf
    utils.no_win_event_call = original_no_win_event_call

    if not ok then
      error(err)
    end
  end)

  it("returns an error when both attempts fail", function()
    local original_set_win_buf = vim.api.nvim_win_set_buf
    local original_no_win_event_call = utils.no_win_event_call

    local calls = 0
    local no_event_calls = 0
    local ok, err = pcall(function()
      vim.api.nvim_win_set_buf = function()
        calls = calls + 1
        if calls == 1 then
          error("first failure")
        end

        error("second failure")
      end
      utils.no_win_event_call = function(f)
        no_event_calls = no_event_calls + 1
        local success, inner_err = pcall(f)
        if not success then
          return false, "retry failure"
        end
        return success, inner_err
      end

      local success, msg, recovered = utils.set_win_buf(1, 1)

      eq(false, success)
      eq(false, recovered)
      eq(2, calls)
      eq(1, no_event_calls)
      eq("retry failure", msg)
    end)

    vim.api.nvim_win_set_buf = original_set_win_buf
    utils.no_win_event_call = original_no_win_event_call

    if not ok then
      error(err)
    end
  end)

  it("bypasses winfixbuf and restores it after a successful swap", function()
    local win = vim.api.nvim_get_current_win()
    local buf_a = vim.api.nvim_create_buf(false, true)
    local buf_b = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_win_set_buf(win, buf_a)
    vim.wo[win].winfixbuf = true

    local success, msg, recovered = utils.set_win_buf(win, buf_b)

    eq(true, success)
    eq(nil, msg)
    eq(false, recovered)
    eq(buf_b, vim.api.nvim_win_get_buf(win))
    eq(true, vim.wo[win].winfixbuf)

    vim.wo[win].winfixbuf = false
    vim.api.nvim_buf_delete(buf_a, { force = true })
    vim.api.nvim_buf_delete(buf_b, { force = true })
  end)

  it("leaves winfixbuf unchanged on a window that did not have it set", function()
    local win = vim.api.nvim_get_current_win()
    local buf_a = vim.api.nvim_create_buf(false, true)
    local buf_b = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_win_set_buf(win, buf_a)
    vim.wo[win].winfixbuf = false

    local success = utils.set_win_buf(win, buf_b)

    eq(true, success)
    eq(false, vim.wo[win].winfixbuf)

    vim.api.nvim_buf_delete(buf_a, { force = true })
    vim.api.nvim_buf_delete(buf_b, { force = true })
  end)

  it("restores winfixbuf after the retry path", function()
    local win = vim.api.nvim_get_current_win()
    local buf_a = vim.api.nvim_create_buf(false, true)
    local buf_b = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_win_set_buf(win, buf_a)
    vim.wo[win].winfixbuf = true

    local original_set_win_buf = vim.api.nvim_win_set_buf
    local calls = 0

    local ok, err = pcall(function()
      vim.api.nvim_win_set_buf = function(w, b)
        calls = calls + 1
        if calls == 1 then
          error(
            'BufEnter Autocommands for "*": Vim:E903: Process failed to start: too many open files'
          )
        end
        return original_set_win_buf(w, b)
      end

      local success, msg, recovered = utils.set_win_buf(win, buf_b)

      eq(true, success)
      eq(true, recovered)
      eq(2, calls)
      eq(buf_b, vim.api.nvim_win_get_buf(win))
      eq(true, vim.wo[win].winfixbuf)
    end)

    vim.api.nvim_win_set_buf = original_set_win_buf
    vim.wo[win].winfixbuf = false
    vim.api.nvim_buf_delete(buf_a, { force = true })
    vim.api.nvim_buf_delete(buf_b, { force = true })

    if not ok then
      error(err)
    end
  end)
end)

describe("diffview.utils.str_pad", function()
  it("left-aligns by default (pads on the right)", function()
    eq("hi   ", utils.str_pad("hi", 5))
  end)

  it("right-aligns (pads on the left)", function()
    eq("   hi", utils.str_pad("hi", 5, nil, "right"))
  end)

  it("center-aligns (pads both sides)", function()
    eq(" hi  ", utils.str_pad("hi", 5, nil, "center"))
  end)

  it("returns the string unchanged when already at min_size", function()
    eq("hello", utils.str_pad("hello", 5))
    eq("hello", utils.str_pad("hello", 3))
  end)

  it("supports a custom fill character", function()
    eq("hi...", utils.str_pad("hi", 5, "."))
    eq("...hi", utils.str_pad("hi", 5, ".", "right"))
  end)

  it("center-aligns with multi-character fill meets min_size", function()
    local result = utils.str_pad("ab", 5, "..", "center")
    assert(#result >= 5, "result length " .. #result .. " is less than min_size 5")
    -- With pad = ceil(3/2) = 2 reps: floor(1) left + ceil(1) right = ".." .. "ab" .. ".."
    eq("..ab..", result)
  end)

  it("coerces non-string input via tostring", function()
    eq("42  ", utils.str_pad(42, 4))
  end)
end)

describe("diffview.utils.str_pad wrappers", function()
  it("str_right_pad pads on the right", function()
    eq("ab   ", utils.str_right_pad("ab", 5))
  end)

  it("str_left_pad pads on the left", function()
    eq("   ab", utils.str_left_pad("ab", 5))
  end)

  it("str_center_pad pads both sides", function()
    eq(" ab  ", utils.str_center_pad("ab", 5))
  end)
end)

describe("diffview.utils.set_local list-like remove", function()
  -- Window-local `winhighlight` is the canonical list-like option that the
  -- gsub-based remove path is meant to handle. Each test seeds the option
  -- directly, runs `set_local` with `method = "remove"`, then reads back the
  -- resulting value via `vim.wo`.

  local winid

  before_each(function()
    winid = vim.api.nvim_get_current_win()
    vim.wo[winid].winhighlight = ""
  end)

  after_each(function()
    vim.wo[winid].winhighlight = ""
  end)

  it("removes a leading block and consumes its trailing comma", function()
    -- Regression: previously the trailing comma was left behind, producing a
    -- malformed `winhighlight` like ",Normal:User".
    vim.wo[winid].winhighlight = "DiffAdd:DiffviewDiffAdd,Normal:User"
    utils.set_local(winid, {
      winhighlight = {
        "DiffAdd:DiffviewDiffAdd",
        opt = { method = "remove" },
      },
    })
    eq("Normal:User", vim.wo[winid].winhighlight)
  end)

  it("removes a trailing block and consumes its leading comma", function()
    vim.wo[winid].winhighlight = "Normal:User,DiffAdd:DiffviewDiffAdd"
    utils.set_local(winid, {
      winhighlight = {
        "DiffAdd:DiffviewDiffAdd",
        opt = { method = "remove" },
      },
    })
    eq("Normal:User", vim.wo[winid].winhighlight)
  end)

  it("removes a middle block without doubling separators", function()
    vim.wo[winid].winhighlight = "Normal:User,DiffAdd:DiffviewDiffAdd,CursorLine:UserCl"
    utils.set_local(winid, {
      winhighlight = {
        "DiffAdd:DiffviewDiffAdd",
        opt = { method = "remove" },
      },
    })
    eq("Normal:User,CursorLine:UserCl", vim.wo[winid].winhighlight)
  end)

  it("removes a multi-entry block prepended ahead of user entries", function()
    -- Mirrors the `Diff1Raw` flow: `vcs.File` prepends a block, the view then
    -- removes the same block. The result must keep the user's entries intact.
    vim.wo[winid].winhighlight = "DiffAdd:DiffviewDiffAdd,DiffDelete:DiffviewDiffDelete,Normal:User"
    utils.set_local(winid, {
      winhighlight = {
        "DiffAdd:DiffviewDiffAdd",
        "DiffDelete:DiffviewDiffDelete",
        opt = { method = "remove" },
      },
    })
    eq("Normal:User", vim.wo[winid].winhighlight)
  end)

  it("clears the option when the removed block is the only entry", function()
    vim.wo[winid].winhighlight = "DiffAdd:DiffviewDiffAdd"
    utils.set_local(winid, {
      winhighlight = {
        "DiffAdd:DiffviewDiffAdd",
        opt = { method = "remove" },
      },
    })
    eq("", vim.wo[winid].winhighlight)
  end)

  it("is a no-op when the value is absent", function()
    vim.wo[winid].winhighlight = "Normal:User"
    utils.set_local(winid, {
      winhighlight = {
        "DiffAdd:DiffviewDiffAdd",
        opt = { method = "remove" },
      },
    })
    eq("Normal:User", vim.wo[winid].winhighlight)
  end)

  it("does not corrupt entries that share a prefix with the removed value", function()
    -- Regression: substring matching used to strip `DiffDelete:DiffviewDiffDelete`
    -- out of `DiffDelete:DiffviewDiffDeleteDim`, leaving a stray `Dim` behind.
    vim.wo[winid].winhighlight = "DiffDelete:DiffviewDiffDeleteDim,Normal:User"
    utils.set_local(winid, {
      winhighlight = {
        "DiffDelete:DiffviewDiffDelete",
        opt = { method = "remove" },
      },
    })
    eq("DiffDelete:DiffviewDiffDeleteDim,Normal:User", vim.wo[winid].winhighlight)
  end)
end)
