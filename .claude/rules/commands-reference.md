# Commands Reference

## User Commands

| Command                               | Description                                                                                         |
| ------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `:VibingChat [position\|file]`        | Create new chat with optional position (current\|right\|left\|top\|bottom\|back) or open saved file |
| `:VibingToggleChat`                   | Toggle existing chat window (preserve current conversation)                                         |
| `:VibingChatFork [position]`          | Fork current chat (create branch from current conversation)                                         |
| `:VibingSlashCommands`                | Show slash command picker in chat                                                                   |
| `:VibingSetFileTitle`                 | Generate AI title and rename chat file                                                              |
| `:VibingSummarize`                    | Generate AI summary of chat history and insert into buffer                                          |
| `:VibingDeleteChats [--unrenamed]`    | Delete chat files (use --unrenamed to delete all unrenamed files)                                   |
| `:VibingContext [path]`               | Add file to context (or from oil.nvim if no path)                                                   |
| `:VibingClearContext`                 | Clear all context                                                                                   |
| `:VibingCancel`                       | Cancel current request                                                                              |
| `:VibingClearAnnotations`             | Remove inline review annotations from every buffer                                                  |
| `:VibingDebugAnalyze`                 | Ask the agent to analyze the stopped debug session (needs nvim-dap)                                 |
| `:VibingDebugHelp`                    | Ask the agent what to check next in the stopped debug session                                       |
| `:VibingPendingResumes`               | List chats waiting on a usage limit reset                                                           |
| `:VibingCancelResume [all]`           | Cancel the pending auto-resume for this chat (or every one with `all`)                              |
| `:VibingReloadCommands`               | Reload custom slash commands                                                                        |
| `:VibingCopyUnsentUserHeader`         | Copy `## User <!-- unsent -->` to clipboard                                                         |
| `:VibingDailySummary [YYYY-MM-DD]`    | Generate daily summary from project chat files (default: today)                                     |
| `:VibingDailySummaryAll [YYYY-MM-DD]` | Generate daily summary from all chat files (default: today)                                         |

`:VibingChat`/`:VibingChatFork` position argument: `current` (replace current window), `right`,
`left`, `top`, `bottom` (splits sized by `config.chat.window.width`/`height`), or `back`
(buffer-only, no window). `:VibingChat <file>` opens a saved chat file instead of creating a new
one. Fork's session/frontmatter mechanics (`forked_from`, session inheritance via `forkSession`)
are documented in `architecture.md` → "Chat Fork" — not duplicated here.

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
bundled with this plugin (`skills/`), not by chat slash commands. See
`skills/vibing-worktree-list/SKILL.md` and its sibling `-create`, `-attach`, `-run`, `-finish`
skills.
