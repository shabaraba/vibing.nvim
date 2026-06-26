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
/**
 * Read enabled plugin IDs from a single settings.json file.
 */
async function readEnabledPluginsFromFile(settingsFile: string): Promise<Record<string, boolean>> {
  try {
    const content = await readFile(settingsFile, 'utf8');
    const settings = JSON.parse(content) as { enabledPlugins?: Record<string, boolean> };
    if (settings.enabledPlugins && typeof settings.enabledPlugins === 'object') {
      return settings.enabledPlugins;
    }
  } catch {
    // File missing or invalid JSON — ignore
  }
  return {};
}

/**
 * Read the merged set of enabled plugin IDs from both user (~/.claude/settings.json)
 * and project (.claude/settings.json) settings files.
 * Returns null if neither file has enabledPlugins (meaning no filtering should apply).
 */
async function loadEnabledPluginIds(): Promise<Set<string> | null> {
  const userSettingsFile = join(homedir(), '.claude', 'settings.json');
  const projectSettingsFile = join(process.cwd(), '.claude', 'settings.json');
  const localSettingsFile = join(process.cwd(), '.claude', 'settings.local.json');

  const [userEnabled, projectEnabled, localEnabled] = await Promise.all([
    readEnabledPluginsFromFile(userSettingsFile),
    readEnabledPluginsFromFile(projectSettingsFile),
    readEnabledPluginsFromFile(localSettingsFile),
  ]);

  const merged = { ...userEnabled, ...projectEnabled, ...localEnabled };
  if (Object.keys(merged).length === 0) {
    debugLog('No enabledPlugins found in user, project, or local settings, loading all installed plugins');
    return null;
  }

  const enabled = new Set(
    Object.entries(merged)
      .filter(([, v]) => v === true)
      .map(([k]) => k)
  );
  if (enabled.size === 0) {
    // Only false entries present — no allowlist to apply, load all plugins
    debugLog('enabledPlugins has no positively-enabled entries; loading all installed plugins');
    return null;
  }
  debugLog(`Enabled plugins (user+project+local): ${[...enabled].join(', ')}`);
  return enabled;
}

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

  // Load enabled plugin IDs to filter completions to only CLI-available plugins
  const enabledIds = await loadEnabledPluginIds();

  // Collect installation paths.
  // For each plugin ID, pick only the best installation to avoid duplicate skills
  // when multiple versions are cached (e.g. scope=user 1.1.0 + scope=local 1.1.1).
  // Inclusion rules:
  //   scope=local → always include (explicitly project-installed, always active)
  //   scope=user  → include only if in enabledPlugins (needs explicit enable)
  // Preference order when multiple installs exist: local > user scope, then most recent.
  const allInstallations: InstalledPlugin[] = [];
  for (const [pluginId, installations] of Object.entries(installed.plugins)) {
    if (!Array.isArray(installations) || installations.length === 0) continue;

    const hasLocalInstall = installations.some((inst) => inst.scope === 'local');
    // null means no filter — include all (mirrors behaviour when no enabledPlugins is configured)
    const isEnabledInSettings = enabledIds === null || enabledIds.has(pluginId);

    if (!hasLocalInstall && !isEnabledInSettings) {
      debugLog(`Skipping plugin (not local and not enabled): ${pluginId}`);
      continue;
    }

    // Pick best: local scope preferred, then most recent lastUpdated
    const best = installations.reduce((a, b) => {
      if (a.scope === 'local' && b.scope !== 'local') return a;
      if (b.scope === 'local' && a.scope !== 'local') return b;
      return a.lastUpdated >= b.lastUpdated ? a : b;
    });
    allInstallations.push(best);
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
