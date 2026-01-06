import * as net from 'net';

const NVIM_RPC_PORT = parseInt(process.env.VIBING_RPC_PORT || '9876', 10);
const NVIM_RPC_TIMEOUT = parseInt(process.env.VIBING_RPC_TIMEOUT || '30000', 10); // Default 30 seconds

let requestId = 0;

// Multi-port support: Map of port -> socket
const sockets = new Map<number, net.Socket>();

// Multi-port support: Map of port -> (request_id -> pending)
const pendingRequests = new Map<number, Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>>();

// Multi-port support: Map of port -> buffer
const buffers = new Map<number, string>();

/**
 * Obtain a connected socket to the Neovim RPC server for a specific port, creating and wiring a new connection if needed.
 *
 * If an active socket already exists for the port, it is returned; otherwise a new socket is created,
 * event handlers are installed to parse newline-delimited JSON responses and resolve/reject
 * matching pending requests, and the socket is connected to the specified RPC port.
 *
 * @param port - The RPC port to connect to
 * @returns The connected `net.Socket` used for Neovim RPC communication.
 */
function getSocket(port: number): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    const existingSocket = sockets.get(port);
    if (existingSocket && !existingSocket.destroyed) {
      resolve(existingSocket);
      return;
    }

    const socket = new net.Socket();

    // Initialize port-specific data structures
    if (!pendingRequests.has(port)) {
      pendingRequests.set(port, new Map());
    }
    if (!buffers.has(port)) {
      buffers.set(port, '');
    }

    const portPending = pendingRequests.get(port)!;

    socket.on('data', (data) => {
      let buffer = buffers.get(port) || '';
      buffer += data.toString();
      buffers.set(port, buffer);

      while (true) {
        const newlinePos = buffer.indexOf('\n');
        if (newlinePos === -1) break;

        const line = buffer.slice(0, newlinePos);
        buffer = buffer.slice(newlinePos + 1);
        buffers.set(port, buffer);

        try {
          const response = JSON.parse(line);
          const pending = portPending.get(response.id);
          if (pending) {
            portPending.delete(response.id);
            if (response.error) {
              pending.reject(new Error(response.error));
            } else {
              pending.resolve(response.result);
            }
          }
        } catch (e) {
          // Ignore parse errors
        }
      }
    });

    socket.on('error', (err) => {
      // Socket not yet connected - reject connection promise
      if (!sockets.has(port)) {
        reject(err);
      }
      // Socket already connected - clean up pending requests
      const portPending = pendingRequests.get(port);
      if (portPending) {
        for (const [id, pending] of portPending) {
          pending.reject(err);
        }
        portPending.clear();
      }
    });

    socket.on('close', () => {
      sockets.delete(port);
      buffers.delete(port);

      // Reject all pending requests for this port
      for (const [id, pending] of portPending) {
        pending.reject(new Error('Socket closed'));
        portPending.delete(id);
      }
    });

    socket.connect(port, '127.0.0.1', () => {
      sockets.set(port, socket);
      resolve(socket);
    });
  });
}

/**
 * Invoke a Neovim RPC method and await its response.
 *
 * @param method - The RPC method name to call on the Neovim server
 * @param params - Parameters to include with the RPC call
 * @param port - Optional RPC port to connect to (defaults to VIBING_RPC_PORT env var or 9876)
 * @returns The `result` value from the RPC response. The promise is rejected with the RPC `error` if the response contains one, and is also rejected if the socket closes or the request times out.
 */
export async function callNeovim(method: string, params: any = {}, port?: number): Promise<any> {
  const targetPort = port !== undefined ? port : NVIM_RPC_PORT;
  const sock = await getSocket(targetPort);
  const id = ++requestId;

  // getSocket() already initialized pendingRequests for this port
  const portPending = pendingRequests.get(targetPort)!;

  return new Promise((resolve, reject) => {
    portPending.set(id, { resolve, reject });

    const request = JSON.stringify({ id, method, params }) + '\n';
    sock.write(request);

    // Timeout after configured duration (default 30 seconds)
    setTimeout(() => {
      if (portPending.has(id)) {
        portPending.delete(id);
        reject(new Error('Request timeout'));
      }
    }, NVIM_RPC_TIMEOUT);
  });
}

/**
 * Destroy all active Neovim RPC sockets.
 *
 * This closes all underlying TCP connections to Neovim RPC servers; if no sockets are open, the call is a no-op.
 */
export function closeSocket(): void {
  for (const [port, socket] of sockets) {
    if (socket && !socket.destroyed) {
      socket.destroy();
    }
  }
  sockets.clear();
  pendingRequests.clear();
  buffers.clear();
}