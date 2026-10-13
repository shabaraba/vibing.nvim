import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, URL } from 'node:url';
import test from 'node:test';

const probe = fileURLToPath(new URL('./background_subagent_lifetime.py', import.meta.url));
function python(code) {
  const result = spawnSync(
    'python3',
    [
      '-B',
      '-c',
      `
import importlib.util, json, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location('probe', ${JSON.stringify(probe)})
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
${code}
`,
    ],
    { encoding: 'utf8' }
  );
  if (result.status !== 0) throw new Error(result.stderr);
  return JSON.parse(result.stdout);
}

test('counts cached input and cumulative modelUsage once across resume/replay', () => {
  const result = python(`
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder) / 'stream.jsonl'
    def assistant(id, usage):
        return {'type': 'assistant', 'session_id': 'session',
                'message': {'id': id, 'usage': usage}}
    def final(input, create, read, output):
        return {'type': 'result', 'session_id': 'session', 'modelUsage': {'haiku': {
            'inputTokens': input, 'cacheCreationInputTokens': create,
            'cacheReadInputTokens': read, 'outputTokens': output}}}
    first = assistant('m1', {'input_tokens': 1, 'cache_creation_input_tokens': 20,
                            'cache_read_input_tokens': 10, 'output_tokens': 4})
    second = assistant('m2', {'input_tokens': 1, 'cache_creation_input_tokens': 5,
                             'cache_read_input_tokens': 10, 'output_tokens': 4})
    records = [first, first, final(1,20,10,100), second, final(3,25,24,200), first]
    path.write_text('\\n'.join(json.dumps(r) for r in records))
    u = m.usage([path, path])
    print(json.dumps([u['input'], u['output'], u['messages']]))
`);
  assert.deepEqual(result, [52, 200, 2]);
});

test('does not infer survival from old recoverable output or invalid exit cells', () => {
  const result = python(`
base = dict(forced=False, exit_code=0, background_started=True, started=True,
            done_at_exit=False, done_after_exit=False)
reports = [base, dict(base, done_after_exit=True), dict(base, done_at_exit=True),
           dict(base, forced=True), dict(base, exit_code=1),
           dict(base, background_started=False), dict(base, started=False)]
print(json.dumps([m.classify(r) for r in reports]))
`);
  assert.deepEqual(result, [
    'no continuation observed within window',
    'continued: separate Write after parent exit',
    'inconclusive: completed before exit',
    'inconclusive: forced or failed exit',
    'inconclusive: forced or failed exit',
    'inconclusive: no confirmed background work',
    'inconclusive: no confirmed background work',
  ]);
});

test('requires explicit opt-in before running the real CLI', () => {
  const folder = mkdtempSync(join(tmpdir(), 'vibing-no-cli-'));
  // Mutation of the opt-in guard must fail safely, never run a paid CLI turn.
  writeFileSync(join(folder, 'claude'), '#!/bin/sh\nexit 79\n', { mode: 0o755 });
  try {
    const result = spawnSync('python3', ['-B', probe], {
      env: { ...process.env, VIBING_PERF: '', PATH: `${folder}:${process.env.PATH}` },
      encoding: 'utf8',
    });
    assert.equal(result.status, 0);
    assert.match(result.stdout, /set VIBING_PERF=1 only after approval/);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test('reserves a full cell or in-flight request before the input cap', () => {
  const result = python(`
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder) / 'stream.jsonl'
    probe = m.Probe(Path(folder))
    probe.streams = [path]
    decisions = []
    for input, reserve in [(203882, m.CELL_INPUT_RESERVE), (285000, m.REQUEST_INPUT_RESERVE),
                           (260000, m.RECOVERY_INPUT_RESERVE), (100000, m.CELL_INPUT_RESERVE)]:
        path.write_text(json.dumps({'type':'result','session_id':'s','modelUsage':{
            'haiku':{'inputTokens':input,'outputTokens':1000}}}))
        try:
            probe.budget(reserve=reserve)
            decisions.append('allow')
        except RuntimeError:
            decisions.append('stop')
    print(json.dumps(decisions))
`);
  assert.deepEqual(result, ['stop', 'stop', 'stop', 'allow']);
});

test('a nested Bash completion cannot complete the background agent control', () => {
  const result = python(`
launch = {'subtype':'task_started', 'task_id':'agent-1', 'is_backgrounded':True,
          'subagent_type':'general-purpose'}
bash = {'subtype':'task_notification','task_id':'shell-1','status':'completed'}
agent = {'subtype':'task_notification','task_id':'agent-1','status':'completed'}
print(json.dumps([m.agent_completed([launch,bash]), m.agent_completed([launch,bash,agent])]))
`);
  assert.deepEqual(result, [false, true]);
});

test('counts input caches in streamed messages before a final usage result exists', () => {
  const result = python(`
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder) / 'stream.jsonl'
    path.write_text(json.dumps({'type':'assistant','session_id':'s','message':{
        'id':'m','usage':{'input_tokens':1,'cache_creation_input_tokens':20,
                         'cache_read_input_tokens':10,'output_tokens':4}}}))
    u = m.usage([path, path])
    print(json.dumps([u['input'], u['output'], u['messages']]))
`);
  assert.deepEqual(result, [31, 4, 1]);
});

test('leaves output headroom for a request already in flight', () => {
  const result = python(`
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder) / 'stream.jsonl'
    path.write_text(json.dumps({'type':'result','session_id':'s','modelUsage':{
        'haiku':{'inputTokens':1000,'outputTokens':8600}}}))
    probe = m.Probe(Path(folder))
    probe.streams = [path]
    try:
        probe.budget()
        print(json.dumps('allow'))
    except RuntimeError:
        print(json.dumps('stop'))
`);
  assert.equal(result, 'stop');
});
