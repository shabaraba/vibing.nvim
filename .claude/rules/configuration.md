# Configuration

The full user-facing configuration reference (every `setup()` field, window positions, permission
rule examples, daily summary, etc.) lives in `handbook/configuration.md` and in
`lua/vibing/config.lua` (defaults + type annotations) — read those instead of duplicating the
field list here. `README.md` keeps only a short "commonly tweaked options" block that links to
`handbook/configuration.md`.

## Where Things Live

- Full option list & defaults: `handbook/configuration.md`
- Defaults and type annotations: `lua/vibing/config.lua`

## Diff Tracking (Claude-relevant behavior)

Per-turn diffs come from a **git tree snapshot**, not from watching tool arguments. The
mechanism and its trade-offs live in `architecture.md` → "Per-Request Diffs"; `config.diff.tool`
(`"git"` | `"auto"`, currently synonymous) only picks what `gd` falls back to when a file has no
patch file. The removed `"mote"` value warns once and behaves as `"git"`.
