# Design: Fix Wrap Configuration Issue #237

## Overview

Fix the issue where `config.ui.wrap` settings are being applied to non-vibing buffers, overwriting user Neovim settings. The problem stems from using `vim.wo[win].wrap`, which is window-local and persists when switching buffers in the same window.

## Requirements Analysis

### Functional Requirements

- Wrap configuration (`ui.wrap: "on"|"off"|"nvim"`) should only affect vibing buffers
- User's Neovim wrap settings for non-vibing buffers must be preserved
- Wrap settings should apply automatically when opening vibing buffers
- Wrap settings should be removed when leaving vibing buffers

### Non-Functional Requirements

- Use Neovim's standard ftplugin mechanism
- Maintain backward compatibility with existing configurations
- Minimal code changes
- No performance degradation

### Constraints

- `vim.wo[win].wrap` is window-local, not buffer-local
- Switching buffers in the same window preserves window-local settings
- Must work with all vibing buffer types (chat, output, inline progress)

## Root Cause Analysis

### Problem

`vim.wo[win].wrap` sets window-local options that apply to **all buffers** displayed in that window. When a user:

1. Opens a vibing buffer (wrap settings applied)
2. Switches to another buffer in the same window
3. The wrap settings remain active, overwriting user preferences

### Current Implementation

```lua
-- lua/vibing/core/utils/ui.lua
function M.apply_wrap_config(win)
  if wrap_setting == "on" then
    vim.wo[win].wrap = true      -- Window-local, persists!
    vim.wo[win].linebreak = true
  elseif wrap_setting == "off" then
    vim.wo[win].wrap = false
  end
end
```

Called from:

- `lua/vibing/presentation/chat/buffer.lua` (line 188)
- `lua/vibing/presentation/common/window.lua` (lines 39, 61)
- `lua/vibing/presentation/inline/progress_view.lua` (line 50)
- `lua/vibing/presentation/inline/output_view.lua` (line 54)
- `lua/vibing/ui/output_buffer.lua` (line 94)
- `lua/vibing/ui/inline_progress.lua` (line 66)

Additionally called from:

- `ftplugin/vibing.lua` (line 27) - for .vibing files

## Architecture

### Solution: Buffer-Local Autocmd Approach

Use `BufEnter` and `BufLeave` autocmds to apply/restore wrap settings per buffer, leveraging the existing `ftplugin/vibing.lua` for filetype-based management.

### Components

| Component                           | Responsibility                                        | Changes                                   |
| ----------------------------------- | ----------------------------------------------------- | ----------------------------------------- |
| `ftplugin/vibing.lua`               | Apply wrap settings on buffer enter for .vibing files | Enhanced with autocmds                    |
| `lua/vibing/core/utils/ui.lua`      | Centralized wrap configuration logic                  | Add autocmd setup function                |
| UI modules (chat, output, progress) | Create UI windows                                     | Remove direct `apply_wrap_config()` calls |

### Data Flow

```
User opens vibing buffer
  ↓
Filetype detection (vibing)
  ↓
ftplugin/vibing.lua loads
  ↓
BufEnter autocmd applies wrap config
  ↓
User switches to another buffer
  ↓
BufLeave autocmd (optional: restore original)
  ↓
User returns to vibing buffer
  ↓
BufEnter autocmd reapplies wrap config
```

### API Design

#### Enhanced `ui.lua` Functions

```lua
-- lua/vibing/core/utils/ui.lua

---Apply wrap configuration using buffer-local autocmds
---Sets up BufEnter/BufLeave autocmds for the current buffer
---@param bufnr number Buffer number (0 for current buffer)
---@return nil
function M.setup_wrap_autocmds(bufnr)
  -- Create buffer-local autocmd group
  -- Apply wrap settings on BufEnter
  -- Optional: Restore settings on BufLeave
end

---Apply wrap configuration to current window (immediate)
---@param win number Window handle (0 for current window)
---@return nil
function M.apply_wrap_config(win)
  -- Existing implementation (kept for ftplugin use)
end
```

