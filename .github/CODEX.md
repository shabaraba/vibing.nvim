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

Codex runs with the official `:workspace` permission profile. It can inspect and edit the checkout
but has no direct network access. Dependencies and GitHub context are prepared before the Codex
step, while fixed workflow scripts own commits, pushes, pull-request creation, comments, and label
transitions after Codex exits.

The workflows deliberately skip `npm run test:e2e` and `npm run test:eval` in unattended runs
because those suites spend model tokens.
