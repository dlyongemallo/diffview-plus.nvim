-- Inline diff renderer for the `diff1_inline` layout.
--
-- The inline strikethrough rendering for deleted characters in the
-- "overleaf" style is adapted from the sample code shared by
-- @tienlonghungson in issue #109:
-- <https://github.com/dlyongemallo/diffview-plus.nvim/issues/109>
-- which was itself modified from inlinediff-nvim:
-- <https://github.com/YouSame2/inlinediff-nvim>
--
-- The hunk dispatch, style architecture, unified-diff rendering,
-- hybrid word/char intraline tokenization, navigation, and caching are
-- original to this implementation.

local api = vim.api

-- `vim.text.diff` was added in Nvim 0.12; `vim.diff` is still supported
-- but marked deprecated by LuaLS. Alias once here so the eventual switch
-- to `vim.text.diff` (when the plugin's minimum Neovim version is raised
-- to 0.12) is a single-line change.
---@diagnostic disable-next-line: deprecated
local diff = vim.diff

local M = {}

M.ns = api.nvim_create_namespace("diffview_inline_diff")

-- Confine inline-diff extmarks to the diffview window so they don't
-- leak into other windows displaying the same buffer (issue #156).
-- Two APIs:
--   * stable `nvim_win_add_ns`/`nvim_win_remove_ns` (0.12+)
--   * experimental `nvim__ns_set` (0.11; the `{wins = {...}}` shape
--     has been steady).
-- Use the stable pair only when *both* halves ship; otherwise fall
-- back to `nvim__ns_set` if present. With neither available,
-- `WIN_SCOPE_SUPPORTED` is false and `attach_to_window` degrades to a
-- one-shot warning.
-- TODO: drop the experimental fallback when the plugin's minimum
-- Neovim version is raised to 0.12.
local has_stable_pair = api.nvim_win_add_ns ~= nil and api.nvim_win_remove_ns ~= nil
local win_add_ns = has_stable_pair and api.nvim_win_add_ns or nil ---@type (fun(win: integer, ns: integer): boolean?)?
local win_remove_ns = has_stable_pair and api.nvim_win_remove_ns or nil ---@type (fun(win: integer, ns: integer): boolean?)?
---@diagnostic disable-next-line: undefined-field -- experimental 0.11 API.
local ns_set = api.nvim__ns_set ---@type fun(ns: integer, opts: table): table?
local WIN_SCOPE_SUPPORTED = has_stable_pair or ns_set ~= nil

-- Upper bound on `string.rep(" ", pad)` per virt_line. Real terminal widths
-- are well under this; the cap exists to bound memory on unusually wide
-- setups (multi-monitor tiles, font-scaled ultrawides) where the windowed
-- width itself could push into the thousands.
local DELETION_HL_WIDTH_CAP = 500

-- Compute the padding target width for `extent = "full_width"`. Returns the
-- largest text-area width across windows currently displaying `bufnr`, or 0
-- when the buffer isn't shown anywhere (in which case `render_deleted_block`
-- skips emitting the padding chunk). The max correctly fills the widest
-- window without truncating any narrower one sharing the buffer, since
-- clipping handles the over-pad on the smaller window. Each window's
-- `'foldcolumn'`/`'signcolumn'`/number-column width (`textoff`) is excluded
-- so the padding string isn't allocated longer than the actual text region.
-- Capped at `DELETION_HL_WIDTH_CAP` to bound the per-virt_line allocation.
--
-- `hint_winid` is folded into the same max so a renderer called before the
-- buffer is shown there (e.g. `Diff1Inline._prerender`) can still size the
-- pad: width/`textoff` are window properties, so the value holds even when
-- the window currently shows a different buffer.
---@param bufnr integer
---@param hint_winid integer?
---@return integer
local function full_width_target(bufnr, hint_winid)
  local max = 0
  local seen = {}
  local function include(winid)
    if seen[winid] or not api.nvim_win_is_valid(winid) then
      return
    end
    seen[winid] = true
    local info = vim.fn.getwininfo(winid)[1]
    local textoff = (info and info.textoff) or 0
    local w = api.nvim_win_get_width(winid) - textoff
    if w > max then
      max = w
    end
  end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    include(winid)
  end
  if hint_winid then
    include(hint_winid)
  end
  return math.min(max, DELETION_HL_WIDTH_CAP)
end

-- Iterate over UTF-8 characters in `s`. Each step yields the character
-- substring, its 0-indexed byte offset, and its byte length. Pure-Lua O(n)
-- traversal: avoids the quadratic cost of `vim.fn.strcharpart(s, i, 1)` in
-- a per-character loop, which matters on long modified lines.
-- TODO: if the plugin's minimum Neovim version is raised to 0.12, replace
-- this decoder with `vim.str_utf_pos(s)`, which returns the byte start
-- positions of each UTF-8 character in a single call.
---@param s string
---@return fun(): string?, integer?, integer?
local function utf8_iter(s)
  local len = #s
  local pos = 1
  return function()
    if pos > len then
      return nil
    end
    local b = s:byte(pos)
    local char_len
    if b < 0x80 then
      char_len = 1
    elseif b < 0xC2 then
      -- Stray continuation byte or overlong lead; fall back to a single byte
      -- so malformed input still makes forward progress.
      char_len = 1
    elseif b < 0xE0 then
      char_len = 2
    elseif b < 0xF0 then
      char_len = 3
    elseif b < 0xF8 then
      char_len = 4
    else
      char_len = 1
    end
    local remaining = len - pos + 1
    if char_len > remaining then
      char_len = remaining
    end
    local ch = s:sub(pos, pos + char_len - 1)
    local start = pos - 1
    pos = pos + char_len
    return ch, start, char_len
  end
end

-- Classify a byte as a word byte: ASCII alphanumeric, underscore, or any
-- non-ASCII byte (multi-byte UTF-8 sequences are bucketed as word bytes so
-- non-Latin scripts tokenize as word runs rather than per-character).
---@param b integer
---@return boolean
local function is_word_byte(b)
  return b >= 0x80
    or (b >= 0x30 and b <= 0x39)
    or (b >= 0x41 and b <= 0x5A)
    or (b >= 0x61 and b <= 0x7A)
    or b == 0x5F
end

-- Classify a UTF-8 character as word-like. Any multi-byte character is
-- word-like; single-byte characters consult `is_word_byte`.
---@param ch string
---@return boolean
local function is_word_char(ch)
  if ch == "" then
    return false
  end
  if #ch > 1 then
    return true
  end
  return is_word_byte(ch:byte(1))
end

-- True when `s` is a word token (a maximal word-char run produced by
-- `tokenize`). Tokens are either an all-word-char run or a single
-- non-word char, so the first byte determines the class.
---@param s string
---@return boolean
local function is_word_token(s)
  return s ~= "" and is_word_byte(s:byte(1))
end

-- Classify a UTF-8 character into a subword class for `tokenize`:
-- "lower" (ASCII a-z), "upper" (ASCII A-Z), "digit" (ASCII 0-9),
-- "under" (`_`), or `nil` for ASCII non-word characters. Multi-byte
-- characters and stray high bytes from malformed UTF-8 bucket as
-- "lower" so non-Latin runs join adjacent ASCII lowercase. Known
-- consequences: accented uppercase (`Ü`, `É`) doesn't trigger a
-- lower→upper split, and Unicode punctuation/symbols stay inside word
-- tokens rather than splitting them.
---@param ch string
---@return "lower"|"upper"|"digit"|"under"|nil
local function subword_class(ch)
  if ch == "" then
    return nil
  end
  if #ch > 1 then
    return "lower"
  end
  local b = ch:byte(1)
  if b >= 0x80 then
    return "lower"
  end
  if b >= 0x61 and b <= 0x7A then
    return "lower"
  end
  if b >= 0x41 and b <= 0x5A then
    return "upper"
  end
  if b >= 0x30 and b <= 0x39 then
    return "digit"
  end
  if b == 0x5F then
    return "under"
  end
  return nil
end

-- Minimum length for `coalesce_hex_runs` to consider folding subword
-- splits back into a single hex-literal token. Sized to catch full
-- SHAs and longer abbreviations without lumping in short identifier
-- suffixes; 7-char abbreviations stay subword-split.
local HEX_TOKEN_MIN_LEN = 8

-- Upper bound on the longest contiguous letter run permitted in a
-- hex-literal candidate. Random hex averages a max letter run of ~3;
-- pseudo-hex words like `cafe`, `face`, `dead`, `cafef00d`, `decade`
-- exceed the threshold. Hashes that roll a 5+ letter streak skip the
-- coalesce and fall back to the existing `INTRALINE_MAX_HUNKS` gate.
local HEX_TOKEN_MAX_LETTER_RUN = 4

