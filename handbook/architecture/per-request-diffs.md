# Per-Request Diffs

Detail behind `.claude/rules/architecture.md` → "Per-Request Diffs". Each turn's
`### Modified Files` list and its `.vibing/patches/*.patch` come from two git tree snapshots of
the working tree, taken before and after the turn. The point of that shape is what it does _not_
need to know: which tool made the change (#625).

Each turn's `### Modified Files` list and its `.vibing/patches/*.patch` come from **two git tree
snapshots of the working tree**, taken before and after the turn and compared with `git diff`
(`core/utils/git_snapshot.lua`). That is the main path, not the only one: a read-only turn takes
no snapshot at all, and the two cases in the table below fall back to `request_diff.lua`.

The point of that shape is what it does _not_ need to know: which tool made the change. The
mechanism it replaced (`request_diff.lua`) backed up the file named in a Write/Edit tool's
arguments, so `sed -i`, `mv`, a formatter, or anything else run through Bash produced no diff
section at all — the change simply did not exist as far as the chat was concerned. This is #625.

**The baseline is lazy, and that is what keeps it cheap.** It is taken at the PreToolUse hook for
the first tool of the turn that could write, not at the start of the request, so a read-only turn
takes no snapshot. It is not literally free of git: `send_message` resolves `_worktree_root` when
it builds the request's opts, which is one `rev-parse --show-toplevel`. That is cached per working
directory, so inside a repository it costs one process the first time a chat sends from a given
directory and nothing after. **Only successes are cached**, so a working directory that is not in a
repository re-resolves on every send — deliberate, since remembering "not a repo" would leave a
directory that later becomes one (or gains a worktree) permanently misjudged, and the miss is a
`rev-parse` that fails fast. The trigger is an **exclusion** list (`Read`/`Glob`/`Grep`/
`WebFetch`/`WebSearch` plus the side-effect-free `INTERNAL_TOOLS`), not an allow list: an MCP tool
whose name says nothing about its behaviour has to count as a writer, and the cost of guessing
wrong that way is one wasted snapshot rather than a silently missing diff. Note that
`INTERNAL_TOOLS` is _not_ a read-only list — it deliberately carries `NotebookEdit`, `Agent`/`Task`
and `EnterWorktree` — so those are put back on the mutating side by name.

**The user's index is never touched.** `git add -A` runs against a copy of the real index handed
over as `GIT_INDEX_FILE`, so it takes a `<tmp>.lock` rather than `.git/index.lock` and cannot
collide with a `git commit` the user runs mid-turn. The copy exists only to inherit the stat
cache, and that is worth more than it looks: measured on an 80k-file tree, a snapshot takes 63ms
with the copied index and 210ms starting from an empty one, so a failed copy means a slower first
snapshot rather than a broken one. `commit-tree` then wraps the tree, with
`HEAD` as parent when there is one — a repository with no commits at all works, parentless.

Three details are not interchangeable:

- **The git calls block the main loop** (`vim.system():wait()`) — the baseline inside the
  synchronous PreToolUse hook, the diff at response time. Measured at 20ms per `git add -A` on a
  9k-file tree and 63ms on an 80k one, which is why it is accepted; but the cost scales with the
  tree, so a very large monorepo or a worktree on a network filesystem is where this would be felt
  first and is worth revisiting if anyone reports it.
- **Every git call takes the same `cwd`,** normalized through `rev-parse --show-toplevel` first.
  `get_cwd()` can point at a subdirectory, and in a linked worktree the whole scope — which index,
  which refs — is decided by that directory. `rev-parse --git-path index` is what finds the index
  at all, since a worktree's lives under `.git/worktrees/<name>/`.
- **`refs/worktree/vibing/<handle>` is a per-worktree namespace** (git 2.23+), so removing a
  worktree takes its leftover refs with it instead of leaving them in the common ref store. The
  ref is only a guard against a `git gc` landing mid-turn, so an `update-ref` that fails (an older
  git) is swallowed and the turn proceeds — freshly written objects are not pruned by gc's
  two-week default either way. `clear()` deletes the ref and nothing else: **no `git gc`**, since
  the unreferenced objects are collected by the user's own `gc --auto` in due course.
- **Leftover refs are swept per worktree, not once at startup**, and that is a consequence of the
  namespace above rather than belt-and-braces: verified against git, a `for-each-ref` in the main
  worktree does not enumerate a linked worktree's `refs/worktree/` at all (they live under
  `.git/worktrees/<name>/refs/`). So `M.sweep()` at startup only reaches Neovim's own cwd, and a
  crash during a turn in `.vibing/worktrees/<branch>/` — the project's normal way of working —
  would leave its ref there forever. `ensure_baseline` therefore sweeps a root the first time it
  takes a baseline in it, deleting only refs older than the session TTL. Only the first of its two
  guards is exact: the ordering rules out a live ref of _this_ process, since the sweep runs on a
  root's _first_ baseline, when no session on that root exists yet. Against another Neovim the pair
  is best-effort — the registry can under-match (it knows an instance's own cwd, not which worktree
  its chats run in) and a turn can outlive the TTL, which is precisely what `sweep_stale` had to
  stop assuming. What is lost when they both miss is one gc guard, not the diff.
