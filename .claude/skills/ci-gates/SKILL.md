---
name: ci-gates
description: The CI gates of vibing.nvim (test:lua exit code, E2E timeout budget, check:doc, check) and the ways each one has silently stopped failing. Use when editing package.json scripts, .github/workflows/ci.yml, scripts/check-help.lua, doc/*.txt, or any tests/*.test.mjs that guards a gate — and whenever a gate passes but you are not sure it actually ran anything.
---

# CI Gates for vibing.nvim

Every gate in this repository has, at some point, passed over a broken tree. Each section below is
one of those failures and the shape that now prevents it. Meta-tests (`tests/*.test.mjs`) pin the
gates themselves; when you change a gate, change its meta-test in the same edit.

## The CI Gate Is the Exit Code

CI runs `npm run test:lua` and reads nothing but its exit status. Do not add output parsing back:
`PlenaryBustedDirectory` prints one summary **per spec file**, so any `grep` for `Failed : 0`
matches while other files are failing — which is exactly how the gate passed a run with five dead
specs (#561). `tests/lua-test-exit-code.test.mjs` pins the three cases the gate rests on: a failing
assertion, a spec that will not load, and an otherwise-passing run.

The one case neither the exit code nor a summary count catches is a spec file that runs **zero**
tests (a `describe` that stopped being reached): plenary exits 0 without printing a summary, which
is also how the E2E specs opt out via `should_run()`.

## A Spec Cannot Outlast Its Harness

`PlenaryBustedDirectory` runs one child Neovim per spec **file** and joins it with a single
timeout — 50000ms unless the invocation says otherwise. A spec still inside a `vim.wait` when that
expires is killed mid-wait: no summary, no failure, no test count. Only the exit code moves, which
is the zero-tests shape above arriving by a different route.

Three E2E specs sat in exactly that state, each budgeting `ASSISTANT_RESPONSE = 60000` against the
50000ms default: they died at 50.2s every run and printed nothing at all. `test:e2e` now passes
`timeout = 240000`, and `tests/e2e-timeout-gate.test.mjs` keeps the two numbers in agreement — it
reads the budget out of the `test:e2e` command itself (so it cannot pass against a command the
project no longer runs) and sums every wait each spec file can perform. The sum is deliberately an
over-estimate; over-counting only ever asks for a larger budget, and an exact model is what would
let the silent case back in. The bound is **per file**, not per test, because the timeout is on
the job.

## Vim Help Verification

`npm run check:doc` (`scripts/check-help.lua`, run by the "Verify Vim help files" CI step) is the
only thing that reads `doc/*.txt`: `npm run check` compiles `lua/` alone, and the prettier / eslint
/ markdownlint steps do not match `.txt`. It checks three things — that `helptags` generates (a
duplicate or malformed tag fails only here), that no line exceeds 78 columns, and that CONTENTS and
the body agree on section numbers and tags.

The width is measured with `strdisplaywidth`, which is why the checker runs inside nvim at all.
A byte count rejects the `•` and `—` already in `vibing.txt`; a character count would let a CJK
line run to 156 columns. Only Vim's own measure is right, and it already honours `ambiwidth`.

`:helptags` raises a Vim error instead of setting an exit code, so the checker wraps it in `pcall`
— nvim otherwise prints `E154` and still exits 0.

The CONTENTS check **fails closed**, which is the part worth not undoing. Keying it on "did any
rows parse" would let one unreadable CONTENTS block switch the check off while the run still
reported OK — the same shape of dead gate this whole file is about. So a file with a `CONTENTS`
heading and no readable `N. Title |tag|` rows is a failure, and the row pattern deliberately does
not require a dot leader, because space-aligned CONTENTS is ordinary vimdoc and used to skip the
check entirely. A file with no CONTENTS heading has nothing to disagree with and passes.

Section headings are matched at column 0 on purpose: that is what keeps a heading-shaped line
inside an indented `>` code example from being read as a real section. CONTENTS rows cannot be
anchored that way — they are indented — so they are read only from inside the CONTENTS block, and
headings only from outside it. Neither side depends on the two patterns never overlapping.

CONTENTS and the body are matched **by section number**, not by position. Walking the two lists in
parallel meant one renumbered section shifted everything after it, so a single typo reported as a
cascade and the first message named a section that was fine. Duplicate numbers on either side are
reported as such.

Sub-section numbering (`2.1`) is **rejected rather than skipped**. Neither pattern can read it, so
it used to drop out of the comparison without a word — checked-looking and unchecked, which is the
failure this checker exists to prevent. Supporting it should be a decision, not something
discovered from a green run.

`tests/help-check.test.mjs` pins each failure the gate is supposed to catch, including both width
cases and both fail-closed cases. The CI step gates the document; that file gates the checker.

## The Lua Syntax Gate Had the Same Hole

`npm run check` could not fail. `find lua -name '*.lua' -exec luac -p {} \;` reports `find`'s exit
status, not `luac`'s, so a file that would not compile printed its error and CI went green. It is
`-exec ... +` now, which propagates, and `tests/lua-syntax-gate.test.mjs` holds it there — reading
the command out of `package.json` rather than restating it, so the test cannot pass against a
command the project no longer runs.

## E2E Specs Are Not Part of the Normal Suite

`test:lua` sweeps `tests/` including `tests/e2e/`, so every E2E spec self-skips unless
`VIBING_E2E=1` — which only `test:e2e` sets (`helper.should_run()`). Do not remove that guard to
"make E2E part of the normal suite": those specs drive full turns against the CLI, so that is a
per-run API bill on `npm test`. Writing or debugging them is the `self-testing` skill.
