# ADR 003: Squad Naming System - Phase 1 Implementation

**Date**: 2025-01-15

**Status**: ✅ **Accepted & Implemented**

**Context**: Issue #305 - Multi-agent coordination for vibing.nvim

**Participants**: Claude Code (AI assistant)

---

## 1. Problem Statement

### The Challenge

When multiple Claude instances work together in vibing.nvim (one on main branch as "Commander", others on worktrees as "Squads"), there's a need to:

1. **Identify which Claude is responding** - Distinguish response from Commander vs Squad members
2. **Track active agents** - Know which squads are currently active
3. **Persistent identification** - Remember squad assignments across chat sessions
4. **Auto-discovery** - Automatically determine role (Commander vs Squad) based on environment

### Why This Matters

- **Debugging**: Easy to see which agent is responding in multi-agent scenarios
- **Future messaging**: Foundation for inter-squad communication (Phase 3)
- **Task routing**: Enable task assignment to specific squads (Phase 2)
- **User experience**: Clear visual indication of who's talking

---

## 2. Design Decisions

### 2.1 Squad Naming Strategy: NATO Phonetic Alphabet

**Decision**: Use NATO phonetic alphabet (Alpha, Bravo, ..., Zulu) + special "Commander" name

**Rationale**:

- ✅ Exactly 26 names = 26 possible squads (reasonable limit)
- ✅ Phonetically distinct, easy to distinguish
- ✅ Familiar to technical users
- ✅ Maps well to common naming conventions
- ✅ Deterministic ordering for stable assignments

**Alternative Considered**:

- Numbers (1-26): Less memorable, more confusing in conversation
- Greek letters (alpha-omega): Only 24 names, less familiar
- Colors: Too ambiguous, limited distinctiveness
- Random IDs: No natural ordering, hard to remember

**Decision**: NATO alphabet wins on distinctiveness + completeness.

---

### 2.2 Role Detection: Path-Based (`.worktrees/`)

**Decision**: Determine Commander vs Squad by checking if `.worktrees/` is in cwd path

**Rationale**:

- ✅ Matches vibing.nvim's existing worktree patterns
- ✅ Automatic, no configuration needed
- ✅ Reliable for git-based projects
- ✅ Simple regex pattern matching

**Detection Logic**:

```lua
if cwd:match("/.worktrees/") then
  role = SQUAD
else
  role = COMMANDER
end
```

**Alternative Considered**:

- Environment variables: Requires manual setup
- Git branch detection: Complex, not reliable
- User configuration: Extra config burden
- Filesystem markers: More complex

**Decision**: Path detection is simple and automatic.

---

### 2.3 Persistence: Frontmatter YAML Field

**Decision**: Store squad name in chat file frontmatter as `squad_name` field

**Example**:

```yaml
---
vibing.nvim: true
session_id: abc123def456
created_at: 2025-01-15T14:30:00
squad_name: Alpha          ← NEW
task_type: squad           ← NEW
mode: code
model: sonnet
---
```

**Rationale**:

- ✅ Survives across sessions automatically
- ✅ Human-readable format
- ✅ Backward compatible (optional field)
- ✅ Integrates with existing frontmatter system
- ✅ No additional database/file needed

**Alternative Considered**:

- JSON sidecar file: Extra file to manage
- SQL database: Overkill, dependency overhead
- Environment persistence: Lost on session restart
- Filename encoding: Makes filenames ugly

**Decision**: Frontmatter YAML is consistent with existing patterns.

---

### 2.4 Architecture: Domain-Driven Design with Clean Architecture

**Decision**: Implement 3-layer architecture (Domain → Infrastructure → Presentation)

```
┌──────────────────────────┐
│  Presentation Layer      │  UI integration (headers, buffer mgmt)
├──────────────────────────┤
│  Infrastructure Layer    │  Persistence (registry, frontmatter)
├──────────────────────────┤
│  Domain Layer            │  Business logic (naming, roles)
└──────────────────────────┘
```

**Rationale**:

- ✅ vibing.nvim already uses this pattern (existing code follows DDD)
- ✅ Testable: Domain logic independent of Lua/Neovim
- ✅ Maintainable: Clear separation of concerns
- ✅ Extensible: Phase 2/3 features plug in naturally
- ✅ Enterprise-grade quality

**Key Patterns**:

- **Values Objects**: `SquadName`, `SquadRole` (immutable, validated)
- **Entity**: `Squad` aggregate root
- **Services**: `NamingService` (business workflows)
- **Repository**: `FrontmatterRepository` (persistence abstraction)
- **Registry**: In-memory active squad tracking

**Alternative Considered**:

- Monolithic module: Simple but not maintainable at scale
- Flat structure: Works for simple features, hard to extend
- Microservices-style: Overkill for Neovim plugin
- Procedural scripting: Hard to test, tightly coupled

**Decision**: Clean Architecture matches existing patterns & ensures quality.

---

