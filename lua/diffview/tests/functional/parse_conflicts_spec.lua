local helpers = require("diffview.tests.helpers")
local vcs_utils = require("diffview.vcs.utils")

local eq = helpers.eq

---Split a heredoc-style string into lines the way `nvim_buf_get_lines`
---returns them (no trailing empty element for a final newline).
---@param text string
---@return string[]
local function lines_of(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  -- Drop the trailing empty element produced by the appended `\n`.
  if out[#out] == "" then
    out[#out] = nil
  end
  return out
end

describe("diffview.vcs.utils.parse_conflicts", function()
  describe("git diff3 markers", function()
    it("extracts ours, base, and theirs contents", function()
      local input = lines_of([[
line 1
<<<<<<< HEAD
ours line
||||||| base
base line
=======
theirs line
>>>>>>> branch
line 3]])

      local conflicts = vcs_utils.parse_conflicts(input)

      eq(1, #conflicts)
      local c = conflicts[1]
      eq(2, c.first)
      eq(8, c.last)
      eq({ "ours line" }, c.ours.content)
      eq({ "base line" }, c.base.content)
      eq({ "theirs line" }, c.theirs.content)
    end)

    it("parses a conflict whose git branch label starts with 'conflict'", function()
      -- The label matches the jj header pattern (`<<<<<<< conflict-*`);
      -- without a peek gate on jj sub-markers the jj parser would eat
      -- the region and drop it silently.
      local input = lines_of([[
<<<<<<< conflict-fix
ours line
=======
theirs line
>>>>>>> conflict-fix]])

      local conflicts = vcs_utils.parse_conflicts(input)

      eq(1, #conflicts)
      eq({ "ours line" }, conflicts[1].ours.content)
      eq({ "theirs line" }, conflicts[1].theirs.content)
    end)
  end)

  describe("jj diff-style markers", function()
    it("reconstructs base and theirs from the diff and snapshot", function()
      -- Left side is diff-formatted (against the base "b"), right is a
      -- snapshot. This matches `jj`'s emitted layout for `ui.conflict-
      -- marker-style = "diff"` (the default).
      local input = lines_of([[
a
<<<<<<< conflict 1 of 1
%%%%%%% diff from: xxx aaaaaaaa "initial"
\\\\\\\        to: yyy bbbbbbbb "left"
-b
+b_left
+++++++ zzz cccccccc "right"
b_right
>>>>>>> conflict 1 of 1 ends
c]])

      local conflicts = vcs_utils.parse_conflicts(input)

      eq(1, #conflicts)
      local c = conflicts[1]
      eq(2, c.first)
      eq(9, c.last)
      eq({ "b_left" }, c.ours.content)
      eq({ "b" }, c.base.content)
      eq({ "b_right" }, c.theirs.content)
    end)

    it("reconstructs base once when both sides are diffs against it", function()
      -- With `ui.conflict-marker-style = "diff"`, `jj` emits a `%%%%%%%`
      -- block for every side that can be represented as a diff against the
      -- base, so a 2-sided conflict often has two diff blocks. The base
      -- must be recovered from just one of them, not concatenated.
      local input = lines_of([[
<<<<<<< conflict 1 of 1
%%%%%%% diff from: xxx aaaaaaaa "base"
\\\\\\\        to: yyy bbbbbbbb "left"
-b
+b_left
%%%%%%% diff from: xxx aaaaaaaa "base"
\\\\\\\        to: zzz cccccccc "right"
-b
+b_right
>>>>>>> conflict 1 of 1 ends]])

      local c = vcs_utils.parse_conflicts(input)[1]

      eq({ "b_left" }, c.ours.content)
      eq({ "b" }, c.base.content)
      eq({ "b_right" }, c.theirs.content)
    end)

    it("preserves diff context lines in both sides", function()
      local input = lines_of([[
<<<<<<< conflict 1 of 1
%%%%%%% diff from: xxx aaaaaaaa "initial"
\\\\\\\        to: yyy bbbbbbbb "left"
 keep
-drop
+add
 tail
+++++++ zzz cccccccc "right"
right only
>>>>>>> conflict 1 of 1 ends]])

      local c = vcs_utils.parse_conflicts(input)[1]

      eq({ "keep", "add", "tail" }, c.ours.content)
      eq({ "keep", "drop", "tail" }, c.base.content)
      eq({ "right only" }, c.theirs.content)
    end)
  end)

  describe("jj snapshot-style markers", function()
    it("extracts ours, base, and theirs from three snapshot blocks", function()
      local input = lines_of([[
a
<<<<<<< conflict 1 of 1
+++++++ yyy bbbbbbbb "left"
b_left
------- xxx aaaaaaaa "initial"
b
+++++++ zzz cccccccc "right"
b_right
>>>>>>> conflict 1 of 1 ends
c]])

      local c = vcs_utils.parse_conflicts(input)[1]

      eq({ "b_left" }, c.ours.content)
      eq({ "b" }, c.base.content)
      eq({ "b_right" }, c.theirs.content)
    end)

    it("emits an empty base when no `-------` block is present", function()
      -- Fallback shape (no explicit base): both sides are snapshots.
      local input = lines_of([[
<<<<<<< conflict 1 of 1
+++++++ yyy bbbbbbbb "left"
left content
+++++++ zzz cccccccc "right"
right content
>>>>>>> conflict 1 of 1 ends]])

      local c = vcs_utils.parse_conflicts(input)[1]

      eq({ "left content" }, c.ours.content)
      eq({}, c.base.content)
      eq({ "right content" }, c.theirs.content)
    end)
  end)

  describe("jj N-sided conflict", function()
    it("skips regions with 3+ sides", function()
      -- 3-sided conflicts can't be projected onto ours/base/theirs, so the
      -- region is dropped from the returned list; the parser advances past
      -- the trailer so downstream regions are still picked up.
      local input = lines_of([[
<<<<<<< conflict 1 of 1
+++++++ a
one
+++++++ b
two
+++++++ c
three
>>>>>>> conflict 1 of 1 ends
<<<<<<< conflict 1 of 1
+++++++ y "ours"
two_ours
+++++++ z "theirs"
two_theirs
>>>>>>> conflict 1 of 1 ends]])

      local conflicts = vcs_utils.parse_conflicts(input)

      eq(1, #conflicts)
      eq({ "two_ours" }, conflicts[1].ours.content)
      eq({ "two_theirs" }, conflicts[1].theirs.content)
    end)

    it("skips a 3-sided region emitted as two diffs and a snapshot", function()
      -- Real `jj` output for a 3-parent merge with
      -- `ui.conflict-marker-style = "diff"`: two `%%%%%%%` blocks against
      -- the same base plus a `+++++++` snapshot side. The region is
      -- 3-sided, so it is dropped; the trailing 2-sided region must still
      -- parse.
      local input = lines_of([[
<<<<<<< conflict 1 of 1
%%%%%%% diff from: n "base"
\\\\\\\        to: s "a"
-25
+A
%%%%%%% diff from: n "base"
\\\\\\\        to: v "b"
-25
+B
+++++++ m "c"
C
>>>>>>> conflict 1 of 1 ends
<<<<<<< conflict 1 of 1
+++++++ y "ours"
tail_ours
+++++++ z "theirs"
tail_theirs
>>>>>>> conflict 1 of 1 ends]])

      local conflicts = vcs_utils.parse_conflicts(input)

      eq(1, #conflicts)
      eq({ "tail_ours" }, conflicts[1].ours.content)
      eq({ "tail_theirs" }, conflicts[1].theirs.content)
    end)
  end)

  describe("multiple regions", function()
    it("handles back-to-back jj regions of mixed styles", function()
      local input = lines_of([[
<<<<<<< conflict 1 of 2
+++++++ y "ours"
one_ours
+++++++ z "theirs"
one_theirs
>>>>>>> conflict 1 of 2 ends
<<<<<<< conflict 2 of 2
%%%%%%% diff from: x "base"
\\\\\\\        to: y "ours"
-old
+two_ours
+++++++ z "theirs"
two_theirs
>>>>>>> conflict 2 of 2 ends]])

      local conflicts = vcs_utils.parse_conflicts(input)

      eq(2, #conflicts)
      eq({ "one_ours" }, conflicts[1].ours.content)
      eq({ "one_theirs" }, conflicts[1].theirs.content)
      eq({ "two_ours" }, conflicts[2].ours.content)
      eq({ "old" }, conflicts[2].base.content)
      eq({ "two_theirs" }, conflicts[2].theirs.content)
    end)
  end)
end)
