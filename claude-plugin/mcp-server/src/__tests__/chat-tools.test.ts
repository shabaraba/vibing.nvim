import { describe, it, expect, vi, beforeEach } from 'vitest';
import { allTools } from '../tools/index.js';
import { APPROVAL_ACTIONS, CHAT_POSITIONS } from '../tools/chat.js';
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

  it('nvim_chat_create rejects a task containing a line break instead of forwarding it', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ bufnr: 7 });

    await expect(
      handlers.nvim_chat_create({ rpc_port: 9878, task: 'PR #688\n-- review' })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('registers nvim_chat_send_message with rpc_port required', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_send_message');
    const inputSchema = tool?.inputSchema as { required?: string[] };
    expect(inputSchema.required).toContain('rpc_port');
  });

  it('offers from_bufnr on both chat tools but never requires it', () => {
    for (const name of ['nvim_chat_send_message', 'nvim_chat_create']) {
      const tool = allTools.find((t) => t.name === name);
      const inputSchema = tool?.inputSchema as {
        required?: string[];
        properties: Record<string, unknown>;
      };
      expect(inputSchema.properties.from_bufnr).toBeDefined();
      // Requiring it would break every existing caller that omits it, and the failure would be a
      // refused send rather than a missing link.
      expect(inputSchema.required).not.toContain('from_bufnr');
    }
  });

  it('nvim_chat_send_message forwards from_bufnr so Neovim can record the link', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, bufnr: 14 });

    await handlers.nvim_chat_send_message({
      rpc_port: 9878,
      bufnr: 14,
      message: 'do the thing',
      from_bufnr: 12,
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'send_message',
      {
        bufnr: 14,
        file_path: undefined,
        message: 'do the thing',
        sender: undefined,
        from_bufnr: 12,
      },
      9878
    );
  });

  it('registers a task property on nvim_chat_send_message (#696 follow-up)', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_send_message');
    const inputSchema = tool?.inputSchema as { properties: Record<string, unknown> };
    expect(inputSchema.properties.task).toBeDefined();
  });

  it('nvim_chat_send_message forwards task to the send_message RPC call (#696 follow-up)', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, bufnr: 14 });

    await handlers.nvim_chat_send_message({
      rpc_port: 9878,
      bufnr: 14,
      message: 'now also update the docs',
      from_bufnr: 12,
      task: 'PR #688 -- now also update the docs',
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'send_message',
      {
        bufnr: 14,
        file_path: undefined,
        message: 'now also update the docs',
        sender: undefined,
        from_bufnr: 12,
        queue_if_busy: undefined,
        task: 'PR #688 -- now also update the docs',
      },
      9878
    );
  });

  it('nvim_chat_send_message rejects a task containing a line break instead of forwarding it', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, bufnr: 14 });

    await expect(
      handlers.nvim_chat_send_message({
        rpc_port: 9878,
        bufnr: 14,
        message: 'do the thing',
        from_bufnr: 12,
        task: 'line one\nline two',
      })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('nvim_chat_send_message still sends when from_bufnr is omitted', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, bufnr: 14 });

    const result = await handlers.nvim_chat_send_message({
      rpc_port: 9878,
      bufnr: 14,
      message: 'do the thing',
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'send_message',
      {
        bufnr: 14,
        file_path: undefined,
        message: 'do the thing',
        sender: undefined,
        from_bufnr: undefined,
      },
      9878
    );
    expect(result.isError).toBeUndefined();
  });

  it('nvim_chat_send_message forwards queue_if_busy and reports that the message was queued', async () => {
    // The tool's own description promises the caller can tell "queued" from "sent", and only this
    // layer decides the wording the model reads. A queued reply read as "sent" makes an
    // orchestrator poll a transcript that has not moved.
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, queued: true, bufnr: 14 });

    const result = await handlers.nvim_chat_send_message({
      rpc_port: 9878,
      bufnr: 14,
      message: 'my report',
      queue_if_busy: true,
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'send_message',
      {
        bufnr: 14,
        file_path: undefined,
        message: 'my report',
        sender: undefined,
        from_bufnr: undefined,
        queue_if_busy: true,
      },
      9878
    );
    expect(result._meta.queued).toBe(true);
    expect(result.content[0].text).toContain('queued');
    expect(result.content[0].text).not.toContain('AI request initiated');
  });

  it('nvim_chat_send_message reports an ordinary send when nothing was queued', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, bufnr: 14 });

    const result = await handlers.nvim_chat_send_message({
      rpc_port: 9878,
      bufnr: 14,
      message: 'do the thing',
      queue_if_busy: true,
    });

    expect(result._meta.queued).toBe(false);
    expect(result.content[0].text).toContain('AI request initiated');
  });

  it('nvim_chat_send_message accepts a file_path instead of a bufnr', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, bufnr: 21 });

    const result = await handlers.nvim_chat_send_message({
      rpc_port: 9878,
      file_path: '.vibing/chat/worker.md',
      message: 'do the thing',
      from_bufnr: 12,
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'send_message',
      {
        bufnr: undefined,
        file_path: '.vibing/chat/worker.md',
        message: 'do the thing',
        sender: undefined,
        from_bufnr: 12,
      },
      9878
    );
    // The caller passed a path, so the bufnr it gets back has to be the one Neovim resolved.
    expect(result._meta.bufnr).toBe(21);
  });

  it('nvim_chat_send_message refuses a call that names the target twice', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, bufnr: 14 });

    await expect(
      handlers.nvim_chat_send_message({
        rpc_port: 9878,
        bufnr: 14,
        file_path: '.vibing/chat/worker.md',
        message: 'do the thing',
      })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('nvim_chat_send_message refuses a call that names no target at all', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, bufnr: 14 });

    await expect(
      handlers.nvim_chat_send_message({ rpc_port: 9878, message: 'do the thing' })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('requires neither bufnr nor file_path in the advertised schema, since exactly one goes', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_send_message');
    const inputSchema = tool?.inputSchema as {
      required?: string[];
      properties: Record<string, unknown>;
    };
    expect(inputSchema.properties.file_path).toBeDefined();
    // A required list naming both mutually exclusive keys reads as "pass both"; the handler is
    // what enforces the choice.
    expect(inputSchema.required).not.toContain('bufnr');
    expect(inputSchema.required).not.toContain('file_path');
    expect(inputSchema.required).toContain('message');
  });

  it('registers nvim_chat_answer_approval with action and from_bufnr required', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_answer_approval');
    const inputSchema = tool?.inputSchema as {
      required?: string[];
      properties: Record<string, any>;
    };

    expect(tool).toBeDefined();
    expect(inputSchema.required).toContain('rpc_port');
    expect(inputSchema.required).toContain('action');
    // Unlike the other two chat tools, this one cannot be called anonymously: it removes a
    // permission gate, so the answer has to be attributable to a chat.
    expect(inputSchema.required).toContain('from_bufnr');
    // Same "name the target once" rule as nvim_chat_send_message.
    expect(inputSchema.required).not.toContain('bufnr');
    expect(inputSchema.required).not.toContain('file_path');
    expect(inputSchema.properties.action.enum).toEqual([...APPROVAL_ACTIONS]);
  });

  it('nvim_chat_answer_approval forwards the action and reports the tool it answered', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({
      success: true,
      bufnr: 21,
      tool: 'Bash',
      action: 'allow_once',
    });

    const result = await handlers.nvim_chat_answer_approval({
      rpc_port: 9878,
      file_path: '.vibing/chat/worker.md',
      action: 'allow_once',
      from_bufnr: 12,
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'answer_approval',
      {
        bufnr: undefined,
        file_path: '.vibing/chat/worker.md',
        action: 'allow_once',
        from_bufnr: 12,
      },
      9878
    );
    expect(result.content[0].text).toContain('Bash');
    expect(result._meta.bufnr).toBe(21);
  });

  it('nvim_chat_answer_approval refuses an action outside the four the prompt offers', async () => {
    await expect(
      handlers.nvim_chat_answer_approval({
        rpc_port: 9878,
        bufnr: 21,
        action: 'allow',
        from_bufnr: 12,
      })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('nvim_chat_answer_approval refuses a call that names no chat as the answerer', async () => {
    await expect(
      handlers.nvim_chat_answer_approval({ rpc_port: 9878, bufnr: 21, action: 'allow_once' })
    ).rejects.toThrow();
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('nvim_chat_answer_approval refuses a call that names the target twice, or not at all', async () => {
    await expect(
      handlers.nvim_chat_answer_approval({
        rpc_port: 9878,
        bufnr: 21,
        file_path: '.vibing/chat/worker.md',
        action: 'allow_once',
        from_bufnr: 12,
      })
    ).rejects.toThrow();

    await expect(
      handlers.nvim_chat_answer_approval({ rpc_port: 9878, action: 'allow_once', from_bufnr: 12 })
    ).rejects.toThrow();

    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('tells the model the delegated-approval gate exists, so a refusal is not a surprise', () => {
    // The Lua side refuses unless agent.orchestration.delegated_approval is on. A description
    // that does not say so turns every blocked worker into one wasted call before the model does
    // the right thing anyway.
    const description =
      allTools.find((t) => t.name === 'nvim_chat_answer_approval')?.description ?? '';

    expect(description).toContain('delegated_approval');
    expect(description).toContain('waiting_approval');
  });

  it('nvim_chat_create forwards from_bufnr so a worker is linked at creation', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ bufnr: 14, file_path: '/tmp/worker.md' });

    await handlers.nvim_chat_create({ rpc_port: 9878, from_bufnr: 12 });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'create_chat',
      { position: undefined, working_dir: undefined, from_bufnr: 12 },
      9878
    );
  });

  it('registers a task property on nvim_chat_create', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_create');
    const inputSchema = tool?.inputSchema as { properties: Record<string, unknown> };
    expect(inputSchema.properties.task).toBeDefined();
  });

  it('nvim_chat_create forwards task to the create_chat RPC call (#696)', async () => {
    // Where task actually lands (the caller's own orchestrated entry, not the new chat) is a
    // Lua-side concern (orchestrated_entry.lua) -- this handler only has to forward the argument.
    vi.mocked(rpc.callNeovim).mockResolvedValue({ bufnr: 14, file_path: '/tmp/worker.md' });

    await handlers.nvim_chat_create({
      rpc_port: 9878,
      task: 'PR #688 — review fixes, merge, cleanup',
    });

    expect(rpc.callNeovim).toHaveBeenCalledWith(
      'create_chat',
      {
        position: undefined,
        working_dir: undefined,
        task: 'PR #688 — review fixes, merge, cleanup',
      },
      9878
    );
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

  it('registers nvim_chat_list as a read, with no required arguments', () => {
    const tool = allTools.find((t) => t.name === 'nvim_chat_list');
    expect(tool).toBeDefined();
    const inputSchema = tool?.inputSchema as {
      required?: string[];
      properties: Record<string, unknown>;
    };
    // A read, like nvim_list_buffers: rpc_port falls back to the instance registry rather than
    // being required (see requireRpcPort's doc comment in ../tools/common.ts).
    expect(inputSchema.required).toEqual([]);
    expect(inputSchema.properties.rpc_port).toBeDefined();
  });

  it('has a handler for nvim_chat_list', () => {
    expect(handlers.nvim_chat_list).toBeDefined();
    expect(typeof handlers.nvim_chat_list).toBe('function');
  });

  it('nvim_chat_list forwards rpc_port and returns the chat list as JSON text', async () => {
    const chats = [
      { bufnr: 3, file_path: '/tmp/a.md', chat_status: 'idle', orchestrated_by: [] },
      {
        bufnr: 7,
        file_path: '/tmp/b.md',
        chat_status: 'responding',
        orchestrated_by: ['/tmp/a.md'],
      },
    ];
    vi.mocked(rpc.callNeovim).mockResolvedValue({ chats });

    const result = await handlers.nvim_chat_list({ rpc_port: 9878 });

    expect(rpc.callNeovim).toHaveBeenCalledWith('list_chats', {}, 9878);
    expect(result.isError).toBeUndefined();
    const parsed = JSON.parse(result.content[0].text);
    expect(parsed.chats).toEqual(chats);
  });

  it('nvim_chat_list works without rpc_port, falling back to the instance registry', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ chats: [] });

    const result = await handlers.nvim_chat_list({});

    expect(rpc.callNeovim).toHaveBeenCalledWith('list_chats', {}, undefined);
    expect(result.isError).toBeUndefined();
  });
});
