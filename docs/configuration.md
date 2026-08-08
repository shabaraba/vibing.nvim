# Configuration Reference

Complete reference for every `require("vibing").setup()` option. Defaults shown below match
`lua/vibing/config.lua`.

## Table of Contents

- [Defaults at a Glance](#defaults-at-a-glance)
- [Adapter](#adapter)
- [Agent](#agent)
- [Chat](#chat)
- [UI](#ui)
- [Keymaps](#keymaps)
- [Diff](#diff)
- [Permissions](#permissions)
- [Granular Permission Rules](#granular-permission-rules)
- [MCP](#mcp)
- [Node.js Executable](#nodejs-executable)
- [Language](#language)
- [Daily Summary](#daily-summary)

## Defaults at a Glance

```lua
require("vibing").setup({
  adapter = "claude",
  agent = {
    default_mode = "code",
    default_model = "sonnet",
    utility_model = "haiku",
    setting_sources = { "user", "project", "local" },
  },
  chat = {
    window = {
      position = "current",
      width = 0.4,
      height = 0.4,
      border = "rounded",
    },
    save_location_type = "project",
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",
  },
  ui = {
    wrap = "on",
    gradient = {
      enabled = true,
      colors = { "#cc3300", "#fffe00" },
      interval = 100,
    },
    tool_result_display = "compact",
    tool_markers = {
      Task = "▶",
      default = "⏺",
    },
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
    open_diff = "gd",
    open_file = "gf",
    open_url = "gx",
  },
  diff = {
    tool = "auto",
    mote = {
      project = nil,
      context_prefix = "vibing",
    },
  },
  permissions = {
    mode = "acceptEdits",
    allow = { "Read", "Edit", "Write", "Glob", "Grep", "Skill", "StructuredOutput" },
    deny = { "Bash" },
    ask = {},
    rules = {},
  },
  node = {
    executable = "auto",
  },
  mcp = {
    enabled = true,
    rpc_port = 9876,
  },
  language = nil,
  daily_summary = {
    save_dir = nil,
    search_dirs = {},
    file_finder_strategy = "auto",
  },
})
```

## Adapter

```lua
adapter = "claude",  -- Global backend adapter
                     -- "claude": Claude CLI (claude -p --output-format stream-json)
                     -- "codex":  Codex CLI  (codex exec --json)
                     -- Overridable per-chat via the "agent" frontmatter field
```

## Agent

```lua
agent = {
  default_mode = "code",    -- Recorded in each new chat's frontmatter as `mode`
                            -- ("code" | "plan" | "explore"). Currently metadata only —
                            -- it does not change runtime behavior.

  default_model = "sonnet", -- Default model for new chats
                            -- "sonnet": Balanced (recommended)
                            -- "opus": Most capable
                            -- "haiku": Fastest
                            -- "fable": Claude Fable

  utility_model = "haiku",  -- Model used for lightweight utility calls
                            -- (AI title generation, chat summaries, daily summaries).
                            -- Takes priority over the chat's model for those calls.

  setting_sources = { "user", "project", "local" },
                            -- Passed to the Claude CLI's --setting-sources flag.
                            -- Drop "user" to skip loading your global CLAUDE.md on
                            -- every chat, reducing fixed per-session token cost.
                            -- Note: does not affect MCP server loading.
}
```

## Chat

```lua
chat = {
  window = {
    position = "current",  -- "current": open in current window
                           -- "right" / "left": vertical split
                           -- "top" / "bottom": horizontal split
                           -- "back": background buffer only (no window)
                           -- "float": floating window

    width = 0.4,           -- Screen-width ratio (0-1). Applied to right/left splits
                           -- and floating windows. Always interpreted as a ratio —
                           -- absolute column counts are not supported.

    height = 0.4,          -- Screen-height ratio (0-1). Applied to top/bottom splits
                           -- only. Floating windows use a fixed 0.8 screen ratio.

    border = "rounded",    -- Border for position = "float" only (any nvim_open_win
                           -- border spec). Split windows have no border.
  },

  save_location_type = "project",  -- Chat file save location
                                   -- "project": .vibing/chat/ in project root
                                   -- "user": stdpath("data") .. "/vibing/chats"
                                   -- "custom": use save_dir

  save_dir = vim.fn.stdpath("data") .. "/vibing/chats",  -- Used when save_location_type = "custom"
}
```

Chat files are created as Markdown (`chat-<timestamp>-....md`) inside the save location.

## UI

```lua
ui = {
  wrap = "on",  -- "nvim": respect Neovim defaults (don't touch wrap settings)
                -- "on": enable wrap + linebreak (recommended for chat readability)
                -- "off": disable line wrapping

  tool_result_display = "compact",  -- "none": don't show tool results
                                    -- "compact": first 100 characters only (default)
                                    -- "full": complete tool output

  gradient = {
    enabled = true,   -- Animate line numbers while the AI is responding
    colors = { "#cc3300", "#fffe00" },  -- Exactly 2 hex colors: { start, end }
    interval = 100,   -- Animation update interval (ms)
  },

  tool_markers = {
    Task = "▶",      -- Marker for the Task tool
    default = "⏺",   -- Default marker for all other tools

    -- Per-tool string markers (optional):
    -- Read = "📄",
    -- Edit = "✏️",
    -- Bash = "💻",
  },
}
```

A `tool_markers` entry may also be a table with a `default` key (e.g.
`Bash = { default = "💻" }`); only the `default` key is used.

## Keymaps

Chat-buffer key bindings (all six are configurable; `q` to close the window is fixed):

```lua
keymaps = {
  send = "<CR>",         -- Send message
  cancel = "<C-c>",      -- Cancel current request
  add_context = "<C-a>", -- Add file to context
  open_diff = "gd",      -- Open diff viewer on file paths
  open_file = "gf",      -- Open file on file paths
  open_url = "gx",       -- Open URL on current line in browser
}
```

## Diff

Selects the strategy used by the `gd` diff viewer:

```lua
diff = {
  tool = "auto",  -- "auto" / "git": per-request patches (vim.diff-based, no external
                  --                 process) — these two currently behave the same
                  -- "mote": mote snapshots (catches Bash-driven file changes too)
  mote = {
    project = nil,              -- Project name (nil = auto-detect from git repo name)
    context_prefix = "vibing",  -- Prefix for mote context names
  },
}
```

mote is **opt-in**: it is used only when `tool = "mote"` is set explicitly, or when a chat has
`mote_dirs` in its frontmatter (added via `:VibingMoteDir` — those directories use mote
regardless of `tool`). Otherwise edited files are backed up before each write and stored as
patches under `.vibing/patches/`; Bash-driven file changes are only captured by the mote
backend. See [MIGRATION_MOTE.md](./MIGRATION_MOTE.md) for mote setup details.

## Permissions

```lua
permissions = {
  mode = "acceptEdits",  -- Permission mode
                         -- "default": ask for confirmation each time
                         -- "acceptEdits": auto-approve Edit/Write (recommended)
                         -- "plan": forwarded to the CLI as --permission-mode plan
                         --         (read-only planning enforced by the CLI itself)
                         -- "auto": approve everything not matched by the deny
                         --         list / deny rules
                         -- "dontAsk": deny instead of prompting
                         -- "bypassPermissions": auto-approve all (use with caution)

  allow = {              -- Tools to allow (empty = allow all except denied)
    "Read", "Edit", "Write", "Glob", "Grep", "Skill", "StructuredOutput",
  },

  deny = { "Bash" },     -- Tools to deny (takes precedence over allow)

  ask = {},              -- Tools requiring confirmation before each use

  rules = {},            -- Granular rules — see next section
}
```

Valid tool names: `Read`, `Edit`, `Write`, `Bash`, `Glob`, `Grep`, `WebSearch`, `WebFetch`,
`Skill`, `StructuredOutput`. Bash command patterns (`Bash(git:*)`) and MCP tool names
(`mcp__server__tool`) are also accepted in the lists.

Two built-in behaviors to be aware of:

- `Read`, `Skill`, and `StructuredOutput` are **always allowed** regardless of the allow list
  (they can still be blocked via `deny`).
- `Skill` is automatically appended to `allow` unless you put it in `deny` or `ask`.

## Granular Permission Rules

Fine-grained control based on tool inputs:

```lua
permissions = {
  mode = "default",
  rules = {
    -- Allow reading specific paths
    { tools = { "Read" }, paths = { "src/**", "tests/**" }, action = "allow" },

    -- Deny writes to sensitive files, with a custom message
    {
      tools = { "Write", "Edit" },
      paths = { ".env", "*.secret" },
      action = "deny",
      message = "Cannot modify sensitive files",
    },

    -- Allow specific Bash commands (exact base-command match)
    { tools = { "Bash" }, commands = { "npm", "yarn" }, action = "allow" },

    -- Deny dangerous Bash command patterns (Lua patterns — escape "-" as "%-")
    { tools = { "Bash" }, patterns = { "^rm %-rf", "^sudo" }, action = "deny" },

    -- Restrict web fetches to specific domains
    { tools = { "WebFetch" }, domains = { "github.com", "*.npmjs.com" }, action = "allow" },
  },
}
```

Field reference:

| Field | Applies to | Matching |
| --- | --- | --- |
| `tools` | any | Exact tool-name match |
| `paths` | tools whose input has a file path (Read/Write/Edit/...) | Glob: `*` (single dir), `**` (recursive); paths are normalized to absolute, symlink-resolved form first |
| `commands` | `Bash` only | Exact match against the base command (first word) |
| `patterns` | `Bash` only | **Lua patterns**, not regex — escape `-` as `%-` (e.g. `"^rm %-rf"`). Patterns longer than 500 chars are ignored |
| `domains` | `WebFetch` only | Domain match with `*.` wildcard support |
| `action` | — | `"allow"` or `"deny"` |
| `message` | — | Shown when a `deny` rule blocks a call |

Evaluation notes:

- Rules are evaluated **after** the tool-level `allow`/`ask` lists.
- Any matching `deny` rule blocks immediately and beats every `allow` rule.
- A rule whose condition doesn't apply to the tool's input (e.g. `paths` on a `Bash` call)
  is skipped.

## MCP

Enables the RPC server that the bundled `vibing-nvim` MCP server connects to (see the README's
Installation section for how the MCP server itself is installed via the Claude Code plugin):

```lua
mcp = {
  enabled = true,   -- Start the Neovim-side RPC server
  rpc_port = 9876,  -- RPC server port
}
```

## Node.js Executable

```lua
node = {
  executable = "auto",  -- "auto": detect from PATH (default)
                        -- or an explicit path, e.g. "/usr/local/bin/node"
                        -- (bun and other Node-compatible runtimes work too)
}
```

During plugin installation (`build.sh`), the `VIBING_NODE_EXECUTABLE` environment variable
controls which binary is used for the build:

```bash
VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh
```

Or in your lazy.nvim spec:

```lua
{
  "shabaraba/vibing.nvim",
  build = "VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh",
  config = function()
    require("vibing").setup({
      node = { executable = "/usr/local/bin/bun" },
    })
  end,
}
```

## Language

Configure AI response language:

```lua
-- Simple: all responses in one language
language = "ja"  -- "ja", "en", "zh", "ko", "fr", "de", "es", ...

-- Advanced: per-context language
language = {
  default = "ja",  -- Default language
  chat = "ja",     -- Chat responses (falls back to default)
}
```

## Daily Summary

Settings for `:VibingDailySummary` / `:VibingDailySummaryAll`:

```lua
daily_summary = {
  save_dir = nil,  -- nil: auto-detect from the chat save directory
                   --      (".../chat/" becomes ".../daily/", otherwise "daily/" is appended)
                   -- string: custom path (relative, absolute, or vim.fn.expand("~/..."))

  search_dirs = {},  -- Directories for :VibingDailySummaryAll
                     -- {} (default): search the standard locations (project .vibing/chat,
                     --     user data dir, custom save_dir)
                     -- { "~/workspaces" }: search ONLY the listed directories.
                     --     Each entry is scanned for `.vibing` directories (max depth 5,
                     --     skipping node_modules/.git/build/dist) and chat files are
                     --     collected from their chat/ subdirectories.

  file_finder_strategy = "auto",  -- File search backend
                                  -- "auto": pick the best available tool
                                  -- "fd" | "find" | "locate" | "ripgrep": force one
}
```

**Usage:**

```vim
:VibingDailySummary [YYYY-MM-DD]     " Current project's chats only (default: today)
:VibingDailySummaryAll [YYYY-MM-DD]  " search_dirs if configured, otherwise default locations
```

Summary files are saved as `YYYY-MM-DD.md` with YAML frontmatter (date, source files, total
messages).
