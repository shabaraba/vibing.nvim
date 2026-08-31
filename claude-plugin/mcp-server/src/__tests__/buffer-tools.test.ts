import { describe, it, expect, vi, beforeEach } from 'vitest';
import { handlers } from '../handlers/index.js';
import * as rpc from '../rpc.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

/**
 * nvim_get_buffer is how an orchestrator polls a worker chat (see the vibing-orchestrate skill),
 * so it has to say whether the reply it just returned is still being written.
 */
describe('nvim_get_buffer chat status', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('asks Neovim for the chat status alongside the lines', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ lines: ['a'], chat_status: null });

    await handlers.nvim_get_buffer({ bufnr: 3, rpc_port: 9878 });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'buf_get_lines',
      { bufnr: 3, file_path: undefined, include_chat_status: true },
      9878
    );
  });

  it('forwards a file_path so a chat can be read without knowing its bufnr', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ lines: ['a'], bufnr: 21, chat_status: 'idle' });

    await handlers.nvim_get_buffer({ file_path: '.vibing/chat/worker.md', rpc_port: 9878 });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'buf_get_lines',
      { bufnr: undefined, file_path: '.vibing/chat/worker.md', include_chat_status: true },
      9878
    );
  });

  it('refuses a call that names the target twice instead of picking one', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ lines: ['a'] });

    await expect(
      handlers.nvim_get_buffer({ bufnr: 3, file_path: '.vibing/chat/worker.md', rpc_port: 9878 })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('treats an explicit null alongside a real target as absent, not as a second target', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ lines: ['a'], bufnr: 3, chat_status: 'idle' });

    await handlers.nvim_get_buffer({ bufnr: 3, file_path: null, rpc_port: 9878 });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'buf_get_lines',
      { bufnr: 3, file_path: undefined, include_chat_status: true },
      9878
    );
  });

  it('refuses to pass off the current buffer as the chat a too-old Neovim could not address', async () => {
    // A Neovim that predates file_path ignores it and answers for `bufnr or 0` — the current
    // buffer — which reads as a healthy transcript of the chat that was asked for, reported idle.
    // Only a Neovim that understands the argument reports the buffer it read.
    vi.mocked(rpc.callNeovim).mockResolvedValue({
      lines: ['someone elses buffer'],
      chat_status: 'idle',
    });

    await expect(
      handlers.nvim_get_buffer({ file_path: '.vibing/chat/worker.md', rpc_port: 9878 })
    ).rejects.toThrow(/too old/);
  });

  it('returns only the buffer text for a non-chat buffer', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ lines: ['line 1', 'line 2'] });

    const result = await handlers.nvim_get_buffer({ bufnr: 3, rpc_port: 9878 });

    expect(result.content).toHaveLength(1);
    expect(result.content[0].text).toBe('line 1\nline 2');
  });

  it('adds a status block saying the reply is incomplete while one is streaming', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({
      lines: ['## Assistant', 'partial'],
      chat_status: 'responding',
    });

    const result = await handlers.nvim_get_buffer({ bufnr: 3, rpc_port: 9878 });

    expect(result.content).toHaveLength(2);
    expect(result.content[0].text).toBe('## Assistant\npartial');
    expect(result.content[1].text).toContain('responding');
  });

  it('adds a status block saying nothing is in flight when the chat is idle', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({
      lines: ['## Assistant', 'done'],
      chat_status: 'idle',
    });

    const result = await handlers.nvim_get_buffer({ bufnr: 3, rpc_port: 9878 });

    expect(result.content).toHaveLength(2);
    expect(result.content[1].text).toContain('idle');
  });

  it('still works against a Neovim old enough to answer with a bare line array', async () => {
    // The MCP server is installed at Claude Code's user scope and updates independently of the
    // plugin, so it can outrun the Lua side that knows about include_chat_status.
    vi.mocked(rpc.callNeovim).mockResolvedValue(['old', 'shape']);

    const result = await handlers.nvim_get_buffer({ bufnr: 3, rpc_port: 9878 });

    expect(result.content).toHaveLength(1);
    expect(result.content[0].text).toBe('old\nshape');
  });
});
