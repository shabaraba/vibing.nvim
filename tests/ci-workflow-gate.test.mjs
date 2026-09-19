#!/usr/bin/env node
/**
 * Nothing held .github/workflows/ci.yml and package.json to each other, so the two could drift
 * in silence. The dangerous direction is not a gate that starts shouting -- it is a gate that
 * stops shouting:
 *
 *   - `continue-on-error: true` lands on a step. That step still runs, still prints its failure,
 *     and the job still goes green. `lint:md` carries it deliberately (the Markdown backlog is
 *     tracked as a count, not as a gate); anywhere else it is a gate that quietly resigned.
 *   - A step restates a command instead of calling `npm run <script>`. Then editing the script
 *     changes what a developer runs and not what CI runs, which is the same dead-gate shape as
 *     #561: the command in CI keeps passing because it is no longer the command being maintained.
 *   - A script `npm test` runs has no CI step at all. That is how the MCP server's 193 vitest
 *     tests sat in no gate until #790.
 *
 * Both files are read at run time rather than restated here, so these tests cannot pass against
 * a workflow or a script list the project no longer has.
 */

import { strict as assert } from 'assert';
import { test } from 'node:test';
import { readFile } from 'fs/promises';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const workflow = await readFile(join(repoRoot, '.github/workflows/ci.yml'), 'utf8');
const scripts = JSON.parse(await readFile(join(repoRoot, 'package.json'), 'utf8')).scripts;

/**
 * The steps of the workflow, each with its scalar keys and the full text of its `run:` body.
 *
 * Deliberately a line scanner rather than a YAML parse: the repository has no YAML dependency,
 * and adding one to read four keys would put this test behind an install. The positive controls
 * below are what stop a scanner that silently matched nothing from passing.
 */
function parseSteps(yaml) {
  const steps = [];
  let current = null;
  for (const line of yaml.split('\n')) {
    const start = line.match(/^(\s*)- ([\w-]+):[ ]?(.*)$/);
    if (start) {
      current = { indent: start[1].length + 2, keys: { [start[2]]: start[3] }, run: [] };
      if (start[2] === 'run') current.run.push(start[3]);
      steps.push(current);
      continue;
    }
    if (!current) continue;
    const key = line.match(/^(\s*)([\w-]+):[ ]?(.*)$/);
    if (key && key[1].length === current.indent) {
      current.key = key[2];
      current.keys[key[2]] = key[3];
      if (key[2] === 'run') current.run.push(key[3]);
      continue;
    }
    // A block scalar's body, or a nested mapping under the key we last saw.
    if (line.trim() !== '' && line.search(/\S/) > current.indent) {
      if (current.key === 'run') current.run.push(line.trim());
      continue;
    }
    if (line.trim() !== '' && line.search(/\S/) <= current.indent - 2) current = null;
  }
  return steps;
}

const steps = parseSteps(workflow);
const runLines = steps.flatMap((s) => s.run).filter((l) => l !== '' && l !== '|' && l !== '>');

test('the step scanner found the workflow it was pointed at', () => {
  // Positive control. Every assertion below is of the form "no step does X", which an empty or
  // broken parse satisfies for free.
  assert.ok(steps.length >= 15, `parsed ${steps.length} steps -- the scanner lost the file`);
  assert.ok(
    steps.some((s) => s.keys.name === 'Run Lua tests'),
    'no step named "Run Lua tests" -- the scanner is not reading step names'
  );
  assert.ok(runLines.length >= 15, `parsed ${runLines.length} run lines`);
});

test('only the Markdown lint step is allowed to fail without failing the job', () => {
  const exempt = steps
    .filter((s) => s.keys['continue-on-error'] === 'true')
    .map((s) => s.keys.name ?? s.keys.uses ?? s.keys.run);

  assert.deepEqual(
    exempt,
    ['Lint Markdown files'],
    'a step other than the Markdown lint carries continue-on-error, or that one lost it'
  );
});

test('every script npm test runs is also a CI step', () => {
  const chained = [...scripts.test.matchAll(/npm run ([\w:-]+)/g)].map((m) => m[1]);
  assert.ok(chained.length > 0, `no scripts parsed out of "${scripts.test}"`);

  for (const name of chained) {
    assert.ok(
      runLines.some((line) => line === `npm run ${name}`),
      `\`npm test\` runs ${name} but no CI step does`
    );
  }
});

test('CI calls npm run <script> instead of restating a script body', () => {
  const byBody = new Map(Object.entries(scripts).map(([name, body]) => [body, name]));

  for (const line of runLines) {
    const name = byBody.get(line);
    assert.equal(
      name,
      undefined,
      `a CI step spells out the body of the "${name}" script; call \`npm run ${name}\` instead, ` +
        'or editing the script stops changing what CI runs'
    );
  }
});
