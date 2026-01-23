/**
 * Type definitions for vibing.nvim agent wrapper
 */

/**
 * Permission rule for granular tool access control
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

/**
 * Agent configuration from command-line arguments
 */
export interface AgentConfig {
  prompt: string;
  cwd: string;
  contextFiles: string[];
  sessionId: string | null;
  allowedTools: string[];
  deniedTools: string[];
  askedTools: string[];
  sessionAllowedTools: string[];
  sessionDeniedTools: string[];
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

/**
 * Generic stream event from Agent SDK
 */
export interface StreamEvent {
  type: string;
  [key: string]: unknown;
}

/**
 * Tool use event emitted when Claude uses a tool
 */
export interface ToolUseEvent {
  type: 'tool_use';
  tool: string;
  file_path?: string;
  [key: string]: unknown;
}

/**
 * VCS operation event for mote integration
 */
export interface VcsOperationEvent {
  type: 'vcs_operation';
  operation: string; // e.g., 'git checkout', 'jj edit'
  command: string; // full command string
}

/**
 * Error event from agent wrapper
 */
export interface ErrorEvent {
  type: 'error';
  message: string;
}
