import * as net from 'net';

const NVIM_RPC_PORT = parseInt(process.env.VIBING_RPC_PORT || '9876', 10);

let requestId = 0;
const pendingRequests = new Map<
  number,
  {
    resolve: (value: any) => void;
    reject: (error: Error) => void;
  }
>();

let socket: net.Socket | null = null;
let buffer = '';

/**
 * Get or create socket connection to Neovim RPC server
 */
function getSocket(): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    if (socket && !socket.destroyed) {
      resolve(socket);
      return;
    }

    socket = new net.Socket();

    socket.on('data', (data) => {
      buffer += data.toString();

      while (true) {
        const newlinePos = buffer.indexOf('\n');
        if (newlinePos === -1) break;

        const line = buffer.slice(0, newlinePos);
        buffer = buffer.slice(newlinePos + 1);

        try {
          const response = JSON.parse(line);
          const pending = pendingRequests.get(response.id);
          if (pending) {
            pendingRequests.delete(response.id);
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
      reject(err);
    });

    socket.on('close', () => {
      socket = null;
      // Reject all pending requests
      for (const [id, pending] of pendingRequests) {
        pending.reject(new Error('Socket closed'));
        pendingRequests.delete(id);
      }
    });

    socket.connect(NVIM_RPC_PORT, '127.0.0.1', () => {
      resolve(socket!);
    });
  });
}

/**
 * Call Neovim RPC method
 */
export async function callNeovim(method: string, params: any = {}): Promise<any> {
  const sock = await getSocket();
  const id = ++requestId;

  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve, reject });

    const request = JSON.stringify({ id, method, params }) + '\n';
    sock.write(request);

    // Timeout after 5 seconds
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error('Request timeout'));
      }
    }, 5000);
  });
}

/**
 * Close socket connection
 */
export function closeSocket(): void {
  if (socket) {
    socket.destroy();
  }
}
