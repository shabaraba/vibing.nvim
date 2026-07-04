#!/usr/bin/env node
// Workspace lifecycle helper for the vibing-workspace-* Claude Code skills.
//
// Manages git-worktree-backed "workspaces" under .vibing/workspace/{active,done}/<id>/,
// each with a meta.yaml (workspace_id, branch, created_at, description, chat_files) and
// a plan.md. This script has no dependency on a running Neovim instance or the vibing.nvim
// Lua runtime — it only needs Node and git, so it can be invoked from any Claude Code skill.
//
// Usage: node vibing-workspace.mjs <subcommand> [args...]
// All subcommands print a single JSON line to stdout on success and exit 0.
// On failure they print a human-readable message to stderr and exit 1.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

function fail(message) {
  process.stderr.write(message + '\n');
  process.exit(1);
}

function run(cmd, args, options = {}) {
  return execFileSync(cmd, args, { encoding: 'utf8', ...options });
}

function tryRun(cmd, args, options = {}) {
  try {
    const stdout = run(cmd, args, options);
    return { ok: true, stdout, stderr: '' };
  } catch (err) {
    return {
      ok: false,
      stdout: err.stdout ? err.stdout.toString() : '',
      stderr: err.stderr ? err.stderr.toString() : err.message,
    };
  }
}

function getGitRoot() {
  const result = tryRun('git', ['rev-parse', '--show-toplevel']);
  if (!result.ok) return null;
  return result.stdout.trim();
}

function getWorkspaceBase() {
  const gitRoot = getGitRoot();
  if (!gitRoot) fail('Not in a git repository');
  return path.join(gitRoot, '.vibing', 'workspace');
}

// ---- meta.yaml (minimal YAML: flat scalars + one list field, mirrors vibing.nvim's
// Frontmatter module so files stay readable/editable by hand) ----

function serializeMeta(data) {
  const lines = [];
  for (const key of ['workspace_id', 'branch', 'created_at', 'description']) {
    if (data[key] !== undefined) lines.push(`${key}: ${data[key]}`);
  }
  lines.push('chat_files:');
  for (const file of data.chat_files || []) {
    lines.push(`  - ${file}`);
  }
  return lines.join('\n') + '\n';
}

function parseMeta(content) {
  const data = { chat_files: [] };
  for (const rawLine of content.split('\n')) {
    const line = rawLine.replace(/\r$/, '');
    const listItem = line.match(/^\s+-\s*(.*)$/);
    if (listItem) {
      data.chat_files.push(listItem[1].trim());
      continue;
    }
    const kv = line.match(/^([\w.]+):\s*(.*)$/);
    if (kv && kv[1] !== 'chat_files') {
      data[kv[1]] = kv[2].trim();
    }
  }
  return data;
}

function readMeta(metaPath) {
  if (!fs.existsSync(metaPath)) return null;
  return parseMeta(fs.readFileSync(metaPath, 'utf8'));
}

function writeMeta(metaPath, data) {
  fs.writeFileSync(metaPath, serializeMeta(data));
}

function planTemplate(description) {
  return `# ${description}\n\n## TODO\n\n- [ ] \n\n## Notes\n`;
}

// ---- branch name validation (mirrors the Lua manager's guard) ----

function isValidBranch(branch) {
  if (!branch) return false;
  if (branch.includes('/') || branch.includes('\\') || branch.includes('..')) return false;
  return true;
}

// ---- counter ----

function nextCounter(base) {
  const counterPath = path.join(base, '.counter');
  fs.mkdirSync(base, { recursive: true });
  let current = 0;
  if (fs.existsSync(counterPath)) {
    current = parseInt(fs.readFileSync(counterPath, 'utf8').trim(), 10) || 0;
  }
  const next = current + 1;
  fs.writeFileSync(counterPath, String(next));
  return next;
}

// ---- git worktree provisioning ----

