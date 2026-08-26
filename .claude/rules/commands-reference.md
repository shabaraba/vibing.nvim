# Commands Reference

## User Commands

| Command                               | Description                                                                                                                                                   |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `:VibingChat [position\|file]`        | Create new chat with optional position (current\|right\|left\|top\|bottom\|back) or open saved file                                                           |
| `:VibingToggleChat`                   | Toggle existing chat window (preserve current conversation)                                                                                                   |
| `:VibingChatFork [position]`          | Fork current chat (create branch from current conversation)                                                                                                   |
| `:VibingSubagentChat [position]`      | Continue a subagent this chat started, in its own buffer                                                                                                      |
| `:VibingChatJumpNextUser [count]`     | Move the cursor to the next User section in the chat buffer                                                                                                   |
| `:VibingChatJumpPrevUser [count]`     | Move the cursor to the previous User section in the chat buffer                                                                                               |
| `:VibingSlashCommands`                | Show slash command picker in chat                                                                                                                             |
| `:VibingSetFileTitle`                 | Generate AI title and rename chat file (prefers an existing `## summary` section as input)                                                                    |
| `:VibingSummarize [--with-title]`     | Generate AI summary of chat history and insert into buffer (`--with-title` chains `:VibingSetFileTitle` on success)                                           |
| `:VibingDeleteChats [--unrenamed]`    | Delete chat files (use --unrenamed to delete all unrenamed files)                                                                                             |
| `:VibingContext [path]`               | Add file to context (or from oil.nvim if no path)                                                                                                             |
| `:VibingClearContext`                 | Clear all context                                                                                                                                             |
| `:VibingCancel`                       | Cancel current request                                                                                                                                        |
| `:VibingSchedule [when]`              | Schedule this chat's unsent message (default: the recorded limit reset; or `30m`, `18:30`, …)                                                                 |
| `:VibingClearAnnotations`             | Remove inline review annotations from every buffer                                                                                                            |
| `:VibingDebugAnalyze`                 | Ask the agent to analyze the stopped debug session (needs nvim-dap)                                                                                           |
| `:VibingDebugHelp`                    | Ask the agent what to check next in the stopped debug session                                                                                                 |
| `:VibingPendingResumes`               | List chats waiting on a usage limit reset or a scheduled send                                                                                                 |
| `:VibingCancelResume [all]`           | Cancel the pending auto-resume/scheduled send for this chat (or every one with `all`); also clears the project's recorded usage limit for that chat's backend |
| `:VibingReloadCommands`               | Reload custom slash commands                                                                                                                                  |
| `:VibingCopyUnsentUserHeader`         | Copy `## User <!-- unsent -->` to clipboard                                                                                                                   |
| `:VibingDailySummary [YYYY-MM-DD]`    | Generate daily summary from project chat files (default: today)                                                                                               |
| `:VibingDailySummaryAll [YYYY-MM-DD]` | Generate daily summary from all chat files (default: today)                                                                                                   |

`:VibingChat`/`:VibingChatFork` position argument: `current` (replace current window), `right`,
`left`, `top`, `bottom` (splits sized by `config.chat.window.width`/`height`), or `back`
(buffer-only, no window). `:VibingChat <file>` opens a saved chat file instead of creating a new
one. Fork's session/frontmatter mechanics (`forked_from`, session inheritance via `forkSession`)
are documented in `architecture.md` → "Chat Fork" — not duplicated here. `:VibingSubagentChat`
takes the same position argument; why it shares the parent's `session_id` and never forks is in
`architecture.md` → "Subagent Chat".

The two jump commands ship without a keymap. They take a count
(`:3VibingChatJumpNextUser`) and clamp to the last section rather than refusing to move, and they
push the starting position onto the jumplist so `<C-o>` comes back — `nvim_win_set_cursor` updates
neither the `'` mark nor the jumplist on its own.

To bind them as `]`/`[` motions and keep the count, forward `v:count1` explicitly. A plain
`<Cmd>VibingChatJumpNextUser<CR>` mapping works but always moves one section, and the command
cannot read `v:count` itself: from the command line that variable still holds the count of the
last Normal-mode command, so `3j` followed by `:VibingChatJumpNextUser` would jump three sections.

```lua
vim.keymap.set("n", "]u", function()
  vim.cmd(vim.v.count1 .. "VibingChatJumpNextUser")
end, { desc = "Next User section" })
```

## Slash Commands (in Chat)

Slash commands can be used within the chat buffer for quick actions:

| Command                   | Description                                                                   |
| ------------------------- | ----------------------------------------------------------------------------- |
| `/context <file>`         | Add file to context                                                           |
| `/clear`                  | Clear context                                                                 |
| `/save`                   | Save current chat                                                             |
| `/summarize`              | Summarize conversation                                                        |
| `/model <model>`          | Set AI model (haiku/sonnet/opus/fable)                                        |
| `/effort <level>`         | Set reasoning effort (low/medium/high/xhigh/max)                              |
| `/help`                   | Show available slash commands                                                 |
| `/permissions` or `/perm` | Interactive Permission Builder - configure tool permissions                   |
| `/allow [tool]`           | Add tool to allow list, or show current list if no args                       |
| `/deny [tool]`            | Add tool to deny list, or show current list if no args                        |
| `/ask [tool]`             | Ask before using tool, or show current list if no args                        |
| `/permission [mode]`      | Set permission mode (default/acceptEdits/plan/auto/dontAsk/bypassPermissions) |
| `/new-session`            | Reset session and start fresh                                                 |

Worktree lifecycle (list/create/attach/run/finish) is handled entirely through natural-language
requests backed by the `vibing-worktree-{list,create,attach,run,finish}` Claude Code skills
bundled with this plugin (`claude-plugin/skills/`), not by chat slash commands. See
`claude-plugin/skills/vibing-worktree-list/SKILL.md` and its sibling `-create`, `-attach`,
`-run`, `-finish` skills.

Running several tasks in parallel across worker chats is the same story: ask for it in natural
language ("並行でやって"), and the bundled `vibing-orchestrate` skill
(`claude-plugin/skills/vibing-orchestrate/SKILL.md`) drives it through the `nvim_chat_create` /
`nvim_chat_send_message` / `nvim_get_buffer` MCP tools. There is no `:Vibing*` command for it —
see `architecture.md` → "Multi-Agent Orchestration".
