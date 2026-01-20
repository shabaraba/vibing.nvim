/**
 * Plugin loader for vibing.nvim
 * Loads installed plugins from ~/.claude/plugins/installed_plugins.json
 * Uses the SDK's native plugin loading mechanism
 */

import { readFile, access } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';

export interface PluginReference {
  type: 'local';
  path: string;
}

interface InstalledPlugin {
  scope: string;
  installPath: string;
  version: string;
  installedAt: string;
  lastUpdated: string;
  gitCommitSha: string;
}

interface InstalledPluginsFile {
  version: number;
  plugins: Record<string, InstalledPlugin[]>;
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

/**
 * Load all installed plugins from ~/.claude/plugins/installed_plugins.json
 * Returns plugin references in the format expected by the Agent SDK
 */
export async function loadInstalledPlugins(): Promise<PluginReference[]> {
  const plugins: PluginReference[] = [];
  const pluginsFile = join(homedir(), '.claude', 'plugins', 'installed_plugins.json');

  try {
    const content = await readFile(pluginsFile, 'utf8');
    const installed = JSON.parse(content) as InstalledPluginsFile;

    for (const [, installations] of Object.entries(installed.plugins)) {
      for (const installation of installations) {
        // Verify the plugin path exists before adding
        if (await pathExists(installation.installPath)) {
          plugins.push({
            type: 'local',
            path: installation.installPath,
          });
        }
      }
    }
  } catch {
    // installed_plugins.json doesn't exist or can't be parsed
    // This is fine - user may not have any plugins installed
  }

  return plugins;
}
