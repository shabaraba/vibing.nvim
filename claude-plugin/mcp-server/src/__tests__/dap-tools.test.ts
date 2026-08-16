import { describe, it, expect, vi, beforeEach } from 'vitest';
import { allTools } from '../tools/index.js';
import { handlers } from '../handlers/index.js';
import * as rpc from '../rpc.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

const DAP_TOOLS = [
  'nvim_dap_get_state',
  'nvim_dap_get_stack_trace',
  'nvim_dap_get_variables',
  'nvim_dap_set_breakpoint',
  'nvim_dap_evaluate',
];

describe('dap tools', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(rpc.callNeovim).mockResolvedValue({ running: false });
  });

  describe('registration', () => {
    it.each(DAP_TOOLS)('registers %s with a handler', (name) => {
      expect(allTools.find((tool) => tool.name === name)).toBeDefined();
      expect(typeof handlers[name]).toBe('function');
    });

    it.each(DAP_TOOLS)('%s requires rpc_port — it targets one debug session', (name) => {
      const tool = allTools.find((t) => t.name === name);
      const schema = tool?.inputSchema as { required?: string[] };
      expect(schema.required).toContain('rpc_port');
    });

    it('requires file and line to set a breakpoint', () => {
      const tool = allTools.find((t) => t.name === 'nvim_dap_set_breakpoint');
      const schema = tool?.inputSchema as { required?: string[] };
      expect(schema.required).toContain('file');
      expect(schema.required).toContain('line');
    });

    it('warns that evaluate runs in the debuggee', () => {
      const tool = allTools.find((t) => t.name === 'nvim_dap_evaluate');
      expect(tool?.description).toMatch(/side effects/);
    });
  });

  describe('forwarding', () => {
    it('asks Neovim for the debugger state', async () => {
      await handlers.nvim_dap_get_state({ rpc_port: 9876 });
      expect(rpc.callNeovim).toHaveBeenCalledWith('dap_get_state', {}, 9876);
    });

    it('passes the optional thread and frame ids through', async () => {
      await handlers.nvim_dap_get_stack_trace({ thread_id: 3, rpc_port: 9876 });
      expect(rpc.callNeovim).toHaveBeenCalledWith('dap_get_stack_trace', { thread_id: 3 }, 9876);

      await handlers.nvim_dap_get_variables({ frame_id: 7, rpc_port: 9876 });
      expect(rpc.callNeovim).toHaveBeenCalledWith('dap_get_variables', { frame_id: 7 }, 9876);
    });

    it('forwards a breakpoint with its condition', async () => {
      await handlers.nvim_dap_set_breakpoint({
        file: 'src/app.py',
        line: 12,
        condition: 'x < 0',
        rpc_port: 9876,
      });

      expect(rpc.callNeovim).toHaveBeenCalledWith(
        'dap_set_breakpoint',
        { file: 'src/app.py', line: 12, condition: 'x < 0' },
        9876
      );
    });

    it('returns the state as readable JSON', async () => {
      vi.mocked(rpc.callNeovim).mockResolvedValue({ running: true, adapter: 'python' });

      const result = await handlers.nvim_dap_get_state({ rpc_port: 9876 });
      expect(result.content[0].text).toContain('python');
      expect(result._meta.running).toBe(true);
    });
  });

  describe('rejects before touching Neovim', () => {
    const rejected: Array<[string, string, Record<string, unknown>]> = [
      ['no rpc_port', 'nvim_dap_get_state', {}],
      ['an empty expression', 'nvim_dap_evaluate', { expression: '', rpc_port: 9876 }],
      ['no expression at all', 'nvim_dap_evaluate', { rpc_port: 9876 }],
      ['no line', 'nvim_dap_set_breakpoint', { file: 'a.py', rpc_port: 9876 }],
      ['a zero line', 'nvim_dap_set_breakpoint', { file: 'a.py', line: 0, rpc_port: 9876 }],
      ['a fractional line', 'nvim_dap_set_breakpoint', { file: 'a.py', line: 1.5, rpc_port: 9876 }],
      [
        'a path traversal attempt',
        'nvim_dap_set_breakpoint',
        { file: '../../../etc/passwd', line: 1, rpc_port: 9876 },
      ],
    ];

    it.each(rejected)('rejects %s', async (_label, name, args) => {
      await expect(handlers[name](args)).rejects.toThrow();
      expect(rpc.callNeovim).not.toHaveBeenCalled();
    });
  });
});
