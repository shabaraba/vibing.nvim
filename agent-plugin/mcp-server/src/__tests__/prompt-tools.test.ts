import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { handlers } from '../handlers/index.js';
import * as rpc from '../rpc.js';
import { allTools } from '../tools/index.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

const QUESTIONS = [
  {
    question: 'Which one?',
    multiSelect: false,
    options: [{ label: 'A' }, { label: 'B', description: 'the second one' }],
  },
];

describe('queued prompt tools', () => {
  const originalProcessId = process.env.VIBING_PROCESS_ID;

  beforeEach(() => {
    vi.clearAllMocks();
    process.env.VIBING_PROCESS_ID = 'p1';
  });

  afterEach(() => {
    if (originalProcessId === undefined) {
      delete process.env.VIBING_PROCESS_ID;
    } else {
      process.env.VIBING_PROCESS_ID = originalProcessId;
    }
  });

  function tool(name: string) {
    return allTools.find((t) => t.name === name);
  }

  it('advertises both tools and says the call does not wait', () => {
    for (const name of ['nvim_ask_question', 'nvim_request_approval']) {
      const advertised = tool(name);
      expect(advertised, name).toBeDefined();
      expect(advertised?.description).toMatch(/does NOT wait/);
      expect(advertised?.description).toMatch(/End your turn/);
    }
  });

  it('sends the process id and the questions to Neovim', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ ok: true, message: 'Queued.' });

    const result = await handlers.nvim_ask_question({ questions: QUESTIONS });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'ask_question',
      { process_id: 'p1', questions: QUESTIONS },
      undefined
    );
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toBe('Queued.');
  });

  it('forwards a manual rpc_port override', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ ok: true, message: 'Queued.' });

    await handlers.nvim_ask_question({ questions: QUESTIONS, rpc_port: 9876 });

    expect(vi.mocked(rpc.callNeovim).mock.calls[0][2]).toBe(9876);
  });

  it('reports a refusal from Neovim as an error', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ ok: false, message: 'no turn is open' });

    const result = await handlers.nvim_ask_question({ questions: QUESTIONS });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toBe('no turn is open');
  });

  it('reports an RPC failure as an error rather than a silent queue', async () => {
    vi.mocked(rpc.callNeovim).mockRejectedValue(new Error('Request timeout'));

    const result = await handlers.nvim_ask_question({ questions: QUESTIONS });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/Request timeout/);
  });

  it('refuses malformed questions without asking Neovim', async () => {
    const result = await handlers.nvim_ask_question({ questions: [] });

    expect(result.isError).toBe(true);
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('refuses more than four questions without asking Neovim', async () => {
    const many = Array.from({ length: 5 }, (_, index) => ({
      question: `Q${index}`,
      options: [{ label: 'A' }],
    }));

    const result = await handlers.nvim_ask_question({ questions: many });

    expect(result.isError).toBe(true);
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('sends a confirmation with its reason and details', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ ok: true, message: 'Queued.' });

    const input = { command: 'rm -rf build' };
    const result = await handlers.nvim_request_approval({
      reason: 'I am about to delete build/.',
      tool: 'Bash',
      input,
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'request_approval',
      { process_id: 'p1', reason: 'I am about to delete build/.', tool: 'Bash', input },
      undefined
    );
    expect(result.isError).toBeUndefined();
  });

  it('refuses a confirmation with no reason without asking Neovim', async () => {
    const result = await handlers.nvim_request_approval({});

    expect(result.isError).toBe(true);
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });
});