const CONFIG_FILES_TO_COPY = [
  '.gitignore',
  '.nvmrc',
  '.node-version',
  'package.json',
  'package-lock.json',
  'yarn.lock',
  'pnpm-lock.yaml',
  'tsconfig.json',
  '.eslintrc.json',
  '.eslintrc.js',
  '.prettierrc',
  '.prettierrc.json',
  '.editorconfig',
];

function copyConfigFiles(gitRoot, worktreePath) {
  for (const name of CONFIG_FILES_TO_COPY) {
    const source = path.join(gitRoot, name);
    if (fs.existsSync(source)) {
      fs.copyFileSync(source, path.join(worktreePath, name));
    }
  }
}

function symlinkNodeModules(gitRoot, worktreePath) {
  const source = path.join(gitRoot, 'node_modules');
  if (fs.existsSync(source)) {
    const dest = path.join(worktreePath, 'node_modules');
    if (!fs.existsSync(dest)) {
      fs.symlinkSync(source, dest, 'dir');
    }
  }
}

function branchExists(branch) {
  const result = tryRun('git', ['branch', '--list', branch]);
  return result.ok && result.stdout.trim() !== '';
}

function createGitWorktree(branch, worktreePath) {
  const args = branchExists(branch)
    ? ['worktree', 'add', worktreePath, branch]
    : ['worktree', 'add', '-b', branch, worktreePath];
  return tryRun('git', args);
}

// ---- subcommands ----

function cmdCreate(branch, description) {
  if (!isValidBranch(branch)) fail(`Invalid branch name: ${branch}`);

  const gitRoot = getGitRoot();
  if (!gitRoot) fail('Not in a git repository');
  const base = getWorkspaceBase();

  const number = nextCounter(base);
  const id = `${String(number).padStart(4, '0')}-${branch}`;
  const dir = path.join(base, 'active', id);

  if (fs.existsSync(dir)) fail(`Workspace directory already exists: ${dir}`);
  fs.mkdirSync(dir, { recursive: true });

  const worktreePath = path.join(dir, 'worktree');
  const worktreeResult = createGitWorktree(branch, worktreePath);
  if (!worktreeResult.ok) {
    fs.rmSync(dir, { recursive: true, force: true });
    fail(`Failed to create git worktree: ${worktreeResult.stderr}`);
  }

  copyConfigFiles(gitRoot, worktreePath);
  symlinkNodeModules(gitRoot, worktreePath);

  const metaPath = path.join(dir, 'meta.yaml');
  writeMeta(metaPath, {
    workspace_id: id,
    branch,
    created_at: new Date().toISOString(),
    description,
    chat_files: [],
  });

  const planPath = path.join(dir, 'plan.md');
  fs.writeFileSync(planPath, planTemplate(description));

  console.log(
    JSON.stringify({
      id,
      dir,
      worktree_path: worktreePath,
      meta_path: metaPath,
      plan_path: planPath,
    })
  );
}

function cmdList(status) {
  status = status === 'done' ? 'done' : 'active';
  const base = getWorkspaceBase();
  const statusDir = path.join(base, status);
  if (!fs.existsSync(statusDir)) {
    console.log(JSON.stringify([]));
    return;
  }

  const entries = [];
  for (const name of fs.readdirSync(statusDir).sort()) {
    const dir = path.join(statusDir, name);
    const metaPath = path.join(dir, 'meta.yaml');
    const data = readMeta(metaPath);
    if (data) {
      entries.push({
        id: data.workspace_id,
        branch: data.branch,
        description: data.description,
        dir,
      });
    }
  }
  console.log(JSON.stringify(entries));
}

function findWorkspace(base, workspaceId) {
  for (const status of ['active', 'done']) {
    const dir = path.join(base, status, workspaceId);
    if (fs.existsSync(dir)) {
      const result = {
        id: workspaceId,
        dir,
        status,
        meta_path: path.join(dir, 'meta.yaml'),
        plan_path: path.join(dir, 'plan.md'),
      };
      if (status === 'active') result.worktree_path = path.join(dir, 'worktree');
      return result;
    }
  }
  return null;
}