-- True when the concatenation of `tokens[i..j]` (with combined byte
-- length `total_len`) looks like a hash or numeric literal rather
-- than a coincidentally-all-hex identifier. Combines four cheap
-- signals in one O(n) pass over the token slice's bytes:
--   * length >= `HEX_TOKEN_MIN_LEN`,
--   * single-case hex (every letter in `[a-f]` or every letter in
--     `[A-F]`),
--   * digit/letter transitions >= `ceil(length / 4)` (rejects
--     word-prefixed candidates like `decade1234567`),
--   * max contiguous letter run <= `HEX_TOKEN_MAX_LETTER_RUN`
--     (rejects dictionary-shaped runs like `cafef00d1234`).
-- Walking the slice directly lets `coalesce_hex_runs` decide before
-- allocating a merged string, so a non-hex word run (e.g. most
-- camelCase identifiers) bails on its first non-[0-9A-Fa-f] byte.
---@param tokens string[]
---@param i integer
---@param j integer
---@param total_len integer
---@return boolean
local function is_hex_run_in_tokens(tokens, i, j, total_len)
  if total_len < HEX_TOKEN_MIN_LEN then
    return false
  end
  local has_lo, has_up = false, false
  local prev_class = 0 -- 0 = none, 1 = digit, 2 = letter.
  local transitions = 0
  local cur_letter_run, max_letter_run = 0, 0
  for k = i, j do
    local t = tokens[k]
    for p = 1, #t do
      local b = t:byte(p)
      local class
      if b >= 0x30 and b <= 0x39 then
        class = 1
        cur_letter_run = 0
      elseif b >= 0x61 and b <= 0x66 then
        class = 2
        has_lo = true
        cur_letter_run = cur_letter_run + 1
        if cur_letter_run > max_letter_run then
          max_letter_run = cur_letter_run
        end
      elseif b >= 0x41 and b <= 0x46 then
        class = 2
        has_up = true
        cur_letter_run = cur_letter_run + 1
        if cur_letter_run > max_letter_run then
          max_letter_run = cur_letter_run
        end
      else
        return false
      end
      if prev_class ~= 0 and prev_class ~= class then
        transitions = transitions + 1
      end
      prev_class = class
    end
  end
  if has_lo and has_up then
    return false
  end
  if max_letter_run > HEX_TOKEN_MAX_LETTER_RUN then
    return false
  end
  if transitions < math.ceil(total_len / 4) then
    return false
  end
  return true
end

