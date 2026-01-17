# Squad Naming System Implementation

## Overview

Squad Naming System is a multi-agent coordination feature for vibing.nvim that enables a Commander Claude (on main branch) to coordinate with Squad Claudes (on worktrees) through automatic squad naming using NATO phonetic alphabet.

**Phase 1 Status**: ✅ **Complete** - Foundation layer implemented

- Automatic squad name assignment (Alpha, Bravo, ..., Zulu, Commander)
- Collision detection and handling
- Header format changes (`## Assistant <Alpha>`)
- Persistent storage in chat frontmatter
- Registry-based tracking of active squads

## Architecture

### Domain Layer

**Values Objects:**

- `SquadName`: Immutable NATO alphabet name + Commander validation
- `SquadRole`: Commander vs Squad role determination from cwd

**Entity:**

- `Squad`: Aggregate root combining name + role + bufnr + metadata
- Business logic: collision tracking, frontmatter conversion

**Services:**

- `NamingService`: Squad name assignment business logic
- `CollisionResolver`: Collision detection and resolution (Phase 2 use)

### Infrastructure Layer

- `Registry`: In-memory tracking of active squads (squad_name → bufnr)
- `FrontmatterRepository`: YAML persistence layer

### Presentation Layer

- `HeaderRenderer`: Generates squad-aware headers (`## Assistant <Alpha>`)
- `CollisionNotifier`: Inserts collision notices in chat buffer
- `StreamingHandler`: Modified to use squad names from buffer-local variables
- `ChatBuffer`: Integrated squad assignment on creation/loading
- `ChatView`: Squad handling for file attachment
- `timestamp`: Extended to parse squad-aware headers

## Implementation Details

### New Chat Creation Flow

```
ChatController.handle_open()
  ↓
use_case.create_new() → ChatSession
  ↓
view.render(session)
  ↓
ChatBuffer:new() + :open()
  ├─ _create_buffer()
  ├─ _create_window()
  ├─ assign_squad_name()  ← NEW
  │  ├─ NamingService.assign_squad_name()
  │  ├─ SquadRole.determine_from_cwd()
  │  │  ├─ `.worktrees/` → Squad (Alpha, Bravo, ...)
  │  │  └─ else → Commander
  │  ├─ Registry.register(squad_name, bufnr)
  │  └─ FrontmatterRepository.save(squad)
  └─ Renderer.init_content()
```

### Assistant Response Header Generation

```
StreamingHandler.start_response(buf)
  ↓
Get squad_name from vim.b[buf].vibing_squad_name
  ↓
HeaderRenderer.render_assistant_header(squad_name)
  ├─ If squad_name exists: "## Assistant <Alpha>"
  └─ Else: "## Assistant"
```

### Existing Chat Loading

```
ChatBuffer:load_from_file(file_path)
  ├─ FileManager.load_from_file()
  └─ parse_frontmatter()
     ├─ If squad_name in frontmatter:
     │  ├─ vim.b[bufnr].vibing_squad_name = squad_name
     │  └─ Registry.register(squad_name, bufnr)
     └─ Else (legacy file):
        └─ assign_squad_name()  ← Auto-upgrade
```

### Cleanup on Buffer Close

```
ChatBuffer:close()
  ├─ adapter:cancel()
  ├─ Registry.unregister(self.buf)  ← NEW
  └─ Close/replace window
```

## Files Created

**Domain:**

- `lua/vibing/domain/squad/value_objects/squad_name.lua`
- `lua/vibing/domain/squad/value_objects/squad_role.lua`
- `lua/vibing/domain/squad/entity.lua`
- `lua/vibing/domain/squad/services/naming_service.lua`
- `lua/vibing/domain/squad/services/collision_resolver.lua`
- `lua/vibing/domain/squad/tests/integration_test.lua`

**Infrastructure:**

- `lua/vibing/infrastructure/squad/registry.lua`
- `lua/vibing/infrastructure/squad/persistence/frontmatter_repository.lua`

**Presentation:**

- `lua/vibing/presentation/chat/modules/header_renderer.lua`
- `lua/vibing/presentation/chat/modules/collision_notifier.lua`

## Files Modified

- `lua/vibing/presentation/chat/buffer.lua` - Added `assign_squad_name()`, integrated squad handling
- `lua/vibing/presentation/chat/modules/streaming_handler.lua` - Uses `vim.b[buf].vibing_squad_name`
- `lua/vibing/presentation/chat/view.lua` - Added squad handling in `attach_to_buffer()`
- `lua/vibing/core/utils/timestamp.lua` - Extended `extract_role()` for squad-aware headers

## Features

### ✅ Phase 1 (Current)

- [x] Automatic squad naming (NATO alphabet)
- [x] Commander vs Squad role detection via cwd (`.worktrees/` path)
- [x] Squad name assignment on chat creation
- [x] Squad name persistence in frontmatter (`squad_name` field)
- [x] Response header format: `## Assistant <Alpha>`
- [x] In-memory registry of active squads
- [x] Collision notification when squad name unavailable
- [x] Auto-upgrade of legacy chat files (Squad name assignment)
- [x] Buffer cleanup on close (Registry.unregister)

### ⏳ Phase 2 (Future)

- [ ] Task references: Store squad assignments per task (use `task_ref`)
- [ ] Persistent squad preferences: Remember assignments across sessions
- [ ] Collision resolution: Automatic/fallback squad name assignment

### ⏳ Phase 3 (Future)

- [ ] Mention syntax: `@Alpha` or `@Bravo` to reference squads in messages
- [ ] Worktree status display: Show active squads in UI
- [ ] Inter-squad messaging: Route messages between Commander and Squads

### ⏳ Phase 4+ (Future)

- [ ] Squad task routing
- [ ] Multi-squad workflows
- [ ] Squad performance tracking

## Testing

Integration test file created: `lua/vibing/domain/squad/tests/integration_test.lua`

Tests cover:

- SquadName validation and creation
- SquadRole determination
- Squad Entity creation and conversion
- Frontmatter serialization/deserialization
- Registry registration/unregistration
- NamingService assignment
- NATO alphabet ordering

## Technical Notes

### Why Clean Architecture?

vibing.nvim already uses a layered architecture (domain/application/presentation/infrastructure), so the Squad System naturally fits this pattern:

- **Domain**: Core business logic (naming rules, role determination)
- **Infrastructure**: Persistence and state management (registry, frontmatter)
- **Presentation**: UI integration (headers, notifications)

This separation ensures the feature is:

- **Testable**: Domain logic can be tested independently
- **Maintainable**: Clear boundaries between concerns
- **Extensible**: Phase 2/3 features can be added without restructuring

### Backward Compatibility

- Existing chat files without `squad_name` are automatically assigned a name on first load
- Existing header parsing (`## Assistant`) still works
- New headers (`## Assistant <Alpha>`) are recognized alongside legacy format

### Performance

- Registry is in-memory only (not persisted across sessions)
- No additional I/O beyond existing frontmatter operations
- Squad name assignment is O(1) average case

## Future Phases

See `docs/specs/squad-naming-system.md` for detailed Phase 2/3 specifications.

Phase 2 will add mention syntax and inter-squad communication UI.
Phase 3 will implement full message routing between squads.
