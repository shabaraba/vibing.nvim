---
name: vibing-chat-recall
description: Use when a vibing.nvim chat session's context feels lost or discontinuous — after a session reset, a dropped connection, or when Claude's own reasoning no longer matches what was discussed earlier in this conversation. Re-reads this conversation's own chat buffer (the file whose path is announced via the "Current vibing.nvim chat buffer file:" line in the system prompt) to silently restore context. Also invoke when the user explicitly asks to "remember", "recall", or "re-read the chat history" (in any language). Not for browsing other, unrelated past chat files — use vibing-chat-search for that.
---

# vibing-chat-recall

Restores this conversation's own context after it appears to have been lost (session reset,
dropped RPC connection, compaction) by re-reading the live vibing.nvim chat buffer this
conversation is running in.

## When this applies

- The user explicitly asks to "思い出して" / "recall" / "re-read the chat history".
- Claude notices its own responses no longer track what was discussed earlier in this same
  conversation — a sign the session was silently reset or compacted.
- Invoked directly via `/vibing-chat-recall`.

This skill only makes sense inside a vibing.nvim chat session. If the environment doesn't look
like one (see below), say so briefly and stop — don't guess at a file to read.

## Locating this conversation's own chat file

Every request sent through vibing.nvim's Claude CLI adapter carries one extra line appended to
the system prompt:

```text
Current vibing.nvim chat buffer file: /absolute/path/to/chat.md
```

Use that path — never rely on which Neovim window currently has focus, since the user may have
switched away, or another chat may be running concurrently.

If that line isn't present in the system prompt, this skill isn't running inside vibing.nvim (or
is running against an older vibing.nvim build that doesn't send it yet). Tell the user briefly
and stop.

## Reading the buffer

1. Call `mcp__vibing-nvim__nvim_load_buffer` with `filepath` set to the path from the system
   prompt. This loads the file into a Neovim buffer in the background (no window switch) and
   returns its `bufnr`, whether or not it was already open.
2. Call `mcp__vibing-nvim__nvim_get_buffer` with that `bufnr` to fetch the buffer's current
   content. This is the _live_ in-memory content, including edits that haven't been written to
   disk yet — vibing.nvim chat buffers are not auto-saved, so the on-disk file can lag behind
   what's actually been discussed.
3. If either MCP call fails (no RPC connection, Neovim not reachable), fall back to reading the
   same path from disk with the normal `Read` tool. This may miss the most recent unsaved
   exchange, but is better than nothing.

## Responding

Read through the recovered conversation to rebuild context internally. Reply with a short
one-line acknowledgment only (e.g. "会話履歴を読み直しました。" / "Context restored.") — do not
summarize the conversation or propose next steps unless the user asks for that separately.