### 2.5 Header Format: Angle Brackets `<Squad>`

**Decision**: Use format `## Assistant <Alpha>` for squad-aware headers

**Examples**:

```markdown
## Assistant <Alpha> ← Squad response

## Assistant <Commander> ← Commander response

## Assistant ← Legacy format (backward compatible)
```

**Rationale**:

- ✅ Clearly distinguishes squad from regular assistant
- ✅ Angle brackets are syntactically neutral
- ✅ Parseable with simple regex: `^## Assistant <[%w%-]+>`
- ✅ Matches existing header conventions
- ✅ Backward compatible (old `## Assistant` still works)

**Alternative Considered**:

- Brackets `[Alpha]`: Markdown link-like, confusing
- Parentheses `(Alpha)`: Used for timestamps elsewhere
- Prefix `Alpha: ## Assistant`: Breaks header pattern
- HTML comment `<!-- Alpha -->`: Less readable

**Decision**: Angle brackets are clean and unambiguous.

---

### 2.6 State Management: In-Memory Registry (Not Persisted)

**Decision**: Track active squads in memory only, NOT across sessions

```lua
Registry._active_squads = {
  ["Alpha"] = bufnr_1,
  ["Bravo"] = bufnr_2,
}
```

**Rationale**:

- ✅ Simple, no extra persistence layer
- ✅ Squad assignments are ephemeral (session-scoped)
- ✅ Automatic cleanup when buffer closes
- ✅ Prevents stale data (dead buffers removed by is_available)
- ✅ No cross-session conflicts

**When Squads Reconnect**:

1. Old chat file has `squad_name: Alpha` in frontmatter
2. When reopened → reads from frontmatter, re-registers in Registry
3. New session has same name, auto-continues

**Alternative Considered**:

- Persist assignments to disk: Overcomplicated
- Cross-session tracking: Breaks when worktrees deleted
- Sticky assignments: Hard to manage cleanup

**Decision**: Session-scoped in-memory registry is appropriate.

---

### 2.7 Backward Compatibility: Auto-Upgrade Legacy Files

**Decision**: When opening chat without `squad_name`, auto-assign one

**Flow**:

```
Old chat file (no squad_name)
         ↓
ChatBuffer:load_from_file()
         ↓
if not frontmatter.squad_name then
  self:assign_squad_name()  ← Auto-assign
end
         ↓
Chat continues with new squad name
```

**Rationale**:

- ✅ No manual user action needed
- ✅ All chats work transparently
- ✅ Ensures consistent behavior
- ✅ Can't break existing workflows

**Risk Mitigation**:

- Squad assignment is idempotent (same chat, same cwd = same role)
- Legacy chats are not modified until first open (safe)
- First-time assignment is logged/observable

**Decision**: Auto-upgrade ensures seamless transition.

---

## 3. Implementation Strategy

### 3.1 Layered Implementation (Bottom-Up)

**Phase A: Domain Layer** (Pure Business Logic)

```
value_objects/squad_name.lua     (NATO validation)
value_objects/squad_role.lua     (Commander/Squad detection)
entity.lua                       (Squad aggregate)
services/naming_service.lua      (Assignment logic)
services/collision_resolver.lua  (Conflict handling)
```

**Phase B: Infrastructure Layer** (Persistence)

```
registry.lua                     (In-memory tracking)
persistence/frontmatter_repo.lua (YAML persistence)
```

**Phase C: Presentation Layer** (UI Integration)

```
modules/header_renderer.lua      (Header generation)
modules/collision_notifier.lua   (Collision notices)
buffer.lua                       (ChatBuffer integration)
streaming_handler.lua            (Response headers)
view.lua                         (File attachment)
core/utils/timestamp.lua         (Header parsing)
```

**Benefits**:

- ✅ Each layer testable independently
- ✅ Dependencies flow cleanly downward
- ✅ Can verify correctness at each step

---

### 3.2 Minimal Surface Area for Existing Code

**Modified Files** (4 total):

```
buffer.lua               (+50 lines new method)
streaming_handler.lua    (+3 lines modification)
view.lua                 (+10 lines new method)
timestamp.lua            (+5 lines new pattern)
```

**Design Goal**: Minimal changes to existing code

- ✅ Reduces risk of breaking changes
- ✅ Makes feature easy to review
- ✅ Keeps codebase readable
- ✅ Easy to revert if needed

---

### 3.3 Error Handling Strategy

**Validation Points**:

1. **Squad Name Validation**:

   ```lua
   if not SquadName.is_valid(name) then
     error("Invalid squad name: " .. name)
   end
   ```

2. **Role Determination**:
   - Always returns either COMMANDER or SQUAD
   - No "unknown" state

3. **Registry Collisions**:
   - Auto-cleanup stale buffers
   - Return next available if current is taken
   - Error if all 26 names exhausted (rare)

4. **Frontmatter Persistence**:
   - Try/catch handled by FrontmatterRepository
   - Graceful fallback if serialization fails

---

