local config = require("diffview.config")
local async = require("diffview.async")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")
local File = require("diffview.vcs.file").File

describe("shared null-buffer keymaps", function()
  local original_config

  before_each(function()
    original_config = vim.deepcopy(config.get_config())
    config.setup({
      use_icons = false,
      keymaps = {
        view = { { "n", "<Space>s", require("diffview.actions").toggle_stage_entry } },
      },
    })
  end)

  after_each(function()
    config.setup(original_config)
  end)

  for _, status in ipairs({ "D", "A" }) do
    it(
      "preserves staging on a "
        .. (status == "D" and "deleted" or "new")
        .. " file when an old entry is destroyed",
      helpers.async_test(function()
        local repo = helpers.make_repo()
        local view
        local paths = { "a.txt", "b.txt" }
        local ok, err = pcall(function()
          for _, path in ipairs(paths) do
            helpers.write(repo, path, { "contents of " .. path })
          end
          if status == "D" then
            helpers.commit(repo, "files to delete")
            for _, path in ipairs(paths) do
              assert.equals(0, vim.fn.delete(repo .. "/" .. path))
            end
          end

          view = assert(lib.diffview_open({ "-C" .. repo }))
          view:open()
          assert.True(vim.wait(5000, function()
            return view.ready and #view.files.working == #paths
          end, 10))
          local previous = view.files.working[1]
          async.await(view:set_file(previous))
          async.await(view:set_file(view.files.working[2]))
          local layout = view.cur_layout --[[@as Diff2 ]]
          local win = status == "D" and layout.b or layout.a
          vim.api.nvim_set_current_win(win.id)
          assert.equals(File.NULL_FILE.bufnr, vim.api.nvim_get_current_buf())
          assert.is_function(vim.fn.maparg(" s", "n", false, true).callback)

          -- A staging refresh can remove the previous entry after navigation
          -- has already attached the next entry to the shared null buffer.
          previous:destroy()
          assert.False(vim.bo.modifiable)
          assert.is_function(vim.fn.maparg(" s", "n", false, true).callback)
          vim.api.nvim_feedkeys(" s", "mtx", false)
          assert.True(
            vim.wait(5000, function()
              return #view.files.staged == 1
            end, 10),
            "Could not stage b.txt from the empty pane"
          )
          helpers.eq(
            status .. "\tb.txt",
            helpers.run({ "git", "diff", "--cached", "--name-status" }, repo)
          )
        end)

        helpers.close_view(view)
        helpers.cleanup_repo(repo)
        if not ok then
          error(err)
        end
        assert.is_nil(File.attached[File.NULL_FILE.bufnr])
      end)
    )
  end
end)