## Implementation Plan

### Phase 1: Enhance `ftplugin/vibing.lua`

**File**: `ftplugin/vibing.lua`

**Changes**:

1. Replace immediate `apply_wrap_config(0)` call with autocmd-based approach
2. Set up `BufEnter` autocmd to apply wrap settings when entering vibing buffer
3. Optional: Set up `BufLeave` autocmd to save/restore original wrap settings

**Implementation**:

```lua
-- Apply wrap configuration for .vibing files using autocmds
local ok, ui_utils = pcall(require, "vibing.core.utils.ui")
if ok then
  -- Apply immediately on first load
  ui_utils.apply_wrap_config(0)

  -- Set up autocmd for future BufEnter events
  local bufnr = vim.api.nvim_get_current_buf()
  local group = vim.api.nvim_create_augroup("vibing_wrap_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      ui_utils.apply_wrap_config(0)
    end,
    desc = "Apply vibing wrap settings on buffer enter"
  })
end
```

### Phase 2: Update UI Modules

**Affected Files**:

- `lua/vibing/presentation/chat/buffer.lua` (line 188)
- `lua/vibing/presentation/common/window.lua` (lines 39, 61)
- `lua/vibing/presentation/inline/progress_view.lua` (line 50)
- `lua/vibing/presentation/inline/output_view.lua` (line 54)
- `lua/vibing/ui/output_buffer.lua` (line 94)
- `lua/vibing/ui/inline_progress.lua` (line 66)

**Changes**:

1. **Option A (Recommended)**: Remove `apply_wrap_config()` calls entirely, rely on filetype detection
2. **Option B (Hybrid)**: Keep immediate call but add autocmd for buffer reentry

**For chat buffers** (`presentation/chat/buffer.lua`):

- Filetype is already set to `"vibing"` (line 106)
- `ftplugin/vibing.lua` will automatically apply wrap settings
- **Action**: Remove `apply_wrap_config()` call at line 188

**For output/progress buffers** (floating windows):

- These use `buftype = "nofile"` and `filetype = "markdown"` or custom types
- **Decision needed**: Should these buffers use vibing wrap settings?
  - **Option 1**: Set `filetype = "vibing"` to leverage ftplugin
  - **Option 2**: Keep separate handling with autocmds

### Phase 3: Enhance `ui.lua` (Optional)

**File**: `lua/vibing/core/utils/ui.lua`

**New Function** (optional helper):

```lua
---Set up buffer-local autocmds for wrap configuration
---@param bufnr number Buffer number (0 for current)
function M.setup_wrap_autocmds(bufnr)
  local buf = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr

  local group = vim.api.nvim_create_augroup("vibing_wrap_" .. buf, { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      M.apply_wrap_config(0)
    end,
    desc = "Apply vibing wrap settings"
  })
end
```

### Files to Modify

#### Primary Changes

1. **`ftplugin/vibing.lua`**
   - Add `BufEnter` autocmd for wrap settings
   - Keep immediate `apply_wrap_config(0)` for first load

#### Secondary Changes (Remove direct calls)

2. **`lua/vibing/presentation/chat/buffer.lua`**
   - Remove line 188: `ui_utils.apply_wrap_config(self.win)`
   - Filetype is already `"vibing"`, ftplugin will handle it

3. **`lua/vibing/presentation/common/window.lua`**
   - Remove lines 39, 61: `ui_utils.apply_wrap_config(self.win)`
   - Check if filetype is set to `"vibing"`

4. **`lua/vibing/presentation/inline/progress_view.lua`**
   - Evaluate: Should progress windows use vibing wrap settings?
   - If yes: Set filetype to `"vibing"` and remove explicit call
   - If no: Keep as-is with autocmd

5. **`lua/vibing/presentation/inline/output_view.lua`**
   - Same evaluation as progress_view.lua

6. **`lua/vibing/ui/output_buffer.lua`**
   - Same evaluation

7. **`lua/vibing/ui/inline_progress.lua`**
   - Same evaluation

