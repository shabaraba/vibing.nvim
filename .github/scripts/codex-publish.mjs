import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, lstatSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
export function validateResult(value, mode) {
  const statuses = mode === 'issue' ? ['completed', 'blocked'] : ['clean', 'fixed', 'blocked'];
  const fields = mode === 'issue' ? ['pr_title', 'pr_body', 'report'] : ['commit_title', 'comment'];
  if (
    !value ||
    !statuses.includes(value.status) ||
    fields.some(
      (key) => typeof value[key] !== 'string' || !value[key].trim() || value[key].length > 50000
    )
  ) {
    throw new Error('Invalid structured result');
  }
  const title = value[mode === 'issue' ? 'pr_title' : 'commit_title'];
  if (
    (value.status === 'completed' || value.status === 'fixed') &&
    (!/^[a-z]+(?:\([a-z0-9/-]+\))?!?: [^\r\n]+$/.test(title) || title.length > 200)
  ) {
    throw new Error('Invalid Conventional Commit title');
  }
  return value;
}
export function validatePaths(paths) {
  if (
    paths.some(
      (path) =>
        path === '.github' ||
        path.startsWith('.github/') ||
        path.split('/').some((part) => part === '..' || part === '.git') ||
        path.startsWith('/') ||
        path.startsWith('.codex-')
    )
  ) {
    throw new Error('Automation or control-file changes require human review');
  }
}
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  if (result.error || result.status !== 0) {
    // Do not copy subprocess output containing untrusted workflow commands into the log.
    throw new Error(`${command} failed`);
  }
  return result.stdout.trimEnd();
}
export function publish(env = process.env) {
  const mode = env.CODEX_MODE;
  if (!['issue', 'review'].includes(mode)) throw new Error('Invalid mode');
  const event = JSON.parse(readFileSync(env.GITHUB_EVENT_PATH, 'utf8'));
  const target = mode === 'issue' ? event.issue : event.pull_request;
  if (
    event.sender?.login !== 'shabaraba' ||
    env.GITHUB_ACTOR !== 'shabaraba' ||
    env.GITHUB_TRIGGERING_ACTOR !== 'shabaraba' ||
    event.label?.name !== (mode === 'issue' ? 'codex:in-progress' : 'codex:in-review') ||
    !Number.isSafeInteger(target?.number) ||
    (mode === 'review' && target.head?.repo?.full_name !== env.GITHUB_REPOSITORY)
  ) {
    throw new Error('Unauthorized event');
  }
  const repo = env.GITHUB_REPOSITORY;
  const number = String(target.number);
  const active = mode === 'issue' ? 'codex:in-progress' : 'codex:in-review';
  const temp = mkdtempSync(join(tmpdir(), 'codex-publish-'));
  const report = join(temp, 'report.md');
  const gh = (args) => run('gh', args, { env });
  let failed = true;
  let message = `Codex の処理に失敗しました。ログ: ${env.GITHUB_SERVER_URL}/${repo}/actions/runs/${env.GITHUB_RUN_ID}`;
  try {
    if (env.CODEX_WORKER_RESULT !== 'success') throw new Error('Worker failed');
    const data = env.CODEX_DATA_DIR;
    for (const name of ['result.json', 'changes.patch']) {
      const stat = lstatSync(join(data, name));
      if (!stat.isFile() || stat.size > 10 * 1024 * 1024) throw new Error('Invalid transfer file');
    }
    const result = validateResult(
      JSON.parse(readFileSync(join(data, 'result.json'), 'utf8')),
      mode
    );
    message = result[mode === 'issue' ? 'report' : 'comment'];
    if (result.status !== 'blocked') {
      const cwd = resolve(env.CODEX_SOURCE_DIR);
      // Source is a fresh checkout; never execute its scripts, hooks, or filters with a token.
      const git = (args, authenticated = false) =>
        run(
          'git',
          [
            '-c',
            'core.hooksPath=/dev/null',
            '-c',
            'core.fsmonitor=false',
            '-c',
            'credential.helper=',
            ...(authenticated ? ['-c', 'credential.helper=!gh auth git-credential'] : []),
            ...args,
          ],
          { cwd, env: { ...env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' } }
        );
      if (git(['rev-parse', 'HEAD']) !== env.CODEX_SOURCE_SHA)
        throw new Error('Unexpected source SHA');
      let branch;
      if (mode === 'review') {
        const current = JSON.parse(gh(['api', `repos/${repo}/pulls/${number}`]));
        branch = current.head?.ref;
        if (
          current.state !== 'open' ||
          current.head?.repo?.full_name !== repo ||
          current.head?.sha !== env.CODEX_SOURCE_SHA ||
          branch !== target.head.ref ||
          branch === current.base.ref
        ) {
          throw new Error('PR changed after authorization');
        }
      } else {
        branch = `codex/issue-${number}-${env.GITHUB_RUN_ID}`;
      }
      git(['check-ref-format', '--branch', branch]);
      const patch = readFileSync(join(data, 'changes.patch'), 'utf8');
      if (patch.trim()) {
        git(['apply', '--check', '--index', join(data, 'changes.patch')]);
        git(['apply', '--index', join(data, 'changes.patch')]);
        validatePaths(git(['diff', '--cached', '--name-only', '-z']).split('\0').filter(Boolean));
        if (mode === 'review' && result.status !== 'fixed')
          throw new Error('Review status does not authorize fixes');
        git(['config', 'user.name', 'github-actions[bot]']);
        git(['config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com']);
        git(['commit', '-m', result[mode === 'issue' ? 'pr_title' : 'commit_title']]);
        // Explicit URL and refspec, no force push and no PR-controlled remote.
        git(['push', `${env.GITHUB_SERVER_URL}/${repo}.git`, `HEAD:refs/heads/${branch}`], true);
        if (mode === 'issue') {
          const body = join(temp, 'body.md');
          writeFileSync(body, result.pr_body + `\n\nFixes #${number}\n`);
          const url = gh([
            'pr',
            'create',
            '--repo',
            repo,
            '--base',
            'main',
            '--head',
            branch,
            '--title',
            result.pr_title,
            '--body-file',
            body,
          ]);
          message += `\n\n実装PR: ${url}`;
        }
      }
      failed = false;
    }
  } catch {
    message += '\n\n安全な公開を完了できませんでした。Actions のログと差分を確認してください。';
  }
  // Exactly one comment attempt, including blocked and failure cases. Label reflection still
  // runs if comment posting fails; never retry by creating a second comment.
  writeFileSync(report, message);
  try {
    gh([
      mode === 'issue' ? 'issue' : 'pr',
      'comment',
      number,
      '--repo',
      repo,
      '--body-file',
      report,
    ]);
  } catch {
    failed = true;
  }
  gh([
    'label',
    'create',
    'codex:failed',
    '--repo',
    repo,
    '--force',
    '--color',
    'D73A4A',
    '--description',
    'The latest Codex run failed or needs input',
  ]);
  const args = [
    mode === 'issue' ? 'issue' : 'pr',
    'edit',
    number,
    '--repo',
    repo,
    '--remove-label',
    active,
  ];
  args.push(failed ? '--add-label' : '--remove-label', 'codex:failed');
  gh(args);
  if (failed) throw new Error('Codex automation failed or requires input');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    publish();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