- **Untracked files that the turn never touched are still hashed into the object database**, since
  that is what `git add -A` does and what makes a new file show up as a diff at all. They are
  written to the local `.git/objects` only, become unreachable the moment `clear()` drops the ref,
  and are never pushed — `git push` sends what is reachable from the refs being pushed, and a
  snapshot commit is an ancestor of no branch. Accepted rather than solved: excluding untracked
  files would cost new-file detection, which is half the point.
- **`-c core.quotePath=false`** on both diff calls, or a non-ASCII path comes back octal-escaped
  and the file list stops matching the file on disk.
- **`-M` on both diff calls too**, not just the patch. Without it on `--name-only`, a user who has
  set `diff.renames=false` gets a pure rename split two ways — one `rename` entry in the patch, two
  entries (the delete and the add) in the file list — and the vanished path is then handed to
  `BufferReload`. Reproduced against git before fixing.
- **The file list is a second `git diff --name-only`, not something parsed out of the patch.**
  Reading `+++ b/…` misses three kinds of change outright, because git emits no such line for
  them — a binary file (`GIT binary patch`), a pure rename (`rename from`/`rename to`), or a
  mode-only change (`old mode`/`new mode`); reading the `diff --git a/X b/Y` header instead cannot
  split a path containing a space, which is the weakness `ui/patch_viewer/parser.lua`'s regex
  already has. Both failures are the silent-omission shape this whole mechanism exists to remove.
  The duplication is also small: this compares two **tree objects**, not the worktree, and
  `--name-only` generates no hunks — measured on a 9k-file repository at 3ms for the patch and 2ms
  here, against 20ms per `git add -A` (twice a turn). A turn whose patch came back empty skips it
  entirely, since an empty patch already answers "no files changed".
- **`.vibing/` is excluded by pathspec**, not left to `.gitignore`. It holds the chat files and the
  patches themselves and changes during the turn, so for anyone who has not git-ignored it every
  turn would list the conversation log as its own output and put the whole transcript in the patch.
  The removed mote integration excluded the same directory through `.moteignore`. The exclusion is
  unconditional on the diff calls (where it matters) and **conditional on `git add -A`**, where it
  only ever saved hashing — because naming it there is what killed the whole mechanism until #664.
  `git add` exits 1 when a pathspec explicitly names an ignored path, and it applies that to a
  **negative** pathspec too, so in any project that git-ignores `.vibing/` — the setup this
  plugin's own docs recommend, and this repository's own `.gitignore` —
  `git add -A -- . ':(exclude).vibing'` always failed. Only the exit code failed: staging completed
  and `write-tree` succeeded, but `snapshot()` reads the code, so no baseline was ever taken and
  every turn fell silently back to `request_diff` — losing exactly the Bash-driven changes #625 was
  filed about. `add_pathspec` therefore asks `git check-ignore -q .vibing` once per worktree root
  and drops the exclude when git is already skipping the directory. An undecidable answer keeps the
  exclude, since keeping it wrongly costs only the one case above while dropping it wrongly puts a
  whole `.vibing/worktrees/` checkout in the patch. Measured against git 2.50.1: `--ignore-errors`
  and every `:(exclude...)` spelling exit 1 alike, and plain `-- .` exits 0.

  The spec that missed this is worth naming, because the gap was in the fixture rather than in the
  assertions: its `.gitignore` held `ignored/` and `*.log` only, so `.vibing/` was never ignored in
  any test, and the one case pinned for this directory was literally the working one — "even when
  it is not gitignored". Both are pinned now.

**The two baselines are taken under separate `pcall`s** (`permission._capture_baselines`). Sharing
one would let the fallback take the main path down with it: `request_diff.capture` builds its
backup directory through `Fs.ensure_dir`, which re-raises everything that is not the
concurrent-creation race, so a throw there would skip `ensure_baseline` and leave a turn with
neither baseline. Both stay guarded, because neither may break the permission decision.

**When both come up empty, the turn says so.** A snapshot that could not be read plus no tool
event at all is indistinguishable from "nothing changed" — and for a turn that worked only through
Bash, that is precisely the silent loss this mechanism exists to remove. `_handle_response` warns
in that one case rather than appending an empty section.

**The fallback's backups are dropped only once the snapshot path has actually produced output.**
`generate` therefore reports "could not tell" separately from "nothing changed" — a second
snapshot or diff that fails (a worktree removed mid-turn, a permission or disk error) returns
`ok = false`, and `_handle_response` routes to `request_diff` instead, whose backups are still
there. Clearing them first would mean a failure at that one point silently produced a turn with no
diff and no warning, which is the failure this whole mechanism exists to remove.

**`request_diff.lua` stays** as the fallback for the cases a snapshot cannot serve, decided in
`_handle_response`:

