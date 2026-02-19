/**
 * Command-line argument parser for agent-wrapper
 * Parses CLI arguments and returns configuration object
 */

import { readFileSync, unlinkSync } from 'fs';
import type { AgentConfig, PermissionRule, ToolMarkersConfig } from '../types.js';
import { toError } from './utils.js';

const validDisplayModes = ['none', 'compact', 'full'] as const;
const validPermissionModes = ['default', 'acceptEdits', 'bypassPermissions'] as const;
const validSaveLocationTypes = ['project', 'user', 'custom'] as const;

const DEFAULT_TOOL_MARKERS: ToolMarkersConfig = {
  Task: '▶',
  TaskComplete: '✓',
  default: '⏺',
};

/**
 * Type guard for permission mode validation
 */
function isValidPermissionMode(mode: string): mode is (typeof validPermissionModes)[number] {
  return validPermissionModes.includes(mode as any);
}

/**
 * Type guard for display mode validation
 */
function isValidDisplayMode(mode: string): mode is (typeof validDisplayModes)[number] {
  return validDisplayModes.includes(mode as any);
}

/**
 * Type guard for save location type validation
 */
function isValidSaveLocationType(type: string): type is (typeof validSaveLocationTypes)[number] {
  return validSaveLocationTypes.includes(type as any);
}

/**
 * Parse command-line arguments into configuration object
 */
export function parseArguments(args: string[]): AgentConfig {
  const config: AgentConfig = {
    prompt: '',
    cwd: process.cwd(),
    contextFiles: [],
    sessionId: null,
    forkSession: false,
    allowedTools: [],
    deniedTools: [],
    askedTools: [],
    sessionAllowedTools: [],
    sessionDeniedTools: [],
    permissionRules: [],
    mode: null,
    model: null,
    permissionMode: 'acceptEdits',
    prioritizeVibingLsp: true,
    mcpEnabled: false,
    language: null,
    rpcPort: null,
    toolResultDisplay: 'compact',
    saveLocationType: 'project',
    saveDir: null,
    toolMarkers: { ...DEFAULT_TOOL_MARKERS },
  };

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--cwd' && args[i + 1]) {
      config.cwd = args[i + 1];
      i++;
    } else if (args[i] === '--context' && args[i + 1]) {
      config.contextFiles.push(args[i + 1]);
      i++;
    } else if (args[i] === '--session' && args[i + 1]) {
      config.sessionId = args[i + 1];
      i++;
    } else if (args[i] === '--fork-session') {
      config.forkSession = true;
    } else if (args[i] === '--mode' && args[i + 1]) {
      config.mode = args[i + 1];
      i++;
    } else if (args[i] === '--model' && args[i + 1]) {
      config.model = args[i + 1];
      i++;
    } else if (args[i] === '--prompt' && args[i + 1]) {
      config.prompt = args[i + 1];
      i++;
    } else if (args[i] === '--prompt-file' && args[i + 1]) {
      // Read prompt from file (for large prompts that exceed command line limits)
      const promptFile = args[i + 1];
      try {
        config.prompt = readFileSync(promptFile, 'utf-8');
        // Clean up temp file after reading
        unlinkSync(promptFile);
      } catch (e) {
        console.error(`Failed to read prompt file: ${promptFile}`);
        process.exit(1);
      }
      i++;
    } else if (args[i] === '--allow' && args[i + 1]) {
      config.allowedTools = args[i + 1]
        .split(',')
        .map((t) => t.trim())
        .filter((t) => t);
      i++;
    } else if (args[i] === '--deny' && args[i + 1]) {
      config.deniedTools = args[i + 1]
        .split(',')
        .map((t) => t.trim())
        .filter((t) => t);
      i++;
    } else if (args[i] === '--ask' && args[i + 1]) {
      config.askedTools = args[i + 1]
        .split(',')
        .map((t) => t.trim())
        .filter((t) => t);
      i++;
    } else if (args[i] === '--session-allow' && args[i + 1]) {
      config.sessionAllowedTools = args[i + 1]
        .split(',')
        .map((t) => t.trim())
        .filter((t) => t);
      i++;
    } else if (args[i] === '--session-deny' && args[i + 1]) {
      config.sessionDeniedTools = args[i + 1]
        .split(',')
        .map((t) => t.trim())
        .filter((t) => t);
      i++;
    } else if (args[i] === '--permission-mode' && args[i + 1]) {
      const mode = args[i + 1];
      if (!isValidPermissionMode(mode)) {
        console.error(
          `Invalid --permission-mode value: "${mode}". Must be one of: ${validPermissionModes.join(', ')}`
        );
        process.exit(1);
      }
      config.permissionMode = mode;
      i++;
    } else if (args[i] === '--rules' && args[i + 1]) {
      try {
        config.permissionRules = JSON.parse(args[i + 1]) as PermissionRule[];
        validatePermissionRules(config.permissionRules);
      } catch (e) {
        const error = toError(e);
        console.error('Failed to parse --rules JSON:', error.message);
        process.exit(1);
      }
      i++;
    } else if (args[i] === '--prioritize-vibing-lsp' && args[i + 1]) {
      config.prioritizeVibingLsp = args[i + 1] === 'true';
      i++;
    } else if (args[i] === '--mcp-enabled' && args[i + 1]) {
      config.mcpEnabled = args[i + 1] === 'true';
      i++;
    } else if (args[i] === '--language' && args[i + 1]) {
      config.language = args[i + 1];
      i++;
    } else if (args[i] === '--rpc-port' && args[i + 1]) {
      const port = parseInt(args[i + 1], 10);
      if (isNaN(port) || port < 1 || port > 65535) {
        console.error(
          `Invalid --rpc-port value: "${args[i + 1]}". Must be a number between 1 and 65535.`
        );
        process.exit(1);
      }
      config.rpcPort = port;
      i++;
    } else if (args[i] === '--tool-result-display' && args[i + 1]) {
      const displayMode = args[i + 1];
      if (!isValidDisplayMode(displayMode)) {
        console.error(
          `Invalid --tool-result-display value: "${displayMode}". Must be one of: ${validDisplayModes.join(', ')}`
        );
        process.exit(1);
      }
      config.toolResultDisplay = displayMode;
      i++;
    } else if (args[i] === '--save-location-type' && args[i + 1]) {
      const locationType = args[i + 1];
      if (!isValidSaveLocationType(locationType)) {
        console.error(
          `Invalid --save-location-type value: "${locationType}". Must be one of: ${validSaveLocationTypes.join(', ')}`
        );
        process.exit(1);
      }
      config.saveLocationType = locationType;
      i++;
    } else if (args[i] === '--save-dir' && args[i + 1]) {
      config.saveDir = args[i + 1];
      i++;
    } else if (args[i] === '--tool-markers' && args[i + 1]) {
      try {
        const parsed = JSON.parse(args[i + 1]) as Record<string, unknown>;
        for (const [key, value] of Object.entries(parsed)) {
          if (typeof value === 'string' && value.trim().length > 0) {
            config.toolMarkers[key] = value;
          }
        }
      } catch (e) {
        const error = toError(e);
        console.error('Failed to parse --tool-markers JSON:', error.message);
        process.exit(1);
      }
      i++;
    } else if (!args[i].startsWith('--')) {
      config.prompt = args[i];
    }
  }

  if (!config.prompt) {
    console.error('Usage: agent-wrapper.mjs --prompt <prompt> [--cwd <dir>] [--context <file>...]');
    process.exit(1);
  }

  if (!validDisplayModes.includes(config.toolResultDisplay)) {
    console.error(
      `Invalid --tool-result-display value: "${config.toolResultDisplay}". Valid values: ${validDisplayModes.join(', ')}`
    );
    process.exit(1);
  }

  return config;
}

