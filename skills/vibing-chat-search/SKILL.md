---
name: vibing-chat-search
description: Use when the user wants to find a past vibing.nvim conversation by topic — phrases like "前に〜について聞いたことあったっけ", "did we talk about X before", "find that chat where I asked about Y". Searches every chat file under .vibing/chat/ (both User and Assistant content) for a natural-language query, narrows candidates with grep, then reads and semantically judges the survivors before presenting matches. Not for recovering this conversation's own lost context — use vibing-chat-recall for that.
---

# vibing-chat-search

Finds past vibing.nvim chat files relevant to a natural-language query, by grepping
`.vibing/chat/` for keyword candidates and then reading the survivors to judge actual relevance.

## When this applies

- The user asks something like "前に〜について聞いたことあったっけ" / "did we discuss X before" /
  "find the chat where I asked about Y".
- Claude suspects a similar topic was covered in an earlier, different conversation.
- Invoked directly via `/vibing-chat-search`.

Not for re-reading _this_ conversation's own history after context loss — that's
`vibing-chat-recall`.

## Step 1: Locate the chat directory

Resolve `.vibing/chat/` relative to the git repository root:

```bash
git rev-parse --show-toplevel
```

Then check `<root>/.vibing/chat/` exists. If the repo has no `.vibing/chat/` directory (not a
git repo, or the directory is missing), fall back to `.vibing/chat/` relative to the current
working directory. If neither exists, tell the user no chat history was found and stop.

## Step 2: Build search keywords

From the user's natural-language query, extract 2-4 candidate keywords or short phrases,
including obvious synonyms/rephrasings — chat content is free-form Japanese or English prose,
not structured data, so a single literal substring rarely covers how the topic was actually
phrased.

Example: query "前にwebfetchのURL表示について話した?" → candidates: `webfetch`, `WebFetch`,
`URL表示`, `閲覧したurl`.

## Step 3: Narrow candidates with Grep

Search both User and Assistant content — don't restrict to `## User` sections only, since the
user's original phrasing may be vague while the topic keyword shows up clearly in Claude's own
reply.

Use the `Grep` tool with `path: ".vibing/chat"`, one call per keyword (or a regex alternation),
`output_mode: "files_with_matches"`. Union the results across all keywords into one candidate
list.

If the candidate list is larger than ~15 files, don't read them all — narrow further:

- Re-run with `output_mode: "count"` and keep only the files with the highest match counts, or
- Tighten the keyword list to more specific terms before re-searching.

## Step 4: Read candidates and judge relevance

Read each remaining candidate file (or just the matched region with `-C` context via `Grep`'s
content mode, for longer files) and judge whether it's actually about what the user is asking —
a keyword hit alone isn't enough; discard files where the match is incidental or off-topic.

## Step 5: Present results

For each file that survives judging, list:

- File path (relative to repo root)
- Date/time — prefer the `created_at` field from the file's YAML frontmatter; fall back to
  parsing the timestamp out of the filename (e.g. `chat-20260208-211227-...`) if frontmatter is
  missing
- A 1-2 line summary of the relevant part

Present this as a plain list. Don't pick a single "best" match, don't suggest a command to open
one, and don't summarize beyond the 1-2 lines per file — opening the file is left to the user.

If nothing survives Step 4, say plainly that nothing was found rather than forcing a weak match.
