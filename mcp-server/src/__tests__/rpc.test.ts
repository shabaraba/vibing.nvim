import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as net from 'net';

vi.mock('../instance-registry.js', () => ({
  listLiveInstances: vi.fn(),
}));

import { callNeovim, closeSocket } from '../rpc.js';
import { listLiveInstances } from '../instance-registry.js';

/**
 * Stand up a throwaway RPC server that answers every request with `result`, so a test can assert
 * which port callNeovim actually dialled.
 */
async function startFakeNeovim(result: unknown): Promise<{ port: number; close: () => void }> {
  const server = net.createServer((socket) => {
    socket.on('data', (chunk) => {
      for (const line of chunk.toString().split('\n')) {
        if (!line.trim()) {
          continue;
        }
        const { id } = JSON.parse(line);
        socket.write(JSON.stringify({ id, result }) + '\n');
      }
    });
  });

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as net.AddressInfo).port;

  return { port, close: () => server.close() };
}

describe('callNeovim port resolution', () => {
  beforeEach(() => {
    vi.mocked(listLiveInstances).mockReset();
  });

  afterEach(() => {
    closeSocket();
  });

  it('uses the given port without consulting the registry', async () => {
    const nvim = await startFakeNeovim('from-explicit-port');
    try {
      await expect(callNeovim('get_current_file', {}, nvim.port)).resolves.toBe(
        'from-explicit-port'
      );
      expect(vi.mocked(listLiveInstances)).not.toHaveBeenCalled();
    } finally {
      nvim.close();
    }
  });

  it('falls back to the sole running instance when no port is given', async () => {
    const nvim = await startFakeNeovim('from-registry');
    vi.mocked(listLiveInstances).mockResolvedValue([{ pid: 111, port: nvim.port, cwd: '/repo' }]);

    try {
      await expect(callNeovim('get_current_file', {})).resolves.toBe('from-registry');
    } finally {
      nvim.close();
    }
  });

  it('rejects rather than guessing a port when nothing is running', async () => {
    vi.mocked(listLiveInstances).mockResolvedValue([]);

    await expect(callNeovim('get_current_file', {})).rejects.toThrow(
      /no running vibing\.nvim Neovim instance found/
    );
  });

  it('rejects and names the candidates when several instances are running', async () => {
    vi.mocked(listLiveInstances).mockResolvedValue([
      { pid: 111, port: 9876, cwd: '/repo-a' },
      { pid: 222, port: 9877, cwd: '/repo-b' },
    ]);

    // Picking one here would silently drive the wrong editor, so the model has to disambiguate.
    const call = callNeovim('get_current_file', {});
    await expect(call).rejects.toThrow(/2 vibing\.nvim Neovim instances are running/);
    await expect(call).rejects.toThrow(/port=9876 cwd=\/repo-a/);
    await expect(call).rejects.toThrow(/port=9877 cwd=\/repo-b/);
  });
});
