# Feature Specifications

This directory contains detailed specifications for vibing.nvim features.

## What is a Specification?

A Feature Specification (SPEC) documents WHAT a feature does and HOW to use it, including:

- User interface (commands, keymaps, UI elements)
- Expected behavior and edge cases
- Implementation details and data flow
- Test coverage requirements
- Known limitations and workarounds
- Usage examples and best practices

While ADRs document WHY decisions were made, SPECs document WHAT the final implementation looks like.

## Index

### Permissions Ask Specification

**Status:** Implemented
**Version:** 1.0.0 (PR #223)

Complete specification for the three-tier permission system (deny/ask/allow), including:

- Slash commands (`/ask`, `/allow`, `/deny`)
- Interactive Permission Builder UI
- Granular pattern matching syntax
- Permission evaluation flow
- Integration with Agent SDK
- Workarounds for SDK limitations

**Key Files:**

- Spec: [permissions-ask-specification.md](./permissions-ask-specification.md)
- ADR: [../adr/004-permissions-ask-implementation.md](../adr/004-permissions-ask-implementation.md)
- Implementation: `bin/agent-wrapper.mjs`, `lua/vibing/chat/handlers/ask.lua`
- Tests: `tests/permission-logic.test.mjs`, `tests/chat_init_spec.lua`

**Quick Start:**

```vim
/ask Bash              " Add Bash to ask list
/ask Bash(npm:*)       " Require approval only for npm commands
/allow Bash(git:*)     " Auto-approve git commands (overrides ask)
```

---

## Creating a New Specification

Use this template when creating a new specification:

```markdown
# [Feature Name] Specification

## Overview

Brief description of the feature and its purpose.

## User Interface

### Commands

List all user-facing commands with syntax and examples.

### Keymaps

Document any keybindings.

### UI Elements

Describe interactive UI components.

## Behavior

### Normal Flow

Step-by-step description of typical usage.

### Edge Cases

Document unusual scenarios and expected behavior.

### Error Handling

How errors are reported and recovered from.

## Implementation Details

### Architecture

High-level design and component interaction.

### Data Flow

How data moves through the system.

### Integration Points

Where this feature interacts with other components.

## Test Coverage

### Unit Tests

List test files and key test cases.

### Integration Tests

End-to-end scenarios.

### Manual Test Scenarios

Tests that require human interaction.

## Limitations and Known Issues

Document any constraints or bugs.

## Future Enhancements

Ideas for improvement or expansion.

## References

Links to related ADRs, issues, code, etc.
```

## Spec Workflow

1. **When to Create a Spec:**
   - Implementing a new user-facing feature
   - Adding significant new functionality to existing feature
   - Feature is complex enough to need detailed documentation

2. **Review Process:**
   - Spec should be created BEFORE or DURING implementation
   - Updated as implementation details are finalized
   - Reviewed alongside feature PR

3. **Updating Specs:**
   - Specs are living documents - update when behavior changes
   - Keep version history in spec header
   - Note breaking changes prominently

## Related Documentation

- [ADRs](../adr/) - Architectural decisions and their rationale
- [API Documentation](../../README.md) - High-level API overview
- [CLAUDE.md](../../CLAUDE.md) - Development guidelines
- [Tests](../../tests/) - Test files referenced in specs