function cmdGet(workspaceId) {
  const base = getWorkspaceBase();
  const ws = findWorkspace(base, workspaceId);
  if (!ws) fail(`Workspace not found: ${workspaceId}`);
  console.log(JSON.stringify(ws));
}

function cmdAddChatFile(workspaceId, chatFile) {
  const base = getWorkspaceBase();
  const ws = findWorkspace(base, workspaceId);
  if (!ws) fail(`Workspace not found: ${workspaceId}`);

  const data = readMeta(ws.meta_path);
  if (!data) fail(`meta.yaml not found: ${ws.meta_path}`);

  if (!data.chat_files.includes(chatFile)) {
    data.chat_files.push(chatFile);
    writeMeta(ws.meta_path, data);
  }
  console.log(JSON.stringify({ ok: true, chat_files: data.chat_files }));
}

function cmdRemoveWorktree(workspaceId) {
  const base = getWorkspaceBase();
  const ws = findWorkspace(base, workspaceId);
  if (!ws || ws.status !== 'active') fail(`Not an active workspace: ${workspaceId}`);

  // Never pass --force: if git refuses due to uncommitted changes, surface that verbatim
  // so the user can decide (commit/stash) rather than silently discarding their work.
  const result = tryRun('git', ['worktree', 'remove', ws.worktree_path]);
  if (!result.ok) fail(result.stderr || 'git worktree remove failed');
  console.log(JSON.stringify({ ok: true }));
}

function cmdMoveToDone(workspaceId) {
  const base = getWorkspaceBase();
  const ws = findWorkspace(base, workspaceId);
  if (!ws || ws.status !== 'active') fail(`Not an active workspace: ${workspaceId}`);

  const doneDir = path.join(base, 'done');
  fs.mkdirSync(doneDir, { recursive: true });
  const target = path.join(doneDir, workspaceId);
  fs.renameSync(ws.dir, target);
  console.log(JSON.stringify({ ok: true, dir: target }));
}

function planHasIncompleteTodos(planPath) {
  if (!fs.existsSync(planPath)) return false;
  const content = fs.readFileSync(planPath, 'utf8');
  return /^\s*-\s*\[\s*\]/m.test(content);
}

function isBranchMerged(branch) {
  const result = tryRun('git', ['branch', '--merged']);
  if (!result.ok) return false;
  return result.stdout
    .split('\n')
    .map((line) => line.replace(/^\*?\s*/, '').trim())
    .includes(branch);
}

function cmdCheckDone(workspaceId) {
  const base = getWorkspaceBase();
  const ws = findWorkspace(base, workspaceId);
  if (!ws || ws.status !== 'active') fail(`Not an active workspace: ${workspaceId}`);

  const data = readMeta(ws.meta_path);
  console.log(
    JSON.stringify({
      plan_incomplete: planHasIncompleteTodos(ws.plan_path),
      branch_merged: data ? isBranchMerged(data.branch) : false,
    })
  );
}

// ---- dispatch ----

const [, , subcommand, ...args] = process.argv;

switch (subcommand) {
  case 'create':
    cmdCreate(args[0], args.slice(1).join(' '));
    break;
  case 'list':
    cmdList(args[0]);
    break;
  case 'get':
    cmdGet(args[0]);
    break;
  case 'add-chat-file':
    cmdAddChatFile(args[0], args[1]);
    break;
  case 'remove-worktree':
    cmdRemoveWorktree(args[0]);
    break;
  case 'move-to-done':
    cmdMoveToDone(args[0]);
    break;
  case 'check-done':
    cmdCheckDone(args[0]);
    break;
  default:
    fail(
      'Usage: vibing-workspace.mjs <create|list|get|add-chat-file|remove-worktree|move-to-done|check-done> [args...]'
    );
}
