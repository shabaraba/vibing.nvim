import { describe, it, expect } from 'vitest';
import { allTools } from '../tools/index.js';
import { handlers } from '../handlers/index.js';

describe('chat tools (worktree redesign)', () => {
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
});
