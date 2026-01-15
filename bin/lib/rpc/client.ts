/**
 * Lightweight RPC client for Neovim communication from agent-wrapper
 * Used by mention checker to query Neovim state during canUseTool
 */

import * as net from 'net';
import type { RpcClientConfig, RpcResponse } from './types.js';

const DEFAULT_TIMEOUT = 1000; // 1 second - keep short to not block tool execution

let requestId = 0;
let socket: net.Socket | null = null;
let socketPort: number | null = null;
const pendingRequests = new Map<
  number,
  { resolve: (value: unknown) => void; reject: (error: Error) => void }
>();
let buffer = '';

/**
 * Get or create socket connection to Neovim RPC server
 */
function getSocket(port: number): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    // Reuse existing socket if connected to same port
    if (socket && !socket.destroyed && socketPort === port) {
      resolve(socket);
      return;
    }

    // Clean up old socket if exists
    if (socket && !socket.destroyed) {
      socket.destroy();
    }

    socket = new net.Socket();
    socketPort = port;
    buffer = '';

    socket.on('data', (data) => {
      buffer += data.toString();

      while (true) {
        const newlinePos = buffer.indexOf('\n');
        if (newlinePos === -1) break;

        const line = buffer.slice(0, newlinePos);
        buffer = buffer.slice(newlinePos + 1);

        try {
          const response: RpcResponse = JSON.parse(line);
          const pending = pendingRequests.get(response.id);
          if (pending) {
            pendingRequests.delete(response.id);
            if (response.error) {
              pending.reject(new Error(response.error));
            } else {
              pending.resolve(response.result);
            }
          }
        } catch {
          // Ignore parse errors
        }
      }
    });

    socket.on('error', (err) => {
      // Reject all pending requests
      for (const [id, pending] of pendingRequests) {
        pending.reject(err);
        pendingRequests.delete(id);
      }
      socket = null;
      socketPort = null;
      reject(err);
    });

    socket.on('close', () => {
      // Reject all pending requests
      for (const [id, pending] of pendingRequests) {
        pending.reject(new Error('Socket closed'));
        pendingRequests.delete(id);
      }
      socket = null;
      socketPort = null;
    });

    socket.connect(port, '127.0.0.1', () => {
      resolve(socket!);
    });
  });
}

/**
 * Call Neovim RPC method
 */
export async function callNeovimRpc(
  method: string,
  params: Record<string, unknown> = {},
  config: RpcClientConfig
): Promise<unknown> {
  const timeout = config.timeout ?? DEFAULT_TIMEOUT;

  const sock = await getSocket(config.port);
  const id = ++requestId;

  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve, reject });

    const request = JSON.stringify({ id, method, params }) + '\n';
    sock.write(request);

    // Timeout
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error('RPC request timeout'));
      }
    }, timeout);
  });
}

/**
 * Close socket connection
 */
export function closeRpcConnection(): void {
  if (socket && !socket.destroyed) {
    socket.destroy();
  }
  socket = null;
  socketPort = null;
  pendingRequests.clear();
  buffer = '';
}