| Condition                                        | Path                      |
| ------------------------------------------------ | ------------------------- |
| `working_dir` is not inside a git repository     | `request_diff`            |
| Another turn's write window overlapped this one  | `request_diff`            |
| The snapshot was attempted and could not be read | `request_diff`, else warn |
| Otherwise                                        | `git_snapshot`            |

The third row is the recovery path rather than a routing decision: the snapshot was the right
mechanism and simply failed, so the turn takes whatever the fallback backed up — and when that is
empty too (a Bash-only turn), it warns instead of rendering as a turn that changed nothing.

The second row is the one worth stating plainly: the tree is shared state, and nothing in it
records _whose_ `sed -i` ran. A snapshot diff spanning a window in which a second chat was also
editing the same worktree would report that chat's work as this turn's. Missing the Bash-driven
changes of one overlapping turn is the less wrong answer.

**The overlap has to be recorded when the baseline is taken, not asked about at response time**,
and getting that wrong makes the guard protect the wrong side. A point-in-time
`find_other_active_for_worktree` at response time is only answered honestly for the turn that
finishes _first_ — by the time the second one asks, the first has already unregistered, so it reads
"no overlap" and takes the snapshot path. But its window (its own baseline → its own diff) is
precisely the one that contains the other turn's changes, so the misattribution lands on exactly
the turn the check waved through. It is structural, not a race: it happens on every overlap.

So `ensure_baseline` walks the sessions already open on the same root, marks itself and marks each
of them (`had_overlap`). A session lives from its baseline to its `clear()`, which is the interval
the diff covers, so two open sessions on one root _are_ two overlapping windows. Marking both is
what makes the fallback symmetric — the second turn still knows, long after the first has gone.

`ActiveStreamRegistry.find_other_active_for_worktree` is kept as the second signal, for a stream
that is writing without a session of its own to be seen through (a `write-tree` that failed on a
conflicted index, say). It excludes by **handle_id**, not by `chat_bufnr` the way
`find_other_active_for_session` does — codex and grok register no `chat_bufnr` (see `features.md`),
so two of those would compare `nil` against `nil` and never see each other.

**Both overlap signals are process-local, so two Neovim instances on one worktree are out of
scope.** `sessions` and `ActiveStreamRegistry` are module tables, so a chat running in a second
Neovim is invisible to the first: both would take the snapshot path and each would report the
other's changes as its own — **all** of them, not just the Bash-driven ones, since a tree diff
carries every change made in the window whatever produced it. So it is the same misattribution the
in-process guard exists to prevent, across a boundary neither table spans — but wider than that
guard's own case, and wider than anything `request_diff` could produce, since that only ever backed
up files this turn's own tools named. Accepted rather than solved — a _turn_ has no
cross-process identity to compare, so telling "another process is mid-turn in my window" from "a
process crashed here earlier" would mean writing that identity down somewhere, which is a design of
its own. Multiple instances are a normal setup here, so this is worth revisiting rather than
forgetting.

**The in-memory session table is swept the same way, and for the same reason.** `sweep_stale` runs
on every `ensure_baseline` for a new handle — that is, every time _another_ chat in this Neovim
starts a turn — so reaping purely by age would drop the session of a turn still running past the
TTL, which a long agent run reaches routinely. The next tool of that turn would then find no
session and re-baseline against the tree as it stands, so everything it changed before the sweep
falls out of the diff with no warning and no fallback: the silent loss again, through a third door.
It therefore asks `ActiveStreamRegistry` whether the request is still running — the same registry
that tells `ChatBuffer:is_responding()` a run is over — and keeps the TTL only as the outer bound
that stops the table growing when a stream never registered.

**Ref cleanup does cross that boundary, and has to**, because deleting a ref another process is
relying on is an action rather than a misreading. `sweep_refs` guards twice. It first asks the
instance registry whether another live Neovim sits on this root and skips the sweep entirely if so
— the same PID-filtered `registry.list()` that `hook_cleanup` uses to avoid deleting another
process's in-flight `.req`/`.res`. What the registry knows is each instance's own cwd, not which
worktree its chats run in, so it can under-match; the second guard is age, deleting only refs older
than the session TTL. Age alone was not enough — a turn running longer than the TTL, ordinary for a
long agent session, would age into the "leftover" bucket while still live — and the registry alone
is not either, hence both.

The registry entry's `worktree_root` is resolved by `send_message` and passed down as
`opts._worktree_root`; the adapters copy it into the entry the same way they copy `chat_bufnr`.
Resolving it inside `stream()` instead would put a synchronous `git rev-parse` on every stream
start, including the utility calls that produce no diff at all.

**Changes to `.gitignore`d files are invisible to the snapshot only while they are untracked**,
which is the trade that keeps `git add -A` cheap. The distinction is git's, not ours: `.gitignore`
governs what gets _added_, so a file that is already tracked keeps showing its modifications even
when it matches an ignore pattern — verified by committing a file with `add -f` and watching the
next snapshot diff report it. A genuinely untracked build artifact a Write tool reported anyway
still reaches `### Modified Files` through `extra_paths` — listed, with no patch section, matching
what `request_diff.generate` already did for files it could not back up.
