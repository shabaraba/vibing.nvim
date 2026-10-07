import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

export type Backend = 'claude' | 'codex';
export interface Message {
  role: 'user' | 'assistant';
  text: string;
  timestamp?: string;
}
interface Session {
  backend: Backend;
  session_id: string;
  file_path: string;
  cwd?: string;
  updated_at: string;
  preview: string;
  match?: string;
  message_count: number;
  malformed_lines: number;
}

function roots(): Array<{ backend: Backend; path: string }> {
  return [
    {
      backend: 'claude',
      path: join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects'),
    },
    {
      backend: 'codex',
      path: join(process.env.CODEX_HOME || join(homedir(), '.codex'), 'sessions'),
    },
    {
      backend: 'codex',
      path: join(process.env.CODEX_HOME || join(homedir(), '.codex'), 'archived_sessions'),
    },
  ];
}

// Never follow directory/file symlinks or mix subagent transcripts into resumable sessions.
async function* files(root: string): AsyncGenerator<string> {
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return;
    throw error;
  }
  for (const entry of entries) {
    if (entry.isDirectory() && entry.name !== 'subagents') yield* files(join(root, entry.name));
    else if (entry.isFile() && entry.name.endsWith('.jsonl')) yield join(root, entry.name);
  }
}

function textContent(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .filter(
      (block) =>
        ['text', 'input_text', 'output_text'].includes(block?.type) &&
        typeof block.text === 'string'
    )
    .map((block) => block.text)
    .join('\n');
}

function messageOf(record: any, backend: Backend): Message | undefined {
  const message =
    backend === 'claude'
      ? ['user', 'assistant'].includes(record.type) && !record.isSidechain && !record.isMeta
        ? record.message
        : undefined
      : record.type === 'response_item' && record.payload?.type === 'message'
        ? record.payload
        : undefined;
  if (!message || !['user', 'assistant'].includes(message.role)) return;
  const text = textContent(message.content);
  if (!text) return;
  return { role: message.role, text, timestamp: record.timestamp };
}

function excerpt(text: string, query = ''): string {
  const at = query ? Math.max(0, text.toLowerCase().indexOf(query)) : 0;
  const start = Math.max(0, at - 100);
  return (
    (start ? '…' : '') + text.slice(start, start + 400) + (text.length > start + 400 ? '…' : '')
  );
}

async function scan(
  file: string,
  backend: Backend,
  query: string,
  onMessage?: (message: Message, index: number) => void,
  expectedId?: string
): Promise<Session | undefined> {
  const info = await stat(file);
  const session: Session = {
    backend,
    session_id: '',
    file_path: file,
    updated_at: info.mtime.toISOString(),
    preview: '',
    message_count: 0,
    malformed_lines: 0,
  };
  const stream = createReadStream(file, { encoding: 'utf8' });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      if (!line.trim()) continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        session.malformed_lines++;
        continue;
      }
      if (!record || typeof record !== 'object') {
        session.malformed_lines++;
        continue;
      }
      if (backend === 'claude' && !record.isSidechain) {
        if (typeof record.sessionId === 'string') session.session_id ||= record.sessionId;
        if (typeof record.cwd === 'string') session.cwd ||= record.cwd;
      } else if (backend === 'codex' && record.type === 'session_meta') {
        const id = record.payload?.id ?? record.payload?.session_id;
        if (typeof id === 'string') session.session_id ||= id;
        if (typeof record.payload?.cwd === 'string') session.cwd ||= record.payload.cwd;
      }
      if (expectedId && session.session_id && session.session_id !== expectedId) return;
      const message = messageOf(record, backend);
      if (!message) continue;
      if (!session.preview) session.preview = excerpt(message.text);
      if (query && !session.match && message.text.toLowerCase().includes(query))
        session.match = excerpt(message.text, query);
      onMessage?.(message, session.message_count);
      session.message_count++;
    }
  } finally {
    lines.close();
    stream.destroy();
  }
  return session.session_id ? session : undefined;
}

export interface SearchOptions {
  backend?: Backend;
  query?: string;
  session_id?: string;
  working_dir?: string;
  limit: number;
}

export async function searchSessions(options: SearchOptions) {
  const sessions: Session[] = [];
  const warnings: string[] = [];
  let scanned_files = 0;
  let matched_sessions = 0;
  const query = (options.query ?? '').toLowerCase();
  for (const root of roots().filter(
    (root) => !options.backend || root.backend === options.backend
  )) {
    try {
      for await (const file of files(root.path)) {
        scanned_files++;
        try {
          const session = await scan(file, root.backend, query);
          if (!session || (query && !session.match)) continue;
          if (options.session_id && !session.session_id.includes(options.session_id)) continue;
          if (
            options.working_dir &&
            (!session.cwd || resolve(session.cwd) !== resolve(options.working_dir))
          )
            continue;
          matched_sessions++;
          sessions.push(session);
          sessions.sort(
            (a, b) =>
              b.updated_at.localeCompare(a.updated_at) || a.file_path.localeCompare(b.file_path)
          );
          if (sessions.length > options.limit) sessions.pop();
        } catch (error) {
          warnings.push(`${file}: ${(error as Error).message}`);
        }
      }
    } catch (error) {
      warnings.push(`${root.path}: ${(error as Error).message}`);
    }
  }
  return {
    sessions,
    scanned_files,
    matched_sessions,
    truncated: matched_sessions > sessions.length,
    warnings,
  };
}

export async function readSession(options: {
  backend: Backend;
  session_id: string;
  offset: number;
  limit: number;
  max_chars: number;
}) {
  const warnings: string[] = [];
  for (const root of roots().filter((root) => root.backend === options.backend)) {
    try {
      for await (const file of files(root.path)) {
        try {
          const messages: Array<Message & { index: number; text_truncated: boolean }> = [];
          const session = await scan(
            file,
            root.backend,
            '',
            (message, index) => {
              if (index >= options.offset && messages.length < options.limit) {
                messages.push({
                  ...message,
                  index,
                  text: message.text.slice(0, options.max_chars),
                  text_truncated: message.text.length > options.max_chars,
                });
              }
            },
            options.session_id
          );
          if (session?.session_id !== options.session_id) continue;
          const next = options.offset + messages.length;
          return {
            ...session,
            messages,
            next_offset: next < session.message_count ? next : null,
            warnings,
          };
        } catch (error) {
          warnings.push(`${file}: ${(error as Error).message}`);
        }
      }
    } catch (error) {
      warnings.push(`${root.path}: ${(error as Error).message}`);
    }
  }
  throw new Error(
    `Session not found: ${options.backend}/${options.session_id}${warnings.length ? `; unreadable logs: ${warnings.join('; ')}` : ''}`
  );
}
