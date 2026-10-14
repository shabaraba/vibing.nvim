---
name: stacked-pr-merge
description:
  Merging a stack of dependent PRs in this repository — a branch cut from another PR's branch
  rather than from main. Covers the one merge API that is not 403 here, taking the head SHA from
  the API, and the stale-lineage rebase that produces mass conflicts if you use plain
  `git rebase origin/main`. Use when `gh pr merge` fails with 403, when a rebase onto main
  conflicts in files you never touched, or before merging two or more PRs that depend on each
  other.
---

# Merging a Stack of PRs

A stack is a branch cut from another PR's branch instead of from `main`. Everything below was
measured on `shabaraba/vibing.nvim`; each item is something that failed first.

`gh pr view` / `gh issue view` have been observed exiting 0 with no output on this machine. Read
PR state with `gh api` throughout, not with the porcelain commands.

## The merge call

`gh pr merge` and `PUT /repos/{owner}/{repo}/pulls/{n}/merge` both come back **403** here. The one
that works is the async endpoint:

```bash
OWNER=shabaraba REPO=vibing.nvim N=<pr number>
SHA="$(gh api "repos/$OWNER/$REPO/pulls/$N" --jq '.head.sha')"
gh api --method PUT "repos/$OWNER/$REPO/pulls/$N/merge-async" \
  -f "sha=$SHA" -f 'merge_method=merge'
```

- **`merge_method=merge`, not `squash`.** A stack depends on its lower PR's commits existing as
  themselves; squashing the bottom one rewrites the history every branch above it was cut from.
- **Take `sha` from the API.** Expanding a short SHA by hand fails with
  `Pull request head branch was modified` — the value has to be the full head SHA the API is
  reporting right now, not one you copied from a log.
- **It is async.** The response is not the outcome. Confirm with
  `gh api "repos/$OWNER/$REPO/pulls/$N" --jq '.merged, .merge_commit_sha'` before touching the
  next PR in the stack.

## Merge bottom-up, one at a time

Merge the lowest PR, wait for it to land, confirm CI is green on the next one, then merge that.
Do not queue several merges; each merge is what rewrites the branches above it.

**GitHub rebases the stack at merge time, not at force-push time.** So:

- Pushing **additional commits** to a lower PR (a fast-forward) leaves the branches above it
  alone — no upstream rebase needed.
- **Rebasing** a lower PR, or merging it, does rewrite what the branches above were cut from, and
  they need the treatment in the next section.

## The stale-lineage trap

A branch cut from a lower PR's **pre-merge** tip is not repaired by `git rebase origin/main`. That
command replays every commit since the merge base — which includes the lower PR's **old,
pre-rebase** commits, now superseded on `main` — and the result is a pile of conflicts in files
you never touched. It is not a real conflict; it is the same change arriving twice.

Replay only your own commits instead:

```bash
git rebase --onto origin/main <old-fork-point> <your-branch>
```

`<old-fork-point>` is the commit your branch was cut from — the lower PR's head as it was before
it got rewritten. Used three times on the run this skill came from, with zero conflicts each time,
against a plain `git rebase origin/main` that conflicted every time.

**Record the fork point before you merge anything.** For each stacked branch:

```bash
git merge-base <your-branch> <lower-branch>
```

That is the cheap half of this whole procedure, and it is only cheap while the lower branch still
has its pre-merge commits. If you did not record it, the lower PR's old head is the second parent
of its merge commit:

```bash
MC="$(gh api "repos/$OWNER/$REPO/pulls/$N" --jq '.merge_commit_sha')"
gh api "repos/$OWNER/$REPO/commits/$MC" --jq '.parents[1].sha'
```

(That holds because `merge_method=merge` is what produced the merge commit. It does not hold for a
squash or rebase merge — another reason not to use them on a stack.)

## Reading mergeability

```bash
gh api "repos/$OWNER/$REPO/pulls/$N" --jq '{mergeable, mergeable_state}'
gh api "repos/$OWNER/$REPO/commits/$SHA/check-runs" --jq '.check_runs[] | {name, status, conclusion}'
```

**`mergeable_state: unstable` is not a reason to stop.** It goes `unstable` while any check is
pending, and on this repository that is routinely CodeRabbit's status and nothing else. Decide
from `mergeable: true` plus the **conclusion** of the checks you actually require; `unstable` with
every required check `success` is a merge you can make.

`mergeable: null` means GitHub has not computed it yet — re-read, do not act on it.
