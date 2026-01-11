/**
 * Type definitions for vibing.nvim agent wrapper
 */

export interface PermissionRule {
  tools: string[];
  paths?: string[];
  commands?: string[];
  patterns?: string[];
  domains?: string[];
  action: 'allow' | 'deny';
  message?: string;
}

export interface AgentConfig {
  prompt: string;
  cwd: string;
  contextFiles: string[];
  sessionId: string | null;
  allowedTools: string[];
  deniedTools: string[];
  askedTools: string[];
  permissionRules: PermissionRule[];
  mode: string | null;
  model: string | null;
  permissionMode: 'default' | 'acceptEdits' | 'bypassPermissions';
  prioritizeVibingLsp: boolean;
  mcpEnabled: boolean;
  language: string | null;
  rpcPort: number | null;
  toolResultDisplay: 'none' | 'compact' | 'full';
  saveLocationType: 'project' | 'user' | 'custom';
  saveDir: string | null;
}

export interface StreamEvent {
  type: string;
  [key: string]: unknown;
}

export interface ToolUseEvent {
  type: 'tool_use';
  tool: string;
  file_path?: string;
  [key: string]: unknown;
}

export interface ErrorEvent {
  type: 'error';
  message: string;
}
