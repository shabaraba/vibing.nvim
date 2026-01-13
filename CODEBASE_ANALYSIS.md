# vibing.nvim Codebase Analysis & Simplification Report

## Executive Summary

The vibing.nvim codebase (117 Lua files, ~15K lines) demonstrates solid architecture with clean separation of concerns following Domain-Driven Design principles. However, there are opportunities for simplification and deduplication.

## Architecture Overview

```
vibing.nvim/
├── lua/vibing/
│   ├── core/                    # Utilities & constants
│   ├── domain/                  # Business logic & entities
│   ├── application/            # Use cases & handlers
│   ├── infrastructure/         # External integrations
│   ├── presentation/           # UI controllers & views
│   └── ui/                     # UI components
├── bin/                        # TypeScript Agent SDK wrapper
└── mcp-server/                 # MCP server implementation
```

## Key Findings

### 1. CODE DUPLICATION

#### A. Buffer/Window Creation Logic (HIGH PRIORITY)

**Issue**: Multiple files implement similar buffer/window creation patterns

**Affected Files** (13 files):

- `ui/inline_preview.lua` (1193 lines) ⚠️
- `ui/patch_viewer.lua` (468 lines)
- `ui/inline_picker.lua` (281 lines)
- `ui/output_buffer.lua` (194 lines)
- `presentation/chat/buffer.lua` (375 lines)
- `presentation/inline/output_view.lua`
- `presentation/inline/progress_view.lua`
- `presentation/common/window.lua` (partial abstraction exists)
- `core/utils/diff.lua`
- `core/utils/git_diff.lua`
- `application/chat/handlers/summarize.lua`
- `infrastructure/buffer/manager.lua` (84 lines - good abstraction)

**Duplication Pattern**:

```lua
-- Repeated across multiple files:
local buf = vim.api.nvim_create_buf(false, true)
local win = vim.api.nvim_open_win(buf, true, {
  relative = "editor",
  width = width,
  height = height,
  row = row,
  col = col,
  style = "minimal",
  border = "rounded",
})
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].modifiable = false
vim.bo[buf].buftype = "nofile"
```

**Solution**: Expand `presentation/common/window.lua` and `infrastructure/buffer/manager.lua`

#### B. Command Validation Duplication (MEDIUM PRIORITY)

**Issue**: Similar validation logic exists in 3 separate files

**Affected Files**:

- `domain/security/command_validator.lua` (188 lines)
- `infrastructure/nvim/command_validator.lua` (169 lines)
- `domain/permissions/evaluator.lua` (261 lines)

**Duplication**:

- Pattern matching for dangerous commands
- Shell metacharacter detection
- Path normalization

**Overlap**:

```lua
-- In command_validator.lua:
local DANGEROUS_PATTERNS = {
  "rm%s+%-rf",
  "sudo",
  "eval%s+",
  -- ...
}

-- In permissions/evaluator.lua:
local function match_command(allowed_commands, command)
  local cmd_name = command:match("^(%S+)")
  -- Similar logic
end
```

**Solution**: Consolidate into single validation module

#### C. Chat Handler Boilerplate (LOW-MEDIUM PRIORITY)

**Issue**: 14 chat handlers with similar structure

**Files**: `application/chat/handlers/*.lua` (14 handlers)

- `allow.lua`, `deny.lua`, `permission.lua`, `permissions.lua`
- `mode.lua`, `model.lua`
- `context.lua`, `clear.lua`
- `save.lua`, `help.lua`, `summarize.lua`
- `ask.lua`, `set_file_title.lua`, `new_session.lua`

**Pattern**:

```lua
-- Repeated structure:
local M = {}
local notify = require("vibing.core.utils.notify")

function M.execute(args, buffer_context)
  -- Validation
  if not args or #args == 0 then
    notify.error("Invalid arguments")
    return false
  end

  -- Business logic
  -- ...

  -- Success notification
  notify.info("Success")
  return true
end

return M
```

**Solution**: Create base handler class with template method pattern

#### D. Vim API Call Frequency (MEDIUM PRIORITY)

**Statistics**:

- `vim.api.nvim_buf_*` calls: 199 occurrences across 36 files
- `vim.api.nvim_create_buf`: 12 files
- `vim.api.nvim_open_win`: 9 files
- `vim.schedule`: 37 occurrences