/**
 * Validate permission rules structure
 */
function validatePermissionRules(rules: unknown): asserts rules is PermissionRule[] {
  if (!Array.isArray(rules)) {
    throw new Error('--rules must be an array of rule objects');
  }

  for (let j = 0; j < rules.length; j++) {
    const rule = rules[j];
    if (!rule || typeof rule !== 'object') {
      throw new Error(`Rule at index ${j} must be an object`);
    }

    const r = rule as Record<string, unknown>;

    if (!Array.isArray(r.tools) || r.tools.length === 0) {
      throw new Error(`Rule at index ${j} must have a non-empty 'tools' array`);
    }

    if (!r.action || !['allow', 'deny'].includes(r.action as string)) {
      throw new Error(`Rule at index ${j} must have 'action' set to "allow" or "deny"`);
    }

    if (r.paths !== undefined && !Array.isArray(r.paths)) {
      throw new Error(`Rule at index ${j}: 'paths' must be an array if specified`);
    }

    if (r.commands !== undefined && !Array.isArray(r.commands)) {
      throw new Error(`Rule at index ${j}: 'commands' must be an array if specified`);
    }

    if (r.patterns !== undefined && !Array.isArray(r.patterns)) {
      throw new Error(`Rule at index ${j}: 'patterns' must be an array if specified`);
    }

    if (r.domains !== undefined && !Array.isArray(r.domains)) {
      throw new Error(`Rule at index ${j}: 'domains' must be an array if specified`);
    }

    if (r.message !== undefined && typeof r.message !== 'string') {
      throw new Error(`Rule at index ${j}: 'message' must be a string if specified`);
    }
  }
}
