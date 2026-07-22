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
| `:VibingReloadCommands`               | Reload custom slash commands                                                                        |
| `:VibingCopyUnsentUserHeader`         | Copy `## User <!-- unsent -->` to clipboard                                                         |
| `:VibingDailySummary [YYYY-MM-DD]`    | Generate daily summary from project chat files (default: today)                                     |
| `:VibingDailySummaryAll [YYYY-MM-DD]` | Generate daily summary from all chat files (default: today)                                         |

## Command Semantics

**`:VibingChat`** - Always creates a fresh chat window. Optionally specify position to control window placement.

- `:VibingChat` - New chat using default position from config
- `:VibingChat current` - New chat in current window
- `:VibingChat right` - New chat in right split
- `:VibingChat left` - New chat in left split
- `:VibingChat top` - New chat in top split
- `:VibingChat bottom` - New chat in bottom split
- `:VibingChat back` - New chat as background buffer only (no window)
- `:VibingChat path/to/file.md` - Open saved chat file

**`:VibingChatFork`** - Fork the current chat conversation. Creates a new chat file with the same conversation history and session, allowing you to branch the conversation in a different direction.

- `:VibingChatFork` - Fork using default position
- `:VibingChatFork right` - Fork and open in right split
- `:VibingChatFork left` - Fork and open in left split
- Position options: `current`, `right`, `left`, `top`, `bottom`, `back`
- The fork file is named `<source>-fork-N.md` with auto-incrementing numbers
- Fork inherits the source's session ID; on the first message, the SDK creates a new session via `forkSession` API
- The `forked_from` frontmatter field tracks the source file for link synchronization
- When the source file is renamed (via `:VibingSetFileTitle`), the fork's `forked_from` is automatically updated

**`:VibingToggleChat`** - Use to show/hide your current conversation. Preserves the existing chat state.

## Slash Commands (in Chat)

Slash commands can be used within the chat buffer for quick actions:

| Command                   | Description                                                                   |
| ------------------------- | ----------------------------------------------------------------------------- |
| `/context <file>`         | Add file to context                                                           |
| `/clear`                  | Clear context                                                                 |
| `/save`                   | Save current chat                                                             |
| `/summarize`              | Summarize conversation                                                        |
| `/model <model>`          | Set AI model (opus/sonnet/haiku/fable)                                        |
| `/help`                   | Show available slash commands                                                 |
| `/permissions` or `/perm` | Interactive Permission Builder - configure tool permissions                   |
| `/allow [tool]`           | Add tool to allow list, or show current list if no args                       |
| `/deny [tool]`            | Add tool to deny list, or show current list if no args                        |
| `/ask [tool]`             | Ask before using tool, or show current list if no args                        |
| `/permission [mode]`      | Set permission mode (default/acceptEdits/plan/auto/dontAsk/bypassPermissions) |
| `/new-session`            | Reset session and start fresh                                                 |

Worktree lifecycle (list/create/attach/finish) is handled entirely through natural-language
requests backed by the `vibing-worktree` Claude Code skill bundled with this plugin (`skills/`),
not by chat slash commands. See `skills/vibing-worktree/SKILL.md`.