**Issue**: Direct Vim API calls scattered throughout, bypassing abstraction layers

**Solution**: Route all calls through infrastructure layer

### 2. LARGE FILES NEEDING REFACTORING

| File                                  | Lines | Issue                                  | Recommendation                                             |
| ------------------------------------- | ----- | -------------------------------------- | ---------------------------------------------------------- |
| `ui/inline_preview.lua`               | 1193  | Monolithic, handles 3-panel UI + state | Split into: state manager, panel renderer, layout manager  |
| `ui/patch_viewer.lua`                 | 468   | Similar to inline_preview              | Extract common panel logic                                 |
| `presentation/chat/buffer.lua`        | 375   | Multiple responsibilities              | Split buffer ops, rendering, event handling                |
| `ui/permission_builder.lua`           | 365   | UI + business logic mixed              | Separate UI from permission logic                          |
| `config.lua`                          | 348   | Config validation + type defs          | Move validation to separate module                         |
| `infrastructure/rpc/handlers/lsp.lua` | 340   | LSP operations                         | Split by LSP feature (definition, references, hover, etc.) |
| `ui/command_picker.lua`               | 320   | Picker UI + command handling           | Split UI from command execution                            |

### 3. ARCHITECTURAL CONCERNS

#### A. Inconsistent Abstraction Usage

**Good Examples**:

- `infrastructure/buffer/manager.lua` - Clean abstraction (84 lines)
- `presentation/common/window.lua` - Partial abstraction (82 lines)

**Problem**: These abstractions exist but are underutilized

- Only 8 files use `buffer/manager.lua`
- Only 1 file uses `common/window.lua`
- 36 files still call `vim.api.nvim_buf_*` directly

#### B. Module Coupling

**Issue**: High coupling between presentation and infrastructure layers

Example from `presentation/chat/buffer.lua`:

```lua
-- Direct infrastructure access bypassing application layer
local git = require("vibing.core.utils.git")
local diff_util = require("vibing.core.utils.diff")
local notify = require("vibing.core.utils.notify")
-- ...plus 7 more direct requires
```

**Recommendation**: Use dependency injection pattern

#### C. Dual Validation Systems

Two separate but overlapping validation systems:

1. **Permission System** (`domain/permissions/evaluator.lua`)
   - Rule-based
   - Path/command/pattern matching
   - Domain-layer

2. **Command Validator** (`domain/security/command_validator.lua`)
   - Pattern-based
   - Security-focused
   - Domain-layer

**Issue**: Unclear boundaries, potential for bypassing security

### 4. SPECIFIC REFACTORING OPPORTUNITIES

#### Opportunity 1: Buffer/Window Factory

**Current State**: Scattered across 13 files

**Proposed**:

```lua
-- infrastructure/ui/factory.lua
local Factory = {}

function Factory.create_preview_layout(opts)
  -- Creates multi-panel layouts (files, diff, response)
  -- Used by inline_preview, patch_viewer
end

function Factory.create_floating_buffer(opts)
  -- Standard floating window pattern
  -- Used by all pickers and output buffers
end

function Factory.create_split_buffer(position, opts)
  -- right, left, top, bottom splits
  -- Used by chat, inline actions
end

return Factory
```

**Impact**: Reduce ~500 lines of duplicated code

#### Opportunity 2: Handler Base Class

**Current State**: 14 handlers with repeated boilerplate

**Proposed**:

```lua
-- application/chat/handlers/base.lua
local BaseHandler = {}

function BaseHandler:new(opts)
  local instance = {
    name = opts.name,
    validate = opts.validate or function() return true end,
    execute_impl = opts.execute,
  }
  setmetatable(instance, self)
  self.__index = self
  return instance
end

function BaseHandler:execute(args, context)
  if not self:validate(args, context) then
    return false
  end

  local ok, result = pcall(self.execute_impl, args, context)
  if not ok then
    notify.error(string.format("[%s] %s", self.name, result))
    return false
  end

  return result
end

return BaseHandler
```

**Impact**: Reduce ~200 lines of boilerplate

#### Opportunity 3: Unified Validation Module

**Proposed**:

