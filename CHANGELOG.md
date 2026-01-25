# Changelog

## 1.25.0 (2026-01-25)

## What's Changed
* feat: add daily summary generation commands by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/349
* feat: add configurable tool markers with Task-specific defaults by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/348
* feat: add :VibingSummarize command to insert summary into chat buffer by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/346
* fix: isolate mote snapshots per worktree to prevent cross-worktree diff pollution by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/347
* docs: add daily_summary and tool_markers configuration examples by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/352
* feat: add pattern matching support for tool_markers configuration by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/353
* feat: improve daily summary with project grouping and external prompts by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/354


**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.24.1...v1.25.0

## 1.24.1 (2026-01-23)

## What's Changed

- fix: improve tool result display and permissions_ask priority by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/340

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.24.0...v1.24.1

## 1.24.0 (2026-01-23)

## What's Changed

- feat: externalize system prompts to MD files with Agent SDK preset by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/336
- fix: correct commit message to prevent unwanted major version bump by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/338

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.23.0...v1.24.0

## 1.23.0 (2026-01-22)

## What's Changed

- feat: add completion engine for slash commands, file paths, and agents by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/334

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.22.0...v1.23.0

## 1.22.0 (2026-01-21)

## What's Changed

- refactor: migrate from git-based patch to mote-only diff system by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/330
- feat: display subagent type in Task tool output by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/332

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.21.1...v1.22.0

## 1.21.1 (2026-01-20)

## What's Changed

- refactor: simplify session validation by delegating to SDK by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/327

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.21.0...v1.21.1

## 1.21.0 (2026-01-20)

## What's Changed

- docs: replace claude.md and e2e-tests by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/319
- feat: Add mote integration for fine-grained snapshot diffing by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/323
- feat: load installed plugins dynamically via SDK plugins option by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/324
- fix: remove self-development assumption and simplify system prompt by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/321
- refactor: improve code clarity and maintainability across core modules by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/325
- fix: allow slash in branch names for feature/xxx pattern by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/326

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.20.0...v1.21.0

## 1.20.0 (2026-01-17)

## What's Changed

