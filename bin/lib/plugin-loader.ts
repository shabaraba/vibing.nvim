/**
 * Plugin loader for vibing.nvim
 *
 * This module loads installed Claude Code plugins from the user's plugin cache
 * and returns them in a format compatible with the Agent SDK's `plugins` option.
 *
 * Plugins are read from ~/.claude/plugins/installed_plugins.json, which is
 * maintained by the Claude Code CLI when users install plugins via `/plugin install`.
 *
 * @module plugin-loader
 */

import { readFile, access } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';

/**
 * Reference to a locally installed plugin.
 * This format is expected by the Agent SDK's `plugins` option.
 */
export interface PluginReference {
  /** Plugin type - always 'local' for filesystem-based plugins */
  type: 'local';
  /** Absolute path to the plugin directory */
  path: string;
}

/**
 * Represents a single plugin installation entry.
 * This matches the structure in installed_plugins.json.
 */
interface InstalledPlugin {
  /** Installation scope: 'user' or 'project' */
  scope: string;
  /** Absolute path to the plugin installation directory */
  installPath: string;
  /** Plugin version string */
  version: string;
  /** ISO timestamp of initial installation */
  installedAt: string;
  /** ISO timestamp of last update */
  lastUpdated: string;
  /** Git commit SHA of the installed version */
  gitCommitSha: string;
}

/**
 * Structure of the installed_plugins.json file.
 */
interface InstalledPluginsFile {
  /** Schema version of the file format */
  version: number;
  /** Map of plugin identifiers to their installations */
  plugins: Record<string, InstalledPlugin[]>;
}

/**
 * Debug logging helper.
 * Only logs when VIBING_DEBUG environment variable is set.
 *
 * @param message - Message to log
 * @param data - Optional data to include in log
 */
function debugLog(message: string, data?: unknown): void {
  if (process.env.VIBING_DEBUG) {
    if (data !== undefined) {
      console.error(`[vibing:plugin-loader] ${message}`, data);
    } else {
      console.error(`[vibing:plugin-loader] ${message}`);
    }
  }
}

/**
 * Check if a path exists on the filesystem.
 *
 * @param path - Path to check
 * @returns Promise resolving to true if path exists, false otherwise
 */
async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

/**
 * Load all installed plugins from ~/.claude/plugins/installed_plugins.json.
 *
 * This function reads the Claude Code plugin registry and returns plugin
 * references in the format expected by the Agent SDK. Only plugins whose
 * installation paths still exist on disk are included.
 *
 * @returns Promise resolving to array of plugin references for the Agent SDK
 *
 * @example
 * ```typescript
 * const plugins = await loadInstalledPlugins();
 * // Returns: [{ type: 'local', path: '/path/to/plugin' }, ...]
 *
 * // Use with Agent SDK:
 * query({ prompt: '...', options: { plugins } });
 * ```
 */
export async function loadInstalledPlugins(): Promise<PluginReference[]> {
  const pluginsFile = join(homedir(), '.claude', 'plugins', 'installed_plugins.json');

  debugLog(`Reading plugins from: ${pluginsFile}`);

  let content: string;
  try {
    content = await readFile(pluginsFile, 'utf8');
  } catch (error) {
    debugLog('Could not read installed_plugins.json', error);
    return [];
  }

  let installed: InstalledPluginsFile;
  try {
    installed = JSON.parse(content) as InstalledPluginsFile;
  } catch (error) {
    debugLog('Could not parse installed_plugins.json', error);
    return [];
  }

  if (!installed.plugins || typeof installed.plugins !== 'object') {
    debugLog('Invalid plugins structure in installed_plugins.json');
    return [];
  }

  // Collect all installation paths
  const allInstallations: InstalledPlugin[] = [];
  for (const installations of Object.values(installed.plugins)) {
    if (Array.isArray(installations)) {
      allInstallations.push(...installations);
    }
  }

  debugLog(`Found ${allInstallations.length} plugin installations`);

  // Check all paths in parallel for better performance
  const pathChecks = await Promise.all(
    allInstallations.map(async (installation) => {
      const exists = await pathExists(installation.installPath);
      if (!exists) {
        debugLog(`Plugin path does not exist: ${installation.installPath}`);
      }
      return { installation, exists };
    })
  );

  // Filter to only existing paths and map to PluginReference format
  const plugins: PluginReference[] = pathChecks
    .filter(({ exists }) => exists)
    .map(({ installation }) => ({
      type: 'local' as const,
      path: installation.installPath,
    }));

  debugLog(`Loaded ${plugins.length} valid plugins`);

  return plugins;
}
