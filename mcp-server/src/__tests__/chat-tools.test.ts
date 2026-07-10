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

  it('registers nvim_ask_user_question with a questions array input schema', () => {
    const tool = allTools.find((t) => t.name === 'nvim_ask_user_question');
    expect(tool).toBeDefined();
    const inputSchema = tool?.inputSchema as {
      required?: string[];
      properties: Record<string, unknown>;
    };
    expect(inputSchema.required).toContain('questions');
    expect(inputSchema.properties.questions).toBeDefined();
  });

  it('has a handler for nvim_ask_user_question', () => {
    expect(handlers.nvim_ask_user_question).toBeDefined();
    expect(typeof handlers.nvim_ask_user_question).toBe('function');
  });

  it('nvim_ask_user_question calls the ask_user_question RPC with questions and handle_id', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ status: 'ok' });
    const previousHandleId = process.env.VIBING_HANDLE_ID;
    process.env.VIBING_HANDLE_ID = 'handle-123';

    const questions = [{ question: 'Which?', options: [{ label: 'A' }] }];
    const result = await handlers.nvim_ask_user_question({ questions });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'ask_user_question',
      { handle_id: 'handle-123', questions },
      undefined
    );
    expect(result.isError).toBeUndefined();

    process.env.VIBING_HANDLE_ID = previousHandleId;
  });

  it('nvim_ask_user_question surfaces an error result when the RPC call fails to find a stream', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ status: 'error', reason: 'no active chat' });

    const result = await handlers.nvim_ask_user_question({
      questions: [{ question: 'Which?', options: [{ label: 'A' }] }],
    });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toBe('no active chat');
  });
});
