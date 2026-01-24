# Commands Reference

## User Commands

| Command                                   | Description                                                                                         |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `:VibingChat [position\|file]`            | Create new chat with optional position (current\|right\|left\|top\|bottom\|back) or open saved file |
| `:VibingChatWorktree [position] <branch>` | Create git worktree and open chat in it (position: right\|left\|top\|bottom\|back\|current)         |
| `:VibingToggleChat`                       | Toggle existing chat window (preserve current conversation)                                         |
| `:VibingSlashCommands`                    | Show slash command picker in chat                                                                   |
| `:VibingContext [path]`                   | Add file to context (or from oil.nvim if no path)                                                   |
| `:VibingClearContext`                     | Clear all context                                                                                   |
| `:VibingInline [action\|prompt]`          | Rich UI picker (no args) or direct execution (with args). Tab completion enabled.                   |
| `:VibingSummarize`                        | Generate AI summary of chat history and insert into buffer                                          |
| `:VibingCancel`                           | Cancel current request                                                                              |

## Command Semantics

**`:VibingChat`** - Always creates a fresh chat window. Optionally specify position to control window placement.

- `:VibingChat` - New chat using default position from config
- `:VibingChat current` - New chat in current window
- `:VibingChat right` - New chat in right split
- `:VibingChat left` - New chat in left split
- `:VibingChat top` - New chat in top split
- `:VibingChat bottom` - New chat in bottom split
- `:VibingChat back` - New chat as background buffer only (no window)
- `:VibingChat path/to/file.vibing` - Open saved chat file

**`:VibingChatWorktree`** - Create or reuse a git worktree for the specified branch and open a chat session in that environment.

- `:VibingChatWorktree feature-branch` - Create worktree in `.worktrees/feature-branch` and open chat
- `:VibingChatWorktree right feature-branch` - Same as above, but open chat in right split
- Position options: `right`, `left`, `top`, `bottom`, `back` (buffer only, no window - accessible via `:bnext`/`:ls`), `current`
- If the worktree already exists, it will be reused without recreating the environment
- Automatically copies configuration files (`.gitignore`, `package.json`, `tsconfig.json`, etc.) to the worktree
- Creates a symbolic link to `node_modules` from the main worktree (if it exists) to avoid duplicate installations
- Chat files are saved in main repository at `.vibing/worktrees/<branch-name>/` (persists after worktree deletion)

**`:VibingToggleChat`** - Use to show/hide your current conversation. Preserves the existing chat state.

## Inline Action Examples

**Rich UI Picker (recommended):**

```vim
:'<,'>VibingInline
" Opens a split-panel UI:
" - Left: Action menu (fix, feat, explain, refactor, test)
"   - Navigate: j/k or arrow keys
"   - Move to input: Tab
" - Right: Additional instruction input (optional)
"   - Move to menu: Shift-Tab
" - Execute: Enter (from either panel)
" - Cancel: Esc or Ctrl-c
```

**Keybindings in Rich UI:**

- `j`/`k` or `↓`/`↑` - Navigate action menu
- `Tab` - Move from menu to input field
- `Shift-Tab` - Move from input field to menu
- `Enter` - Execute selected action
- `Esc` or `Ctrl-c` - Cancel

**Direct Execution (with arguments):**

```vim
:'<,'>VibingInline fix       " Fix code issues
:'<,'>VibingInline feat      " Implement feature
:'<,'>VibingInline explain   " Explain code
:'<,'>VibingInline refactor  " Refactor code
:'<,'>VibingInline test      " Generate tests

" With additional instructions
:'<,'>VibingInline explain 日本語で
:'<,'>VibingInline fix using async/await
:'<,'>VibingInline test using Jest with mocks
:'<,'>VibingInline refactor to use functional style
```

**Natural Language Instructions:**

```vim
:'<,'>VibingInline "Convert this function to TypeScript"
:'<,'>VibingInline "Add error handling with try-catch"
:'<,'>VibingInline "Optimize this loop for performance"
```

## Slash Commands (in Chat)

Slash commands can be used within the chat buffer for quick actions:

| Command                   | Description                                                 |
| ------------------------- | ----------------------------------------------------------- |
| `/context <file>`         | Add file to context                                         |
| `/clear`                  | Clear context                                               |
| `/save`                   | Save current chat                                           |
| `/summarize`              | Summarize conversation                                      |
| `/mode <mode>`            | Set execution mode (auto/plan/code/explore)                 |
| `/model <model>`          | Set AI model (opus/sonnet/haiku)                            |
| `/permissions` or `/perm` | Interactive Permission Builder - configure tool permissions |
| `/allow [tool]`           | Add tool to allow list, or show current list if no args     |
| `/deny [tool]`            | Add tool to deny list, or show current list if no args      |
| `/permission [mode]`      | Set permission mode (default/acceptEdits/bypassPermissions) |
