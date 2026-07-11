import { describe, it, expect } from 'vitest';
import { callNeovim } from '../rpc.js';

describe('callNeovim', () => {
  it('rejects when rpc_port is omitted instead of falling back to a default port', async () => {
    await expect(callNeovim('get_current_file', {})).rejects.toThrow(
      /requires an explicit rpc_port/
    );
  });
});
