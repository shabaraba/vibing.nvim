import { beforeEach, describe, expect, it, vi } from 'vitest';
import { handlers } from '../handlers/index.js';
import * as rpc from '../rpc.js';
import { allTools } from '../tools/index.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

describe('Neovim-owned background jobs', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(rpc.callNeovim).mockResolvedValue({ id: 'job-1', status: 'running' });
  });

  it('registers every job tool and tells agents not to use shell backgrounding', () => {
    for (const name of [
      'nvim_job_start',
      'nvim_job_status',
      'nvim_job_list',
      'nvim_job_stop',
      'nvim_job_wait',
    ]) {
      expect(allTools.find((tool) => tool.name === name)).toBeDefined();
      expect(typeof handlers[name]).toBe('function');
    }

    const start = allTools.find((tool) => tool.name === 'nvim_job_start');
    expect(start?.description).toMatch(/survives the current.*CLI turn/i);
    expect(start?.description).toMatch(/nohup/);
    expect(start?.description).toMatch(/new Notice turn/);
  });

  it('resolves cwd against the CLI cwd and forwards the source chat and route', async () => {
    await handlers.nvim_job_start({
      command: ['npm', 'run', 'dev'],
      name: 'dev server',
      cwd: 'packages/web',
      from_bufnr: 42,
      notify: 'on_failure',
      env: { PORT: '4321' },
      ready_pattern: 'ready on',
      ready_timeout_ms: 45000,
      rpc_port: 9876,
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'job_start',
      {
        command: ['npm', 'run', 'dev'],
        name: 'dev server',
        cwd: expect.stringMatching(/packages\/web$/),
        base_cwd: process.cwd(),
        from_bufnr: 42,
        notify: 'on_failure',
        env: { PORT: '4321' },
        ready_pattern: 'ready on',
        ready_timeout_ms: 45000,
      },
      9876
    );
  });

  it('forwards status, list, stop, and bounded wait calls', async () => {
    await handlers.nvim_job_status({ job_id: 'job-1', tail_lines: 7, rpc_port: 9001 });
    await handlers.nvim_job_list({ rpc_port: 9002 });
    await handlers.nvim_job_stop({ job_id: 'job-1', rpc_port: 9003 });
    await handlers.nvim_job_wait({
      job_id: 'job-1',
      timeout_ms: 1234,
      tail_lines: 4,
      until: 'ready',
      rpc_port: 9004,
    });

    expect(rpc.callNeovim).toHaveBeenNthCalledWith(
      1,
      'job_status',
      { job_id: 'job-1', tail_lines: 7 },
      9001
    );
    expect(rpc.callNeovim).toHaveBeenNthCalledWith(2, 'job_list', {}, 9002);
    expect(rpc.callNeovim).toHaveBeenNthCalledWith(3, 'job_stop', { job_id: 'job-1' }, 9003);
    expect(rpc.callNeovim).toHaveBeenNthCalledWith(
      4,
      'job_wait',
      { job_id: 'job-1', timeout_ms: 1234, tail_lines: 4, until: 'ready' },
      9004
    );
  });

  it.each([
    ['an empty argv', { command: [], from_bufnr: 42 }],
    ['an empty argument', { command: ['sh', ''], from_bufnr: 42 }],
    ['a multiline argument', { command: ['sh', 'bad\nargument'], from_bufnr: 42 }],
    ['a missing source chat', { command: ['npm', 'run', 'dev'] }],
    ['an invalid notification policy', { command: ['true'], from_bufnr: 42, notify: 'sometimes' }],
    ['a wait longer than the RPC budget', { job_id: 'job-1', timeout_ms: 25001 }],
    ['an unknown wait event', { job_id: 'job-1', until: 'started' }],
  ])('rejects %s before touching Neovim', async (_label, args) => {
    const call = 'command' in args ? handlers.nvim_job_start : handlers.nvim_job_wait;
    await expect(call(args)).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });
});
