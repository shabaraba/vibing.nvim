export interface BufferParams {
  bufnr?: number;
}

export interface WindowParams {
  winnr?: number;
}

export interface FilePathParams {
  filepath: string;
}

export interface CommandParams {
  command: string;
}

export class ValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ValidationError';
  }
}

export function validateBufferParams(params: BufferParams): void {
  if (params.bufnr !== undefined) {
    if (typeof params.bufnr !== 'number') {
      throw new ValidationError('bufnr must be a number');
    }
    if (params.bufnr < 0) {
      throw new ValidationError('bufnr must be non-negative');
    }
  }
}

export interface ChatTargetParams {
  bufnr?: number;
  file_path?: string;
}

/**
 * Check how a tool that accepts `bufnr` **or** `file_path` was pointed at a chat (#641).
 *
 * Refuse rather than pick: two names for one target is a sign the caller is confused about which
 * chat it means, and quietly preferring one reaches a chat nobody intended with nothing saying so.
 *
 * `required` is the only thing the two tools disagree about — `nvim_get_buffer` falls back to the
 * current buffer when given neither, `nvim_chat_send_message` has nothing to fall back to. The
 * rule itself lives here rather than in each handler so the two cannot drift, which is what
 * `handlers/bufnr.lua`'s `resolve_chat_target` is on the Lua side of the wire.
 */
export function validateChatTarget(params: ChatTargetParams, opts: { required?: boolean } = {}) {
  // `!= null` on purpose: a model that spells an unused optional argument as an explicit `null`
  // would otherwise be told it named the target twice for a call that named it once.
  const hasBufnr = params?.bufnr != null;
  const hasFilePath = params?.file_path != null;

  if (hasBufnr && hasFilePath) {
    throw new ValidationError('Pass either bufnr or file_path, not both');
  }
  if (opts.required && !hasBufnr && !hasFilePath) {
    throw new ValidationError('Pass either bufnr or file_path');
  }
}

export function validateWindowParams(params: WindowParams): void {
  if (params.winnr !== undefined) {
    if (typeof params.winnr !== 'number') {
      throw new ValidationError('winnr must be a number');
    }
    if (params.winnr < 0) {
      throw new ValidationError('winnr must be non-negative');
    }
  }
}

const SENSITIVE_PATHS = ['/etc/', '/var/', '/usr/', '/root/', '/home/', '/tmp/', '/bin/', '/sbin/'];

const PATH_TRAVERSAL_PATTERNS = [/\.\.\//, /\.\.\\/];

export function validateFilePath(params: FilePathParams): void {
  const { filepath } = params;

  if (!filepath || filepath.trim() === '') {
    throw new ValidationError('filepath cannot be empty');
  }

  for (const pattern of PATH_TRAVERSAL_PATTERNS) {
    if (pattern.test(filepath)) {
      throw new ValidationError('Path traversal detected');
    }
  }

  for (const sensitive of SENSITIVE_PATHS) {
    if (filepath.includes(sensitive)) {
      throw new ValidationError(`Access to sensitive path: ${sensitive}`);
    }
  }
}

const DANGEROUS_COMMAND_PATTERNS = [
  /^!/,
  /^:!/,
  /vim\.fn\.system/,
  /vim\.fn\.jobstart/,
  /vim\.fn\.termopen/,
  /vim\.loop\.spawn/,
  /vim\.uv\.spawn/,
  /\$\(/,
  /`[^`]*`/,
  /\|\s*!/,
  /os\.execute/,
  /io\.popen/,
];

export function validateCommand(params: CommandParams): void {
  const { command } = params;

  if (!command || command.trim() === '') {
    throw new ValidationError('command cannot be empty');
  }

  for (const pattern of DANGEROUS_COMMAND_PATTERNS) {
    if (pattern.test(command)) {
      throw new ValidationError('Dangerous command pattern detected');
    }
  }
}

export function validatePositiveInteger(value: unknown, name: string): void {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new ValidationError(`${name} must be a non-negative integer`);
  }
}

export function validateString(value: unknown, name: string): void {
  if (typeof value !== 'string') {
    throw new ValidationError(`${name} must be a string`);
  }
}

export function validateRequired<T>(value: T | undefined | null, name: string): asserts value is T {
  if (value === undefined || value === null) {
    throw new ValidationError(`${name} is required`);
  }
}
