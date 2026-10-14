import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, URL } from 'node:url';
import { validatePaths, validateResult } from '../.github/scripts/codex-publish.mjs';

const publisher = fileURLToPath(new URL('../.github/scripts/codex-publish.mjs', import.meta.url));
const review = {
  status: 'fixed',
  commit_title: 'fix: correct behavior',
  comment: '修正しました。',
};
const issue = {
  status: 'completed',
  pr_title: 'feat: add behavior',
  pr_body: '変更と検証。',
  report: '実装しました。',
};

test('result validation rejects malformed status, blank reports and multiline titles', () => {
  assert.equal(validateResult(review, 'review'), review);
  assert.equal(validateResult(issue, 'issue'), issue);
  for (const value of [
    { ...review, status: 'unknown' },
    { ...review, comment: '' },
    { ...review, commit_title: 'fix: title\nspoofed' },
    { ...review, comment: null },
  ]) {
    assert.throws(() => validateResult(value, 'review'));
  }
});

test('protected paths reject workflow changes and traversal, while ordinary files pass', () => {
  validatePaths(['lua/vibing/init.lua', 'tests/fixture with spaces.lua']);
  for (const path of [
    '.github/workflows/ci.yml',
    '.github/scripts/codex-publish.mjs',
    '../control/script.mjs',
    '/absolute/file',
    '.git/config',
    '.codex-result.json',
  ]) {
    assert.throws(() => validatePaths([path]), path);
  }
});

function scenario(options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'codex-publisher-test-'));
  const bin = join(dir, 'bin');
  const data = join(dir, 'data');
  mkdirSync(bin);
  mkdirSync(data);
  const sha = 'a'.repeat(40);
  const mode = options.mode || 'review';
  const target = {
    number: 7,
    head: { ref: 'feature/test', sha, repo: { full_name: 'owner/repo' } },
    base: { ref: 'main' },
    state: 'open',
  };
  const event = {
    sender: { login: 'shabaraba' },
    label: { name: mode === 'issue' ? 'codex:in-progress' : 'codex:in-review' },
    ...(mode === 'issue' ? { issue: { number: 7 } } : { pull_request: target }),
  };
  if (options.fork) target.head.repo.full_name = 'attacker/repo';
  if (options.sender) event.sender.login = options.sender;
  const current = JSON.parse(JSON.stringify(target));
  if (options.stale) current.head.sha = 'b'.repeat(40);
  if (options.closed) current.state = 'closed';
  writeFileSync(join(dir, 'event.json'), JSON.stringify(event));
  writeFileSync(
    join(data, 'result.json'),
    options.invalid
      ? '{}'
      : JSON.stringify({ ...(mode === 'issue' ? issue : review), ...options.result })
  );
  writeFileSync(join(data, 'changes.patch'), options.empty ? '' : 'fixture patch');
  const log = join(dir, 'calls.jsonl');
  const fake = `#!${process.execPath}
const fs = require("node:fs");
const args = process.argv.slice(2);
const command = require("node:path").basename(process.argv[1]);
fs.appendFileSync(process.env.TEST_LOG, JSON.stringify({ command, args }) + "\\n");
if (command === "gh") {
  if (args[0] === "api") console.log(process.env.TEST_CURRENT);
  if (args[0] === "pr" && args[1] === "create") console.log("https://github.com/owner/repo/pull/8");
  if (args[1] === "comment") {
    fs.writeFileSync(process.env.TEST_COMMENT, fs.readFileSync(args[args.indexOf("--body-file") + 1]));
    if (process.env.TEST_COMMENT_FAIL === "1") process.exit(1);
  }
} else {
  if (args.includes("rev-parse")) console.log(process.env.CODEX_SOURCE_SHA);
  if (args.includes("diff")) process.stdout.write(process.env.TEST_PATHS + "\\0");
  if (args.includes("push") && process.env.TEST_PUSH_FAIL === "1") process.exit(1);
}
`;
  for (const command of ['git', 'gh']) {
    const file = join(bin, command);
    writeFileSync(file, fake);
    chmodSync(file, 0o755);
  }
  const env = {
    ...process.env,
    PATH: bin + ':' + process.env.PATH,
    CODEX_MODE: mode,
    CODEX_WORKER_RESULT: options.worker || 'success',
    CODEX_SOURCE_SHA: sha,
    CODEX_SOURCE_DIR: dir,
    CODEX_DATA_DIR: data,
    GITHUB_EVENT_PATH: join(dir, 'event.json'),
    GITHUB_ACTOR: options.actor || 'shabaraba',
    GITHUB_TRIGGERING_ACTOR: options.triggeringActor || 'shabaraba',
    GITHUB_REPOSITORY: 'owner/repo',
    GITHUB_SERVER_URL: 'https://github.com',
    GITHUB_RUN_ID: '123',
    TEST_LOG: log,
    TEST_CURRENT: JSON.stringify(current),
    TEST_PATHS: options.path || 'lua/file.lua',
    TEST_COMMENT: join(dir, 'comment.md'),
    TEST_PUSH_FAIL: options.pushFail ? '1' : '0',
    TEST_COMMENT_FAIL: options.commentFail ? '1' : '0',
  };
  const result = spawnSync(process.execPath, [publisher], { env, encoding: 'utf8' });
  let calls = [];
  try {
    calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
  } catch {
    /* Unauthorized runs have no calls. */
  }
  let comment = '';
  try {
    comment = readFileSync(env.TEST_COMMENT, 'utf8');
  } catch {
    /* No comment for unauthorized events. */
  }
  return { result, calls, comment };
}

