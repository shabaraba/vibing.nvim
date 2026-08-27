#!/usr/bin/env node
/**
 * Test that `list-commands` scans the plugin directories handed to it on argv.
 *
 * vibing.nvim no longer installs its Claude Code plugin into the user scope — it passes
 * `--plugin-dir` per session (see lua/vibing/infrastructure/plugins/plugin_dirs.lua). Those
 * plugins are invisible to ~/.claude/plugins/installed_plugins.json by construction, so without
 * the argv path the `/` picker would be blind to skills the CLI itself loads perfectly well.
 *
 * This runs the built dist/bin/list-commands.js rather than reimplementing its logic, because
 * that binary is what skills.lua actually spawns. HOME is pointed at a temp directory so the
 * developer's own installed plugins cannot make an assertion pass or fail by accident.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { execFile } from 'child_process';
import { mkdir, writeFile, mkdtemp, rm } from 'fs/promises';
import { join, dirname } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);
const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = join(REPO_ROOT, 'dist', 'bin', 'list-commands.js');

/** Create a plugin directory declaring `name` and carrying one skill. */
async function writePlugin(dir, name, skillName, description) {
  await mkdir(join(dir, '.claude-plugin'), { recursive: true });
  await writeFile(join(dir, '.claude-plugin', 'plugin.json'), JSON.stringify({ name }));
  await mkdir(join(dir, 'skills', skillName), { recursive: true });
  await writeFile(
    join(dir, 'skills', skillName, 'SKILL.md'),
    `---\nname: ${skillName}\ndescription: ${description}\n---\n\nBody.\n`
  );
}

/** Run the built script with `dirs` as argv and a throwaway HOME. */
async function listCommands(home, dirs) {
  const { stdout } = await execFileAsync(process.execPath, [SCRIPT, ...dirs], {
    env: { ...process.env, HOME: home },
    cwd: home,
  });
  return JSON.parse(stdout);
}

