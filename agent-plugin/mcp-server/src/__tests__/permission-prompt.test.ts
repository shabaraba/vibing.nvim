import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { handlers } from '../handlers/index.js';
import { promptWaitMs } from '../handlers/permission.js';
import * as rpc from '../rpc.js';
import { allTools } from '../tools/index.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

const INPUT = { file_path: '/repo/.vibing/plugins/x/SKILL.md', old_string: 'a', new_string: 'b' };

async function ask(args: unknown = { tool_name: 'Edit', input: INPUT, tool_use_id: 'toolu_1' }) {
  const result = await handlers.nvim_permission_prompt(args);
  return JSON.parse(result.content[0].text);
}

describe('nvim_permission_prompt', () => {
  const originalProcessId = process.env.VIBING_PROCESS_ID;
  const originalWait = process.env.VIBING_PROMPT_TOOL_WAIT_SEC;

  beforeEach(() => {
    vi.clearAllMocks();
    process.env.VIBING_PROCESS_ID = 'p1';
    process.env.VIBING_PROMPT_TOOL_WAIT_SEC = '990';
  });

  afterEach(() => {
    for (const [key, value] of [
      ['VIBING_PROCESS_ID', originalProcessId],
      ['VIBING_PROMPT_TOOL_WAIT_SEC', originalWait],
    ] as const) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  });

  it('is registered for the CLI and says a model never calls it', () => {
    const tool = allTools.find((t) => t.name === 'nvim_permission_prompt');
    expect(tool?.description).toMatch(/--permission-prompt-tool/);
    expect(tool?.description).toMatch(/--disallowedTools/);
  });

  it('names its process and waits as long as Neovim bound', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ decision: 'allow' });
    await ask();

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'permission_prompt',
      { process_id: 'p1', tool_name: 'Edit', input: INPUT, tool_use_id: 'toolu_1' },
      undefined,
      990_000
    );
  });

  it('forwards a manual rpc_port override', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ decision: 'allow' });
    await ask({ tool_name: 'Edit', input: INPUT, rpc_port: 9876 });
    expect(vi.mocked(rpc.callNeovim).mock.calls[0][2]).toBe(9876);
  });

  it('answers allow with the input unchanged', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ decision: 'allow' });
    expect(await ask()).toEqual({ behavior: 'allow', updatedInput: INPUT });
  });

  it("passes a denial's message through", async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ decision: 'deny', message: 'no thanks' });
    expect(await ask()).toEqual({ behavior: 'deny', message: 'no thanks' });
  });

  it('denies when the RPC fails or times out', async () => {
    vi.mocked(rpc.callNeovim).mockRejectedValue(new Error('Request timeout'));
    const reply = await ask();
    expect(reply.behavior).toBe('deny');
    expect(reply.message).toMatch(/Request timeout/);
  });

  it('denies a reply that is neither allow nor deny', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({});
    expect((await ask()).behavior).toBe('deny');
  });

  it('denies a malformed request without asking Neovim', async () => {
    expect((await ask({ input: INPUT })).behavior).toBe('deny');
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('falls back to the default deadline when the variable is missing or nonsense', () => {
    expect(promptWaitMs({})).toBe(990_000);
    expect(promptWaitMs({ VIBING_PROMPT_TOOL_WAIT_SEC: 'abc' })).toBe(990_000);
    expect(promptWaitMs({ VIBING_PROMPT_TOOL_WAIT_SEC: '1200' })).toBe(1_200_000);
  });
});