for (const mode of ['issue', 'review']) {
  test(`successful ${mode} publishes only the authorized ref and one Japanese comment`, () => {
    const { result, calls, comment } = scenario({ mode });
    assert.equal(result.status, 0, result.stderr);
    const push = calls.find((call) => call.command === 'git' && call.args.includes('push'));
    assert.ok(push);
    assert.ok(push.args.includes('https://github.com/owner/repo.git'));
    assert.ok(
      push.args.includes(
        mode === 'issue' ? 'HEAD:refs/heads/codex/issue-7-123' : 'HEAD:refs/heads/feature/test'
      )
    );
    assert.ok(!push.args.some((arg) => arg.includes('--force')));
    const commit = calls.find((call) => call.command === 'git' && call.args.includes('commit'));
    assert.ok(commit.args.includes('core.hooksPath=/dev/null'));
    assert.equal(calls.filter((call) => call.args[1] === 'comment').length, 1);
    assert.match(comment, /[実修]/);
    const labels = calls.find((call) => call.args[1] === 'edit').args;
    assert.deepEqual(labels.slice(-2), ['--remove-label', 'codex:failed']);
  });
}

for (const [name, options] of [
  ['blocked', { result: { status: 'blocked' } }],
  ['blocked issue', { mode: 'issue', result: { status: 'blocked' } }],
  ['invalid result', { invalid: true }],
  ['worker failure', { worker: 'failure' }],
  ['worker cancellation', { worker: 'cancelled' }],
  ['stale head', { stale: true }],
  ['closed PR', { closed: true }],
  ['protected workflow change', { path: '.github/workflows/ci.yml' }],
  ['clean status with edits', { result: { status: 'clean' } }],
  ['push failure', { pushFail: true }],
  ['comment failure', { commentFail: true }],
]) {
  test(`${name} fails closed, comments once, and reflects codex:failed`, () => {
    const { result, calls } = scenario(options);
    assert.equal(result.status, 1);
    assert.equal(calls.filter((call) => call.args[1] === 'comment').length, 1);
    const labels = calls.find((call) => call.args[1] === 'edit').args;
    assert.deepEqual(labels.slice(-2), ['--add-label', 'codex:failed']);
    if (!options.pushFail && !options.commentFail) {
      assert.ok(!calls.some((call) => call.command === 'git' && call.args.includes('push')));
    }
  });
}

for (const options of [
  { fork: true },
  { sender: 'attacker' },
  { actor: 'attacker' },
  { triggeringActor: 'attacker' },
]) {
  test(`unauthorized event ${JSON.stringify(options)} performs no GitHub writes`, () => {
    const { result, calls } = scenario(options);
    assert.equal(result.status, 1);
    assert.equal(calls.length, 0);
  });
}

test('clean review posts once without commit or push', () => {
  const { result, calls } = scenario({
    empty: true,
    result: { status: 'clean', commit_title: 'No changes' },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!calls.some((call) => call.command === 'git' && call.args.includes('push')));
  assert.equal(calls.filter((call) => call.args[1] === 'comment').length, 1);
});

test('workflow boundaries remain read-only for Codex and use trusted publisher code', () => {
  const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
  for (const file of ['codex.yml', 'codex-code-review.yml']) {
    const workflow = readFileSync(join(root, '.github/workflows', file), 'utf8');
    const worker = workflow.split('\n  publish:')[0];
    // The setup-labels job owns only issues:write; the execution job is read-only.
    const execution = worker.slice(worker.search(/\n {2}(implement|review):/));
    assert.match(execution, /contents: read/);
    assert.doesNotMatch(execution, /(?:contents|issues|pull-requests): write/);
    assert.match(execution, /persist-credentials: false/);
    assert.match(execution, /safety-strategy: drop-sudo/);
    assert.match(execution, /if \[ -e \.codex \] \|\| \[ -L \.codex \]/);
    assert.ok(
      execution.indexOf('Reject checkout-controlled') <
        execution.indexOf('uses: openai/codex-action@')
    );
    if (file === 'codex-code-review.yml') {
      assert.match(workflow, /pull_request_target:/);
      assert.match(execution, /github.event.pull_request.head.repo.full_name == github.repository/);
      assert.match(execution, /ref: \$\{\{ github.event.pull_request.head.sha \}\}/);
    }
    assert.match(execution, /working-directory: \$\{\{ github.workspace \}\}\/source/);
    assert.match(workflow, /ref: \$\{\{ github.workflow_sha \}\}/);
    assert.match(execution, /github.actor == 'shabaraba'/);
    assert.match(execution, /github.event.sender.login == 'shabaraba'/);
  }
});
