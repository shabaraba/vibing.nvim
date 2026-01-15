/**
 * canUseTool callback implementation
 * Handles permission logic for tool usage with ask/allow/deny lists and rules
 */

import { matchesPermission } from './matchers.js';
import { checkRule } from './rule-checker.js';
import { safeJsonStringify, toError } from '../utils.js';
import { checkForUnprocessedMentions, formatMentionSummary } from '../mention/checker.js';
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

/**
 * Suffix for one-time permission (allow_once/deny_once)
 */
const ONCE_SUFFIX = ':once';

/**
 * Create canUseTool callback for Agent SDK
 */
export function createCanUseToolCallback(config: AgentConfig): CanUseToolCallback {
  const {
    allowedTools,
    askedTools,
    sessionAllowedTools,
    sessionDeniedTools,
    permissionRules,
    permissionMode,
    mcpEnabled,
    rpcPort,
    squadName,
  } = config;

  return async (toolName: string, input: Record<string, unknown>): Promise<CanUseToolResult> => {
    try {
      /**
       * Permission evaluation order (highest to lowest priority):
       * 0. Mention interruption check (blocks all tools if unprocessed mentions exist)
       * 1. Session-level deny list (immediate block)
       * 2. Session-level allow list (auto-approve)
       * 3. Permission modes (acceptEdits, default, bypassPermissions)
       * 4. Ask list (request approval if not in allow list)
       * 5. Allow list (with pattern matching support)
       * 6. Granular permission rules (path/command/pattern/domain based)
       */

      // Check for unprocessed mentions (interruption mechanism)
      // Skip mention check for vibing-nvim MCP tools to avoid infinite recursion
      if (rpcPort && squadName && !toolName.startsWith('mcp__vibing-nvim__')) {
        const mentionResult = await checkForUnprocessedMentions({
          rpcPort,
          squadName,
        });

        if (mentionResult.shouldInterrupt) {
          const summary = formatMentionSummary(mentionResult);
          return {
            behavior: 'deny',
            message: summary,
          };
        }
      }

      // AskUserQuestion: Insert choices into chat buffer and deny
      if (toolName === 'AskUserQuestion') {
        console.log(
          safeJsonStringify({
            type: 'insert_choices',
            questions: input.questions,
          })
        );

        return {
          behavior: 'deny',
          message: 'Please wait for user to select from the provided options.',
        };
      }

      // Check session-level deny list (highest priority)
      // Use reverse loop to safely remove :once items
      if (sessionDeniedTools && sessionDeniedTools.length > 0) {
        for (let i = sessionDeniedTools.length - 1; i >= 0; i--) {
          const deniedTool = sessionDeniedTools[i];

          if (deniedTool.endsWith(ONCE_SUFFIX)) {
            const baseTool = deniedTool.slice(0, -ONCE_SUFFIX.length);
            if (matchesPermission(toolName, input, baseTool)) {
              // Deny once and remove from list
              sessionDeniedTools.splice(i, 1);
              return {
                behavior: 'deny',
                message: `Tool ${toolName} was denied once.`,
              };
            }
          } else if (matchesPermission(toolName, input, deniedTool)) {
            return {
              behavior: 'deny',
              message: `Tool ${toolName} was denied for this session.`,
            };
          }
        }
      }

      // Check session-level allow list (second priority)
      // Use reverse loop to safely remove :once items
      if (sessionAllowedTools && sessionAllowedTools.length > 0) {
        for (let i = sessionAllowedTools.length - 1; i >= 0; i--) {
          const allowedTool = sessionAllowedTools[i];

          if (allowedTool.endsWith(ONCE_SUFFIX)) {
            const baseTool = allowedTool.slice(0, -ONCE_SUFFIX.length);
            if (matchesPermission(toolName, input, baseTool)) {
              // Allow once and remove from list
              sessionAllowedTools.splice(i, 1);
              return {
                behavior: 'allow',
                updatedInput: input,
              };
            }
          } else if (matchesPermission(toolName, input, allowedTool)) {
            return {
              behavior: 'allow',
              updatedInput: input,
            };
          }
        }
      }

      // Implement permission modes
      if (permissionMode === 'acceptEdits' && (toolName === 'Edit' || toolName === 'Write')) {
        return { behavior: 'allow', updatedInput: input };
      }

      if (permissionMode === 'default') {
        // In default mode, ask for approval for all tools unless explicitly allowed
        // Check if tool is in allow list
        let explicitlyAllowed = false;
        for (const allowedTool of allowedTools) {
          if (matchesPermission(toolName, input, allowedTool)) {
            explicitlyAllowed = true;
            break;
          }
        }

        if (!explicitlyAllowed) {
          // Send approval_required event to show interactive UI in chat
          console.log(
            safeJsonStringify({
              type: 'approval_required',
              tool: toolName,
              input: input,
              options: [
                {
                  value: 'allow_once',
                  label: 'allow_once - Allow this execution only',
                },
                {
                  value: 'deny_once',
                  label: 'deny_once - Deny this execution only',
                },
                {
                  value: 'allow_for_session',
                  label: 'allow_for_session - Allow for this session',
                },
                {
                  value: 'deny_for_session',
                  label: 'deny_for_session - Deny for this session',
                },
              ],
            })
          );

          return {
            behavior: 'deny',
            message: 'Please wait for user approval from the provided options.',
          };
        }
      }

      // Special handling for vibing-nvim internal MCP tools
      if (toolName.startsWith('mcp__vibing-nvim__')) {
        if (mcpEnabled) {
          return { behavior: 'allow', updatedInput: input };
        } else {
          return {
            behavior: 'deny',
            message:
              'vibing.nvim MCP integration is disabled. Enable it in config: mcp.enabled = true',
          };
        }
      }

      // Check ask list (first priority - but allow list can override)
      for (const askedTool of askedTools) {
        const askMatches = matchesPermission(toolName, input, askedTool);

        if (askMatches) {
          let allowedByAllowList = false;

          for (const allowedTool of allowedTools) {
            const matches = matchesPermission(toolName, input, allowedTool);
            if (matches) {
              allowedByAllowList = true;
              break;
            }
          }

          if (!allowedByAllowList) {
            // Send approval_required event to show interactive UI in chat
            console.log(
              safeJsonStringify({
                type: 'approval_required',
                tool: toolName,
                input: input,
                options: [
                  {
                    value: 'allow_once',
                    label: 'allow_once - Allow this execution only',
                  },
                  {
                    value: 'deny_once',
                    label: 'deny_once - Deny this execution only',
                  },
                  {
                    value: 'allow_for_session',
                    label: 'allow_for_session - Allow for this session',
                  },
                  {
                    value: 'deny_for_session',
                    label: 'deny_for_session - Deny for this session',
                  },
                ],
              })
            );

            return {
              behavior: 'deny',
              message: 'Please wait for user approval from the provided options.',
            };
          }

          return {
            behavior: 'allow',
            updatedInput: input,
          };
        }
      }

      // Check allow list (if specified, with pattern support)
      if (allowedTools.length > 0) {
        let allowed = false;
        for (const allowedTool of allowedTools) {
          if (matchesPermission(toolName, input, allowedTool)) {
            allowed = true;
            break;
          }
        }
        if (!allowed) {
          const toolLower = toolName.toLowerCase();
          const toolPatterns = allowedTools.filter((t) =>
            t.toLowerCase().startsWith(toolLower + '(')
          );

          let message = `Tool ${toolName} is not in the allowed list`;

          if (toolPatterns.length > 0) {
            const patterns = toolPatterns.map((p) => `'${p}'`).join(', ');

            if (toolLower === 'bash' && input.command) {
              message = `Bash command '${input.command}' does not match any allowed patterns. Allowed: ${patterns}`;
            } else if (['read', 'write', 'edit'].includes(toolLower) && input.file_path) {
              message = `${toolName} access to '${input.file_path}' does not match any allowed patterns. Allowed: ${patterns}`;
            } else if (['webfetch', 'websearch'].includes(toolLower) && input.url) {
              message = `${toolName} access to '${input.url}' does not match any allowed patterns. Allowed: ${patterns}`;
            } else if (['glob', 'grep'].includes(toolLower) && input.pattern) {
              message = `${toolName} pattern '${input.pattern}' does not match any allowed patterns. Allowed: ${patterns}`;
            }
          }

          return {
            behavior: 'deny',
            message: message,
          };
        }
      }

      // Check granular permission rules
      if (permissionRules && permissionRules.length > 0) {
        for (const rule of permissionRules) {
          const ruleResult = checkRule(rule, toolName, input);
          if (ruleResult === 'deny') {
            return {
              behavior: 'deny',
              message: rule.message || `Tool ${toolName} is denied by permission rule`,
            };
          }
        }
      }

      return {
        behavior: 'allow',
        updatedInput: input,
      };
    } catch (error) {
      const err = toError(error);
      console.error('[ERROR] canUseTool failed:', err.message, err.stack);
      console.error('[ERROR] toolName:', toolName, 'input:', JSON.stringify(input));

      if (error instanceof TypeError || error instanceof ReferenceError) {
        throw error;
      }

      return {
        behavior: 'deny',
        message: `Permission check failed due to internal error: ${err.message}. Please report this issue if it persists.`,
      };
    }
  };
}
