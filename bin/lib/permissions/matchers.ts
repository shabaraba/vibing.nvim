/**
 * Permission pattern matching functions
 * Handles glob patterns, bash commands, domains, and tool permission strings
 */

import { URL } from 'url';
import { toError } from '../utils.js';

interface ParsedToolPattern {
  toolName: string;
  ruleContent: string | null;
  type:
    | 'bash_wildcard'
    | 'bash_exact'
    | 'file_glob'
    | 'domain_pattern'
    | 'search_pattern'
    | 'unknown_pattern'
    | 'tool_name';
}

/**
 * Simple glob pattern matching
 */
export function matchGlob(pattern: string, str: string): boolean {
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
 */
export function parseToolPattern(toolStr: string): ParsedToolPattern {
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
 */
export function matchesBashPattern(
  command: string,
  ruleContent: string,
  type: 'bash_wildcard' | 'bash_exact'
): boolean {
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
 */
export function matchesFileGlob(filePath: string, globPattern: string): boolean {
  return matchGlob(globPattern, filePath);
}

/**
 * Match URL domain against pattern
 */
export function matchesDomainPattern(url: string, domainPattern: string): boolean {
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
 */
export function matchesPermission(
  toolName: string,
  input: Record<string, unknown>,
  permissionStr: string
): boolean {
  try {
    // Strip :once suffix before parsing (handled by can-use-tool.ts)
    const normalizedPermissionStr = permissionStr.replace(/:once$/, '');
    const parsed = parseToolPattern(normalizedPermissionStr);

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
          ? matchesBashPattern(input.command as string, parsed.ruleContent!, parsed.type)
          : false;

      case 'file_glob':
        return input.file_path
          ? matchesFileGlob(input.file_path as string, parsed.ruleContent!)
          : false;

      case 'domain_pattern':
        return input.url ? matchesDomainPattern(input.url as string, parsed.ruleContent!) : false;

      case 'search_pattern':
        return input.pattern ? input.pattern === parsed.ruleContent : false;

      default:
        return false;
    }
  } catch (error) {
    const err = toError(error);
    const errorMsg = `Permission matching failed for ${toolName} with pattern ${permissionStr}: ${err.message}`;
    console.error('[ERROR]', errorMsg, err.stack);

    console.log(
      JSON.stringify({
        type: 'error',
        message: errorMsg,
      })
    );

    return false;
  }
}
