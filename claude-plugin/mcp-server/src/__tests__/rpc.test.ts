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
  const originalRpcPort = process.env.VIBING_NVIM_RPC_PORT;

  beforeEach(() => {
    vi.mocked(listLiveInstances).mockReset();
    delete process.env.VIBING_NVIM_RPC_PORT;
  });

  afterEach(() => {
    closeSocket();
    if (originalRpcPort === undefined) {
      delete process.env.VIBING_NVIM_RPC_PORT;
    } else {
      process.env.VIBING_NVIM_RPC_PORT = originalRpcPort;
    }
  });

  it('uses the process-bound port without consulting the registry', async () => {
    const nvim = await startFakeNeovim('from-process-environment');
    process.env.VIBING_NVIM_RPC_PORT = String(nvim.port);

    try {
      await expect(callNeovim('get_current_file', {})).resolves.toBe('from-process-environment');
      expect(vi.mocked(listLiveInstances)).not.toHaveBeenCalled();
    } finally {
      nvim.close();
    }
  });

  it('keeps the process binding authoritative over a legacy tool argument', async () => {
    const bound = await startFakeNeovim('from-bound-port');
    const requested = await startFakeNeovim('from-requested-port');
    process.env.VIBING_NVIM_RPC_PORT = String(bound.port);

    try {
      await expect(callNeovim('get_current_file', {}, requested.port)).resolves.toBe(
        'from-bound-port'
      );
    } finally {
      bound.close();
      requested.close();
    }
  });

  it('fails closed when the process binding is invalid', async () => {
    process.env.VIBING_NVIM_RPC_PORT = 'not-a-port';

    await expect(callNeovim('get_current_file', {}, 9876)).rejects.toThrow(
      /VIBING_NVIM_RPC_PORT must be an integer from 1 to 65535/
    );
    expect(vi.mocked(listLiveInstances)).not.toHaveBeenCalled();
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
