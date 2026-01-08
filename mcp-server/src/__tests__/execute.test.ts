import { describe, it, expect, vi, beforeEach } from 'vitest';
import { handleExecute } from '../handlers/execute';
import * as rpc from '../rpc';

// Mock the RPC module
vi.mock('../rpc', () => ({
  callNeovim: vi.fn(),
}));

describe('handleExecute', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('command execution with output', () => {
    it('should return command output when available', async () => {
      // Mock callNeovim to return output
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: 'nowrap',
      });

      const result = await handleExecute({ command: 'set wrap?' });

      expect(result.content).toHaveLength(1);
      expect(result.content[0].type).toBe('text');
      expect(result.content[0].text).toContain('Command output:');
      expect(result.content[0].text).toContain('nowrap');
    });

    it('should trim output whitespace', async () => {
      // Mock callNeovim to return output with whitespace
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: '  test output  \n',
      });

      const result = await handleExecute({ command: 'echo "test output"' });

      expect(result.content[0].text).toContain('test output');
      expect(result.content[0].text).not.toContain('  test output  ');
    });

    it('should handle multi-line output', async () => {
      const multilineOutput = 'line1\nline2\nline3';
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: multilineOutput,
      });

      const result = await handleExecute({ command: 'messages' });

      expect(result.content[0].text).toContain('Command output:');
      expect(result.content[0].text).toContain(multilineOutput);
    });
  });

  describe('command execution without output', () => {
    it('should return success message when output is empty', async () => {
      // Mock callNeovim to return empty output
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: '',
      });

      const result = await handleExecute({ command: 'set number' });

      expect(result.content[0].text).toContain('Command executed successfully');
      expect(result.content[0].text).toContain('set number');
    });

    it('should return success message when output is only whitespace', async () => {
      // Mock callNeovim to return whitespace output
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: '   \n\t  ',
      });

      const result = await handleExecute({ command: 'write' });

      expect(result.content[0].text).toContain('Command executed successfully');
      expect(result.content[0].text).toContain('write');
    });

    it('should return success message when output is null', async () => {
      // Mock callNeovim to return null output
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: null,
      });

      const result = await handleExecute({ command: 'set wrap' });

      expect(result.content[0].text).toContain('Command executed successfully');
    });

    it('should return success message when output is undefined', async () => {
      // Mock callNeovim to return undefined output
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
      });

      const result = await handleExecute({ command: 'set number' });

      expect(result.content[0].text).toContain('Command executed successfully');
    });
  });

  describe('validation', () => {
    it('should throw error when command is missing', async () => {
      await expect(handleExecute({})).rejects.toThrow();
    });

    it('should throw error when command is empty string', async () => {
      await expect(handleExecute({ command: '' })).rejects.toThrow();
    });

    it('should throw error when args is null', async () => {
      await expect(handleExecute(null as any)).rejects.toThrow();
    });

    it('should throw error when args is undefined', async () => {
      await expect(handleExecute(undefined as any)).rejects.toThrow();
    });
  });

  describe('error handling', () => {
    it('should propagate errors from callNeovim', async () => {
      // Mock callNeovim to throw error
      vi.mocked(rpc.callNeovim).mockRejectedValue(new Error('Command execution failed'));

      await expect(handleExecute({ command: 'invalid_command' })).rejects.toThrow(
        'Command execution failed'
      );
    });

    it('should propagate validation errors', async () => {
      // Shell commands should be blocked by validation
      await expect(handleExecute({ command: '!rm -rf /' })).rejects.toThrow();
    });
  });

  describe('rpc_port parameter', () => {
    it('should pass rpc_port to callNeovim', async () => {
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: 'test',
      });

      await handleExecute({ command: 'set wrap?', rpc_port: 9876 });

      expect(rpc.callNeovim).toHaveBeenCalledWith(
        'execute',
        { command: 'set wrap?' },
        9876
      );
    });

    it('should work without rpc_port', async () => {
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: 'test',
      });

      await handleExecute({ command: 'set wrap?' });

      expect(rpc.callNeovim).toHaveBeenCalledWith(
        'execute',
        { command: 'set wrap?' },
        undefined
      );
    });
  });

  describe('output format consistency', () => {
    it('should use consistent format for commands with output', async () => {
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: 'some output',
      });

      const result = await handleExecute({ command: 'echo "test"' });

      expect(result.content[0].text).toMatch(/^Command output:\n/);
    });

    it('should use consistent format for commands without output', async () => {
      vi.mocked(rpc.callNeovim).mockResolvedValue({
        success: true,
        output: '',
      });

      const result = await handleExecute({ command: 'set number' });

      expect(result.content[0].text).toMatch(/^Command executed successfully \(no output\):/);
    });
  });
});
