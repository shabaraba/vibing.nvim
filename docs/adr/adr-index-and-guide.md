# Architecture Decision Records (ADR)

This directory contains Architecture Decision Records for vibing.nvim.

## What is an ADR?

An Architecture Decision Record (ADR) documents important architectural decisions made during the development of the project, including:

- The context and problem being addressed
- The decision that was made
- The rationale behind the decision
- Consequences and trade-offs
- Alternatives that were considered
- References to related discussions, issues, or commits

ADRs help future maintainers understand WHY certain design choices were made, especially when those choices involve non-obvious constraints or trade-offs.

## Index

### ADR 001: Permissions Ask Implementation and Agent SDK Constraints

**Status:** Accepted
**Date:** 2025-01-26

Documents the implementation of the three-tier permission system (deny/ask/allow) and the critical workarounds required for Claude Agent SDK constraints, particularly:

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
