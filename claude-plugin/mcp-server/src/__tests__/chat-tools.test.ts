import { describe, it, expect, vi, beforeEach } from 'vitest';
import { allTools } from '../tools/index.js';
import { CHAT_POSITIONS } from '../tools/chat.js';
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

  it('registers nvim_ask_user_question with chat_bufnr, rpc_port, and questions all required', () => {
    const tool = allTools.find((t) => t.name === 'nvim_ask_user_question');
    expect(tool).toBeDefined();
    const inputSchema = tool?.inputSchema as {
      required?: string[];
      properties: Record<string, unknown>;
    };
    expect(inputSchema.required).toContain('chat_bufnr');
    // Still required despite the registry fallback added for read-only tools: this one cancels
    // the in-flight turn, and every Claude Code session on the machine can see it.
    expect(inputSchema.required).toContain('rpc_port');
    expect(inputSchema.required).toContain('questions');
    expect(inputSchema.properties.chat_bufnr).toBeDefined();
    expect(inputSchema.properties.rpc_port).toBeDefined();
    expect(inputSchema.properties.questions).toBeDefined();
  });

  it('registers nvim_chat_create with rpc_port required and everything else optional', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_create');
    expect(tool).toBeDefined();
    const inputSchema = tool?.inputSchema as {
      required?: string[];
      properties: Record<string, any>;
    };
    // It creates a buffer, so it is a write: it must name its instance rather than fall back to
    // the registry (see requireRpcPort in ../tools/common.ts).
    expect(inputSchema.required).toEqual(['rpc_port']);
    expect(inputSchema.properties.position.enum).toEqual([...CHAT_POSITIONS]);
    expect(inputSchema.properties.working_dir).toBeDefined();
  });

  it('nvim_chat_create defaults to no position and lets Neovim apply "back"', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ bufnr: 7, file_path: '/tmp/chat.md' });

    const result = await handlers.nvim_chat_create({ rpc_port: 9878 });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'create_chat',
      { position: undefined, working_dir: undefined },
      9878
    );
    expect(result.isError).toBeUndefined();
    expect(result._meta).toEqual({ bufnr: 7, file_path: '/tmp/chat.md' });
  });

  it('nvim_chat_create forwards position and working_dir, and returns the bufnr as text', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({
      bufnr: 12,
      file_path: '/repo/.vibing/worktrees/x/.vibing/chat/chat-1.md',
      working_dir: '.vibing/worktrees/x',
    });

    const result = await handlers.nvim_chat_create({
      rpc_port: 9878,
      position: 'back',
      working_dir: '.vibing/worktrees/x',
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'create_chat',
      { position: 'back', working_dir: '.vibing/worktrees/x' },
      9878
    );
    // The orchestrator has to read bufnr back out of the transcript on a later turn, so it has
    // to be in the text, not only in _meta.
    expect(result.content[0].text).toContain('"bufnr": 12');
  });

  it('nvim_chat_create rejects a call missing rpc_port instead of guessing an instance', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ bufnr: 7 });

    await expect(handlers.nvim_chat_create({ position: 'back' })).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('nvim_chat_create rejects a position the Lua handler would refuse anyway', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ bufnr: 7 });

    await expect(
      handlers.nvim_chat_create({ rpc_port: 9878, position: 'sideways' })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('registers nvim_chat_send_message with rpc_port required', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_send_message');
    const inputSchema = tool?.inputSchema as { required?: string[] };
    expect(inputSchema.required).toContain('rpc_port');
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

  it('nvim_ask_user_question rejects a call missing rpc_port instead of falling back to the registry', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ status: 'ok' });

    await expect(
      handlers.nvim_ask_user_question({
        chat_bufnr: 12,
        questions: [{ question: 'Which?', options: [{ label: 'A' }] }],
      })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
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
