/**
 * canUseTool callback implementation
 *
 * Permission evaluation order (highest to lowest priority):
 * 1. Session-level deny list (immediate block)
 * 2. Session-level allow list (auto-approve)
 * 3. Permission modes (acceptEdits, default, bypassPermissions)
 * 4. Allow list (with pattern matching support)
 * 5. Ask list (granular patterns override broader allow list permissions)
 * 6. Granular permission rules (path/command/pattern/domain based)
 *
 * IMPORTANT: Ask list is checked AFTER allow list to ensure granular patterns
 * like Bash(rm:*) can override broader permissions like Bash.
 */

import { matchesPermission } from './matchers.js';
import { checkRule } from './rule-checker.js';
import { safeJsonStringify, toError } from '../utils.js';
import type { AgentConfig } from '../../types.js';

interface CanUseToolResult {
  behavior: 'allow' | 'deny' | 'ask';
  message?: string;
  updatedInput?: Record<string, unknown>;
}

type CanUseToolCallback = (
  toolName: string,
  input: Record<string, unknown>
) => Promise<CanUseToolResult>;

const ONCE_SUFFIX = ':once';

const APPROVAL_OPTIONS = [
  { value: 'allow_once', label: 'allow_once - Allow this execution only' },
  { value: 'deny_once', label: 'deny_once - Deny this execution only' },
  { value: 'allow_for_session', label: 'allow_for_session - Allow for this session' },
  { value: 'deny_for_session', label: 'deny_for_session - Deny for this session' },
] as const;

function allow(input: Record<string, unknown>): CanUseToolResult {
  return { behavior: 'allow', updatedInput: input };
}

function deny(message: string): CanUseToolResult {
  return { behavior: 'deny', message };
}

function requestApproval(toolName: string, input: Record<string, unknown>): CanUseToolResult {
  console.log(
    safeJsonStringify({
      type: 'approval_required',
      tool: toolName,
      input: input,
      options: APPROVAL_OPTIONS,
    })
  );
  return deny('Please wait for user approval from the provided options.');
}

/**
 * Check session permission list and handle one-time permissions
 * Returns the result if matched, or null to continue checking
 */
function checkSessionList(
  toolName: string,
  input: Record<string, unknown>,
  sessionList: string[] | undefined,
  action: 'allow' | 'deny'
): CanUseToolResult | null {
  if (!sessionList || sessionList.length === 0) {
    return null;
  }

  for (let i = sessionList.length - 1; i >= 0; i--) {
    const item = sessionList[i];
    const isOnce = item.endsWith(ONCE_SUFFIX);
    const pattern = isOnce ? item.slice(0, -ONCE_SUFFIX.length) : item;

    if (matchesPermission(toolName, input, pattern)) {
      if (isOnce) {
        sessionList.splice(i, 1);
      }

      if (action === 'allow') {
        return allow(input);
      }
      const suffix = isOnce ? 'once' : 'for this session';
      return deny(`Tool ${toolName} was denied ${suffix}.`);
    }
  }

  return null;
}

export function createCanUseToolCallback(config: AgentConfig): CanUseToolCallback {
  const {
    allowedTools,
    askedTools,
    sessionAllowedTools,
    sessionDeniedTools,
    permissionRules,
    permissionMode,
    mcpEnabled,
  } = config;

  return async (toolName: string, input: Record<string, unknown>): Promise<CanUseToolResult> => {
    try {
      // Handle AskUserQuestion specially - insert choices into chat buffer
      if (toolName === 'AskUserQuestion') {
        console.log(safeJsonStringify({ type: 'insert_choices', questions: input.questions }));
        return deny('Please wait for user to select from the provided options.');
      }

      // 1. Session-level deny list (highest priority)
      const sessionDenyResult = checkSessionList(toolName, input, sessionDeniedTools, 'deny');
      if (sessionDenyResult) {
        return sessionDenyResult;
      }

      // 2. Session-level allow list
      const sessionAllowResult = checkSessionList(toolName, input, sessionAllowedTools, 'allow');
      if (sessionAllowResult) {
        return sessionAllowResult;
      }

      // 3. Permission modes
      if (permissionMode === 'acceptEdits' && (toolName === 'Edit' || toolName === 'Write')) {
        return allow(input);
      }

      if (permissionMode === 'default') {
        const explicitlyAllowed = allowedTools.some((pattern) =>
          matchesPermission(toolName, input, pattern)
        );
        if (!explicitlyAllowed) {
          return requestApproval(toolName, input);
        }
      }

      // Handle vibing-nvim MCP tools
      if (toolName.startsWith('mcp__vibing-nvim__')) {
        if (mcpEnabled) {
          return allow(input);
        }
        return deny(
          'vibing.nvim MCP integration is disabled. Enable it in config: mcp.enabled = true'
        );
      }

      // 4. Check allow list (with pattern support)
      if (allowedTools.length > 0) {
        const isAllowed = allowedTools.some((pattern) =>
          matchesPermission(toolName, input, pattern)
        );
        if (!isAllowed) {
          return deny(buildNotAllowedMessage(toolName, input, allowedTools));
        }
      }

      // 5. Check ask list (AFTER allow list - granular patterns override broader permissions)
      const requiresApproval = askedTools.some((pattern) =>
        matchesPermission(toolName, input, pattern)
      );
      if (requiresApproval) {
        return requestApproval(toolName, input);
      }

      // 6. Check granular permission rules
      if (permissionRules && permissionRules.length > 0) {
        for (const rule of permissionRules) {
          const ruleResult = checkRule(rule, toolName, input);
          if (ruleResult === 'deny') {
            return deny(rule.message || `Tool ${toolName} is denied by permission rule`);
          }
        }
      }

      return allow(input);
    } catch (error) {
      const err = toError(error);
      console.error('[ERROR] canUseTool failed:', err.message, err.stack);
      console.error('[ERROR] toolName:', toolName, 'input:', JSON.stringify(input));

      if (error instanceof TypeError || error instanceof ReferenceError) {
        throw error;
      }

      return deny(
        `Permission check failed due to internal error: ${err.message}. Please report this issue if it persists.`
      );
    }
  };
}

function buildNotAllowedMessage(
  toolName: string,
  input: Record<string, unknown>,
  allowedTools: string[]
): string {
  const toolLower = toolName.toLowerCase();
  const toolPatterns = allowedTools.filter((t) => t.toLowerCase().startsWith(toolLower + '('));

  if (toolPatterns.length === 0) {
    return `Tool ${toolName} is not in the allowed list`;
  }

  const patterns = toolPatterns.map((p) => `'${p}'`).join(', ');

  if (toolLower === 'bash' && input.command) {
    return `Bash command '${input.command}' does not match any allowed patterns. Allowed: ${patterns}`;
  }
  if (['read', 'write', 'edit'].includes(toolLower) && input.file_path) {
    return `${toolName} access to '${input.file_path}' does not match any allowed patterns. Allowed: ${patterns}`;
  }
  if (['webfetch', 'websearch'].includes(toolLower) && input.url) {
    return `${toolName} access to '${input.url}' does not match any allowed patterns. Allowed: ${patterns}`;
  }
  if (['glob', 'grep'].includes(toolLower) && input.pattern) {
    return `${toolName} pattern '${input.pattern}' does not match any allowed patterns. Allowed: ${patterns}`;
  }

  return `Tool ${toolName} is not in the allowed list`;
}