## 4. Trade-offs & Justifications

### 4.1 In-Memory vs Persistent Registry

| Aspect            | In-Memory    | Persistent        |
| ----------------- | ------------ | ----------------- |
| Complexity        | ✅ Simple    | ❌ Complex        |
| Cross-session?    | ❌ No        | ✅ Yes            |
| Need for Phase 1? | ✅ Yes       | ❌ Not yet        |
| Maintenance?      | ✅ Automatic | ❌ Manual cleanup |

**Chosen**: In-memory (sufficient for Phase 1, can upgrade later)

---

### 4.2 Path-Based vs Config-Based Role Detection

| Aspect       | Path-Based    | Config        |
| ------------ | ------------- | ------------- |
| Automation   | ✅ Automatic  | ❌ Manual     |
| Setup Burden | ✅ None       | ❌ Required   |
| Reliability  | ✅ Filesystem | ⚠️ User error |
| Flexibility  | ⚠️ Fixed      | ✅ Flexible   |

**Chosen**: Path-based (zero configuration)

---

### 4.3 NATO Alphabet vs Other Names

| Scheme  | Count | Distinctiveness | Memorability |
| ------- | ----- | --------------- | ------------ |
| NATO    | 26    | ✅✅✅          | ✅✅✅       |
| Numbers | ∞     | ⚠️              | ❌           |
| Greek   | 24    | ✅              | ⚠️           |
| Colors  | ~10   | ✅              | ✅           |

**Chosen**: NATO (optimal combination)

---

## 5. Testing Strategy

### 5.1 Unit Test Coverage

Created: `lua/vibing/domain/squad/tests/integration_test.lua`

Tests:

- ✅ SquadName validation (all 26 NATO names + Commander)
- ✅ SquadRole determination (cwd-based)
- ✅ Squad Entity creation & conversion
- ✅ Frontmatter serialization/deserialization
- ✅ Registry registration/cleanup
- ✅ NamingService assignment logic

### 5.2 Integration Points

Manually verified:

- ✅ New chat creation flow
- ✅ Existing chat loading flow
- ✅ File attachment flow
- ✅ Buffer cleanup flow
- ✅ Header generation flow

### 5.3 Build Verification

- ✅ `npm run build` succeeds
- ✅ No TypeScript errors
- ✅ dist/bin/agent-wrapper.js generated

---

## 6. Risk Assessment

### Low Risk ✅

**Why?**

- Domain logic is completely isolated
- Infrastructure changes are additive (new Registry)
- Presentation changes are minimal (4 small edits)
- No modifications to critical paths
- Backward compatible throughout

### Mitigated Risks

| Risk                    | Mitigation                                 |
| ----------------------- | ------------------------------------------ |
| Frontmatter corruption  | Values are validated before save           |
| Buffer memory leaks     | Explicit Registry.unregister() on close    |
| Naming collisions       | Registry checks availability before assign |
| Cross-session conflicts | In-memory registry auto-resets per session |

---

## 7. Future Extensibility

### Phase 2: Task-Based Squad Tracking

**Will need**:

- Task reference storage (task_ref field)
- Persistent squad preferences
- Collision resolution strategies

**Changes needed**:

- Extend NamingService with task-aware logic
- Add PersistentSquadRegistry (upgrade from in-memory)
- New UI for squad preferences

**Can reuse**:

- All current domain objects
- HeaderRenderer, CollisionNotifier
- Frontmatter infrastructure

---

### Phase 3: Inter-Squad Messaging

**Will need**:

- Message routing system
- Mention syntax parser (@Alpha)
- Squad-to-squad communication

**Changes needed**:

- New domain: Message, Route, Dispatcher services
- New infrastructure: MessageQueue, RoutingTable
- New presentation: MentionRenderer, SquadStatusUI

**Can reuse**:

- All current architecture
- Registry and Role determination
- Header rendering system

---

## 8. Conclusion

### Summary

Squad Naming System Phase 1 provides a **solid foundation** for multi-agent coordination:

- ✅ Automatic, zero-configuration squad naming
- ✅ Persistent identification across sessions
- ✅ Clean architecture for future extensions
- ✅ Minimal risk, minimal code changes
- ✅ Enterprise-grade quality

### Key Metrics

- **Code Added**: ~640 lines across 11 files
- **Code Modified**: 4 files with ~70 lines total changes
- **Architecture**: 3-layer DDD with 5 domain services
- **Test Coverage**: Integration tests for core logic
- **Build Status**: ✅ Passing

### Next Steps

1. **Phase 2** (Future): Task-based squad assignment
2. **Phase 3** (Future): Inter-squad messaging
3. **Monitoring**: Track squad usage patterns
4. **Feedback**: Gather user experience insights

---

## References

- Issue #305: Squad Naming System
- docs/specs/squad-naming-system.md (Specification)
- docs/features/squad-naming-system.md (Feature Guide)
- lua/vibing/domain/squad/ (Implementation)