- chore(main): release 1.19.0 by @github-actions[bot] in https://github.com/shabaraba/vibing.nvim/pull/302
- feat: Prioritize vibing.nvim commands in Claude Agent SDK by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/307
- feat: implement programmatic message sending to chat buffers (#304) by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/309
- feat: implement Squad Naming System Phase 1 for multi-agent coordination by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/310
- revert: Squad Naming System Phase 1 by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/315

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.19.0...v1.20.0

## 1.19.0 (2026-01-14)

## What's Changed

- feat: add configurable Node.js executable support by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/289
- docs: enhance README with architecture comparison and FAQ by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/282
- docs: add race condition analysis for patch storage issue by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/283
- docs: add self-development loop ADR and design spec by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/290
- feat: add top/bottom/back position options for VibingChat by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/294
- feat: add session validation and recovery for worktree chat sessions by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/296
- refactor: comprehensive codebase modularization and cleanup by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/295
- fix: Support simultaneous main/worktree sessions + staging warnings by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/299
- feat: add interactive tool approval UI with session-level permissions by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/288
- fix: Display question text with choices in AskUserQuestion by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/301

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.18.0...v1.19.0

## 1.18.0 (2026-01-11)

## What's Changed

- feat: add VibingCopyUnsentUserHeader command by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/284
- refactor: modularize agent-wrapper.mjs for better maintainability by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/281
- fix: enhance AskUserQuestion with ol/ul support and proactive usage by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/287

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.17.2...v1.18.0

## 1.17.2 (2026-01-09)

## What's Changed

- fix: save file content before Edit/Write to preserve diff after commit by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/279

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.17.1...v1.17.2

## 1.17.1 (2026-01-08)

## What's Changed

- fix: capture nvim_execute output and prevent blocking by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/276
- fix: improve VibingContext with clipboard copy and path normalization by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/275

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.17.0...v1.17.1

## 1.17.0 (2026-01-07)

## What's Changed

- refactor: comprehensive project-wide refactoring and security enhancements by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/272
- feat: remove time from VibingSetFileTitle filename format by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/274

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.16.0...v1.17.0

## 1.16.0 (2026-01-07)

## What's Changed

### Features

- feat: Add position argument to VibingChat command by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/264
- feat: Add line number gradient animation during AI response by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/267
- feat: Add tool result display configuration by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/271
- feat: simplify AskUserQuestion implementation by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/270

### Refactoring (Week 1-2)

- refactor: split chat/buffer.lua into focused modules by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/272
  - Split `presentation/chat/buffer.lua` (1086 lines) into main file (375 lines) + 8 modules (824 lines total)
  - Created dedicated modules: window_manager, file_manager, preview_data, frontmatter_handler, renderer, streaming_handler, conversation_extractor, keymap_handler
  - Each module follows single responsibility principle and is under 201 lines
  - Improves maintainability and testability per issue #269

- refactor: split inline/use_case.lua into focused modules by @shabaraba
  - Split `application/inline/use_case.lua` (472 lines) into main file (129 lines) + 5 modules (425 lines total)
  - Created dedicated modules: action_config, unsaved_buffer, task_queue, execution, prompt_builder
  - All modules under 201 lines, following single responsibility principle
  - Maintains full backward compatibility with exported functions and action configurations

- refactor: split adapter/agent_sdk.lua into focused modules by @shabaraba
  - Split `infrastructure/adapter/agent_sdk.lua` (405 lines) into main file (195 lines, 52% reduction) + 4 modules (461 lines total)
  - Created specialized modules:
    - command_builder.lua (227 lines): Command-line argument construction with all configuration flags
    - event_processor.lua (83 lines): JSON Lines event handling (session, chunk, tool_use, insert_choices, error)
    - stream_handler.lua (76 lines): stdout/stderr buffering and line-by-line processing
    - session_manager.lua (75 lines): Session ID storage, retrieval, and cleanup
  - Each module follows single responsibility principle and is under 227 lines
  - Improves code organization and maintainability

### Security Enhancements (Week 3)

- feat: add path traversal attack prevention by @shabaraba
  - Implemented `domain/security/path_sanitizer.lua` (138 lines) with functions:
    - `normalize()`: Path normalization with tilde expansion and symlink resolution
    - `check_traversal_patterns()`: Detection of `../` and other traversal patterns
    - `validate_within_roots()`: Ensure paths stay within allowed directories
    - `sanitize()`: Complete sanitization pipeline
  - Integrated into `domain/permissions/evaluator.lua` for enhanced path validation
  - Integrated into `core/utils/git.lua` to protect Git operations from malicious paths

- feat: add command injection attack prevention by @shabaraba
  - Implemented `domain/security/command_validator.lua` (195 lines) with functions:
    - `contains_metacharacters()`: Detects shell metacharacters (`;`, `&`, `|`, `$`, `` ` ``, etc.)
    - `matches_dangerous_pattern()`: Detects dangerous commands (`rm -rf`, `sudo`, `dd`, `eval`, etc.)
    - `validate_command()` and `validate_arguments()`: Command and argument validation
    - `is_allowed_command()`: Whitelist-based command filtering
    - `escape_for_shell()`: Safe shell string escaping
  - Integrated into `core/utils/git.lua` to validate all Git commands before execution

- test: comprehensive security test suite by @shabaraba
  - Created `tests/security_spec.lua` (280 lines) with 38 test cases
  - PathSanitizer tests: normalization, traversal detection, root validation, sanitization
  - CommandValidator tests: metacharacter detection, dangerous patterns, validation, whitelisting, escaping
  - All 38 tests passing with full coverage of security modules

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.15.1...v1.16.0

## 1.15.1 (2026-01-06)

## What's Changed

- fix: apply wrap settings only to vibing buffers by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/260

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.15.0...v1.15.1

## 1.15.0 (2026-01-06)

## What's Changed

- fix: custom command execution error due to missing use_case.send by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/251
- feat: add multi-instance Neovim support for MCP integration by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/255

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.14.2...v1.15.0

## 1.14.2 (2026-01-04)

## What's Changed

- fix: prevent wrap settings from leaking to non-vibing buffers by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/252
- docs: add ADR 003 - Agent SDK vs CLI Architecture Decision by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/254

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.14.1...v1.14.2

## 1.14.1 (2025-12-30)

## What's Changed

- fix: handle table language config in build_command by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/248

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.14.0...v1.14.1

## 1.14.0 (2025-12-30)

## What's Changed

- feat: truncate long descriptions in command picker by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/246

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.13.2...v1.14.0

## 1.13.2 (2025-12-30)

## What's Changed

- fix: resolve undefined function error in command_picker by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/244

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.13.1...v1.13.2

## 1.13.1 (2025-12-30)

## What's Changed

- refactor: complete Clean Architecture migration by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/242

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.13.0...v1.13.1

## 1.13.0 (2025-12-29)

## What's Changed

- feat: Add concurrent execution support with handle/session maps and inline queue by @shabaraba in <https://github.com/shabaraba/vibing.nvim/pull/239>
- fix: Display plugin slash commands with plugin name in VibingSlashCommands by @shabaraba in <https://github.com/shabaraba/vibing.nvim/pull/241>

**Full Changelog**: <https://github.com/shabaraba/vibing.nvim/compare/v1.12.1...v1.13.0>

## 1.12.1 (2025-12-29)

## What's Changed

- fix: resolve issue#214 and improve header spacing by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/235

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.12.0...v1.12.1

## 1.12.0 (2025-12-29)

## What's Changed

- feat: Add timestamps to chat message headers by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/231

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.11.0...v1.12.0

## 1.11.0 (2025-12-27)

## What's Changed

- feat: add :VibingSetFileTitle command for AI-powered chat file renaming by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/228

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.10.0...v1.11.0

## 1.10.0 (2025-12-26)

## What's Changed

- feat: move cursor to end after send to enable auto-scroll mode by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/219
- feat: add permissions_ask for manual tool approval workflow (Issue #174) by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/223

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.9.1...v1.10.0

## 1.9.1 (2025-12-25)

## What's Changed

- chore: update changelog by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/217

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.9.0...v1.9.1

## 1.9.0 (2025-12-25)

## What's Changed

- feat: VibingChat always creates new chat, VibingToggleChat preserves conversation by @shabaraba in https://github.com/shabaraba/vibing.nvim/pull/215

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.8.0...v1.9.0

## 1.8.0 (2025-12-25)

## What's Changed

- feat: implement smart auto-scroll in chat (scroll only when cursor is at bottom) by @claude[bot] in https://github.com/shabaraba/vibing.nvim/pull/208

**Full Changelog**: https://github.com/shabaraba/vibing.nvim/compare/v1.7.0...v1.8.0

## [1.7.0](https://github.com/shabaraba/vibing.nvim/compare/v1.6.1...v1.7.0) (2025-12-25)

### Features

- add line wrap configuration for vibing buffers ([#204](https://github.com/shabaraba/vibing.nvim/issues/204)) ([4e6d160](https://github.com/shabaraba/vibing.nvim/commit/4e6d160787614601a7c92225eedc4a7cb0883c6c))

## [1.6.1](https://github.com/shabaraba/vibing.nvim/compare/v1.6.0...v1.6.1) (2025-12-25)

### Bug Fixes

- format CHANGELOG.md to comply with Prettier rules ([#199](https://github.com/shabaraba/vibing.nvim/issues/199)) ([c67a007](https://github.com/shabaraba/vibing.nvim/commit/c67a007eb153f5bb86f2b034773556a911dec91b))

## [1.6.0](https://github.com/shabaraba/vibing.nvim/compare/v1.5.0...v1.6.0) (2025-12-25)

### Features

- Add direct window buffer operations (win_set_buf, win_open_file) ([#188](https://github.com/shabaraba/vibing.nvim/issues/188)) ([bb770c1](https://github.com/shabaraba/vibing.nvim/commit/bb770c1e2409c52cbc700b372257447de06bdfa0))
- Add window/pane information and manipulation MCP tools ([#186](https://github.com/shabaraba/vibing.nvim/issues/186)) ([51ad1ad](https://github.com/shabaraba/vibing.nvim/commit/51ad1add7b87fbc1e8c200251470fa2ced9afb03))

### Bug Fixes

- support diff display for unsaved new buffers in preview UI ([#194](https://github.com/shabaraba/vibing.nvim/issues/194)) ([f5a3eb1](https://github.com/shabaraba/vibing.nvim/commit/f5a3eb1c7c2d92bb8f86b572184805777d61d78f))

### Documentation

- add missing English docstrings to adapter and UI modules ([#192](https://github.com/shabaraba/vibing.nvim/issues/192)) ([223edd5](https://github.com/shabaraba/vibing.nvim/commit/223edd5fd99a970e02a6c7616c5f0d8ac1c6b5bf))

### Miscellaneous

- cleanup root directory structure ([#196](https://github.com/shabaraba/vibing.nvim/issues/196)) ([5604769](https://github.com/shabaraba/vibing.nvim/commit/560476970f81e16afd94ee6fcfe2a327481f015c))
- fix CHANGELOG.md formatting ([#183](https://github.com/shabaraba/vibing.nvim/issues/183)) ([81465ea](https://github.com/shabaraba/vibing.nvim/commit/81465ea1075f798bf8b0bd7420b903cfb4166594))

## [1.5.0](https://github.com/shabaraba/vibing.nvim/compare/v1.4.0...v1.5.0) (2025-12-24)

### Features

- support visual selection for VibingContext command ([#181](https://github.com/shabaraba/vibing.nvim/issues/181)) ([2b01a41](https://github.com/shabaraba/vibing.nvim/commit/2b01a41343bef5a0b17db4293d6754847214098f))

## [1.4.0](https://github.com/shabaraba/vibing.nvim/compare/v1.3.0...v1.4.0) (2025-12-24)

### Features

- add inline preview UI with diff viewer for inline actions ([#177](https://github.com/shabaraba/vibing.nvim/issues/177)) ([6f75db4](https://github.com/shabaraba/vibing.nvim/commit/6f75db4aa601a1656c23f8c3b1c0c16c3f88ca9c))
- add status notifications with floating window ([#172](https://github.com/shabaraba/vibing.nvim/issues/172)) ([b45fb54](https://github.com/shabaraba/vibing.nvim/commit/b45fb543f7ba9244679018b7b376ed3317799bb2))
- enable user MCP servers, slash commands, skills, and subagents in vibing.nvim ([#171](https://github.com/shabaraba/vibing.nvim/issues/171)) ([44deb67](https://github.com/shabaraba/vibing.nvim/commit/44deb6783db32eed217b3f77a3d0c23b11504c5b))

### Bug Fixes

- prioritize frontmatter permissions over config defaults ([#169](https://github.com/shabaraba/vibing.nvim/issues/169)) ([f7cbfd5](https://github.com/shabaraba/vibing.nvim/commit/f7cbfd505285a89bb9acd5bcb3d268ee81e99f13))

### Code Refactoring

- remove redundant and deprecated commands ([#175](https://github.com/shabaraba/vibing.nvim/issues/175)) ([ba629e2](https://github.com/shabaraba/vibing.nvim/commit/ba629e2b9652cdc76d2eb417393faabf2b08eb1c))

## [1.3.0](https://github.com/shabaraba/vibing.nvim/compare/v1.2.1...v1.3.0) (2025-12-23)

### Features

- add default language configuration for AI responses ([#142](https://github.com/shabaraba/vibing.nvim/issues/142)) ([8c3e4c2](https://github.com/shabaraba/vibing.nvim/commit/8c3e4c277dd57639d612d4354ccd631819f6cef0))
- add filetype detection for .vibing extension ([#141](https://github.com/shabaraba/vibing.nvim/issues/141)) ([3a65290](https://github.com/shabaraba/vibing.nvim/commit/3a6529035f1bac9f7c863f535010e70308d5e868))
- add granular permissions control with rules-based configuration ([#146](https://github.com/shabaraba/vibing.nvim/issues/146)) ([e5d1cb3](https://github.com/shabaraba/vibing.nvim/commit/e5d1cb3b51d699fe1cf71205248bfe705233dcb0))
- add granular permissions control with rules-based configuration ([#156](https://github.com/shabaraba/vibing.nvim/issues/156)) ([7f3f804](https://github.com/shabaraba/vibing.nvim/commit/7f3f804ac857ea68952025bf14faa3730b25f8be))
- add Neovim Agent Tools via MCP integration ([#166](https://github.com/shabaraba/vibing.nvim/issues/166)) ([cdae130](https://github.com/shabaraba/vibing.nvim/commit/cdae130a60ec66210b8d8133a4a102481667ba8c))
- add slash command completion for vibing files ([#144](https://github.com/shabaraba/vibing.nvim/issues/144)) ([b2105ed](https://github.com/shabaraba/vibing.nvim/commit/b2105ed207caf1d1531ac80f412a0147d57552c0))
- add slash command completion with custom command support ([051bd9e](https://github.com/shabaraba/vibing.nvim/commit/051bd9ee1ada8b76ecb7664ac951e1183ea12ee3))
- add slash command completion with custom command support ([91e782b](https://github.com/shabaraba/vibing.nvim/commit/91e782b010316cfb84d84aa565916b308338b563))
- change default chat window mode to current buffer ([#161](https://github.com/shabaraba/vibing.nvim/issues/161)) ([8203fee](https://github.com/shabaraba/vibing.nvim/commit/8203fee6b27f2a01e1cc87b90ff747634afc905e))
- display edited files with diff viewer in chat ([#143](https://github.com/shabaraba/vibing.nvim/issues/143)) ([ba663bd](https://github.com/shabaraba/vibing.nvim/commit/ba663bdc3298e932a0d6bdfdd987f41dca70dc3c))
- enhance inline actions with optional arguments and progress display ([#132](https://github.com/shabaraba/vibing.nvim/issues/132)) ([0139c0f](https://github.com/shabaraba/vibing.nvim/commit/0139c0f3453feebce4fc5b65b35c8a0646fa1957))
- migrate to V2 Agent SDK API for proper session resumption ([11ab2c6](https://github.com/shabaraba/vibing.nvim/commit/11ab2c6810ee0f6d29c66f6371e37852257a23ae))
- prompt for arguments when custom command requires them ([#134](https://github.com/shabaraba/vibing.nvim/issues/134)) ([ccaf0de](https://github.com/shabaraba/vibing.nvim/commit/ccaf0de7a823ab705ba5c0bb598b371eb6a62728))
- support $ARGUMENTS and {{ARGUMENTS}} placeholders ([c186f59](https://github.com/shabaraba/vibing.nvim/commit/c186f59911b5f459efd89ea6eef90cb43e2a7a22))
- unify permission builder with improved architecture ([#162](https://github.com/shabaraba/vibing.nvim/issues/162)) ([b4cec79](https://github.com/shabaraba/vibing.nvim/commit/b4cec7972e182ce6e7415a4c065897637fcc9794))
- use .vibing extension and vibing filetype to prevent plugin conflicts ([9026d81](https://github.com/shabaraba/vibing.nvim/commit/9026d81b0a1d402ccf6ee8cd37c0f4e5a63c6a7d))

### Bug Fixes

- add context gathering to GitHub workflow ([#157](https://github.com/shabaraba/vibing.nvim/issues/157)) ([8877ec9](https://github.com/shabaraba/vibing.nvim/commit/8877ec9508645a3ada98b98bb0753022b33b541c))
- add file operation tools for implementation tasks ([cdeb784](https://github.com/shabaraba/vibing.nvim/commit/cdeb784dd2b094e77d41b07ad200175415d529a3))
- address PR review comments ([c7577af](https://github.com/shabaraba/vibing.nvim/commit/c7577af4c714615c45cba4144220b1f726e42999))
- clear adapter session_id for new chats to prevent session sharing ([8d89445](https://github.com/shabaraba/vibing.nvim/commit/8d89445f81d7192f02d25db07a925abcbcb5f3e0))
- consolidate and streamline user commands (18 → 9 commands) ([#163](https://github.com/shabaraba/vibing.nvim/issues/163)) ([#165](https://github.com/shabaraba/vibing.nvim/issues/165)) ([b43e34a](https://github.com/shabaraba/vibing.nvim/commit/b43e34a182492e62927d85dd61b02071ac5b1b98))
- execute custom commands and remove omnifunc to avoid LSP conflicts ([2ae4456](https://github.com/shabaraba/vibing.nvim/commit/2ae445659d80f05be6a1abc2a6865fdb187b6464))
- update inline_spec test for new feat prompt ([720e35a](https://github.com/shabaraba/vibing.nvim/commit/720e35aa31aa2deb26ad9b6e1f65b9d52713b923))
- update test to use attached_buffers instead of chat_buffer ([ce79431](https://github.com/shabaraba/vibing.nvim/commit/ce794319aea605b8331dd5e31c427b8075b25fd1))
- update tests and format for new commands ([7d9b6eb](https://github.com/shabaraba/vibing.nvim/commit/7d9b6eb43bc0c4a628afaa9e1c8843ed34f8cec9))
- use claude_args instead of invalid allowed_tools param ([#138](https://github.com/shabaraba/vibing.nvim/issues/138)) ([5a6adf6](https://github.com/shabaraba/vibing.nvim/commit/5a6adf60e631f730b393dafe4d3672ca1d875c16))
- use frontmatter values and add permission control ([#130](https://github.com/shabaraba/vibing.nvim/issues/130)) ([cbfecf0](https://github.com/shabaraba/vibing.nvim/commit/cbfecf03928bd148a7953386b207ba6846b32c9f))

### Documentation

- update README and CLAUDE.md with latest features ([#164](https://github.com/shabaraba/vibing.nvim/issues/164)) ([d66e3bc](https://github.com/shabaraba/vibing.nvim/commit/d66e3bc95fe0ecb974d7bab4487157dfe26a9bfc))

### Miscellaneous

- cleanup gitignore and fix PR [#117](https://github.com/shabaraba/vibing.nvim/issues/117) review comments ([#121](https://github.com/shabaraba/vibing.nvim/issues/121)) ([a84f906](https://github.com/shabaraba/vibing.nvim/commit/a84f9068c394f4c589977b5cc3445b02d5c6a869))
- enable full output in Claude Code GitHub Action ([#139](https://github.com/shabaraba/vibing.nvim/issues/139)) ([f944e2c](https://github.com/shabaraba/vibing.nvim/commit/f944e2c127c54e48a2f5dad980b1464f129ee498))

## [1.2.1](https://github.com/shabaraba/vibing.nvim/compare/v1.2.0...v1.2.1) (2025-12-18)

### Bug Fixes

- address PR [#117](https://github.com/shabaraba/vibing.nvim/issues/117) review comments ([#119](https://github.com/shabaraba/vibing.nvim/issues/119)) ([482da11](https://github.com/shabaraba/vibing.nvim/commit/482da11f90e1cd6d5a42e1f9d06aba4e286f3487))
- complete notify API migration in chat handlers ([#120](https://github.com/shabaraba/vibing.nvim/issues/120)) ([4ea29e5](https://github.com/shabaraba/vibing.nvim/commit/4ea29e56946e44a989e14bd98a783c9ed5097e42))

### Performance Improvements

- optimize buffer operations and file I/O ([#117](https://github.com/shabaraba/vibing.nvim/issues/117)) ([4138185](https://github.com/shabaraba/vibing.nvim/commit/41381859b152c58f9d48fd927f146f94b77e41d8))

### Tests

- add comprehensive test coverage for action commands ([#94](https://github.com/shabaraba/vibing.nvim/issues/94)) ([59c5b3c](https://github.com/shabaraba/vibing.nvim/commit/59c5b3cb1a3a421f19369d816a13f5f00672f83b))
- add comprehensive test coverage for chat command handlers ([#86](https://github.com/shabaraba/vibing.nvim/issues/86)) ([15a8ff1](https://github.com/shabaraba/vibing.nvim/commit/15a8ff11e255f78c83ca49f41a7f1bce21e779c1))
- add comprehensive test coverage for chat command parser ([#88](https://github.com/shabaraba/vibing.nvim/issues/88)) ([3cdd8f8](https://github.com/shabaraba/vibing.nvim/commit/3cdd8f811a82cc156bec8ab306ab9f512b4faf8d))
- add comprehensive test coverage for chat initialization ([#92](https://github.com/shabaraba/vibing.nvim/issues/92)) ([e182032](https://github.com/shabaraba/vibing.nvim/commit/e182032e07129977f8f94c6fc5ae1cbb1eea5cb4))
- add comprehensive test coverage for Claude API adapters ([#84](https://github.com/shabaraba/vibing.nvim/issues/84)) ([387fd37](https://github.com/shabaraba/vibing.nvim/commit/387fd371711b5ae25736c7c299ee832bdb82e8bc))
- add comprehensive test coverage for context management module ([#82](https://github.com/shabaraba/vibing.nvim/issues/82)) ([4329b1d](https://github.com/shabaraba/vibing.nvim/commit/4329b1dee97622230a9a11d1732984963616cab8))
- add comprehensive test coverage for context migrator ([#90](https://github.com/shabaraba/vibing.nvim/issues/90)) ([1e0ea3c](https://github.com/shabaraba/vibing.nvim/commit/1e0ea3c7fe634e0895fae2cf8f9d9ae9bc8d6e02))
- add comprehensive test coverage for init module (plugin entry point) ([#100](https://github.com/shabaraba/vibing.nvim/issues/100)) ([6e471d0](https://github.com/shabaraba/vibing.nvim/commit/6e471d0c7d0223c1ce3d8027fa2bd6ad11bcdc08))
- add comprehensive test coverage for inline actions module ([#80](https://github.com/shabaraba/vibing.nvim/issues/80)) ([01a1066](https://github.com/shabaraba/vibing.nvim/commit/01a10666e5ce93d3401e94f84da905aeb22583bf)), closes [#78](https://github.com/shabaraba/vibing.nvim/issues/78)
- add comprehensive test coverage for oil.nvim integration ([#96](https://github.com/shabaraba/vibing.nvim/issues/96)) ([d665acc](https://github.com/shabaraba/vibing.nvim/commit/d665acc4bf5dd0032b38b58ae1c459f8f44764be))
- add comprehensive test coverage for remote control module ([#98](https://github.com/shabaraba/vibing.nvim/issues/98)) ([96b816c](https://github.com/shabaraba/vibing.nvim/commit/96b816cc3ce99f2d56ea1c0ad258a415e43d4054))

### Code Refactoring

- enhance type annotations in agent_sdk adapter (partial [#101](https://github.com/shabaraba/vibing.nvim/issues/101)) ([#107](https://github.com/shabaraba/vibing.nvim/issues/107)) ([b3c5370](https://github.com/shabaraba/vibing.nvim/commit/b3c53708a26f4da1d75ff3b09454783d8b4b7fd0))
- enhance type annotations in UI modules (partial [#101](https://github.com/shabaraba/vibing.nvim/issues/101)) ([#106](https://github.com/shabaraba/vibing.nvim/issues/106)) ([d3b1bed](https://github.com/shabaraba/vibing.nvim/commit/d3b1bede3087627370cbb5ecf3c218f9cf78e142))
- enhance type annotations in utils and context modules (partial [#101](https://github.com/shabaraba/vibing.nvim/issues/101)) ([#105](https://github.com/shabaraba/vibing.nvim/issues/105)) ([70b1643](https://github.com/shabaraba/vibing.nvim/commit/70b164346c4d0611327e0c9486a6dd5156b3ff56))
- standardize error handling and messaging across all modules ([#115](https://github.com/shabaraba/vibing.nvim/issues/115)) ([cdbd18b](https://github.com/shabaraba/vibing.nvim/commit/cdbd18b78fecc0b4461d42335d08bcfd987e57c6))

### Documentation

- enhance type annotations in actions modules ([#108](https://github.com/shabaraba/vibing.nvim/issues/108)) ([127fb58](https://github.com/shabaraba/vibing.nvim/commit/127fb58d81fe84e904bad584e8118ad990f4e8d7))
- enhance type annotations in adapters/base.lua and config.lua ([#111](https://github.com/shabaraba/vibing.nvim/issues/111)) ([522691c](https://github.com/shabaraba/vibing.nvim/commit/522691cef60e92e134a66818ccf3a61e0a10d25a))
- enhance type annotations in chat system modules ([#109](https://github.com/shabaraba/vibing.nvim/issues/109)) ([1a9855a](https://github.com/shabaraba/vibing.nvim/commit/1a9855a7e1aebc4ff9cdd98cb2e285bcc2676fa2))
- enhance type annotations in context modules (collector, formatter, migrator) ([#113](https://github.com/shabaraba/vibing.nvim/issues/113)) ([354ed0a](https://github.com/shabaraba/vibing.nvim/commit/354ed0a39d1c8ea014aa88b4696d7b97dfe9fccb))
- enhance type annotations in init.lua ([#112](https://github.com/shabaraba/vibing.nvim/issues/112)) ([0084855](https://github.com/shabaraba/vibing.nvim/commit/00848556dadebc63b0a847e6d5355d3673371ac5))
- enhance type annotations in remaining adapters (claude, claude_acp) ([#114](https://github.com/shabaraba/vibing.nvim/issues/114)) ([79d50f3](https://github.com/shabaraba/vibing.nvim/commit/79d50f365a89a8dc33ac26a4b8eb8bf4c5647904))
- enhance type annotations in utils/context/integrations/remote modules ([#110](https://github.com/shabaraba/vibing.nvim/issues/110)) ([41374db](https://github.com/shabaraba/vibing.nvim/commit/41374db820bd0804ad5bb77af8cb14f9d666bd8b))
- expand documentation with API reference and tutorials ([#116](https://github.com/shabaraba/vibing.nvim/issues/116)) ([17655e6](https://github.com/shabaraba/vibing.nvim/commit/17655e6ebddda1a4bdb1c4aa5b6593de8e07dd30))

## [1.2.0](https://github.com/shabaraba/vibing.nvim/compare/v1.1.0...v1.2.0) (2025-12-17)

### Features

- add GitHub issue and PR templates ([#55](https://github.com/shabaraba/vibing.nvim/issues/55)) ([4858f1d](https://github.com/shabaraba/vibing.nvim/commit/4858f1ddab3a0948ff0b65400a038e4303de65c8))

### Bug Fixes

- resolve config property inconsistency and add adapter/UI tests ([#73](https://github.com/shabaraba/vibing.nvim/issues/73)) ([998697b](https://github.com/shabaraba/vibing.nvim/commit/998697b392283dde7c0bbbd12ce0be43eeb3d01a)), closes [#71](https://github.com/shabaraba/vibing.nvim/issues/71)
- resolve merge conflict in agent-wrapper.mjs ([#48](https://github.com/shabaraba/vibing.nvim/issues/48)) ([4a55d02](https://github.com/shabaraba/vibing.nvim/commit/4a55d02229aa8accdf34ce25ce895729706d17a4))
- update markdownlint-cli to resolve security vulnerabilities ([#53](https://github.com/shabaraba/vibing.nvim/issues/53)) ([b650762](https://github.com/shabaraba/vibing.nvim/commit/b6507622e12793e039770e74c5d106196e7b7413))

### Tests

- add automated test infrastructure with plenary.nvim ([#66](https://github.com/shabaraba/vibing.nvim/issues/66)) ([c13f29c](https://github.com/shabaraba/vibing.nvim/commit/c13f29c33c2ab0b43eb4e067d211a18271702605))
- add comprehensive tests for chat actions module ([#77](https://github.com/shabaraba/vibing.nvim/issues/77)) ([199b036](https://github.com/shabaraba/vibing.nvim/commit/199b036a386d2c52501ac8b85db9f1679109a070))
- add comprehensive tests for chat_buffer UI component ([#75](https://github.com/shabaraba/vibing.nvim/issues/75)) ([ac6dd78](https://github.com/shabaraba/vibing.nvim/commit/ac6dd78a0a9b8eae293d6e2b173edae9cd81e7f4))
- expand test coverage for core modules ([#68](https://github.com/shabaraba/vibing.nvim/issues/68)) ([f19d040](https://github.com/shabaraba/vibing.nvim/commit/f19d0403867a17ce2b6cd2122b3ecafafeb95eae))

### Documentation

- add comprehensive contributor guidelines ([#42](https://github.com/shabaraba/vibing.nvim/issues/42)) ([f39c33b](https://github.com/shabaraba/vibing.nvim/commit/f39c33bc5f4b654939dec12f469083b7929923e9))
- add comprehensive README.md ([#31](https://github.com/shabaraba/vibing.nvim/issues/31)) ([f2f2d39](https://github.com/shabaraba/vibing.nvim/commit/f2f2d39320dce7ec90ec17e241afbfd5548b8a05))
- add MIT License file ([#34](https://github.com/shabaraba/vibing.nvim/issues/34)) ([41badfd](https://github.com/shabaraba/vibing.nvim/commit/41badfde1d1636a554d4382670cf77946099d678))
- add security policy (SECURITY.md) ([#61](https://github.com/shabaraba/vibing.nvim/issues/61)) ([a6af709](https://github.com/shabaraba/vibing.nvim/commit/a6af709ec1f0f532b7f7d2db8a6386abe930169a))
- add status badges to README ([#57](https://github.com/shabaraba/vibing.nvim/issues/57)) ([e920162](https://github.com/shabaraba/vibing.nvim/commit/e920162646fa481fb66be49b70d952ec72d6dca8))
- add table of contents to README ([#64](https://github.com/shabaraba/vibing.nvim/issues/64)) ([44a3c6a](https://github.com/shabaraba/vibing.nvim/commit/44a3c6a942a275452e1e76e616cfbe7e47fa09f9))
- add Vim help documentation ([#36](https://github.com/shabaraba/vibing.nvim/issues/36)) ([81ed879](https://github.com/shabaraba/vibing.nvim/commit/81ed8795368a094b17a1520e800257532cf35b20))

### Miscellaneous

- add .editorconfig for consistent code style ([#46](https://github.com/shabaraba/vibing.nvim/issues/46)) ([8ac8836](https://github.com/shabaraba/vibing.nvim/commit/8ac883680465efe3a07be45a55699401549ac7bc))
- add development tools and linting configuration ([#49](https://github.com/shabaraba/vibing.nvim/issues/49)) ([fce5a87](https://github.com/shabaraba/vibing.nvim/commit/fce5a872449289533e2fcce3e8af0dd4a365cfc7))
- add metadata to package.json ([#59](https://github.com/shabaraba/vibing.nvim/issues/59)) ([a48215d](https://github.com/shabaraba/vibing.nvim/commit/a48215dca9a4e2aba8e238a408fd1dcfdf88487d))
- add npm scripts for development and testing ([#40](https://github.com/shabaraba/vibing.nvim/issues/40)) ([00b05e0](https://github.com/shabaraba/vibing.nvim/commit/00b05e0d689a7006a9d6b1aa6fbea6a5d0ade512))
- add test commits to CHANGELOG via release-please ([#70](https://github.com/shabaraba/vibing.nvim/issues/70)) ([02b4d07](https://github.com/shabaraba/vibing.nvim/commit/02b4d07e9674dd46005f8b47946857d3304c2272))
- improve .gitignore with comprehensive patterns ([#38](https://github.com/shabaraba/vibing.nvim/issues/38)) ([f07dabc](https://github.com/shabaraba/vibing.nvim/commit/f07dabca86bdac51e09ce41736f172234cfee2fe))

## [1.1.0](https://github.com/shabaraba/vibing.nvim/compare/v1.0.0...v1.1.0) (2025-12-17)

### Features

- add :VibingCustom command for natural language inline instructions ([#21](https://github.com/shabaraba/vibing.nvim/issues/21)) ([cbeba3f](https://github.com/shabaraba/vibing.nvim/commit/cbeba3f28009ffb39c6fb853bc699d62386086d2))
- add configurable chat file save location ([#19](https://github.com/shabaraba/vibing.nvim/issues/19)) ([3bdb7d2](https://github.com/shabaraba/vibing.nvim/commit/3bdb7d246e82a9ee334ab3e7c31e48824fbad510))
- add default allow/deny permissions configuration ([#27](https://github.com/shabaraba/vibing.nvim/issues/27)) ([ed56c22](https://github.com/shabaraba/vibing.nvim/commit/ed56c2251d03bc48566fe65755a8836ec924b3b5))
- add default mode and model configuration for Agent SDK ([#20](https://github.com/shabaraba/vibing.nvim/issues/20)) ([933c9ad](https://github.com/shabaraba/vibing.nvim/commit/933c9add971f067fe3fbab7c5f6e3a8ce434584b))
- add individual commands for inline actions ([#18](https://github.com/shabaraba/vibing.nvim/issues/18)) ([bd3515d](https://github.com/shabaraba/vibing.nvim/commit/bd3515df654a6ae4afc041bf292232128ffa509d))
- add inline action file mention and chat auto-detection ([9c92051](https://github.com/shabaraba/vibing.nvim/commit/9c9205186d3fcc091bc8f3ea4901506a46573c9e))
- add Neovim remote control via --server socket ([#29](https://github.com/shabaraba/vibing.nvim/issues/29)) ([5ebdd43](https://github.com/shabaraba/vibing.nvim/commit/5ebdd4376107501c3ea180e5cc36df8fc7c94909))
- add oil.nvim integration for sending files to chat ([#22](https://github.com/shabaraba/vibing.nvim/issues/22)) ([5a5e6dc](https://github.com/shabaraba/vibing.nvim/commit/5a5e6dcfd2155c4a31b00ed6e5a333232fe4e3d4))
- add release-please automation and branch protection ([#1](https://github.com/shabaraba/vibing.nvim/issues/1)) ([43b2f78](https://github.com/shabaraba/vibing.nvim/commit/43b2f782e83b641c0a5f7c31e59c9e50db464ca3))
- auto-generate chat file names from first message ([#25](https://github.com/shabaraba/vibing.nvim/issues/25)) ([a7a7a92](https://github.com/shabaraba/vibing.nvim/commit/a7a7a92e724c36dd19297ad109fe08acf7379ce5))
- enable slash commands in chat ([#23](https://github.com/shabaraba/vibing.nvim/issues/23)) ([1c00545](https://github.com/shabaraba/vibing.nvim/commit/1c00545e8198c2663935386c79411ca8afb876e5))
- initial vibing.nvim implementation with Agent SDK ([dc5af8d](https://github.com/shabaraba/vibing.nvim/commit/dc5af8d3d7a487c167b7cead275440e1193df2d4))
- move context display to end of chat messages ([#17](https://github.com/shabaraba/vibing.nvim/issues/17)) ([b70a89d](https://github.com/shabaraba/vibing.nvim/commit/b70a89d56c42020e1d0af7d889eef8a405352055))