```lua
-- domain/security/validator.lua
local Validator = {}

function Validator.validate_command(cmd, rules)
  -- Consolidates command_validator + permission evaluator
end

function Validator.validate_path(path, rules)
  -- Consolidates path checks from both validators
end

function Validator.matches_pattern(text, patterns)
  -- Common pattern matching logic
end

return Validator
```

**Impact**: Eliminate 100+ lines of duplication

#### Opportunity 4: UI State Manager Pattern

**Problem**: `ui/inline_preview.lua` (1193 lines) manages complex state

**Proposed**:

```lua
-- ui/inline_preview/state.lua (already exists partially)
-- Expand to handle all state operations

-- ui/inline_preview/panels/files.lua
-- ui/inline_preview/panels/diff.lua
-- ui/inline_preview/panels/response.lua
-- ui/inline_preview/layout.lua
-- ui/inline_preview/init.lua (orchestrator)
```

**Impact**: Break 1193-line file into 5 manageable modules (~200 lines each)

### 5. POSITIVE PATTERNS (Keep These)

✅ **Clean Domain Layer**

- `domain/chat/message.lua`
- `domain/context/entity.lua`
- `domain/session/entity.lua`

✅ **Good Module Size**

- `infrastructure/buffer/manager.lua` (84 lines)
- `presentation/common/window.lua` (82 lines)
- `core/utils/notify.lua` (assumed small)

✅ **Clear Separation of Concerns**

- Domain layer doesn't depend on infrastructure
- Application layer coordinates between layers

✅ **Type Annotations**

- Consistent use of LuaLS annotations
- Clear interfaces and contracts

## Refactoring Priority Matrix

### HIGH PRIORITY (Do First)

1. **Buffer/Window Factory** (13 files affected, ~500 lines saved)
2. **ui/inline_preview.lua split** (1193 → 5 × 200 lines)
3. **Vim API abstraction enforcement** (36 files, consistency improvement)

### MEDIUM PRIORITY (Do Second)

4. **Command Validation consolidation** (3 files → 1, security critical)
5. **Chat handler base class** (14 files, ~200 lines saved)
6. **Large file splitting** (7 files > 300 lines)

### LOW PRIORITY (Nice to Have)

7. **Dependency injection pattern** (better testing, loose coupling)
8. **Config validation extraction** (cleaner config.lua)
9. **Handler command registration** (reduce init.lua complexity)

## Metrics

### Current State

- **Total Lua Files**: 117
- **Total Lines**: ~15,000
- **Largest File**: 1193 lines (ui/inline_preview.lua)
- **Files > 300 lines**: 7
- **Average File Size**: 128 lines
- **Buffer/Window Creation Sites**: 13 files
- **Direct vim.api.nvim*buf*\* calls**: 199 occurrences

### After Refactoring (Projected)

- **Lines Saved**: ~1,000-1,500 lines (7-10% reduction)
- **Files > 300 lines**: 2-3
- **Largest File**: ~400 lines
- **Code Duplication**: Reduced by ~40%
- **Abstraction Violation**: Reduced by ~60%

## Implementation Roadmap

### Phase 1: Infrastructure (Week 1)

1. Create `infrastructure/ui/factory.lua`
2. Migrate 5 files to use new factory
3. Update remaining 8 files incrementally

### Phase 2: Domain (Week 2)

1. Consolidate validation modules
2. Create handler base class
3. Refactor 14 chat handlers

### Phase 3: UI (Week 3)

1. Split `ui/inline_preview.lua`
2. Split `ui/patch_viewer.lua`
3. Extract common panel logic

### Phase 4: Polish (Week 4)

1. Add tests for new abstractions
2. Update documentation
3. Performance profiling

## Conclusion

vibing.nvim has a solid architectural foundation with clear layer separation. The main opportunities for improvement are:

1. **Reducing duplication** through better abstraction usage
2. **Breaking up large files** using composition patterns
3. **Enforcing abstraction boundaries** to prevent direct API access
4. **Consolidating validation logic** for better security

These refactorings would improve:

- **Maintainability**: Smaller, focused modules
- **Testability**: Better abstraction boundaries
- **Performance**: Reduced code paths
- **Developer Experience**: Clearer code organization
