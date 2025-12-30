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
