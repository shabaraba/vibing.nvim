/**
 * canUseTool callback implementation
 * Handles permission logic for tool usage with ask/allow/deny lists and rules
 */

import { matchesPermission } from './matchers.mjs';
import { checkRule } from './rule-checker.mjs';
import { safeJsonStringify } from '../utils.mjs';

/**
 * Create canUseTool callback for Agent SDK
 * @param {Object} config - Configuration object
 * @returns {Function} canUseTool callback
 */
export function createCanUseToolCallback(config) {
  const { allowedTools, askedTools, permissionRules, permissionMode, mcpEnabled, sessionId } =
    config;

  return async (toolName, input) => {
    try {
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

      // Implement acceptEdits mode: auto-approve Edit/Write tools
      if (permissionMode === 'acceptEdits' && (toolName === 'Edit' || toolName === 'Write')) {
        return { behavior: 'allow', updatedInput: input };
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
            // Issue #29 workaround: In resume sessions, Agent SDK bypasses canUseTool
            if (sessionId) {
              return {
                behavior: 'deny',
                message: `Tool ${toolName} requires user approval before use. Add it to the allow list with /allow ${askedTool} to enable in resume sessions.`,
              };
            } else {
              return {
                behavior: 'ask',
                updatedInput: input,
              };
            }
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
      console.error('[ERROR] canUseTool failed:', error.message, error.stack);
      console.error('[ERROR] toolName:', toolName, 'input:', JSON.stringify(input));

      if (error instanceof TypeError || error instanceof ReferenceError) {
        throw error;
      }

      return {
        behavior: 'deny',
        message: `Permission check failed due to internal error: ${error.message}. Please report this issue if it persists.`,
      };
    }
  };
}
