/**
 * RPC client types for Neovim communication
 */

export interface RpcRequest {
  id: number;
  method: string;
  params: Record<string, unknown>;
}

export interface RpcResponse {
  id: number;
  result?: unknown;
  error?: string;
}

export interface RpcClientConfig {
  port: number;
  timeout?: number;
}
