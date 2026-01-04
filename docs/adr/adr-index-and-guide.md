# Architecture Decision Records (ADR)

This directory contains Architecture Decision Records for vibing.nvim.

## What is an ADR?

An Architecture Decision Record (ADR) documents important architectural decisions made
during the development of the project, including:

- The context and problem being addressed
- The decision that was made
- The rationale behind the decision
- Consequences and trade-offs
- Alternatives that were considered
- References to related discussions, issues, or commits

ADRs help future maintainers understand WHY certain design choices were made,
especially when those choices involve non-obvious constraints or trade-offs.

## Index

### ADR 001: Permissions Ask Implementation and Agent SDK Constraints

**Status:** Accepted
**Date:** 2025-01-26

Documents the implementation of the three-tier permission system (deny/ask/allow) and the
critical workarounds required for Claude Agent SDK constraints, particularly:

- Why `permissionMode` is intentionally left undefined
- How Issue #29 (resume session bypass) is mitigated
- Why custom permission logic is implemented in `canUseTool` instead of using SDK features

**Key Files:**

- ADR: [001-permissions-ask-implementation.md](./001-permissions-ask-implementation.md)
- Spec: [../specs/permissions-ask-specification.md](../specs/permissions-ask-specification.md)
- Implementation: `bin/agent-wrapper.mjs` (lines 559-700)
- Tests: `tests/permission-logic.test.mjs`

**Related Issues:**

- [Issue #174](https://github.com/shabaraba/vibing.nvim/issues/174) - Add "ask" permission tier
- [Agent SDK Issue #29](https://github.com/anthropics/claude-agent-sdk-typescript/issues/29) - Resume session bypass

---

### ADR 002: Concurrent Execution Support

**Status:** Accepted
**Date:** 2024-12-29

Documents the implementation of concurrent execution support for multiple chat windows and inline actions, including:

- Handle-based concurrent request management
- Session lifecycle management and cleanup
- Inline action queuing system
- Error handling improvements

**Key Files:**

- ADR: [002-concurrent-execution-support.md](./002-concurrent-execution-support.md)
- Implementation: `lua/vibing/adapters/agent_sdk.lua`
- Queue: `lua/vibing/actions/inline.lua`
- Session sync: `lua/vibing/actions/chat.lua`
- Tests: `tests/agent_sdk_spec.lua`

**Related Issues:**

- [PR #239](https://github.com/shabaraba/vibing.nvim/pull/239) - Agent singleton check

---

### ADR 003: Agent SDK vs CLI Architecture Decision

**Status:** Accepted
**Date:** 2026-01-04

Comprehensive comparison between Claude Agent SDK (`query()` API) and Claude CLI
(`claude -p`) for vibing.nvim's architecture. Documents the decision to continue using
Agent SDK based on:

- Custom permission control requirements (`canUseTool` callback)
- Dependency management reliability (npm vs global binary)
- Performance considerations (in-process vs subprocess)
- Known issues comparison (Agent SDK Issue #29 vs CLI bugs)
- vibing.nvim-specific requirements (granular patterns, MCP control, Issue #29 workarounds)

**Key Files:**

- ADR: [003-agent-sdk-vs-cli-comparison.md](./003-agent-sdk-vs-cli-comparison.md)
- Implementation: `bin/agent-wrapper.mjs` (full implementation)
- Dependencies: `package.json` (line 44: `@anthropic-ai/claude-agent-sdk: ^0.1.76`)

**Related ADRs:**

- [ADR 001](#adr-001-permissions-ask-implementation-and-agent-sdk-constraints) - Permission system constraints
- [ADR 002](#adr-002-concurrent-execution-support) - Concurrent execution architecture

**Related Issues:**

- [Agent SDK Issue #29](https://github.com/anthropics/claude-agent-sdk-typescript/issues/29) - Resume session bypass
- [CLI Issue #913](https://github.com/eyaltoledano/claude-task-master/issues/913) - JSON Truncation
- [CLI Issue #1920](https://github.com/anthropics/claude-code/issues/1920) - Missing Final Result Event
- [CLI Issue #3187](https://github.com/anthropics/claude-code/issues/3187) - Stream Input Hang
- [CLI Issue #3188](https://github.com/anthropics/claude-code/issues/3188) - Resume Bug
- [CLI Issue #563](https://github.com/anthropics/claude-code/issues/563) - AllowedTools Reliability

---

## Creating a New ADR

Use this template when creating a new ADR:

```markdown
# ADR XXX: [Title]

## Status

[Proposed | Accepted | Deprecated | Superseded by ADR-YYY]

## Date

YYYY-MM-DD

## Context

What is the issue we're trying to solve? What are the constraints?

## Decision

What decision did we make?

## Consequences

### Positive

- List of positive outcomes

### Negative

- List of negative outcomes or trade-offs

### Risks and Mitigations

- What could go wrong and how do we handle it?

## Alternatives Considered

### Alternative 1: [Name]

- Why it was considered
- Why it was rejected

## References

- Related issues, PRs, or external resources
- Links to implementation code
- Chat history or discussion threads

## Notes

Any additional context that future maintainers should know.
```

## ADR Workflow

1. **When to Create an ADR:**
   - Making a significant architectural decision
   - Choosing between multiple design approaches
   - Implementing a workaround for external constraints
   - Deviating from standard practices or conventions

2. **Review Process:**
   - Create ADR as part of PR implementing the decision
   - ADR should be reviewed alongside code changes
   - Once merged, ADR status changes to "Accepted"

3. **Updating ADRs:**
   - ADRs are historical records - don't modify after acceptance
   - If a decision is reversed, create a new ADR that supersedes the old one
   - If new information is discovered, add to "Notes" section with date

## Related Documentation

- [Specifications](../specs/) - Detailed implementation specs for features
- [CLAUDE.md](../../CLAUDE.md) - Development guidelines and project conventions
- [README.md](../../README.md) - Project overview and getting started guide
