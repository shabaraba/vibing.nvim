/**
 * Permission rule checker
 * Evaluates granular permission rules based on paths, commands, patterns, domains
 */

/* global URL */

import { matchGlob } from './matchers.mjs';

/**
 * Check if rule matches tool and input
 * @param {Object} rule - Permission rule to check
 * @param {string} toolName - Tool name
 * @param {Object} input - Tool input parameters
 * @returns {string|null} "allow", "deny", or null if rule doesn't apply
 */
export function checkRule(rule, toolName, input) {
  if (!rule.tools || !rule.tools.includes(toolName)) {
    return null;
  }

  if (rule.paths && rule.paths.length > 0 && input.file_path) {
    const pathMatches = rule.paths.some((pattern) => matchGlob(pattern, input.file_path));
    if (pathMatches) {
      return rule.action;
    }
    return null;
  }

  if (toolName === 'Bash' && input.command) {
    const commandParts = input.command.trim().split(/\s+/);
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
          return regex.test(input.command);
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
        const url = new URL(input.url);
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
