# Contributing

Thanks for helping improve `diffview+`. This document covers the local setup
and a few conventions worth knowing before opening a PR.

## Development setup

Run the tests and formatter locally before pushing.

### Tests

```bash
make test                                                       # run the full suite
TEST_PATH=lua/diffview/tests/functional/foo_spec.lua make test  # a single file
```

Requires Neovim >= 0.10.0 with [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim);
see `scripts/test_init.lua` for how dependencies are fetched.

### Formatting (stylua)

The codebase is formatted with [stylua](https://github.com/JohnnyMorganz/StyLua)
**2.4.1 built with the `luajit` feature**. The `luajit` feature matters: the
default `stylua` build formats Lua 5.x syntax.

Install with:

```bash
cargo install stylua --locked --version 2.4.1 --features luajit
```

Then run:

```bash
stylua --check lua/ scripts/   # CI equivalent; fails on any diff
stylua lua/ scripts/           # apply formatting
```

### Type annotations

Annotations are consumed by [lua-language-server](https://github.com/LuaLS/lua-language-server).
A `type-check` CI job runs LuaLS in `--check` mode. Source code
(`lua/diffview/`, excluding `tests/`) must be free of diagnostics; the
job is required and fails if any are reported (after the suppressions
configured in `.luarc.json`). The test tree is checked separately and
advisory, because Luassert modifier chains (`assert.is_not_nil`,
`assert.has_no.errors`, etc.) are not fully covered by the static type
annotations `plenary.nvim` ships.

Prerequisites on `PATH`:
[`lua-language-server`](https://github.com/LuaLS/lua-language-server)
(>= 3.13) to drive `--check` mode,
[`jq`](https://jqlang.org/) to derive `.luarc.source.json` from
`.luarc.json`, `nvim` to resolve `VIMRUNTIME` for the generated config,
and `git` (used by `make dev` to fetch the neodev and plenary sources
into `.dev/`).

CI pins the Neovim version used for the type-check job (see
`NVIM_TYPECHECK_VERSION` in `.github/workflows/ci.yml`) so the required
gate stays deterministic across upstream Neovim releases. To reproduce
the CI result exactly, install that same version locally; otherwise a
newer Neovim's `$VIMRUNTIME` may surface diagnostics that CI does not.

To reproduce locally:

```bash
make dev                 # one-time: fetch neodev types + plenary into .dev/
make type-check          # strict check of source (fails on any diagnostic)
make type-check-tests    # advisory check of tests (never fails)
```

Suppressions live in `.luarc.json`. Prefer fixing a diagnostic over adding a
blanket suppression; use `---@diagnostic disable-next-line:<code>` for local,
justified exceptions.

## Adding or changing a config option

Type annotations in `lua/diffview/config.lua` power editor completion and
hover information on options passed to `setup()`.

When you add, remove, or rename a key under `M.defaults` in
`lua/diffview/config.lua`, update **all** of the following in the same PR:

1. `M.defaults` itself — the actual value.
2. `@class DiffviewConfig` — the internal/resolved type.
3. `@class DiffviewConfig.user` — the user-facing (optional-fields) type passed
   to `setup()`. Include a short description on the `@field` line so it shows
   up in editor tooltips.
4. `doc/diffview_defaults.txt` — the annotated example users copy from.
5. `doc/diffview.txt` — the reference section for that option, if it warrants
   prose (type, valid values, behavioural notes).

The CI job `config-schema` performs a mechanical key-drift/consistency check
to ensure #1, #2, and #3 stay in sync. Doc/reference drift (#4 and #5) is
reviewer-enforced.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/). Keep the
subject terse; put rationale in the body when it's not obvious from the diff.

## Debugging

Set `DEBUG_DIFFVIEW=1` in the environment to enable debug logging.
