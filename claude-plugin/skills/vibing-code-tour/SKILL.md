---
name: vibing-code-tour
description: Walk the user through a real execution path by opening the actual files and jumping to the actual lines in their running Neovim, instead of describing the path in chat text. Use when someone asks to be walked through how something works ("walk me through the auth flow", "give me a tour of how a request gets handled", "show me step by step where this bug comes from").
---

# vibing-code-tour

A list of `file:line` references in a chat message is something the user still has to go open
themselves. This skill instead drives their editor: each stop of the explanation is a real file
opened at a real line, and the whole route is left behind in the quickfix list so they can walk it
again afterwards with `:cnext` / `:cprev`.

Requires the `vibing-nvim` MCP tools (a running Neovim). Without them, fall back to explaining the
flow as text with `file:line` references, and say that's what you're doing.

## When to use it

- A flow that crosses three or more files, or several hops of a call chain
- Onboarding-style questions: "how does X work", "where does this request go"
- Tracing a bug back to its origin, when the answer is a path rather than a spot

Not for single-symbol questions ("where is X defined") — use the `nvim-lsp-navigation` skill for
those.

## Workflow

### 1. Find the route

Establish the path with the LSP tools (see `nvim-lsp-navigation` for which tool answers which
question), falling back to `Grep`/`Glob` where LSP has nothing to say. `nvim_load_buffer` loads a
file in the background so you can analyze it without disturbing what the user is looking at.

Build an ordered list of stops as you go: `{ filename, lnum, col, text }`, where `text` is a short
label — it is what shows in the quickfix window, so make it say what happens at that line, not
what the file is called.

### 2. Publish the route, once

One `nvim_set_qflist` call with every stop in visiting order, a `title` naming the tour, and
`open: true`.

Call it exactly once per tour. Each call pushes a **new** quickfix list, so a second call leaves
`:cnext` walking a different list than the one you are narrating. (The same property is why this
is safe to call at all: whatever the user had in quickfix before is still there under `:colder`.)

Note `col` is 1-based here, matching native quickfix — unlike the 0-based `col` that
`nvim_set_cursor` and the `nvim_lsp_*` tools use. Add 1 when you carry a position over from an LSP
result.

### 3. Walk it

For each stop:

1. `nvim_list_windows` to find a window that isn't the chat buffer — never assume `winnr: 0`
2. `nvim_win_open_file` with that `winnr`, then `nvim_set_cursor` with **the same `winnr`**
   (1-based line, **0-based** col)
3. Explain that stop in chat: what this code does, and why the flow moves from here to the next
   stop

Pass `winnr` to `nvim_set_cursor` every time. `nvim_win_open_file` restores focus before it
returns, so the window holding the file is not the current one; omitting `winnr` moves the chat's
cursor instead and nothing reports an error. Same for `nvim_highlight_range` — give it the `bufnr`
the open returned, not `0`.

### 4. Let the user set the pace

Every stop or two, ask with `nvim_ask_user_question` — options along the lines of "next", "go
deeper here", "stop".

**This ends your turn.** `nvim_ask_user_question` cancels the in-flight turn to render the choice
list, so nothing after it runs and the tool never returns an answer to you; the user's reply
arrives as the next turn (see `.claude/rules/features.md` → AskUserQuestion Support).

The consequence for a tour: **nothing you are holding in your head survives the question.** Before
every ask, write the tour state into your chat message as plain text — which stop you are on, how
many there are, and the remaining stops with their `file:line`. The next turn resumes the same
session, so that text is what you will read to pick the tour back up. There is no way to query the
quickfix list back out of Neovim; the transcript is the only copy of the route.

### 5. Close out

When the tour ends — finished, or the user stopped it — tell them the route is still in quickfix:
`:cnext` / `:cprev` to walk it, `:cc N` to jump to one stop, `:copen` to see the list, and
`:colder` to get back to whatever quickfix list they had before the tour.