### Dependencies

- No new packages needed
- Leverages existing `ftplugin` mechanism
- Uses existing `vibing.core.utils.ui` module

## Edge Cases

### Case 1: Multiple vibing buffers in different windows

**Scenario**: User opens multiple vibing chat files in splits

**Handling**:

- Each buffer gets its own autocmd group (identified by bufnr)
- Autocmds are buffer-local, no conflicts
- Each window independently applies wrap settings when buffer is entered

### Case 2: Non-vibing buffers in windows that previously had vibing buffers

**Scenario**: User opens vibing buffer, then opens a regular file in same window

**Current Problem**: Wrap settings persist

**Fix**:

- When leaving vibing buffer, wrap settings are NOT removed
- When entering non-vibing buffer, its ftplugin (or lack thereof) controls wrap
- No interference because we're not setting window-local options outside of vibing buffers

**Note**: Window-local options are reset when a new buffer is displayed IF that buffer's ftplugin sets them. Since non-vibing buffers don't have vibing ftplugin, their default or user-configured wrap settings apply naturally.

### Case 3: User changes wrap settings while in vibing buffer

**Scenario**: User manually runs `:set wrap` or `:set nowrap` in vibing buffer

**Handling**:

- User's manual change takes effect immediately
- Next time buffer is entered, autocmd will reapply config.ui.wrap setting
- This is expected behavior (config overrides manual changes on reentry)

**Alternative**: Could skip autocmd if user has manually changed settings (check if setting differs from last applied value), but this adds complexity for minimal benefit.

### Case 4: Floating windows (output, progress) without filetype

**Scenario**: Floating windows use `buftype = "nofile"` and may not have vibing filetype

**Handling Options**:

**Option A (Recommended)**: Set `filetype = "vibing"` for all vibing-related buffers

```lua
-- In output_buffer.lua, inline_progress.lua, etc.
vim.bo[self.buf].filetype = "vibing"
-- ftplugin will automatically apply wrap settings
```

**Option B**: Keep separate filetype but use autocmd in buffer creation

```lua
-- In _create_buffer() or _create_window()
local ui_utils = require("vibing.core.utils.ui")
ui_utils.setup_wrap_autocmds(self.buf)
```

**Option C**: Remove wrap configuration from temporary floating windows

```lua
-- Don't apply wrap settings to output/progress windows
-- Let them use Neovim defaults or user settings
```

### Case 5: config.ui.wrap = "nvim"

**Scenario**: User sets `ui.wrap = "nvim"` to respect Neovim defaults

**Handling**:

- `apply_wrap_config()` returns early, doesn't modify any settings
- No autocmds needed for this case
- Vibing buffers use Neovim's default wrap behavior

## Testing Strategy

### Manual Testing

#### Test 1: Vibing buffer doesn't affect other buffers

1. Set `ui.wrap = "on"` in config
2. Open a vibing chat (`:VibingChat`)
3. Verify wrap is enabled
4. Switch to a regular file (`:e test.txt`)
5. **Expected**: Wrap settings match user's Neovim config (not forced on)
6. Switch back to vibing chat
7. **Expected**: Wrap is enabled again

#### Test 2: Multiple vibing buffers

1. Open vibing chat A (`:VibingChat`)
2. Open vibing chat B (`:VibingChat`)
3. Switch between A and B
4. **Expected**: Both have wrap enabled

#### Test 3: Floating windows (output/progress)

1. Set `ui.wrap = "on"`
2. Run inline action (`:VibingInline explain`)
3. Check output window wrap settings
4. **Expected**: Wrap enabled (if we choose to apply to floating windows)

#### Test 4: Wrap config modes

1. Test with `ui.wrap = "on"` → wrap enabled
2. Test with `ui.wrap = "off"` → wrap disabled
3. Test with `ui.wrap = "nvim"` → respect Neovim defaults

### Automated Testing

#### Unit Tests (using plenary.nvim or busted)

