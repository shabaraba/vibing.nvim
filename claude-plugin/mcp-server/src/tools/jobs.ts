import { withRpcPort } from './common.js';

const jobId = {
  type: 'string' as const,
  description: 'Job ID returned by nvim_job_start.',
};

const tailLines = {
  type: 'integer' as const,
  minimum: 0,
  maximum: 200,
  description: 'Number of recent output lines to return (default 20, maximum 200).',
};

export const jobTools = [
  {
    name: 'nvim_job_start',
    description:
      'Start a long-running command as a Neovim-owned process, so it survives the current ' +
      'Claude/Codex CLI turn. Use this instead of Bash backgrounding (`&`, `nohup`, `setsid`) ' +
      'for development servers, watchers, and long scripts. The command is an argv array and is ' +
      'not interpreted by a shell. Completion normally reaches from_bufnr as a new Notice turn; ' +
      'the passive policy only appends it to the chat.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        command: {
          type: 'array' as const,
          minItems: 1,
          maxItems: 100,
          items: { type: 'string' as const, minLength: 1 },
          description: 'Executable followed by arguments, for example ["npm", "run", "dev"].',
        },
        name: {
          type: 'string' as const,
          minLength: 1,
          maxLength: 100,
          description: 'Short display name for status and completion notices.',
        },
        cwd: {
          type: 'string' as const,
          description:
            'Working directory, absolute or relative to the calling CLI cwd. It must stay inside that Git root.',
        },
        from_bufnr: {
          type: 'integer' as const,
          description:
            'Current vibing.nvim chat buffer number, used as the completion destination.',
        },
        notify: {
          type: 'string' as const,
          enum: ['always', 'on_failure', 'never', 'passive'],
          description:
            'Completion behavior (default always): on_failure wakes only for failures, passive appends a Notice without starting an LLM turn, and never only records status.',
        },
        env: {
          type: 'object' as const,
          additionalProperties: { type: 'string' as const },
          description: 'Environment variables added to the inherited process environment.',
        },
        ready_pattern: {
          type: 'string' as const,
          minLength: 1,
          maxLength: 500,
          description:
            'Plain-text output substring that marks the process ready. Process existence alone never means ready.',
        },
        ready_timeout_ms: {
          type: 'integer' as const,
          minimum: 1,
          maximum: 3600000,
          description: 'Time until a pending readiness check becomes timed_out (default 30000).',
        },
      }),
      required: ['command', 'from_bufnr'],
    },
  },
  {
    name: 'nvim_job_status',
    description: 'Read one Neovim-owned background job and a bounded tail of its output.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({ job_id: jobId, tail_lines: tailLines }),
      required: ['job_id'],
    },
  },
  {
    name: 'nvim_job_list',
    description: 'List background jobs owned by this Neovim instance.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
    },
  },
  {
    name: 'nvim_job_stop',
    description:
      'Request graceful termination of a Neovim-owned background job. Repeated calls are safe.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({ job_id: jobId }),
      required: ['job_id'],
    },
  },
  {
    name: 'nvim_job_wait',
    description:
      'Wait for a Neovim-owned background job for up to 25 seconds and return its status and output tail. ' +
      'A timeout does not stop the job.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        job_id: jobId,
        timeout_ms: {
          type: 'integer' as const,
          minimum: 0,
          maximum: 25000,
          description: 'Maximum wait in milliseconds (default and maximum 25000).',
        },
        tail_lines: tailLines,
        until: {
          type: 'string' as const,
          enum: ['exit', 'ready'],
          description:
            'Event to wait for (default exit). ready also returns when readiness times out or the process exits.',
        },
      }),
      required: ['job_id'],
    },
  },
];
