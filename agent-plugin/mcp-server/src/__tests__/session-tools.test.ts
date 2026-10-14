import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mkdtemp, mkdir, writeFile, rm, symlink, utimes } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { handleSessionSearch, handleSessionRead } from '../handlers/sessions.js';
import { allTools } from '../tools/index.js';
import { handlers } from '../handlers/index.js';

let root: string;
const json = (result: any) => JSON.parse(result.content[0].text);
async function log(path: string, records: unknown[]) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(
    path,
    records
      .map((record) => (typeof record === 'string' ? record : JSON.stringify(record)))
      .join('\n') + '\n'
  );
}
const claude = (id: string, content: unknown, role = 'user') => ({
  type: role,
  sessionId: id,
  cwd: '/work/repo',
  timestamp: '2026-10-07T00:00:00Z',
  message: { role, content },
});
const meta = (id: string) => ({ type: 'session_meta', payload: { id, cwd: '/work/repo' } });
const codex = (role: string, text: string) => ({
  type: 'response_item',
  payload: {
    type: 'message',
    role,
    content: [{ type: role === 'user' ? 'input_text' : 'output_text', text }],
  },
});

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'vibing-session-test-'));
  vi.stubEnv('CLAUDE_CONFIG_DIR', join(root, 'claude'));
  vi.stubEnv('CODEX_HOME', join(root, 'codex'));
});
afterEach(async () => {
  vi.unstubAllEnvs();
  await rm(root, { recursive: true, force: true });
});

