# Squad Naming System - Complete Guide

This guide provides an overview of the Squad Naming System implementation in vibing.nvim.

---

## 📚 Documentation Index

### For Decision Makers & Architects

**[ADR 003: Squad Naming System Phase 1](./adr/003-squad-naming-system-phase1.md)**

- Design decisions and rationale
- Architecture patterns and trade-offs
- Risk assessment and mitigation
- Future extensibility roadmap

**Duration**: 15-20 minutes read

---

### For Feature Users

**[Squad Naming System Feature Guide](./features/squad-naming-system.md)**

- Feature overview and capabilities
- How to use (examples)
- Current limitations (Phase 1)
- What's coming next (Phases 2-3)

**Duration**: 10-15 minutes read

---

### For Implementers & Contributors

**[Squad Naming System Specification](./specs/squad-naming-system.md)**

- Detailed Phase 1 specification
- Phase 2 and 3 planning
- Technical requirements
- Collision handling examples

**Duration**: 15-20 minutes read

---

## 🎯 Quick Start

### What Squad Naming Does

Squad Naming System automatically assigns NATO phonetic alphabet names (Alpha, Bravo, ..., Zulu) to chat buffers to identify which Claude agent is responding in multi-agent scenarios.

### Key Features

✅ **Automatic Assignment**

- No configuration needed
- Role detection: Commander (main branch) vs Squad (worktrees)

✅ **Persistent Identification**

- Squad name saved to chat file
- Remembered across sessions

✅ **Visual Indication**

- Response headers show squad: `## Assistant <Alpha>`
- Easy to identify who's talking

✅ **Backward Compatible**

- Legacy chats automatically upgraded
- Old header format still works

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────┐
│  Presentation Layer         │  Headers, UI, Buffer management
├─────────────────────────────┤
│  Infrastructure Layer       │  Registry, Persistence
├─────────────────────────────┤
│  Domain Layer               │  Business Logic
└─────────────────────────────┘
```

### Files Organization

```
lua/vibing/
├── domain/squad/                          (Business Logic)
│   ├── value_objects/
│   │   ├── squad_name.lua                (NATO validation)
│   │   └── squad_role.lua                (Commander/Squad detection)
│   ├── entity.lua                        (Squad aggregate)
│   ├── services/
│   │   ├── naming_service.lua            (Assignment logic)
│   │   └── collision_resolver.lua        (Collision handling)
│   └── tests/
│       └── integration_test.lua          (Tests)
│
├── infrastructure/squad/                  (Persistence & State)
│   ├── registry.lua                      (In-memory tracking)
│   └── persistence/
│       └── frontmatter_repository.lua    (YAML storage)
│
├── presentation/chat/
│   ├── modules/
│   │   ├── header_renderer.lua           (Header generation)
│   │   └── collision_notifier.lua        (Collision notices)
│   ├── buffer.lua                        (Modified: Squad integration)
│   ├── streaming_handler.lua             (Modified: Squad-aware headers)
│   └── view.lua                          (Modified: File attachment)
│
└── core/utils/
    └── timestamp.lua                     (Modified: Squad-aware parsing)

docs/
├── adr/
│   └── 003-squad-naming-system-phase1.md (Design decisions)
├── features/
│   └── squad-naming-system.md            (Feature guide)
├── specs/
│   └── squad-naming-system.md            (Specification)
└── SQUAD_NAMING_GUIDE.md                 (This file)
```

---

## 📖 Implementation Timeline

### Phase 1 ✅ COMPLETE

**Features**:

- [x] Automatic squad naming (NATO alphabet)
- [x] Commander vs Squad role detection
- [x] Response header format (`## Assistant <Alpha>`)
- [x] Persistent storage (frontmatter)
- [x] In-memory registry
- [x] Backward compatibility (auto-upgrade)

**Timeline**: January 15, 2025

**Code**: ~640 lines across 11 new files, 4 modified files

---

### Phase 2 ⏳ PLANNED

**Features**:

- [ ] Task-based squad assignment
- [ ] Persistent squad preferences
- [ ] Collision resolution strategies
- [ ] Squad status in UI

**Timeline**: TBD

---

### Phase 3 ⏳ PLANNED

**Features**:

- [ ] Mention syntax (`@Alpha`)
- [ ] Inter-squad messaging
- [ ] Message routing system
- [ ] Squad activity display

**Timeline**: TBD

---

## 🔧 Common Tasks

### As a User