```lua
describe("vibing wrap configuration", function()
  before_each(function()
    -- Create test buffer
    -- Set up vibing filetype
  end)

  it("applies wrap settings on BufEnter for vibing filetype", function()
    -- Set config.ui.wrap = "on"
    -- Trigger BufEnter autocmd
    -- Assert vim.wo.wrap == true
  end)

  it("does not affect non-vibing buffers", function()
    -- Open vibing buffer
    -- Switch to non-vibing buffer
    -- Assert wrap settings are not from vibing config
  end)

  it("respects ui.wrap = 'nvim' setting", function()
    -- Set config.ui.wrap = "nvim"
    -- Open vibing buffer
    -- Assert no wrap settings are modified
  end)
end)
```

### Integration Testing

1. **Test with lazy.nvim**: Ensure ftplugin loads correctly after plugin installation
2. **Test with multiple config locations**: User global config, project config
3. **Test with MCP integration**: Ensure wrap settings work with remote Neovim instances

## Implementation Phases

### Phase 1: Core Fix (Priority: High)

**Duration**: 1-2 hours

1. Modify `ftplugin/vibing.lua` to use autocmds
2. Remove `apply_wrap_config()` from `presentation/chat/buffer.lua`
3. Manual testing with chat buffers

### Phase 2: UI Modules (Priority: Medium)

**Duration**: 1-2 hours

1. Audit all UI modules for `apply_wrap_config()` usage
2. Decide on filetype strategy for floating windows
3. Remove or refactor calls based on decision
4. Manual testing with inline actions, output windows

### Phase 3: Documentation (Priority: Low)

**Duration**: 30 minutes

1. Update CLAUDE.md if architecture changes
2. Add comments explaining autocmd approach
3. Update user documentation if behavior changes

## Open Questions

1. **Should floating windows (output, progress) use vibing wrap settings?**
   - **Recommendation**: Yes, for consistency, but they're temporary so less critical
   - **Decision**: Set filetype to "vibing" for all vibing-related buffers

2. **Should we restore original wrap settings on BufLeave?**
   - **Pros**: More isolated behavior
   - **Cons**: Complex state management, edge cases with window splits
   - **Recommendation**: No, rely on ftplugin mechanism of target buffer

3. **Backward compatibility concerns?**
   - **Analysis**: No breaking changes for users
   - **Config**: No changes needed
   - **Behavior**: Improvement (fix bug), not a breaking change

## Risk Assessment

| Risk                               | Severity | Mitigation                                   |
| ---------------------------------- | -------- | -------------------------------------------- |
| Autocmds not triggering            | Medium   | Thorough testing, fallback to immediate call |
| Performance impact (many autocmds) | Low      | Autocmds are buffer-local, minimal overhead  |
| Conflicts with other plugins       | Low      | Use unique autocmd group names               |
| User customization broken          | Low      | Provide `ui.wrap = "nvim"` option            |

## Rollback Plan

If issues are discovered post-deployment:

1. **Quick fix**: Revert to immediate `apply_wrap_config()` calls
2. **Alternative approach**: Use `WinEnter` autocmd with buffer filetype check
3. **Nuclear option**: Disable wrap configuration entirely, let users configure manually

## Success Criteria

1. ✅ Wrap settings only affect vibing buffers
2. ✅ Non-vibing buffers retain user Neovim settings
3. ✅ All three wrap modes work correctly (on/off/nvim)
4. ✅ No performance degradation
5. ✅ Manual tests pass
6. ✅ No user-facing breaking changes

## Timeline

- **Design**: 1 hour (complete)
- **Implementation**: 2-4 hours
- **Testing**: 1-2 hours
- **Documentation**: 0.5 hours
- **Total**: 4.5-7.5 hours

## Related Issues

- Issue #237: Wrap設定がvibingファイル以外にも適用される (this issue)

## References

- Neovim documentation: `:help ftplugin`, `:help autocmd`, `:help 'wrap'`
- vibing.nvim architecture: CLAUDE.md
- Config schema: `lua/vibing/config.lua`
