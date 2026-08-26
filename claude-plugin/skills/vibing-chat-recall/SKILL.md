---
name: vibing-chat-recall
description: Use when a vibing.nvim chat session's context feels lost or discontinuous — after a session reset, a dropped connection, or when Claude's own reasoning no longer matches what was discussed earlier in this conversation. Re-reads this conversation's own chat buffer (the buffer announced via the "Current vibing.nvim chat buffer number:" line in the system prompt) to silently restore context. Also invoke when the user explicitly asks to "remember", "recall", or "re-read the chat history" (in any language). Not for browsing other, unrelated past chat files — use vibing-chat-search for that.
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

## Locating this conversation's own chat buffer

Every request sent through vibing.nvim's Claude CLI adapter carries one extra line appended to
the system prompt:

```text
Current vibing.nvim chat buffer number: 12
```

Use that buffer number — never rely on which Neovim window currently has focus, since the user
may have switched away, or another chat may be running concurrently. It is a buffer number rather
than a path so that `:VibingSetFileTitle` renaming the chat mid-conversation neither breaks this
lookup nor invalidates the prompt cache.

If that line isn't present in the system prompt, this skill isn't running inside vibing.nvim (or
is running against an older vibing.nvim build that doesn't send it yet). Tell the user briefly
and stop.

## Reading the buffer

Pass this turn's `rpc_port` (also in the system prompt) on both calls below — this skill only runs
inside a vibing.nvim chat, so the port is always there and `nvim_list_instances` is never the
route. If the
`mcp__vibing-nvim__` prefix is unavailable, look for a tool name **ending** in the one you need —
loaded as a plugin they are `mcp__plugin_vibing-nvim_vibing-nvim__<tool>`. The
`nvim-context` skill explains both in full.

1. Call `mcp__vibing-nvim__nvim_get_buffer` with the `bufnr` from the system prompt to fetch the
   buffer's current content. This is the _live_ in-memory content, including edits that haven't
   been written to disk yet — vibing.nvim chat buffers are not auto-saved, so the on-disk file
   can lag behind what's actually been discussed.
2. If that call reports an invalid buffer — a resumed conversation can replay a buffer number
   from an earlier Neovim session — call `mcp__vibing-nvim__nvim_list_buffers`, find the chat
   file by name, and use its current `bufnr`.
3. If the RPC connection itself is down (Neovim not reachable), there is no fallback: every other
   route to the buffer goes over the same channel. Tell the user briefly and stop.

## Responding

Read through the recovered conversation to rebuild context internally. Reply with a short
one-line acknowledgment only (e.g. "会話履歴を読み直しました。" / "Context restored.") — do not
summarize the conversation or propose next steps unless the user asks for that separately.
