#!/usr/bin/env node
// Probe the ACP (Agent Client Protocol) surface of `grok agent stdio`, grok 1.0.50.
//
// Pure measurement: spawns a real grok, drives one tiny turn, and logs every JSON-RPC frame in
// both directions so the protocol shapes can be read back verbatim. **Spends real tokens.**
//
//   node tests/perf/grok_acp_probe.mjs --log /tmp/x.jsonl --prompt "write hello.txt containing hi"
//
// Options:
//   --log <path>          traffic log (default /tmp/grok_acp_probe.jsonl)
//   --cwd <dir>           session cwd; a fresh mktemp dir is made when omitted
//   --prompt <text>       the prompt to send (omit to only initialize + session/new)
//   --mcp <name=cmd,arg>  add a stdio mcpServers entry to session/new (repeatable)
//   --plugin-dir <dir>    passed to grok before the `stdio` subcommand (repeatable)
//   --permission <id>     how to answer session/request_permission: the optionId to pick,
//                         or `reject`/`cancel` for the outcome of that name (default: log + reject)
//   --fs-caps             advertise clientCapabilities.fs read/write
//   --timeout <sec>       hard deadline (default 120)
//   --list-mcp-tools      after session/new, dump any tool listing the agent exposes
//   --cancel-after <sec>  send a `session/cancel` notification this long after the first prompt,
//                         without waiting for it — measures how a client interrupts a running turn,
//                         which is what a duplex transport needs and a rejected approval does not
//                         answer (that cancel comes from the agent's own side).
//   --prompt-gap <sec>    wait this long between prompts. A cancelled turn's `session/prompt`
//                         resolves the instant the cancel lands, so the next prompt would
//                         otherwise race whatever the agent still has to unwind.

import { spawn } from 'node:child_process';
import { mkdtempSync, appendFileSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const argv = process.argv.slice(2);
function opt(name, def) {
  const i = argv.indexOf(name);
  return i === -1 ? def : argv[i + 1];
}
function optAll(name) {
  const out = [];
  for (let i = 0; i < argv.length; i++) if (argv[i] === name) out.push(argv[i + 1]);
  return out;
}
function flag(name) {
  return argv.includes(name);
}

const LOG = opt('--log', '/tmp/grok_acp_probe.jsonl');
const CWD = opt('--cwd', null) || mkdtempSync(join(tmpdir(), 'grokacp-'));
const PROMPTS = optAll('--prompt'); // repeatable, sent in order on one session
const TIMEOUT = Number(opt('--timeout', '120')) * 1000;
const PERMISSION = optAll('--permission'); // repeatable: one answer per request, in order
let permIdx = 0;
const PLUGIN_DIRS = optAll('--plugin-dir');

writeFileSync(LOG, '');
function log(dir, obj) {
  appendFileSync(LOG, JSON.stringify({ t: Date.now(), dir, msg: obj }) + '\n');
  console.error(`[${dir}] ${JSON.stringify(obj)}`);
}

const mcpServers = optAll('--mcp').map((spec) => {
  const eq = spec.indexOf('=');
  const name = spec.slice(0, eq);
  const parts = spec.slice(eq + 1).split(',');
  return { name, command: parts[0], args: parts.slice(1), env: [] };
});

const args = ['agent', '--no-leader'];
for (const d of PLUGIN_DIRS) args.push('--plugin-dir', d);
args.push('stdio');
console.error(`$ grok ${args.join(' ')}   (cwd=${CWD})`);
appendFileSync(LOG, JSON.stringify({ t: Date.now(), dir: 'meta', argv: args, cwd: CWD }) + '\n');

const child = spawn('grok', args, { cwd: CWD, stdio: ['pipe', 'pipe', 'pipe'] });
child.stderr.on('data', (d) => {
  appendFileSync(LOG, JSON.stringify({ t: Date.now(), dir: 'stderr', text: d.toString() }) + '\n');
  console.error(`[stderr] ${d.toString().trimEnd()}`);
});

let nextId = 1;
const pending = new Map();
function send(obj) {
  log('out', obj);
  child.stdin.write(JSON.stringify(obj) + '\n');
}
function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send({ jsonrpc: '2.0', id, method, params });
  });
}
function respond(id, result) {
  send({ jsonrpc: '2.0', id, result });
}
function respondError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