-- Thin string wrapper around `is_hex_run_in_tokens`. The production
-- path (`coalesce_hex_runs`) drives the token-slice variant directly;
-- this wrapper exists so the predicate stays exercisable from tests
-- with a single string input.
---@param s string
---@return boolean
local function is_hex_run(s)
  return is_hex_run_in_tokens({ s }, 1, 1, #s)
end

-- Walk a fresh `tokenize` token list and merge runs of byte-adjacent
-- word tokens whose joined string passes `is_hex_run_in_tokens`. A
-- 40-char hash that would otherwise fragment into ~25 alternating
-- digit/letter subwords folds back into one token, so a 1:1 hash
-- replacement renders as a whole-token swap instead of slipping under
-- `INTRALINE_MAX_HUNKS` from coincidental subword matches between two
-- unrelated hashes.
--
-- The walk is bounded by byte adjacency so it can't span a non-word
-- char: `"v1.0-1c9dfb..."` keeps `v`, dots, and dashes as natural
-- boundaries. Within one source word run the walk is all-or-nothing.
---@param tokens string[]
---@param byte_map { byte: integer, byte_len: integer }[]
---@return string[]
---@return { byte: integer, byte_len: integer }[]
local function coalesce_hex_runs(tokens, byte_map)
  local out, out_map = {}, {}
  local i = 1
  while i <= #tokens do
    if not is_word_token(tokens[i]) then
      out[#out + 1] = tokens[i]
      out_map[#out_map + 1] = byte_map[i]
      i = i + 1
    else
      local j = i
      while
        j + 1 <= #tokens
        and is_word_token(tokens[j + 1])
        and byte_map[j + 1].byte == byte_map[j].byte + byte_map[j].byte_len
      do
        j = j + 1
      end

      if j > i then
        local merged_len = byte_map[j].byte + byte_map[j].byte_len - byte_map[i].byte
        if is_hex_run_in_tokens(tokens, i, j, merged_len) then
          out[#out + 1] = table.concat(tokens, "", i, j)
          out_map[#out_map + 1] = {
            byte = byte_map[i].byte,
            byte_len = merged_len,
          }
        else
          for k = i, j do
            out[#out + 1] = tokens[k]
            out_map[#out_map + 1] = byte_map[k]
          end
        end
      else
        out[#out + 1] = tokens[i]
        out_map[#out_map + 1] = byte_map[i]
      end
      i = j + 1
    end
  end
  return out, out_map
end

-- Tokenize `s` for intraline diffing. Splits at ASCII non-word
-- characters and at subword boundaries within word-char runs:
-- camelCase (`fooBar` → `foo`, `Bar`), acronym→word (`XMLParser` →
-- `XML`, `Parser`), digit↔letter (`error123abc` → `error`, `123`,
-- `abc`), and underscore (`audio_preservation` → `audio`, `_`,
-- `preservation`). Each non-word char becomes its own token; each
-- subword run becomes one token. Multi-byte chars bucket as
-- lowercase; see `subword_class`. Returns the token list and a
-- parallel byte-range map.
--
-- Subword granularity keeps `vim.diff --minimal` from latching onto
-- coincidental letters in dissimilar lines or in the divergent tails
-- of structurally similar identifiers, both of which would render as
-- per-char noise in overleaf style. A post-pass (`coalesce_hex_runs`)
-- folds the splits back into one token for long hash-like hex runs
-- so git SHAs and similar literals stay atomic.
---@param s string
---@return string[] tokens
---@return { byte: integer, byte_len: integer }[] byte_map
local function tokenize(s)
  local tokens, byte_map = {}, {}
  -- Active token state. `cur_class == nil` means no active word run.
  ---@type "lower"|"upper"|"digit"|"under"|nil
  local cur_class
  local cur_chars = {}
  local cur_start_byte = 0
  local cur_byte_len = 0

  local function flush()
    if #cur_chars == 0 then
      return
    end
    tokens[#tokens + 1] = table.concat(cur_chars)
    byte_map[#byte_map + 1] = { byte = cur_start_byte, byte_len = cur_byte_len }
    cur_chars = {}
    cur_byte_len = 0
    cur_class = nil
  end

  for ch, byte_pos, char_len in utf8_iter(s) do
    local cls = subword_class(ch)

    if cls == nil then
      -- Non-word: each char is its own token, breaks any active run.
      flush()
      tokens[#tokens + 1] = ch
      byte_map[#byte_map + 1] = { byte = byte_pos, byte_len = char_len }
    elseif cur_class == nil then
      cur_chars = { ch }
      cur_start_byte = byte_pos
      cur_byte_len = char_len
      cur_class = cls
    elseif cur_class == cls then
      cur_chars[#cur_chars + 1] = ch
      cur_byte_len = cur_byte_len + char_len
    elseif cur_class == "upper" and cls == "lower" then
      -- Upper→lower transition. A single-upper run (`P` in `Parser`)
      -- continues with the lowercase tail as one subword. A multi-upper
      -- run (`XML` in `XMLParser`) is the acronym→word case: the trailing
      -- upper actually starts the following lowercase word, so split off
      -- the prefix and seed a new run with the popped upper + this lower.
      if #cur_chars >= 2 then
        local last_ch = cur_chars[#cur_chars]
        local last_byte_len = #last_ch
        cur_chars[#cur_chars] = nil
        cur_byte_len = cur_byte_len - last_byte_len
        flush()
        cur_chars = { last_ch, ch }
        cur_start_byte = byte_pos - last_byte_len
        cur_byte_len = last_byte_len + char_len
        cur_class = "lower"
      else
        cur_chars[#cur_chars + 1] = ch
        cur_byte_len = cur_byte_len + char_len
        cur_class = "lower"
      end
    else
      flush()
      cur_chars = { ch }
      cur_start_byte = byte_pos
      cur_byte_len = char_len
      cur_class = cls
    end
  end
  flush()

  return coalesce_hex_runs(tokens, byte_map)
end

-- Decompose `s` into UTF-8 characters with byte offsets. Used to refine a
-- 1:1 word-token replacement into per-character sub-hunks, preserving
-- typo-level precision (e.g. `recieve` → `receive` highlights only the
-- moved `i`).
---@param s string
---@return string[] chars
---@return { byte: integer, byte_len: integer }[] byte_map
local function split_chars(s)
  local chars, byte_map = {}, {}
  for ch, byte_pos, char_len in utf8_iter(s) do
    chars[#chars + 1] = ch
    byte_map[#byte_map + 1] = { byte = byte_pos, byte_len = char_len }
  end
  return chars, byte_map
end

-- Diff two unit arrays (tokens or chars) using `vim.diff`. Units are
-- joined with newlines so each unit maps to one "line" in vim.diff's
-- output; indices in the returned hunks are 1-based positions into the
-- input arrays.
--
-- Appending a trailing newline to both joined strings is essential.
-- Without it, `vim.diff` treats the final unit as an incomplete line
-- and can spuriously classify a matching trailing unit as
-- deleted+reinserted when one side has many more units after the
-- common run — e.g. `"function...(status)"` vs the same line with
-- `" return ... end"` appended would report `)` as deleted and
-- `) return ... end` as inserted, instead of recognizing `)` as the
-- end of the common prefix and treating the rest as pure addition.
-- Same remedy as the outer line-level diff in `render()`.
--
-- `'diffopt'`'s `ignore_*` whitespace/blank-line flags are deliberately
-- not forwarded here. Those flags only decide which lines are paired as
-- modifications by the outer hunk diff; once a pair is formed, the
-- intraline highlight reflects the actual character differences so the
-- reader can see exactly what changed. This matches how |hl-DiffText|
-- works in the built-in side-by-side diff.
---@param a_units string[]
---@param b_units string[]
---@return integer[][]
local function diff_units(a_units, b_units)
  if #a_units == 0 or #b_units == 0 then
    return {}
  end
  local a = table.concat(a_units, "\n") .. "\n"
  local b = table.concat(b_units, "\n") .. "\n"
  return diff(a, b, {
    result_type = "indices",
    algorithm = "minimal",
    ctxlen = 0,
    linematch = 0,
    indent_heuristic = false,
  }) --[[@as integer[][] ]] or {}
end

-- Skip intraline highlighting when a diff produces more than this many
-- hunks. Applied to word-level hunks as the similarity gate (dissimilar
-- lines cascade into many small word-level hunks) and to char-level
-- sub-hunks inside a 1:1 word replacement (if refinement fragments,
-- render the word as a whole instead).
local INTRALINE_MAX_HUNKS = 3

-- A 1:1 word replacement is safe to refine to char level only when the
-- sub-diff won't interleave deleted and inserted chars into garbage. A
-- single sub-hunk always renders cleanly (one anchor, one span). Two or
-- three sub-hunks are fine when the words genuinely overlap, signalled
-- by a shared prefix or suffix of at least two chars (e.g. `recieve`
-- vs `receive` shares `rec` + `ve`). Without that overlap, a lone
-- coincidental match (e.g. the single `r` in `param`/`return`)
-- fragments the diff and renders as `[pa]r[am]eturn` — worse than
-- falling back to a whole-word `[param]return` replacement.
---@param old_chars string[]
---@param new_chars string[]
---@param n_hunks integer
---@return boolean
local function refinement_safe(old_chars, new_chars, n_hunks)
  if n_hunks == 0 or n_hunks > INTRALINE_MAX_HUNKS then
    return false
  end
  if n_hunks == 1 then
    return true
  end

  local pre = 0
  while pre < #old_chars and pre < #new_chars and old_chars[pre + 1] == new_chars[pre + 1] do
    pre = pre + 1
  end
  if pre >= 2 then
    return true
  end

  local suf = 0
  while
    suf < #old_chars - pre
    and suf < #new_chars - pre
    and old_chars[#old_chars - suf] == new_chars[#new_chars - suf]
  do
    suf = suf + 1
  end
  return suf >= 2
end

-- Render a single intraline diff hunk as extmarks. Units (tokens or
-- characters) are located via `byte_map` with positions relative to the
-- span's origin at `base_byte`; `span_byte_len` is the byte length of
-- the span (the full line for word-level hunks, a single token for
-- refined char-level sub-hunks) and serves as the deletion-anchor
-- fallback when an index falls off the map.
---@param bufnr integer
---@param new_row integer
---@param base_byte integer
---@param span_byte_len integer
---@param byte_map { byte: integer, byte_len: integer }[]
---@param new_start integer
---@param new_count integer
---@param del_text string Joined deleted units ("" if none).
---@param inline_del boolean
local function render_hunk(
  bufnr,
  new_row,
  base_byte,
  span_byte_len,
  byte_map,
  new_start,
  new_count,
  del_text,
  inline_del
)
  if new_count > 0 then
    -- A hunk is a contiguous range, so emit one extmark spanning all units
    -- rather than one per unit (avoids thousands of extmarks on long lines).
    local first = byte_map[new_start]
    local last = byte_map[new_start + new_count - 1]
    if first and last then
      api.nvim_buf_set_extmark(bufnr, M.ns, new_row, base_byte + first.byte, {
        end_col = base_byte + last.byte + last.byte_len,
        hl_group = "DiffviewDiffAddInline",
        priority = 200,
      })
    else
      -- Defensive fallback when byte_map can't resolve both ends — should
      -- not happen with a well-formed UTF-8 string but handle it so partial
      -- highlighting still appears.
      for k = new_start, new_start + new_count - 1 do
        local info = byte_map[k]
        if info then
          api.nvim_buf_set_extmark(bufnr, M.ns, new_row, base_byte + info.byte, {
            end_col = base_byte + info.byte + info.byte_len,
            hl_group = "DiffviewDiffAddInline",
            priority = 200,
          })
        end
      end
    end
  end

  if inline_del and del_text ~= "" then
    local anchor_col
    if new_count > 0 then
      -- Replacement: anchor before the first added unit.
      anchor_col = base_byte + ((byte_map[new_start] and byte_map[new_start].byte) or span_byte_len)
    elseif new_start < 1 then
      -- Pure deletion at the start of the span.
      anchor_col = base_byte
    else
      -- Pure deletion mid/end: anchor after the context unit at new_start.
      local info = byte_map[new_start]
      anchor_col = base_byte + (info and (info.byte + info.byte_len) or span_byte_len)
    end

    api.nvim_buf_set_extmark(bufnr, M.ns, new_row, anchor_col, {
      virt_text = { { del_text, "DiffviewDiffDeleteInline" } },
      virt_text_pos = "inline",
      priority = 200,
    })
  end
end

-- Highlight changed ranges on a paired line. Uses a hybrid
-- word/char-level diff: hunks are computed at word granularity to avoid
-- coincidental-letter fragmentation, and 1:1 word-token replacements are
-- refined with a per-character sub-diff so typo-level precision is
-- preserved (e.g. `recieve` → `receive` highlights only the moved `i`
-- rather than the whole word).
--
-- When `inline_del` is true, additionally emit inline virtual text for
-- deleted units (the "overleaf" style). Bails out when the word-level
-- diff is too fragmented (a signal that the paired lines aren't really
-- related).
---@param bufnr integer
---@param new_row integer 0-indexed row in `bufnr`.
---@param old_line string
---@param new_line string
---@param inline_del boolean Render deleted units as inline virt_text.
---@return "ok"|"noop"|"skipped" # `ok`: rendered; `noop`: identical (nothing to do); `skipped`: fragmented, caller may want to fall back.
local function render_char_highlights(bufnr, new_row, old_line, new_line, inline_del)
  if old_line == new_line then
    return "noop"
  end
  -- Blank-to-nonblank (or vice versa) has no meaningful char-level diff, but
  -- the lines differ: signal `skipped` so the caller's fallback path still
  -- renders a line highlight / echoes the old line in overleaf style.
  if old_line == "" or new_line == "" then
    return "skipped"
  end

  local old_tokens = tokenize(old_line)
  local new_tokens, new_map = tokenize(new_line)
  local hunks = diff_units(old_tokens, new_tokens)
  if #hunks == 0 then
    return "noop"
  end
  if #hunks > INTRALINE_MAX_HUNKS then
    return "skipped"
  end

  local new_line_len = #new_line

  for _, h in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]

    -- Try char-level refinement by diffing the concatenation of the old
    -- tokens in this hunk against the concatenation of the new tokens.
    -- This covers:
    --   - typo-style 1:1 word replacements (`recieve` → `receive`),
    --   - mid-word edits split across token boundaries
    --     (`statusend` → `status end`: delete the word, insert
    --     word+space+word — concat diff sees one inserted space),
    --   - punctuation swaps (`,` → `;`: one sub-hunk, clean).
    -- The `refinement_safe` guard rejects concatenations whose char-level
    -- diff is fragmented without genuine overlap (e.g. `something` vs
    -- `any tracked metric` shares only coincidental letters and falls
    -- back to word-level whole-token rendering).
    local refined = false
    if old_count > 0 and new_count > 0 then
      local old_parts = {}
      for k = old_start, old_start + old_count - 1 do
        old_parts[#old_parts + 1] = old_tokens[k] or ""
      end
      local new_parts = {}
      for k = new_start, new_start + new_count - 1 do
        new_parts[#new_parts + 1] = new_tokens[k] or ""
      end
      local old_concat = table.concat(old_parts)
      local new_concat = table.concat(new_parts)

      if old_concat ~= "" and new_concat ~= "" and old_concat ~= new_concat then
        local old_chars = split_chars(old_concat)
        local new_chars, new_char_map = split_chars(new_concat)
        local sub_hunks = diff_units(old_chars, new_chars)

        if refinement_safe(old_chars, new_chars, #sub_hunks) then
          refined = true
          local region_start = new_map[new_start]
          local region_end = new_map[new_start + new_count - 1]
          local region_base = region_start.byte
          local region_len = (region_end.byte + region_end.byte_len) - region_base

          for _, sh in ipairs(sub_hunks) do
            local sos, soc, sns, snc = sh[1], sh[2], sh[3], sh[4]
            local del_text = ""
            if inline_del and soc > 0 then
              local parts = {}
              for k = sos, sos + soc - 1 do
                parts[#parts + 1] = old_chars[k] or ""
              end
              del_text = table.concat(parts)
            end
            render_hunk(
              bufnr,
              new_row,
              region_base,
              region_len,
              new_char_map,
              sns,
              snc,
              del_text,
              inline_del
            )
          end
        end
      end
    end

    if not refined then
      local del_text = ""
      if inline_del and old_count > 0 then
        local parts = {}
        for k = old_start, old_start + old_count - 1 do
          parts[#parts + 1] = old_tokens[k] or ""
        end
        del_text = table.concat(parts)
      end
      render_hunk(
        bufnr,
        new_row,
        0,
        new_line_len,
        new_map,
        new_start,
        new_count,
        del_text,
        inline_del
      )
    end
  end

  return "ok"
end

-- A single tree-sitter capture span on one line: `{col_start, col_end,
-- hl_group}`, with byte-0-indexed columns and `hl_group` in `@<capture>`
-- form.
---@alias InlineDiff.LineCapture { [1]: integer, [2]: integer, [3]: string }

-- Cap on the total source length (`#source`) above which
-- `compute_old_line_captures` short-circuits to `{}` rather than parsing.
-- A full TS parse + highlights-query iteration is synchronous and runs
-- on every render that touches a deletion-bearing call site (modulo the
-- `M._captures_by_buf` cache hit), so a large source — e.g. a deletion
-- spanning a generated/minified file — would block the UI. The per-line
-- `CAPTURED_CHUNKS_MAX_LEN` cap protects the chunk builder but does
-- nothing about the parse cost, which is what this cap is for. Sized
-- around the upper bound of a hand-written deletion block: a
-- thousand-line file averaging 100 chars/line is ~100 KB, and anything
-- larger is almost certainly generated content the user didn't expect
-- to syntax-highlight.
local CAPTURE_SOURCE_MAX_LEN = 100000

-- Compute per-line tree-sitter captures for `old_lines` using the buffer's
-- filetype to pick the parser. Returns a table mapping 1-based line index to
-- a list of `InlineDiff.LineCapture` entries. Multi-line captures (e.g.
-- multi-line strings or comments) are split into one entry per spanned line
-- so the per-line chunk builder can apply them without crossing line
-- boundaries. Returns an empty table whenever any required piece is missing
-- — no filetype, no language mapping, parser not installed, parse failure,
-- no highlights query, or source larger than `CAPTURE_SOURCE_MAX_LEN` — so
-- callers can unconditionally treat the result as "captures or nothing."
-- `source` is optional; when supplied (e.g. by `M.render`, which already
-- joined `old_lines` for `vim.diff`), it's reused as the parser input,
-- avoiding a second O(N) `table.concat`. A trailing newline is harmless.
---@param old_lines string[]
---@param bufnr integer
---@param source? string Pre-joined `old_lines` (`"\n"`-separated). Computed if omitted.
---@return table<integer, InlineDiff.LineCapture[]>
local function compute_old_line_captures(old_lines, bufnr, source)
  if #old_lines == 0 or not api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local ft = vim.bo[bufnr].filetype
  if not ft or ft == "" then
    return {}
  end

  local lang = vim.treesitter.language.get_lang(ft)
  if not lang then
    return {}
  end

  source = source or table.concat(old_lines, "\n")
  if #source > CAPTURE_SOURCE_MAX_LEN then
    return {}
  end
  -- `get_string_parser` loads the parser shared library on first use; pcall
  -- catches the "parser not installed" path so we degrade silently rather
  -- than surfacing a stack trace through every render.
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok_parser or not parser then
    return {}
  end

  -- Wrap parse + capture iteration in pcall: injection-language failures,
  -- malformed queries, or runtime errors inside predicates can throw, and
  -- a render-time exception would be more disruptive than missing colour.
  local ok, result = pcall(function()
    local trees = parser:parse(true)
    if not trees or not trees[1] then
      return nil
    end
    local root = trees[1]:root()

    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      return nil
    end

    local out = {}
    local function add(line_idx, col_start, col_end, hl)
      out[line_idx] = out[line_idx] or {}
      out[line_idx][#out[line_idx] + 1] = { col_start, col_end, hl }
    end

    for id, node in query:iter_captures(root, source) do
      local capture = query.captures[id]
      -- Underscore-prefixed captures are TS-internal scratch names used by
      -- predicates; they don't map to highlight groups.
      if not capture:match("^_") then
        local sr, sc, er, ec = node:range()
        local hl = "@" .. capture
        if sr == er then
          add(sr + 1, sc, ec, hl)
        else
          -- Multi-line capture: emit one entry per spanned line. Line `sr`
          -- runs from `sc` to end-of-line; intermediate lines span the full
          -- line; line `er` runs from 0 to `ec`.
          add(sr + 1, sc, #(old_lines[sr + 1] or ""), hl)
          for k = sr + 1, er - 1 do
            add(k + 1, 0, #(old_lines[k + 1] or ""), hl)
          end
          add(er + 1, 0, ec, hl)
        end
      end
    end

    return out
  end)

  if not ok or not result then
    return {}
  end
  return result
end

-- Cap on `text` length above which `captured_chunks` skips per-byte capture
-- resolution and emits the plain `{ {text, del_hl} }` chunk. The per-byte
-- pass is O(text_len) in time and memory, which gets pathological on
-- minified-bundle lines (10s of KB). Mirrors the spirit of `'synmaxcol'`
-- (Neovim's syntax-highlighting cutoff) with a higher bound, since this
-- runs once per render rather than per redraw.
local CAPTURED_CHUNKS_MAX_LEN = 5000

-- Build virt_line chunks for `text`, layering tree-sitter captures on top of
-- `del_hl` so deletions keep their background while showing TS colours on
-- top. `caps` is a list of `{col_start, col_end, hl}` whose columns reference
-- `text` directly — slice callers (e.g. the "hanging" extent) must offset
-- before calling. Each output chunk uses `{del_hl, ts_hl_1, ts_hl_2, ...}` —
-- the full capture stack covering that byte run, in `iter_captures` order
-- (= rightmost in the resulting hl_group list = highest priority for
-- Neovim's merger). Forwarding the whole stack rather than picking the
-- last capture matters for decoration-only captures like `@spell` that
-- define no fg: a "last wins" pick would silently drop the earlier
-- `@comment` fg, leaving deleted comments under the default Normal fg.
-- Stacking lets Neovim's hl-group merger compose attributes the same way
-- the on-buffer TS highlighter would — rightmost wins per-attribute, but
-- undefined attributes don't override. With no captures (or `text` over
-- `CAPTURED_CHUNKS_MAX_LEN`), returns the same `{ {text, del_hl} }` the
-- pre-TS code produced. Empty `text` returns `{ { "", del_hl } }` rather
-- than `{}` so a deleted blank line still renders as a virt_line row
-- instead of being elided to nothing.
---@param text string
---@param caps InlineDiff.LineCapture[]?
---@param del_hl string
---@return table[]
local function captured_chunks(text, caps, del_hl)
  if text == "" or not caps or #caps == 0 or #text > CAPTURED_CHUNKS_MAX_LEN then
    return { { text, del_hl } }
  end

  local len = #text
  -- Per-byte capture stack: every hl that covers the byte, appended in
  -- `iter_captures` order. The hl_group list treats that order as priority
  -- (rightmost = highest), so a more-specific capture (e.g.
  -- `@comment.documentation` following `@comment`) wins for any attribute it
  -- redefines, while earlier captures still contribute attributes the later
  -- ones leave undefined.
  local stacks = {}
  for _, c in ipairs(caps) do
    local sc, ec, hl = c[1], c[2], c[3]
    -- Clamp to `len` so a stale or off-by-one capture can't write past
    -- the string end and create a phantom chunk on the next iteration.
    local stop = math.min(ec, len)
    for i = sc + 1, stop do
      local s = stacks[i]
      if s == nil then
        stacks[i] = { hl }
      else
        s[#s + 1] = hl
      end
    end
  end

  -- Coalesce contiguous bytes whose stacks are element-wise identical into a
  -- single chunk. Captures only ever get appended (never removed mid-byte) in
  -- the loop above, so two adjacent positions with the same stack must have
  -- been covered by the same set of captures in the same iteration order.
  local function same_stack(a, b)
    if a == nil and b == nil then
      return true
    end
    if a == nil or b == nil then
      return false
    end
    if #a ~= #b then
      return false
    end
    for k = 1, #a do
      if a[k] ~= b[k] then
        return false
      end
    end
    return true
  end

  local function build_groups(stack)
    if not stack then
      return del_hl
    end
    local groups = { del_hl }
    for _, hl in ipairs(stack) do
      groups[#groups + 1] = hl
    end
    return groups
  end

  local chunks = {}
  local segment_start = 1
  local current = stacks[1]
  for i = 2, len do
    if not same_stack(stacks[i], current) then
      chunks[#chunks + 1] = { text:sub(segment_start, i - 1), build_groups(current) }
      segment_start = i
      current = stacks[i]
    end
  end
  chunks[#chunks + 1] = { text:sub(segment_start, len), build_groups(current) }
  return chunks
end

-- Attach a block of deleted lines as virtual lines near `new_start`. The
-- `extent` argument controls how far the `del_hl` background reaches:
--   • `"text"`:       only the deleted characters carry `del_hl`.
--   • `"full_width"`: append a space-padded chunk under `del_hl` so the
--                     highlight spans the row (matching
--                     `diff2_horizontal`'s native `DiffDelete` look). Pad
--                     target is `full_width_target(bufnr)`.
--   • `"hanging"`:    leading whitespace is emitted unhighlighted; the
--                     remainder of the line carries `del_hl`.
-- When `line_captures` is supplied, foreground tree-sitter highlights are
-- layered on each line's chunks so the deleted text reads with syntax
-- colour even though the lines themselves are virtual (and so unparsable
-- by the buffer's own TS attachment).
---@param bufnr integer
---@param old_lines string[]
---@param old_from integer 1-based start index into `old_lines`.
---@param old_to integer 1-based end index (inclusive).
---@param new_start integer Line position in new content (0 = before first line).
---@param anchor_row? integer 0-indexed row to attach to; default `new_start - 1`.
---@param above? boolean Default: `new_start == 0`.
---@param del_hl? string Highlight group for the deleted text. Default: `DiffviewDiffDelete`.
---@param extent? "text"|"full_width"|"hanging" Default: `"text"`.
---@param fw_target? integer Pad target for `extent == "full_width"`. Default: 0 (no padding).
---@param line_captures? table<integer, InlineDiff.LineCapture[]> Per-`old_lines` index TS captures from `compute_old_line_captures`.
local function render_deleted_block(
  bufnr,
  old_lines,
  old_from,
  old_to,
  new_start,
  anchor_row,
  above,
  del_hl,
  extent,
  fw_target,
  line_captures
)
  del_hl = del_hl or "DiffviewDiffDelete"
  extent = extent or "text"
  fw_target = fw_target or 0
  local virt_lines = {}
  -- `strdisplaywidth` reads `tabstop` from the current buffer; evaluate
  -- widths against `bufnr` so tab-bearing deletions pad correctly when
  -- the caller's current buffer differs.
  api.nvim_buf_call(bufnr, function()
    for k = old_from, old_to do
      local text = old_lines[k] or ""
      local caps = line_captures and line_captures[k] or nil
      local chunks
      if extent == "full_width" then
        chunks = captured_chunks(text, caps, del_hl)
        local pad = fw_target - vim.fn.strdisplaywidth(text)
        if pad > 0 then
          chunks[#chunks + 1] = { string.rep(" ", pad), del_hl }
        end
      elseif extent == "hanging" then
        local indent, rest = text:match("^(%s*)(.*)$")
        if rest ~= "" then
          chunks = {}
          if indent ~= "" then
            chunks[#chunks + 1] = { indent }
          end
          -- Captures reference offsets in `text`; shift them to `rest`'s
          -- coordinate space and drop entries that fell entirely inside
          -- the unhighlighted indent.
          local rest_caps
          if caps then
            local indent_len = #indent
            rest_caps = {}
            for _, c in ipairs(caps) do
              if c[2] > indent_len then
                rest_caps[#rest_caps + 1] = {
                  math.max(0, c[1] - indent_len),
                  c[2] - indent_len,
                  c[3],
                }
              end
            end
          end
          for _, rc in ipairs(captured_chunks(rest, rest_caps, del_hl)) do
            chunks[#chunks + 1] = rc
          end
        else
          -- Empty or all-whitespace line: no "rest" to highlight without
          -- making the row invisible. Fall back to highlighting the whole
          -- line so the deletion stays visible.
          chunks = { { text, del_hl } }
        end
      else
        chunks = captured_chunks(text, caps, del_hl)
      end
      virt_lines[#virt_lines + 1] = chunks
    end
  end)

  if #virt_lines == 0 then
    return
  end

  local row = anchor_row
  if row == nil then
    row = new_start == 0 and 0 or new_start - 1
  end

  if above == nil then
    above = new_start == 0
  end

  local line_count = api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return
  end

  if row >= line_count then
    row = line_count - 1
  end

  api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = above,
    priority = 100,
  })
end

-- Per-buffer cache of hunks so ]c/[c navigation can find them without
-- re-scanning extmarks. Keyed by bufnr; cleared by `M.clear` and by a
-- buffer-lifecycle autocmd so externally-wiped buffers don't leak entries.
---@type table<integer, integer[][]>
M._hunks_by_buf = {}

-- Per-buffer cache of tree-sitter captures for the old side. Survives
-- `M.clear`/`M.render` so `_repaint`-style flows (where `old_lines` is held
-- by the caller and reused unchanged) skip the parse on every redraw. The
-- entry is matched by filetype + content equality on the joined old-side
-- string `old`, so an in-place mutation of `old_lines` still invalidates
-- (the next render rebuilds `old` and the comparison fails). String
-- equality on `old` is O(N) but always cheaper than re-parsing + running
-- the highlights query. Cleared by `M.detach` and by the same
-- buffer-lifecycle autocmd as `_hunks_by_buf`.
---@type table<integer, { ft: string, old: string, captures: table<integer, InlineDiff.LineCapture[]> }>
M._captures_by_buf = {}

-- Per-buffer set of winids where `M.ns` is currently scoped. Maintained
-- via the stable `nvim_win_add_ns`/`nvim_win_remove_ns` pair, or via
-- `nvim__ns_set` (which `detach_from_all_windows` rebuilds from the
-- remaining buffers' winids). Lets `M.detach` and the buffer-lifecycle
-- autocmd drop this buffer's contributions before clearing extmarks.
-- Empty when neither scope API is available.
---@type table<integer, table<integer, true>>
M._scoped_wins_by_buf = {}

-- One-shot per-session flag: the first time `attach_to_window` runs on
-- Neovim < 0.11 against a buffer that's also displayed outside the
-- diffview window, emit the leak warning once. Avoids re-warning on
-- every repaint or on every file inside a long file-history walk.
local leak_warned = false

-- Forward declaration so the BufWipeout/BufDelete autocmd installed by
-- `register_cache_cleanup` (defined below) can call into this helper,
-- which itself isn't declared until further down the file. The body is
-- assigned at the actual definition site.
---@type fun(bufnr: integer)
local detach_from_all_windows

-- Track which buffers already have a cleanup autocmd so we don't register
-- duplicates across repeated render passes on the same buffer.
---@type table<integer, true>
local cache_cleanup_registered = {}

local cache_cleanup_augroup =
  api.nvim_create_augroup("diffview_inline_diff_hunk_cache", { clear = true })

-- Track buffers whose CursorMoved scroll-adjuster is already installed.
---@type table<integer, true>
local scroll_adjuster_registered = {}

local scroll_adjuster_augroup =
  api.nvim_create_augroup("diffview_inline_diff_scroll", { clear = true })

---@param bufnr integer
local function register_cache_cleanup(bufnr)
  if cache_cleanup_registered[bufnr] or not api.nvim_buf_is_valid(bufnr) then
    return
  end

  cache_cleanup_registered[bufnr] = true
  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = cache_cleanup_augroup,
    buffer = bufnr,
    once = true,
    callback = function(args)
      M._hunks_by_buf[args.buf] = nil
      M._captures_by_buf[args.buf] = nil
      -- The hosting windows may still be valid (e.g. `:bdelete`
      -- switches them to an alternate buffer rather than closing
      -- them), and on the experimental `nvim__ns_set` path the
      -- namespace's window list is global across all attached
      -- buffers, so leaving stale winids in it would leak this
      -- buffer's old slots into rendering for *other* still-attached
      -- buffers. `detach_from_all_windows` rebuilds the list
      -- correctly under both APIs.
      detach_from_all_windows(args.buf)
      cache_cleanup_registered[args.buf] = nil
      -- Buffer-scoped autocmds on the scroll-adjuster group are dropped by
      -- Neovim when the buffer is wiped, so only the registration flag needs
      -- resetting here.
      scroll_adjuster_registered[args.buf] = nil
    end,
  })
end

-- Count virt_lines on a single row that match the `above` orientation.
---@param bufnr integer
---@param row integer 0-indexed.
---@param above boolean
---@return integer
local function count_edge_virt_lines(bufnr, row, above)
  local marks = api.nvim_buf_get_extmarks(bufnr, M.ns, { row, 0 }, { row, -1 }, { details = true })
  local total = 0
  for _, m in ipairs(marks) do
    local d = m[4]
    if d and d.virt_lines and (d.virt_lines_above or false) == above then
      total = total + #d.virt_lines
    end
  end
  return total
end

-- Bump `topline` just enough that virt_lines attached below the last
-- buffer line are visible whenever the cursor sits on that line.
-- Neovim's scroll computation does not count virt_lines, so motions
-- that land at EOF (`G`, `:$`, `}`, `Shift-L`, `<C-End>`, …) leave the
-- rendered deletions clipped below the viewport — the user sees them
-- only after a manual `zz`/`zb`. Idempotent: when topline is already
-- high enough, winrestview is not called (so WinScrolled doesn't
-- re-fire and there's no feedback loop).
---@param bufnr integer
---@param winid integer
function M.ensure_eof_virt_lines_visible(bufnr, winid)
  if not (api.nvim_buf_is_valid(bufnr) and api.nvim_win_is_valid(winid)) then
    return
  end
  if api.nvim_win_get_buf(winid) ~= bufnr then
    return
  end

  local last_row = api.nvim_buf_line_count(bufnr)
  if last_row == 0 then
    return
  end
  if api.nvim_win_get_cursor(winid)[1] ~= last_row then
    return
  end

  local below = count_edge_virt_lines(bufnr, last_row - 1, false)
  if below == 0 then
    return
  end

  local height = api.nvim_win_get_height(winid)
  -- Clamp `below` so we never ask for a topline past `last_row`: we can't
  -- show more virt_lines below the cursor than a full window's worth.
  local effective_below = math.min(below, math.max(height - 1, 0))
  local min_topline = math.min(last_row, math.max(1, last_row - (height - 1 - effective_below)))

  api.nvim_win_call(winid, function()
    local view = vim.fn.winsaveview()
    if view.topline < min_topline then
      view.topline = min_topline
      vim.fn.winrestview(view)
    end
  end)
end

-- Keep `topfill` in sync with the `virt_lines_above` count attached to
-- line 1: when `topline == 1`, topfill should equal the BOF virt_lines
-- count so the deletions render inside the viewport above line 1;
-- otherwise topfill should be 0 so stale filler from a previous render
-- doesn't leave an empty band at the top after BOF deletions go away
-- (e.g. re-render with no leading hunks, or a layout switch).
--
-- Gated on `M._hunks_by_buf[bufnr]` so we only touch topfill while the
-- buffer still hosts an inline diff — the CursorMoved autocmd that
-- calls this function outlives the inline layout, and we don't want to
-- fight diff-mode's own topfill on a buffer that's since switched
-- layouts.
--
-- `topfill` is normally a diff-mode filler-rows count, but Neovim
-- honours it for virt_lines_above on topline even when `'diff'` is off.
---@param bufnr integer
---@param winid integer
function M.ensure_bof_virt_lines_visible(bufnr, winid)
  if not (api.nvim_buf_is_valid(bufnr) and api.nvim_win_is_valid(winid)) then
    return
  end
  if api.nvim_win_get_buf(winid) ~= bufnr then
    return
  end
  if M._hunks_by_buf[bufnr] == nil then
    return
  end

  api.nvim_win_call(winid, function()
    local view = vim.fn.winsaveview()
    local desired = 0
    if view.topline == 1 then
      desired = count_edge_virt_lines(bufnr, 0, true)
    end
    if (view.topfill or 0) == desired then
      return
    end
    view.topfill = desired
    vim.fn.winrestview(view)
  end)
end

---@param bufnr integer
local function register_scroll_adjuster(bufnr)
  if scroll_adjuster_registered[bufnr] or not api.nvim_buf_is_valid(bufnr) then
    return
  end

  scroll_adjuster_registered[bufnr] = true
  api.nvim_create_autocmd("CursorMoved", {
    group = scroll_adjuster_augroup,
    buffer = bufnr,
    callback = function(args)
      local winid = api.nvim_get_current_win()
      M.ensure_eof_virt_lines_visible(args.buf, winid)
      M.ensure_bof_virt_lines_visible(args.buf, winid)
    end,
  })
end

-- Emit a one-shot WARN if the inline diff is being rendered against a
-- buffer that's also displayed in a window other than `winid`, but the
-- running Neovim is too old (< 0.11) to scope `M.ns` to a single
-- window. The buffer-shared extmarks will leak into those other
-- windows; the warning makes that visible without spamming on every
-- repaint or on every file in a long file-history walk.
---@param bufnr integer
---@param winid integer
local function maybe_warn_leak(bufnr, winid)
  if leak_warned then
    return
  end
  if not (api.nvim_buf_is_valid(bufnr) and api.nvim_win_is_valid(winid)) then
    return
  end
  for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
    if w ~= winid then
      leak_warned = true
      vim.notify(
        "diffview+: `diff1_inline` highlights may leak into other windows showing this file. "
          .. "Upgrade to Neovim 0.11+ to fix.",
        vim.log.levels.WARN
      )
      return
    end
  end
end

-- Confine `M.ns` to `winid` so the inline-diff extmarks render only in
-- the diffview window (issue #156). Without `WIN_SCOPE_SUPPORTED`,
-- `maybe_warn_leak` emits a one-shot warning instead. Idempotent:
-- re-attaching the same `winid` is a no-op.
--
-- A window hosts one buffer at a time, so `winid` already recorded
-- under another `bufnr` means it's been reassigned (e.g. `diff1_inline`
-- cycles entries through one window). Transfer ownership so a later
-- detach of the previous buffer doesn't strip the namespace off a
-- window the current buffer still relies on.
---@param bufnr integer
---@param winid integer
function M.attach_to_window(bufnr, winid)
  if not (api.nvim_buf_is_valid(bufnr) and api.nvim_win_is_valid(winid)) then
    return
  end
  if not WIN_SCOPE_SUPPORTED then
    maybe_warn_leak(bufnr, winid)
    return
  end
  local set = M._scoped_wins_by_buf[bufnr] or {}
  if set[winid] then
    return
  end
  local ok
  if win_add_ns then
    ok = pcall(win_add_ns, winid, M.ns)
  else
    -- The experimental `nvim__ns_set` replaces the entire window list
    -- in one call, so collect every previously-scoped winid (across
    -- all buffers, since the list is per-namespace not per-buffer)
    -- plus the new one and pass them together. Stale winids are
    -- filtered out so a closed window doesn't carry forward.
    local wins = { winid }
    for _, other in pairs(M._scoped_wins_by_buf) do
      for w in pairs(other) do
        if w ~= winid and api.nvim_win_is_valid(w) then
          wins[#wins + 1] = w
        end
      end
    end
    ok = pcall(ns_set, M.ns, { wins = wins })
  end
  if not ok then
    return
  end
  for other_bufnr, other in pairs(M._scoped_wins_by_buf) do
    if other_bufnr ~= bufnr and other[winid] then
      other[winid] = nil
      if next(other) == nil then
        M._scoped_wins_by_buf[other_bufnr] = nil
      end
    end
  end
  set[winid] = true
  M._scoped_wins_by_buf[bufnr] = set
end

-- Reverse of `attach_to_window`. Called by `M.detach` for each window
-- the namespace was scoped to before clearing the buffer's extmarks,
-- so a later non-diffview render pass on the same buffer in the same
-- window slot doesn't silently inherit the scope. Forward-declared
-- above so the BufWipeout/BufDelete autocmd in `register_cache_cleanup`
-- can reach it.
---@param bufnr integer
detach_from_all_windows = function(bufnr)
  if not WIN_SCOPE_SUPPORTED then
    return
  end
  local set = M._scoped_wins_by_buf[bufnr]
  if not set then
    return
  end
  if win_remove_ns then
    for winid in pairs(set) do
      if api.nvim_win_is_valid(winid) then
        pcall(win_remove_ns, winid, M.ns)
      end
    end
  else
    -- Experimental fallback: rebuild the namespace's window list from
    -- the remaining buffers' scoped winids, dropping the ones tied to
    -- `bufnr`.
    local wins = {}
    for other_bufnr, other in pairs(M._scoped_wins_by_buf) do
      if other_bufnr ~= bufnr then
        for w in pairs(other) do
          if api.nvim_win_is_valid(w) then
            wins[#wins + 1] = w
          end
        end
      end
    end
    pcall(ns_set, M.ns, { wins = wins })
  end
  M._scoped_wins_by_buf[bufnr] = nil
end

-- Clear all inline-diff extmarks from the buffer.
---@param bufnr integer
function M.clear(bufnr)
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
  -- Note: keep `cache_cleanup_registered[bufnr]` set. The BufWipeout/BufDelete
  -- autocmd installed by `register_cache_cleanup` is still pending and will
  -- reset the flag when it fires. Clearing the flag here would cause the next
  -- render pass to register a duplicate autocmd.
  if bufnr then
    M._hunks_by_buf[bufnr] = nil
  end
end

-- Fully detach the inline diff from `bufnr`: clear extmarks and cached hunks
-- (as `clear()` does), remove the CursorMoved scroll-adjuster autocmd so the
-- buffer doesn't keep firing a now-useless handler after the inline view is
-- torn down (e.g. layout switch, or closing the view while keeping the
-- underlying file buffer alive), and reset any `topfill` that
-- `ensure_bof_virt_lines_visible()` set on windows showing `bufnr` so
-- teardown doesn't leave an empty filler band above line 1.
---@param bufnr integer
function M.detach(bufnr)
  if bufnr then
    detach_from_all_windows(bufnr)
  end
  M.clear(bufnr)
  if not bufnr then
    return
  end
  M._captures_by_buf[bufnr] = nil
  if scroll_adjuster_registered[bufnr] then
    scroll_adjuster_registered[bufnr] = nil
    if api.nvim_buf_is_valid(bufnr) then
      pcall(api.nvim_clear_autocmds, { group = scroll_adjuster_augroup, buffer = bufnr })
    end
  end
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if api.nvim_win_is_valid(winid) then
      api.nvim_win_call(winid, function()
        local view = vim.fn.winsaveview()
        if (view.topfill or 0) ~= 0 then
          view.topfill = 0
          vim.fn.winrestview(view)
        end
      end)
    end
  end
end

-- Return the sorted list of 0-indexed rows where each hunk's cursor target
-- should land. For add/change hunks this is the first modified new-side row;
-- for pure deletions it's the row adjacent to the virt_lines anchor.
---@param bufnr integer
---@return integer[]
function M.hunk_anchor_rows(bufnr)
  local hunks = M._hunks_by_buf[bufnr]
  if not hunks then
    return {}
  end

  local rows = {}
  local line_count = api.nvim_buf_is_valid(bufnr) and api.nvim_buf_line_count(bufnr) or 0
  local seen = {}

  for _, h in ipairs(hunks) do
    local new_start, new_count = h[3], h[4]
    local row
    if new_count > 0 then
      row = new_start - 1
    else
      -- Pure deletion: anchor at the line that holds the virt_lines.
      row = new_start == 0 and 0 or new_start - 1
    end
    if row < 0 then
      row = 0
    end
    if line_count > 0 and row >= line_count then
      row = line_count - 1
    end

    if not seen[row] then
      seen[row] = true
      rows[#rows + 1] = row
    end
  end

  table.sort(rows)
  return rows
end

-- Find the row of the first hunk strictly after `cursor_row` (0-indexed).
---@param bufnr integer
---@param cursor_row integer
---@return integer? row
function M.next_hunk_row(bufnr, cursor_row)
  for _, r in ipairs(M.hunk_anchor_rows(bufnr)) do
    if r > cursor_row then
      return r
    end
  end
end

-- Return the cached hunks for `bufnr`, or `nil` if no inline diff is
-- currently attached. Each hunk is `{ old_start, old_count, new_start,
-- new_count }` in 1-indexed form, as returned by `vim.diff`.
---@param bufnr integer
---@return integer[][]?
function M.get_hunks(bufnr)
  return M._hunks_by_buf[bufnr]
end

-- Find the row of the last hunk strictly before `cursor_row` (0-indexed).
---@param bufnr integer
---@param cursor_row integer
---@return integer? row
function M.prev_hunk_row(bufnr, cursor_row)
  local rows = M.hunk_anchor_rows(bufnr)
  local prev
  for _, r in ipairs(rows) do
    if r < cursor_row then
      prev = r
    else
      break
    end
  end
  return prev
end

---@class InlineDiffOpts
---@field algorithm? string
---@field linematch? integer
---@field indent_heuristic? boolean
---@field ignore_whitespace? boolean
---@field ignore_whitespace_change? boolean
---@field ignore_whitespace_change_at_eol? boolean
---@field ignore_blank_lines? boolean
---@field style? "unified"|"overleaf" Default: `"unified"`.
---@field deletion_highlight? "text"|"full_width"|"hanging" Extent of the `del_hl` background on virt_line deletions. Default: `"text"`.
---@field deletion_treesitter? boolean Layer TS captures over deleted virt_lines. Default: `true`.
---@field winid? integer Eventual display window. Folded into the `full_width` pad target so a renderer called before the buffer is displayed (e.g. `Diff1Inline._prerender`) can still size padding correctly.

---@class InlineDiffStyle
---@field del_hl string Highlight group for virt_line deletions.
---@field inline_del boolean Render paired char-level deletions as inline virt_text.
---@field echo_paired_old boolean Emit full old content as virt_lines above paired modifications.
---@field change_line_hl? string Line highlight on paired modified rows, or `nil` to skip.

---@type table<string, InlineDiffStyle>
local STYLES = {
  -- Proper unified diff: deletions visible as virt_lines above the new block.
  unified = {
    del_hl = "DiffviewDiffDelete",
    inline_del = false,
    echo_paired_old = true,
    change_line_hl = "DiffviewDiffChange",
  },
  -- Overleaf style: deletions rendered inline as strikethrough virt_text so
  -- the reader sees the change in flow. No block echo, no line hl — the
  -- char-level rendering stands alone.
  overleaf = {
    del_hl = "DiffviewDiffDeleteInline",
    inline_del = true,
    echo_paired_old = false,
    change_line_hl = nil,
  },
}

-- Render a unified inline diff into `bufnr` using extmarks. The buffer is
-- assumed to contain `new_lines`; deletions and char-level highlights are
-- layered on top without modifying buffer contents.
---@param bufnr integer
---@param old_lines string[] Content of the old side.
---@param new_lines string[] Content of the new side (matches `bufnr`).
---@param opts? InlineDiffOpts
function M.render(bufnr, old_lines, new_lines, opts)
  opts = opts or {}
  local style = STYLES[opts.style] or STYLES.unified
  local extent = opts.deletion_highlight or "text"
  M.clear(bufnr)

  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  if api.nvim_buf_line_count(bufnr) == 0 then
    return
  end

  -- Terminate with a trailing newline so `vim.diff` treats the last line as a
  -- complete line. Without it, EOF additions/deletions get classified as
  -- modifications of the adjacent line (e.g. `{old_last, e} -> {old_last}`
  -- reports as a 2:1 modify rather than a pure delete of `e`), which both
  -- hides the EOF hunk's real shape and echoes the unchanged adjacent line
  -- as a spurious virt_line under the "unified" style.
  local old = #old_lines > 0 and table.concat(old_lines, "\n") .. "\n" or ""
  local new = #new_lines > 0 and table.concat(new_lines, "\n") .. "\n" or ""

  local diff_opts = { result_type = "indices" }
  -- Only forward each `vim.diff` option (`algorithm`, `linematch`,
  -- `indent_heuristic`, and the `ignore_*` whitespace/blank-line flags) when
  -- explicitly set so vim.diff's own defaults apply otherwise. This mirrors
  -- how `'diffopt'` toggles flags/options by presence/absence rather than
  -- forcing fallback values here.
  if opts.algorithm ~= nil then
    diff_opts.algorithm = opts.algorithm
  end
  if opts.linematch ~= nil then
    diff_opts.linematch = opts.linematch
  end
  if opts.indent_heuristic ~= nil then
    diff_opts.indent_heuristic = opts.indent_heuristic
  end
  if opts.ignore_whitespace ~= nil then
    diff_opts.ignore_whitespace = opts.ignore_whitespace
  end
  if opts.ignore_whitespace_change ~= nil then
    diff_opts.ignore_whitespace_change = opts.ignore_whitespace_change
  end
  if opts.ignore_whitespace_change_at_eol ~= nil then
    diff_opts.ignore_whitespace_change_at_eol = opts.ignore_whitespace_change_at_eol
  end
  if opts.ignore_blank_lines ~= nil then
    diff_opts.ignore_blank_lines = opts.ignore_blank_lines
  end

  local hunks = diff(old, new, diff_opts) --[[@as integer[][]? ]]

  if not hunks then
    return
  end

  M._hunks_by_buf[bufnr] = hunks
  register_cache_cleanup(bufnr)
  register_scroll_adjuster(bufnr)

  -- Resolve the `full_width` pad target once for the whole render. It depends
  -- only on the buffer's displayed windows (plus the optional `opts.winid`
  -- hint), so a hunk loop that emits many deleted blocks would otherwise
  -- repeat a `win_findbuf` + `getwininfo` traversal per block.
  local fw_target = extent == "full_width" and full_width_target(bufnr, opts.winid) or 0

  -- TS captures for the entire old side, computed lazily and memoized:
  -- the data is shared across every `render_deleted_block` call below
  -- (each pure deletion or unified-style echo of an old line indexes
  -- into it), so a single parse covers the render. Hunks with no
  -- deletion-bearing call sites (e.g. pure-addition diffs, or overleaf
  -- runs that take only the inline-strikethrough path) skip the parse
  -- entirely. `compute_old_line_captures` returns an empty table when
  -- TS is unavailable, which the chunk builder handles transparently.
  --
  -- The result is also cached across renders in `M._captures_by_buf`
  -- so `_repaint`-style flows (re-render on `TextChanged` while
  -- `old_lines` is held by the caller and reused) skip the parse on
  -- every redraw. The cache is keyed by filetype + content equality
  -- on the joined `old` string, so an in-place mutation of `old_lines`
  -- still invalidates correctly on the next lookup.
  --
  -- Disabled when `opts.deletion_treesitter == false`: skip the parse
  -- altogether and pass `nil` to `render_deleted_block`, which then
  -- emits a single `del_hl` chunk per line.
  local ts_enabled = opts.deletion_treesitter ~= false
  local line_captures
  local function get_line_captures()
    if not ts_enabled then
      return nil
    end
    if line_captures then
      return line_captures
    end
    local ft = api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or ""
    local entry = M._captures_by_buf[bufnr]
    if entry and entry.ft == ft and entry.old == old then
      line_captures = entry.captures
    else
      line_captures = compute_old_line_captures(old_lines, bufnr, old)
      M._captures_by_buf[bufnr] = {
        ft = ft,
        old = old,
        captures = line_captures,
      }
    end
    return line_captures
  end

  for _, h in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]

    if old_count == 0 and new_count > 0 then
      -- Pure addition: highlight the new lines.
      for k = 0, new_count - 1 do
        local row = new_start - 1 + k
        api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
          line_hl_group = "DiffviewDiffAdd",
          priority = 100,
        })
      end
    elseif new_count == 0 and old_count > 0 then
      -- Pure deletion: show the old lines as virtual lines.
      render_deleted_block(
        bufnr,
        old_lines,
        old_start,
        old_start + old_count - 1,
        new_start,
        nil,
        nil,
        style.del_hl,
        extent,
        fw_target,
        get_line_captures()
      )
    elseif old_count > 0 and new_count > 0 then
      -- Modification: unified and overleaf diverge on how deletions are
      -- conveyed. Unified echoes the full old content as virt_lines above
      -- (block-level unified diff); overleaf relies on char-level inline
      -- strikethrough on the paired new rows and only uses virt_lines for
      -- overflow old lines that don't pair with any new line.
      local paired = math.min(old_count, new_count)

      if style.echo_paired_old then
        render_deleted_block(
          bufnr,
          old_lines,
          old_start,
          old_start + old_count - 1,
          new_start,
          new_start - 1,
          true,
          style.del_hl,
          extent,
          fw_target,
          get_line_captures()
        )
      elseif old_count > paired then
        -- Overleaf: overflow old lines still get a virt_line above.
        local anchor = new_start - 1 + paired - 1
        render_deleted_block(
          bufnr,
          old_lines,
          old_start + paired,
          old_start + old_count - 1,
          new_start,
          anchor,
          false,
          style.del_hl,
          extent,
          fw_target,
          get_line_captures()
        )
      end

      for k = 0, paired - 1 do
        local row = new_start - 1 + k
        local ol = old_lines[old_start + k] or ""
        local nl = new_lines[new_start + k] or ""
        local char_result = render_char_highlights(bufnr, row, ol, nl, style.inline_del)

        -- `"skipped"` draws no `DiffviewDiffAddInline` overlay, so the
        -- subtle `DiffviewDiffChange` backdrop alone would be a bare
        -- smudge. Treat as a pure addition — the deletion is still
        -- echoed above (unified unconditionally; overleaf via the
        -- fallback below).
        local line_hl = style.change_line_hl
        if char_result == "skipped" then
          line_hl = "DiffviewDiffAdd"
        end
        if line_hl then
          api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
            line_hl_group = line_hl,
            priority = 100,
          })
        end

        -- Overleaf fallback: when char-level was skipped and we're not
        -- already echoing old lines, show this paired old line above the
        -- new one so the reader can see what changed. Use the style's
        -- own `del_hl` so the echoed line keeps the overleaf look (e.g.
        -- the strikethrough on `DiffviewDiffDeleteInline`) rather than
        -- silently downgrading to the unified `DiffviewDiffDelete`.
        if not style.echo_paired_old and char_result == "skipped" and ol ~= nl then
          render_deleted_block(
            bufnr,
            old_lines,
            old_start + k,
            old_start + k,
            new_start + k,
            row,
            true,
            style.del_hl,
            extent,
            fw_target,
            get_line_captures()
          )
        end
      end

      if new_count > paired then
        for k = paired, new_count - 1 do
          local row = new_start - 1 + k
          api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
            line_hl_group = "DiffviewDiffAdd",
            priority = 100,
          })
        end
      end
    end
  end

  -- Cover the case where the buffer was already showing its last/first
  -- line (e.g. a refresh after the user navigated to either edge) — the
  -- next CursorMoved might not fire until they move again.
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    M.ensure_eof_virt_lines_visible(bufnr, winid)
    M.ensure_bof_virt_lines_visible(bufnr, winid)
  end
end

M._test = {
  is_word_char = is_word_char,
  is_word_token = is_word_token,
  subword_class = subword_class,
  is_hex_run = is_hex_run,
  tokenize = tokenize,
  split_chars = split_chars,
  diff_units = diff_units,
  refinement_safe = refinement_safe,
  INTRALINE_MAX_HUNKS = INTRALINE_MAX_HUNKS,
  compute_old_line_captures = compute_old_line_captures,
  captured_chunks = captured_chunks,
}

return M
