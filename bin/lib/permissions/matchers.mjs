/**
 * Permission pattern matching functions
 * Handles glob patterns, bash commands, domains, and tool permission strings
 */

import { URL } from 'url';

/**
 * Simple glob pattern matching
 * @param {string} pattern - Glob pattern (supports * and ?)
 * @param {string} str - String to match
 * @returns {boolean} Whether pattern matches string
 */
export function matchGlob(pattern, str) {
  if (typeof pattern !== 'string' || typeof str !== 'string') {
    return false;
  }

  if (pattern.length > 1000) {
    return false;
  }

  try {
    const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    const regexPattern = escaped.replace(/\*/g, '.*?').replace(/\?/g, '.');
    const regex = new RegExp(`^${regexPattern}$`);
    return regex.test(str);
  } catch {
    return false;
  }
}

/**
 * Parse tool permission string like "Tool(pattern)"
 * @param {string} toolStr - Tool permission string
 * @returns {Object} Parsed pattern { toolName, ruleContent, type }
 */
export function parseToolPattern(toolStr) {
  const granularMatch = toolStr.match(/^([a-z]+)\((.+)\)$/i);
  if (granularMatch) {
    const toolName = granularMatch[1].toLowerCase();
    const ruleContent = granularMatch[2];

    if (toolName === 'bash') {
      const isWildcard = ruleContent.match(/^([^:]+):\*$/);
      return {
        toolName: 'bash',
        ruleContent: ruleContent.toLowerCase(),
        type: isWildcard ? 'bash_wildcard' : 'bash_exact',
      };
    } else if (['read', 'write', 'edit'].includes(toolName)) {
      return {
        toolName: toolName,
        ruleContent: ruleContent,
        type: 'file_glob',
      };
    } else if (['webfetch', 'websearch'].includes(toolName)) {
      return {
        toolName: toolName,
        ruleContent: ruleContent.toLowerCase(),
        type: 'domain_pattern',
      };
    } else if (['glob', 'grep'].includes(toolName)) {
      return {
        toolName: toolName,
        ruleContent: ruleContent,
        type: 'search_pattern',
      };
    }

    return {
      toolName: toolName,
      ruleContent: ruleContent,
      type: 'unknown_pattern',
    };
  }

  return { toolName: toolStr.toLowerCase(), ruleContent: null, type: 'tool_name' };
}

/**
 * Match Bash command against permission pattern
 * @param {string} command - Bash command to check
 * @param {string} ruleContent - Rule content from pattern
 * @param {string} type - Pattern type (bash_wildcard or bash_exact)
 * @returns {boolean} Whether command matches pattern
 */
export function matchesBashPattern(command, ruleContent, type) {
  const cmd = command.trim().toLowerCase();
  const rule = ruleContent.toLowerCase();

  if (type === 'bash_wildcard') {
    const basePattern = rule.split(':')[0];
    const cmdParts = cmd.split(/\s+/);
    return cmdParts[0] === basePattern;
  } else {
    return cmd === rule || cmd.startsWith(rule + ' ');
  }
}

/**
 * Match file path against glob pattern
 * @param {string} filePath - File path to check
 * @param {string} globPattern - Glob pattern
 * @returns {boolean} Whether path matches pattern
 */
export function matchesFileGlob(filePath, globPattern) {
  return matchGlob(globPattern, filePath);
}

/**
 * Match URL domain against pattern
 * @param {string} url - URL to check
 * @param {string} domainPattern - Domain pattern (supports wildcards)
 * @returns {boolean} Whether domain matches pattern
 */
export function matchesDomainPattern(url, domainPattern) {
  try {
    const urlObj = new URL(url);
    const hostname = urlObj.hostname.toLowerCase();
    const pattern = domainPattern.toLowerCase();

    if (hostname === pattern) {
      return true;
    }

    if (pattern.startsWith('*.')) {
      const baseDomain = pattern.slice(2);
      return hostname === baseDomain || hostname.endsWith('.' + baseDomain);
    }

    return false;
  } catch {
    return false;
  }
}

/**
 * Check if tool matches permission string (unified for all tools)
 * @param {string} toolName - Tool name to check
 * @param {Object} input - Tool input parameters
 * @param {string} permissionStr - Permission string
 * @returns {boolean} Whether tool matches permission
 */
export function matchesPermission(toolName, input, permissionStr) {
  try {
    const parsed = parseToolPattern(permissionStr);

    if (parsed.type === 'tool_name') {
      const permToolName = parsed.toolName;
      const actualToolName = toolName.toLowerCase();

      if (permToolName.endsWith('*')) {
        const prefix = permToolName.slice(0, -1);
        return actualToolName.startsWith(prefix);
      }

      return actualToolName === permToolName;
    }

    if (toolName.toLowerCase() !== parsed.toolName) {
      return false;
    }

    switch (parsed.type) {
      case 'bash_wildcard':
      case 'bash_exact':
        return input.command
          ? matchesBashPattern(input.command, parsed.ruleContent, parsed.type)
          : false;

      case 'file_glob':
        return input.file_path ? matchesFileGlob(input.file_path, parsed.ruleContent) : false;

      case 'domain_pattern':
        return input.url ? matchesDomainPattern(input.url, parsed.ruleContent) : false;

      case 'search_pattern':
        return input.pattern ? input.pattern === parsed.ruleContent : false;

      default:
        return false;
    }
  } catch (error) {
    const errorMsg = `Permission matching failed for ${toolName} with pattern ${permissionStr}: ${error.message}`;
    console.error('[ERROR]', errorMsg, error.stack);

    console.log(
      JSON.stringify({
        type: 'error',
        message: errorMsg,
      })
    );

    return false;
  }
}
