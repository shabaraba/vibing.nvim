# Codex label-driven automation

The repository has two opt-in Codex workflows:

- Add `codex:in-progress` to an issue to let Codex implement it and open a pull request.
- Add `codex:in-review` to a same-repository pull request to let Codex review it, push
  high-confidence fixes to that branch, and post one Japanese review comment.

Only label events initiated by `shabaraba` are accepted. The implementation workflow creates or
updates `codex:in-progress`, `codex:in-review`, and `codex:failed` after it lands on `main`; it can
also be run manually once to set them up.

## Required secret

Create the repository Actions secret `OPENAI_API_KEY`. The official `openai/codex-action` uses it
through its Responses API proxy; a ChatGPT or Codex subscription login is not a replacement for
this secret.

## Execution boundary

Codex runs once with the official `:workspace` permission profile and `drop-sudo`, on a job with
read-only GitHub permissions and no persisted checkout credentials. Dependency lifecycle scripts
are disabled; the action runs outside the source checkout so PR-controlled npm configuration
cannot affect its own installation. Its Codex home is outside the checkout too. Checkouts with a
`.codex` directory or symlink are refused before the secret is used, so project-controlled profiles,
MCP servers, and hooks cannot change the runtime policy.

The review uses `pull_request_target` only to load trusted base-branch workflow code. Sender,
actor, and `github.triggering_actor` must all be `shabaraba`; a rerun by anyone else is skipped.
Forks are rejected, and the source checkout is pinned to the head
SHA authorized by that label event. Issue/PR context and repository guidance remain untrusted
model input; prompt instructions alone are not the credential boundary.

A separate, fresh publishing job receives only a patch and structured JSON. It runs the fixed
publisher from the workflow's trusted SHA and never executes scripts from the proposed changes.
It validates the result and paths, disables git hooks, rechecks the PR head, and pushes an explicit
refspec without force. Changes to `.github/`, new or modified symlinks, and submodule entries
require human review and produce `codex:failed`. Unchanged repository symlinks are allowed.
Reviewing a PR whose head is its base branch is also refused. No GitHub write token is available
on the Codex runner. Git authentication is supplied only to fixed context-fetch/push commands.

Success removes the active label and `codex:failed`; blocked, invalid, stale-head, or failed runs
remove the active label and add `codex:failed`. The publisher attempts exactly one Japanese
comment, including on failure. A failure of GitHub itself or runner provisioning can prevent
comment/label delivery; consult Actions logs in that case. Dependencies and fast checks may fail
offline, in which case the agent must report the limitation rather than claim validation.

The `GITHUB_TOKEN`-created push/PR does not start ordinary push/PR workflows. Inspect the reported
checks and explicitly arrange CI before merging the generated PR. Branch protection and Actions
settings must allow the bot to create a PR and push fixes; never bypass those policies.

The workflows deliberately skip `npm run test:e2e` and `npm run test:eval` in unattended runs
because those suites spend model tokens.
