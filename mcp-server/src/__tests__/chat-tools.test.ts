import { describe, it, expect, vi, beforeEach } from 'vitest';
import { allTools } from '../tools/index.js';
import { handlers } from '../handlers/index.js';
import * as rpc from '../rpc.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

describe('chat tools (worktree redesign)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('does not register nvim_chat_worktree', () => {
    const names = allTools.map((tool) => tool.name);
    expect(names).not.toContain('nvim_chat_worktree');
  });

  it('still registers nvim_chat_send_message', () => {
    const names = allTools.map((tool) => tool.name);
    expect(names).toContain('nvim_chat_send_message');
  });

  it('does not have a handler for nvim_chat_worktree', () => {
    expect(handlers.nvim_chat_worktree).toBeUndefined();
  });

  it('still has a handler for nvim_chat_send_message', () => {
    expect(handlers.nvim_chat_send_message).toBeDefined();
    expect(typeof handlers.nvim_chat_send_message).toBe('function');
  });

  it('registers nvim_ask_user_question with chat_bufnr and questions required, rpc_port optional', () => {
    const tool = allTools.find((t) => t.name === 'nvim_ask_user_question');
    expect(tool).toBeDefined();
    const inputSchema = tool?.inputSchema as {
      required?: string[];
      properties: Record<string, unknown>;
    };
    expect(inputSchema.required).toContain('chat_bufnr');
    expect(inputSchema.required).toContain('questions');
    // rpc_port is offered but not required: omitting it resolves through the instance registry,
    // which only answers when exactly one Neovim is live (see resolveRpcPort in rpc.ts).
    expect(inputSchema.required).not.toContain('rpc_port');
    expect(inputSchema.properties.chat_bufnr).toBeDefined();
    expect(inputSchema.properties.rpc_port).toBeDefined();
    expect(inputSchema.properties.questions).toBeDefined();
  });

  it('registers nvim_chat_send_message with rpc_port optional', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_send_message');
    const inputSchema = tool?.inputSchema as {
      required?: string[];
      properties: Record<string, unknown>;
    };
    expect(inputSchema.required).not.toContain('rpc_port');
    expect(inputSchema.properties.rpc_port).toBeDefined();
  });

  it('has a handler for nvim_ask_user_question', () => {
    expect(handlers.nvim_ask_user_question).toBeDefined();
    expect(typeof handlers.nvim_ask_user_question).toBe('function');
  });

  it('nvim_ask_user_question calls the ask_user_question RPC with chat_bufnr and rpc_port passed as arguments', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ status: 'ok' });

    const questions = [{ question: 'Which?', options: [{ label: 'A' }] }];
    const result = await handlers.nvim_ask_user_question({
      chat_bufnr: 12,
      rpc_port: 9878,
      questions,
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'ask_user_question',
      { chat_bufnr: 12, questions },
      9878
    );
    expect(result.isError).toBeUndefined();
  });

  it('nvim_ask_user_question rejects a call missing chat_bufnr instead of silently guessing', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ status: 'ok' });

    await expect(
      handlers.nvim_ask_user_question({
        rpc_port: 9878,
        questions: [{ question: 'Which?', options: [{ label: 'A' }] }],
      })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('nvim_ask_user_question leaves a missing rpc_port for callNeovim to resolve, never guessing one here', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ status: 'ok' });

    const questions = [{ question: 'Which?', options: [{ label: 'A' }] }];
    await handlers.nvim_ask_user_question({ chat_bufnr: 12, questions });

    // undefined, not a default: callNeovim resolves it from the instance registry and errors when
    // more than one Neovim is live, so the wrong editor can never be targeted silently.
    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'ask_user_question',
      { chat_bufnr: 12, questions },
      undefined
    );
  });

  it('nvim_ask_user_question surfaces an error result when the RPC call fails to find a stream', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ status: 'error', reason: 'no active chat' });

    const result = await handlers.nvim_ask_user_question({
      chat_bufnr: 12,
      rpc_port: 9878,
      questions: [{ question: 'Which?', options: [{ label: 'A' }] }],
    });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toBe('no active chat');
  });
});
