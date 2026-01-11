/**
 * Permission rule checker
 * Evaluates granular permission rules based on paths, commands, patterns, domains
 */

import { matchGlob } from './matchers.js';
import type { PermissionRule } from '../../types.js';

/**
 * Check if rule matches tool and input
 * @returns "allow", "deny", or null if rule doesn't apply
 */
export function checkRule(
  rule: PermissionRule,
  toolName: string,
  input: Record<string, unknown>
): 'allow' | 'deny' | null {
  if (!rule.tools || !rule.tools.includes(toolName)) {
    return null;
  }

  if (rule.paths && rule.paths.length > 0 && input.file_path) {
    const pathMatches = rule.paths.some((pattern) => matchGlob(pattern, input.file_path as string));
    if (pathMatches) {
      return rule.action;
    }
    return null;
  }

  if (toolName === 'Bash' && input.command) {
    const commandParts = (input.command as string).trim().split(/\s+/);
    const baseCommand = commandParts[0];

    if (rule.commands && rule.commands.length > 0) {
      const commandMatches = rule.commands.includes(baseCommand);
      if (commandMatches) {
        return rule.action;
      }
    }

    if (rule.patterns && rule.patterns.length > 0) {
      const patternMatches = rule.patterns.some((pattern) => {
        try {
          if (typeof pattern !== 'string' || pattern.length > 500) {
            return false;
          }
          const regex = new RegExp(pattern);
          return regex.test(input.command as string);
        } catch {
          return false;
        }
      });
      if (patternMatches) {
        return rule.action;
      }
    }

    if (
      (rule.commands && rule.commands.length > 0) ||
      (rule.patterns && rule.patterns.length > 0)
    ) {
      return null;
    }
  }

  if (toolName === 'WebFetch' && input.url) {
    if (rule.domains && rule.domains.length > 0) {
      try {
        const url = new URL(input.url as string);
        const hostname = url.hostname.toLowerCase();
        const domainMatches = rule.domains.some((domain) => matchGlob(domain, hostname));
        if (domainMatches) {
          return rule.action;
        }
        return null;
      } catch {
        return null;
      }
    }
  }

  return null;
}
