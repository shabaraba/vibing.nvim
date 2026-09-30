#!/usr/bin/env node
/**
 * Pins scripts/audit-mcp-server-imports.mjs (#792): `zod` was imported as a value by four files
 * under claude-plugin/mcp-server/src while nothing in claude-plugin/mcp-server/package.json
 * declared it, and every path that ran the suite happened to install the repository root first,
 * which resolves it from there by Node's own upward directory walk. A tree with no such upstream
 * `node_modules` -- the shape claude-plugin/ is actually distributed as -- crashes at runtime
 * instead.
 *
 * These tests run the real script against throwaway trees rather than asserting on its source, so
 * a change to the regex or the declared-dependency check is caught by behaviour, not by reading
 * the diff.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm } from 'fs/promises';
import { dirname, join } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const script = join(repoRoot, 'scripts/audit-mcp-server-imports.mjs');

/** A throwaway `<dir>/package.json` + `<dir>/src/*` tree, with the real script run against it. */
async function runAudit({ dependencies = {}, devDependencies = {}, files }) {
  const dir = await mkdtemp(join(tmpdir(), 'vibing-mcp-import-audit-'));
  try {
    await mkdir(join(dir, 'src'), { recursive: true });
    await writeFile(
      join(dir, 'package.json'),
      JSON.stringify({ name: 'scratch', dependencies, devDependencies })
    );
    for (const [name, body] of Object.entries(files)) {
      const full = join(dir, 'src', name);
      await mkdir(dirname(full), { recursive: true });
      await writeFile(full, body);
    }
    return spawnSync(process.execPath, [script, dir], { encoding: 'utf8' });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('fails on a runtime import with no declared dependency', async () => {
  const result = await runAudit({
    dependencies: {},
    files: { 'index.ts': "import { z } from 'zod';\nz.object({});\n" },
  });
  assert.notEqual(result.status, 0, 'an undeclared value import did not fail the audit');
  assert.match(result.stderr, /zod/);
  assert.match(result.stderr, /index\.ts/);
});

test('passes when the import is declared in dependencies', async () => {
  const result = await runAudit({
    dependencies: { zod: '^4.6.5' },
    files: { 'index.ts': "import { z } from 'zod';\nz.object({});\n" },
  });
  assert.equal(result.status, 0, result.stderr);
});

test('a devDependency does not satisfy a non-test file', async () => {
  // `vitest` is a devDependency everywhere in this repository; if it also satisfied ordinary
  // source files, a runtime dependency shipped only in devDependencies -- installed in CI and
  // stripped in a production install -- would pass here and crash the same way `zod` did.
  const result = await runAudit({
    devDependencies: { zod: '^4.6.5' },
    files: { 'index.ts': "import { z } from 'zod';\nz.object({});\n" },
  });
  assert.notEqual(result.status, 0, 'a devDependency-only package satisfied a non-test import');
});

test('a devDependency does satisfy a test file', async () => {
  const result = await runAudit({
    devDependencies: { vitest: '^5.0.1' },
    files: {
      '__tests__/index.test.ts': "import { test } from 'vitest';\ntest('ok', () => {});\n",
    },
  });
  assert.equal(result.status, 0, result.stderr);
});

test('relative imports and node builtins are never flagged', async () => {
  const result = await runAudit({
    files: {
      'util.ts': 'export const x = 1;\n',
      'index.ts':
        "import { x } from './util.js';\n" +
        "import { readFileSync } from 'node:fs';\n" +
        "import * as path from 'path';\n" +
        'console.log(x, readFileSync, path);\n',
    },
  });
  assert.equal(result.status, 0, result.stderr);
});

test('fails on an undeclared import written across multiple lines', async () => {
  // The first version of this script excluded `\n` from the body between "import" and "from",
  // which matched single-line imports only -- so reformatting the identical undeclared import onto
  // several lines (a named-import block a formatter is free to wrap) silently passed.
  const result = await runAudit({
    dependencies: {},
    files: {
      'index.ts': "import {\n  z,\n} from 'zod';\n\nz.object({});\n",
    },
  });
  assert.notEqual(result.status, 0, 'a multi-line undeclared import was not flagged');
  assert.match(result.stderr, /zod/);
});

test('prose that contains the word "from" is not mistaken for an import', async () => {
  // The first version of this script matched `from\s+['"]...['"]` anywhere in the file, which
  // read a comment like this one -- distinguishing "queued" from "sent" -- as `import ... from
  // 'sent'`, and treated the un-terminated quote as extending across the following lines until
  // a later, unrelated quote closed it.
  const result = await runAudit({
    files: {
      'index.ts':
        '// The caller can tell "queued" from "sent", and only this layer decides the wording.\n' +
        "export const ok = 'sent';\n",
    },
  });
  assert.equal(result.status, 0, result.stderr);
});