**Q: How do I see which squad is responding?**
A: Look at the response header. It shows `## Assistant <Alpha>` for Squad Alpha, `## Assistant <Commander>` for Commander.

**Q: Can I change a squad's name?**
A: Not in Phase 1. Squad names are auto-assigned based on location. Phase 2 will add preferences.

**Q: What happens if all 26 squad names are in use?**
A: The system will error. This is unlikely in practice (would need 26+ concurrent chats).

---

### As a Contributor

**Q: How do I add a new squad feature?**

1. Read [ADR 003](./adr/003-squad-naming-system-phase1.md) for architecture
2. Identify which layer needs changes (Domain/Infrastructure/Presentation)
3. Modify the appropriate file(s)
4. Add tests in `lua/vibing/domain/squad/tests/`
5. Verify with `npm run build`

**Q: How do I test squad naming?**

Run the integration test:

```bash
nvim --headless -c "luafile lua/vibing/domain/squad/tests/integration_test.lua" -c "qa!"
```

**Q: What's the best way to extend this?**

Follow the existing 3-layer architecture:

1. Add domain logic (value objects, services)
2. Add infrastructure if persistence needed
3. Add presentation for UI

---

## 📊 Implementation Statistics

### Code Metrics

| Metric               | Value                   |
| -------------------- | ----------------------- |
| Domain Layer         | 351 lines               |
| Infrastructure Layer | 148 lines               |
| Presentation Layer   | 141 lines               |
| Tests                | 182 lines               |
| **Total New Code**   | **~640 lines**          |
| **Modified Code**    | **~70 lines (4 files)** |

### File Count

| Category                 | Count        |
| ------------------------ | ------------ |
| New Domain Files         | 5            |
| New Infrastructure Files | 2            |
| New Presentation Files   | 2            |
| New Test Files           | 1            |
| Modified Files           | 4            |
| **Total Affected**       | **14 files** |

### Build Status

- ✅ `npm run build` passes
- ✅ TypeScript errors: 0
- ✅ Lua syntax: Valid
- ✅ dist/bin/agent-wrapper.js: Generated

---

## 🎓 Learning Path

### For Beginners

1. **Start**: [Feature Guide](./features/squad-naming-system.md)
   - Understand what Squad Naming does
   - See real examples

2. **Then**: Architecture Overview (above)
   - Get big picture
   - Understand layers

3. **Finally**: Implementation files
   - Read the code
   - Follow the patterns

---

### For Advanced Readers

1. **Read**: [ADR 003](./adr/003-squad-naming-system-phase1.md)
   - Understand design decisions
   - See trade-offs considered

2. **Study**: Domain layer code
   - Value objects & validation
   - Entity aggregates
   - Business services

3. **Explore**: Infrastructure & Presentation
   - How layers interact
   - Integration patterns

4. **Plan**: Phase 2/3 extensions
   - What needs to change
   - Where to add code

---

## ❓ FAQ

**Q: Why NATO alphabet and not just "Agent 1, Agent 2"?**
A: NATO names are more memorable and distinctive in conversation. Also, they're fun!

**Q: What if I'm not on a worktree?**
A: You're the Commander. Simple as that.

**Q: Can squads have custom names?**
A: Phase 1 uses auto-assignment. Phase 2 will add preferences.

**Q: How are squad names stored?**
A: In the chat file's frontmatter YAML as `squad_name: Alpha`.

**Q: What if the registry gets corrupted?**
A: It won't - it's just in-memory during the session. Shut down and restart.

**Q: Is this backward compatible?**
A: Yes! Old chats work fine. Squad names are assigned automatically on first open.

---

## 🚀 Next Steps

### For Users

- Try creating a new chat in a worktree: You'll see `## Assistant <Alpha>`
- Try creating one on main: You'll see `## Assistant <Commander>`
- Open an old chat: It gets automatically assigned a squad name

### For Contributors

- Read ADR 003 for full context
- Check out the domain layer code (clean patterns!)
- Plan Phase 2 extensions

### For Maintainers

- Monitor squad naming usage patterns
- Gather feedback from users
- Plan Phase 2 timeline

---

## 📞 Questions?

- **Feature questions?** → See [Feature Guide](./features/squad-naming-system.md)
- **Design questions?** → See [ADR 003](./adr/003-squad-naming-system-phase1.md)
- **Technical questions?** → See [Specification](./specs/squad-naming-system.md)

---

**Document Version**: 1.0

**Last Updated**: 2025-01-15

**Status**: Approved & Implemented
