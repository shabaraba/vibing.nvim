/**
 * Command-line argument parser for agent-wrapper
 * Parses CLI arguments and returns configuration object
 */

const validDisplayModes = ['none', 'compact', 'full'];

/**
 * Parse command-line arguments into configuration object
 * @param {string[]} args - Command-line arguments (process.argv.slice(2))
 * @returns {Object} Parsed configuration
 */
export function parseArguments(args) {
  const config = {
    prompt: '',
    cwd: process.cwd(),
    contextFiles: [],
    sessionId: null,
    allowedTools: [],
    deniedTools: [],
    askedTools: [],
    permissionRules: [],
    mode: null,
    model: null,
    permissionMode: 'acceptEdits',
    prioritizeVibingLsp: true,
    mcpEnabled: false,
    language: null,
    rpcPort: null,
    toolResultDisplay: 'compact',
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
    } else if (args[i] === '--mode' && args[i + 1]) {
      config.mode = args[i + 1];
      i++;
    } else if (args[i] === '--model' && args[i + 1]) {
      config.model = args[i + 1];
      i++;
    } else if (args[i] === '--prompt' && args[i + 1]) {
      config.prompt = args[i + 1];
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
    } else if (args[i] === '--permission-mode' && args[i + 1]) {
      config.permissionMode = args[i + 1];
      i++;
    } else if (args[i] === '--rules' && args[i + 1]) {
      try {
        config.permissionRules = JSON.parse(args[i + 1]);
        validatePermissionRules(config.permissionRules);
      } catch (e) {
        console.error('Failed to parse --rules JSON:', e.message);
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
      config.toolResultDisplay = args[i + 1];
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
 * @param {Array} rules - Permission rules to validate
 * @throws {Error} If validation fails
 */
function validatePermissionRules(rules) {
  if (!Array.isArray(rules)) {
    throw new Error('--rules must be an array of rule objects');
  }

  for (let j = 0; j < rules.length; j++) {
    const rule = rules[j];
    if (!rule || typeof rule !== 'object') {
      throw new Error(`Rule at index ${j} must be an object`);
    }

    if (!Array.isArray(rule.tools) || rule.tools.length === 0) {
      throw new Error(`Rule at index ${j} must have a non-empty 'tools' array`);
    }

    if (!rule.action || !['allow', 'deny'].includes(rule.action)) {
      throw new Error(`Rule at index ${j} must have 'action' set to "allow" or "deny"`);
    }

    if (rule.paths !== undefined && !Array.isArray(rule.paths)) {
      throw new Error(`Rule at index ${j}: 'paths' must be an array if specified`);
    }

    if (rule.commands !== undefined && !Array.isArray(rule.commands)) {
      throw new Error(`Rule at index ${j}: 'commands' must be an array if specified`);
    }

    if (rule.patterns !== undefined && !Array.isArray(rule.patterns)) {
      throw new Error(`Rule at index ${j}: 'patterns' must be an array if specified`);
    }

    if (rule.domains !== undefined && !Array.isArray(rule.domains)) {
      throw new Error(`Rule at index ${j}: 'domains' must be an array if specified`);
    }

    if (rule.message !== undefined && typeof rule.message !== 'string') {
      throw new Error(`Rule at index ${j}: 'message' must be a string if specified`);
    }
  }
}