describe('external session log tools', () => {
  it('searches actual IDs and text for both CLIs without a Neovim connection', async () => {
    await log(join(root, 'claude/projects/repo/unrelated-name.jsonl'), [
      claude('claude-real-id', '認証のOAuthを修正'),
      claude('claude-real-id', [{ type: 'text', text: 'OAuth fixed' }], 'assistant'),
    ]);
    await log(join(root, 'codex/sessions/2026/10/07/rollout.jsonl'), [
      meta('codex-real-id'),
      codex('user', 'OAuth migration'),
      codex('assistant', 'Ready'),
    ]);
    const result = json(await handlers.nvim_session_search({ query: 'oauth' }));
    expect(result.sessions.map((s: any) => s.session_id).sort()).toEqual([
      'claude-real-id',
      'codex-real-id',
    ]);
    expect(
      result.sessions.every((s: any) => s.match.includes('OAuth') && s.cwd === '/work/repo')
    ).toBe(true);
    expect(result.scanned_files).toBe(2);
    expect(result.warnings).toEqual([]);
    const page = json(
      await handlers.nvim_session_read({ backend: 'codex', session_id: 'codex-real-id' })
    );
    expect(page.messages.map((m: any) => m.text)).toEqual(['OAuth migration', 'Ready']);
  });

  it('excludes reasoning, tool payloads, system messages, duplicate Codex events and subagents', async () => {
    await log(join(root, 'claude/projects/repo/main.jsonl'), [
      claude(
        'c',
        [
          { type: 'thinking', thinking: 'hidden' },
          { type: 'tool_use', input: { text: 'hidden' } },
        ],
        'assistant'
      ),
      claude('c', [{ type: 'tool_result', content: 'hidden' }]),
      { ...claude('c', 'hidden'), isMeta: true },
      { ...claude('c', 'hidden'), isSidechain: true },
      claude('c', 'visible'),
    ]);
    await log(join(root, 'claude/projects/repo/c/subagents/agent-a.jsonl'), [
      claude('sub', 'hidden'),
    ]);
    await log(join(root, 'codex/sessions/main.jsonl'), [
      meta('x'),
      codex('system', 'hidden'),
      { type: 'event_msg', payload: { type: 'agent_message', message: 'hidden' } },
      {
        type: 'response_item',
        payload: { type: 'reasoning', content: [{ type: 'text', text: 'hidden' }] },
      },
      codex('assistant', 'visible'),
    ]);
    expect(json(await handleSessionSearch({ query: 'hidden' })).sessions).toEqual([]);
    expect(
      json(await handleSessionRead({ backend: 'claude', session_id: 'c' })).messages.map(
        (m: any) => m.text
      )
    ).toEqual(['visible']);
    expect(
      json(await handleSessionRead({ backend: 'codex', session_id: 'x' })).messages.map(
        (m: any) => m.text
      )
    ).toEqual(['visible']);
  });

  it('continues past malformed or partial JSONL records, with diagnostics', async () => {
    await log(join(root, 'claude/projects/repo/log.jsonl'), [
      'broken',
      null,
      claude('c', '検索 [literal]'),
      '{"partial":',
    ]);
    const result = json(await handleSessionSearch({ query: '[literal]' }));
    expect(result.sessions[0].malformed_lines).toBe(3);
    expect(result.sessions[0].session_id).toBe('c');
  });

  it('supports archived Codex sessions, backend/ID/cwd filters and newest-first limits', async () => {
    const old = join(root, 'claude/projects/repo/a.jsonl');
    await log(old, [claude('old', 'old')]);
    await utimes(old, new Date('2020-01-01'), new Date('2020-01-01'));
    await log(join(root, 'codex/archived_sessions/a.jsonl'), [
      meta('archived-id'),
      codex('user', 'archive'),
    ]);
    const limited = json(await handleSessionSearch({ limit: 1 }));
    expect(limited.sessions[0].session_id).toBe('archived-id');
    expect(limited.truncated).toBe(true);
    expect(limited.matched_sessions).toBe(2);
    expect(
      json(
        await handleSessionSearch({
          backend: 'codex',
          session_id: 'archived',
          working_dir: '/work/repo/',
        })
      ).sessions
    ).toHaveLength(1);
    expect(json(await handleSessionSearch({ working_dir: '/elsewhere' })).sessions).toEqual([]);
    expect(
      json(await handleSessionRead({ backend: 'codex', session_id: 'archived-id' })).messages[0]
        .text
    ).toBe('archive');
  });

  it('paginates messages and reports clipping and completion explicitly', async () => {
    await log(join(root, 'claude/projects/repo/a.jsonl'), [
      claude('c', 'first'),
      claude('c', 'second', 'assistant'),
      claude('c', 'third'),
    ]);
    const page = json(
      await handleSessionRead({
        backend: 'claude',
        session_id: 'c',
        offset: 1,
        limit: 1,
        max_chars: 3,
      })
    );
    expect(page.messages).toEqual([
      {
        role: 'assistant',
        text: 'sec',
        timestamp: '2026-10-07T00:00:00Z',
        index: 1,
        text_truncated: true,
      },
    ]);
    expect(page.next_offset).toBe(2);
    const last = json(
      await handleSessionRead({ backend: 'claude', session_id: 'c', offset: page.next_offset })
    );
    expect(last.messages[0].text).toBe('third');
    expect(last.next_offset).toBeNull();
    expect(
      json(await handleSessionRead({ backend: 'claude', session_id: 'c', offset: 99 })).messages
    ).toEqual([]);
  });

  it('does not follow symlinks or infer IDs from filenames', async () => {
    await log(join(root, 'outside.jsonl'), [claude('outside', 'needle')]);
    const dir = join(root, 'claude/projects/repo');
    await mkdir(dir, { recursive: true });
    await symlink(join(root, 'outside.jsonl'), join(dir, 'link.jsonl'));
    await log(join(dir, 'invented-id.jsonl'), [
      { type: 'user', message: { role: 'user', content: 'needle' } },
    ]);
    expect(json(await handleSessionSearch({ query: 'needle' })).sessions).toEqual([]);
  });

  it('reports unreadable roots rather than presenting them as a complete empty search', async () => {
    await mkdir(join(root, 'codex'), { recursive: true });
    await writeFile(join(root, 'codex/sessions'), 'not a directory');
    const result = json(await handleSessionSearch({ backend: 'codex' }));
    expect(result.warnings).toHaveLength(1);
    expect(result.warnings[0]).toContain('ENOTDIR');
    await log(join(root, 'codex/archived_sessions/a.jsonl'), [
      { type: 'session_meta', payload: { session_id: 'archive', cwd: '/work/repo' } },
      codex('user', 'recoverable'),
    ]);
    const read = json(await handleSessionRead({ backend: 'codex', session_id: 'archive' }));
    expect(read.messages[0].text).toBe('recoverable');
    expect(read.warnings[0]).toContain('ENOTDIR');
  });

  it('validates bounded inputs and handles missing logs', async () => {
    expect(json(await handleSessionSearch({})).sessions).toEqual([]);
    await expect(handleSessionRead({ backend: 'claude', session_id: 'missing' })).rejects.toThrow(
      'Session not found'
    );
    for (const args of [{ backend: 'grok' }, { limit: 0 }, { limit: 101 }, { limit: 1.5 }])
      await expect(handleSessionSearch(args)).rejects.toThrow();
    for (const args of [{ offset: -1 }, { max_chars: 20001 }, { session_id: '' }])
      await expect(
        handleSessionRead({ backend: 'codex', session_id: 'x', ...args })
      ).rejects.toThrow();
  });

  it('registers both read-only tools with schemas independent of RPC', () => {
    for (const name of ['nvim_session_search', 'nvim_session_read']) {
      const tool = allTools.find((t) => t.name === name)!;
      expect('annotations' in tool && tool.annotations?.readOnlyHint).toBe(true);
      expect(tool.inputSchema.properties).not.toHaveProperty('rpc_port');
      expect(handlers[name]).toBeTypeOf('function');
    }
  });
});