// --- agent -> client requests. Everything is logged verbatim; a few get a usable reply so the
// turn can keep going far enough to reach the thing being measured.
function handleAgentRequest(msg) {
  const { id, method, params } = msg;
  if (method === 'session/request_permission') {
    // One answer per prompt, in order; the last one repeats once the list runs out.
    const want = PERMISSION[permIdx] ?? PERMISSION[PERMISSION.length - 1] ?? 'cancel';
    permIdx++;
    let outcome;
    if (want === 'cancel') {
      outcome = { outcome: 'cancelled' };
    } else if (want === 'bogus') {
      outcome = { outcome: 'rejected' }; // not an ACP outcome; measures the fail direction
    } else {
      outcome = { outcome: 'selected', optionId: want };
    }
    respond(id, { outcome });
    return;
  }
  if (method === 'fs/read_text_file') {
    try {
      respond(id, { content: readFileSync(params.path, 'utf8') });
    } catch (e) {
      respondError(id, -32000, String(e));
    }
    return;
  }
  if (method === 'fs/write_text_file') {
    try {
      writeFileSync(params.path, params.content ?? '');
      respond(id, {});
    } catch (e) {
      respondError(id, -32000, String(e));
    }
    return;
  }
  respondError(id, -32601, `probe does not implement ${method}`);
}

let buf = '';
child.stdout.on('data', (d) => {
  buf += d.toString();
  let nl;
  while ((nl = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      appendFileSync(LOG, JSON.stringify({ t: Date.now(), dir: 'in-unparsed', text: line }) + '\n');
      continue;
    }
    log('in', msg);
    if (msg.id !== undefined && msg.method) {
      handleAgentRequest(msg);
    } else if (msg.id !== undefined) {
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
      }
    }
  }
});

const timer = setTimeout(() => {
  console.error('!! probe timeout');
  appendFileSync(LOG, JSON.stringify({ t: Date.now(), dir: 'meta', timeout: true }) + '\n');
  child.kill('SIGKILL');
  process.exit(3);
}, TIMEOUT);

async function main() {
  const clientCapabilities = flag('--fs-caps')
    ? { fs: { readTextFile: true, writeTextFile: true } }
    : {};
  await request('initialize', { protocolVersion: 1, clientCapabilities });

  const newParams = { cwd: CWD, mcpServers };
  let session;
  try {
    session = await request('session/new', newParams);
  } catch (e) {
    console.error(`session/new FAILED: ${e.message}`);
    clearTimeout(timer);
    child.kill();
    process.exit(2);
  }
  const sessionId = session.sessionId;
  console.error(`sessionId=${sessionId}`);

  // --call '<method>' / --call '<method>=<json params>'; $SID is substituted with the session id.
  for (const spec of optAll('--call')) {
    const eq = spec.indexOf('=');
    const method = eq === -1 ? spec : spec.slice(0, eq);
    const raw = eq === -1 ? '{}' : spec.slice(eq + 1).replaceAll('$SID', sessionId);
    try {
      await request(method, JSON.parse(raw));
    } catch (e) {
      console.error(`${method} -> ${e.message}`);
    }
  }

  if (flag('--list-mcp-tools')) {
    for (const m of ['session/list_tools', 'tools/list', 'session/tools']) {
      try {
        await request(m, { sessionId });
      } catch (e) {
        console.error(`${m} -> ${e.message}`);
      }
    }
  }

  const cancelAfter = opt('--cancel-after', null);
  const promptGap = Number(opt('--prompt-gap', '0')) * 1000;
  let first = true;
  for (const text of PROMPTS) {
    if (!first && promptGap > 0) {
      await new Promise((r) => setTimeout(r, promptGap));
    }
    const inFlight = request('session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
    // Fired while the prompt is still running, which is the whole point: an interrupt has to reach
    // a turn that has not finished. Scheduled before the await, or the timer never gets to run.
    if (first && cancelAfter !== null) {
      setTimeout(
        () => send({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId } }),
        Number(cancelAfter) * 1000
      );
    }
    first = false;
    try {
      console.error(`prompt done: ${JSON.stringify(await inFlight)}`);
    } catch (e) {
      console.error(`session/prompt FAILED: ${e.message}`);
    }
  }

  clearTimeout(timer);
  child.kill();
  console.error(`\n--- log: ${LOG}\n--- cwd: ${CWD}`);
  setTimeout(() => process.exit(0), 300);
}

main();