test('list-commands surfaces skills from a directory passed on argv', async () => {
  const root = await mkdtemp(join(tmpdir(), 'vibing-list-commands-'));
  try {
    const home = join(root, 'home');
    await mkdir(home, { recursive: true });
    const plugin = join(root, 'my-plugin');
    await writePlugin(plugin, 'my-plugin', 'do-a-thing', 'Does a thing.');

    const commands = await listCommands(home, [plugin]);
    const entry = commands.find((c) => c.name === 'my-plugin:do-a-thing');

    assert.ok(entry, 'skill from the argv plugin directory is missing');
    assert.equal(entry.description, 'Does a thing.');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('a block scalar description is read, not its `>-` header', async () => {
  const root = await mkdtemp(join(tmpdir(), 'vibing-list-commands-'));
  try {
    const home = join(root, 'home');
    await mkdir(home, { recursive: true });
    const plugin = join(root, 'my-plugin');
    await mkdir(join(plugin, '.claude-plugin'), { recursive: true });
    await writeFile(join(plugin, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'p' }));
    await mkdir(join(plugin, 'skills', 'folded'), { recursive: true });
    // Wrapping a long description in a folded block is ordinary YAML, and reading the line the
    // key is on gave ">-" as the whole description in the `/` picker.
    await writeFile(
      join(plugin, 'skills', 'folded', 'SKILL.md'),
      [
        '---',
        'name: folded',
        'description: >-',
        '  First line of the description.',
        '  TRIGGER: second line.',
        'user-invocable: true',
        '---',
        '',
        'Body.',
        '',
      ].join('\n')
    );

    const commands = await listCommands(home, [plugin]);
    const entry = commands.find((c) => c.name === 'p:folded');

    assert.ok(entry, 'skill with a folded description is missing');
    assert.equal(entry.description, 'First line of the description. TRIGGER: second line.');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('a block scalar does not swallow the keys after it', async () => {
  const root = await mkdtemp(join(tmpdir(), 'vibing-list-commands-'));
  try {
    const home = join(root, 'home');
    await mkdir(home, { recursive: true });
    const plugin = join(root, 'my-plugin');
    await mkdir(join(plugin, '.claude-plugin'), { recursive: true });
    await writeFile(join(plugin, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'p' }));
    await mkdir(join(plugin, 'skills', 'hidden'), { recursive: true });
    await writeFile(
      join(plugin, 'skills', 'hidden', 'SKILL.md'),
      [
        '---',
        'description: |',
        '  Literal block.',
        'user-invocable: false',
        'name: hidden',
        '---',
        '',
      ].join('\n')
    );

    const commands = await listCommands(home, [plugin]);

    assert.ok(!commands.some((c) => c.name === 'p:hidden'), 'user-invocable: false was not seen');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('list-commands namespaces by the manifest name, not the directory name', async () => {
  const root = await mkdtemp(join(tmpdir(), 'vibing-list-commands-'));
  try {
    const home = join(root, 'home');
    await mkdir(home, { recursive: true });
    // Claude Code namespaces a skill as `<plugin.json name>:<skill>` regardless of where the
    // directory sits, which matters most for vibing.nvim itself: the directory is
    // `claude-plugin/` and the plugin is `vibing-nvim`.
    const plugin = join(root, 'some-checkout-dir');
    await writePlugin(plugin, 'declared-name', 'a-skill', 'Desc.');

    const commands = await listCommands(home, [plugin]);

    assert.ok(commands.some((c) => c.name === 'declared-name:a-skill'));
    assert.ok(!commands.some((c) => c.name === 'some-checkout-dir:a-skill'));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('list-commands skips an argv directory with no readable manifest', async () => {
  const root = await mkdtemp(join(tmpdir(), 'vibing-list-commands-'));
  try {
    const home = join(root, 'home');
    await mkdir(home, { recursive: true });

    const noManifest = join(root, 'no-manifest');
    await mkdir(join(noManifest, 'skills', 'orphan'), { recursive: true });
    await writeFile(
      join(noManifest, 'skills', 'orphan', 'SKILL.md'),
      '---\nname: orphan\ndescription: Orphaned.\n---\n'
    );

    const broken = join(root, 'broken');
    await mkdir(join(broken, '.claude-plugin'), { recursive: true });
    await writeFile(join(broken, '.claude-plugin', 'plugin.json'), '{ not json');

    // A directory that does not exist at all must not take the process down either — the CLI
    // itself ignores one silently, so completion refusing to produce any list would be worse.
    const commands = await listCommands(home, [noManifest, broken, join(root, 'absent')]);

    assert.ok(!commands.some((c) => c.name.includes('orphan')));
    assert.ok(
      commands.some((c) => c.name === 'compact'),
      'built-in commands still listed'
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('an argv plugin wins over an installed one of the same name', async () => {
  const root = await mkdtemp(join(tmpdir(), 'vibing-list-commands-'));
  try {
    const home = join(root, 'home');
    const installed = join(root, 'installed');
    await writePlugin(installed, 'dup', 'from-installed', 'Installed copy.');
    await mkdir(join(home, '.claude', 'plugins'), { recursive: true });
    await writeFile(
      join(home, '.claude', 'plugins', 'installed_plugins.json'),
      JSON.stringify({
        version: 1,
        plugins: {
          'dup@somewhere': [
            {
              scope: 'user',
              installPath: installed,
              version: '1.0.0',
              installedAt: '2026-01-01T00:00:00Z',
              lastUpdated: '2026-01-01T00:00:00Z',
              gitCommitSha: 'abc',
            },
          ],
        },
      })
    );

    const session = join(root, 'session');
    await writePlugin(session, 'dup', 'from-session', 'Session copy.');

    // This mirrors the CLI, where the earlier --plugin-dir wins outright and the loser's skills
    // never load. Listing both would offer a `/dup:from-installed` that cannot be invoked.
    const commands = await listCommands(home, [session]);

    assert.ok(commands.some((c) => c.name === 'dup:from-session'));
    assert.ok(!commands.some((c) => c.name === 'dup:from-installed'));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('with no argv directories, installed plugins are still scanned', async () => {
  const root = await mkdtemp(join(tmpdir(), 'vibing-list-commands-'));
  try {
    const home = join(root, 'home');
    const installed = join(root, 'installed');
    await writePlugin(installed, 'legacy', 'still-here', 'Installed skill.');
    await mkdir(join(home, '.claude', 'plugins'), { recursive: true });
    await writeFile(
      join(home, '.claude', 'plugins', 'installed_plugins.json'),
      JSON.stringify({
        version: 1,
        plugins: {
          'legacy@market': [
            {
              scope: 'user',
              installPath: installed,
              version: '1.0.0',
              installedAt: '2026-01-01T00:00:00Z',
              lastUpdated: '2026-01-01T00:00:00Z',
              gitCommitSha: 'abc',
            },
          ],
        },
      })
    );

    const commands = await listCommands(home, []);

    assert.ok(commands.some((c) => c.name === 'legacy:still-here'));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
