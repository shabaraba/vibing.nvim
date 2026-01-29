/**
 * Type definitions for vibing.nvim agent wrapper
 */

/**
 * Tool-specific marker configuration with pattern matching support.
 * Allows different markers based on tool input (e.g., different markers for npm vs git commands in Bash).
 *
 * @example
 * ```typescript
 * const bashMarker: ToolMarkerDefinition = {
 *   default: '⏺',
 *   patterns: {
 *     '^npm': '📦',
 *     '^git': '🌿',
 *   }
 * };
 * ```
 */
export interface ToolMarkerDefinition {
  /** Default marker when no pattern matches */
  default?: string;
  /** Regex pattern to marker mapping. Patterns are tested against tool input. */
  patterns?: Record<string, string>;
}

/**
 * Configuration for tool execution markers displayed in chat output.
 * Supports both simple string markers and pattern-based ToolMarkerDefinition objects.
 *
 * @example
 * ```typescript
 * const markers: ToolMarkersConfig = {
 *   Task: '▶',
 *   TaskComplete: '✓',
 *   default: '⏺',
 *   Bash: {
 *     default: '⏺',
 *     patterns: { '^npm': '📦' }
 *   }
 * };
 * ```
 */
export interface ToolMarkersConfig {
  /** Marker for Task tool start */
  Task?: string;
  /** Marker for Task tool completion */
  TaskComplete?: string;
  /** Default marker for tools without specific configuration */
  default?: string;
  /** Tool-specific markers (string for simple marker, ToolMarkerDefinition for pattern matching) */
  [toolName: string]: string | ToolMarkerDefinition | undefined;
}

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
  forkSessionId: string | null;
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
  toolMarkers: ToolMarkersConfig;
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
