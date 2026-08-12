/**
 * Reads the registry of running Neovim instances written by
 * lua/vibing/infrastructure/rpc/registry.lua.
 *
 * This sits beside `rpc.ts` rather than under `handlers/` because both the transport (to resolve
 * an omitted rpc_port) and the `nvim_list_instances` handler need it, and handlers depend on the
 * transport, never the other way round.
 */
import { promises as fs } from 'fs';
import * as path from 'path';
import * as os from 'os';

/**
 * Overrides the registry directory. Must match ENV_REGISTRY_DIR in
 * lua/vibing/infrastructure/rpc/registry.lua, or the two sides look at different directories.
 */
const REGISTRY_DIR_ENV = 'VIBING_INSTANCES_DIR';

/**
 * Get platform-aware registry directory path
 *
 * IMPORTANT: Must match get_registry_dir() in lua/vibing/infrastructure/rpc/registry.lua
 * which uses vim.fn.stdpath("data") + "/vibing-instances"
 *
 * Platform paths:
 * - Linux/macOS: $XDG_DATA_HOME/nvim/vibing-instances or ~/.local/share/nvim/vibing-instances
 * - Windows: %LOCALAPPDATA%\nvim-data\vibing-instances
 *
 * @returns Registry directory path
 */
function getRegistryPath(): string {
  const override = process.env[REGISTRY_DIR_ENV];
  if (override) {
    return override;
  }

  const platform = os.platform();

  if (platform === 'win32') {
    // Windows: use %LOCALAPPDATA%\nvim-data\vibing-instances
    // Note: This should match Neovim's stdpath("data") on Windows
    const localAppData = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    return path.join(localAppData, 'nvim-data', 'vibing-instances');
  } else {
    // Linux/macOS: use XDG_DATA_HOME or ~/.local/share
    const xdgDataHome = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
    return path.join(xdgDataHome, 'nvim', 'vibing-instances');
  }
}

/**
 * A live Neovim instance as recorded by lua/vibing/infrastructure/rpc/registry.lua.
 */
export interface InstanceInfo {
  pid: number;
  port: number;
  cwd?: string;
  started_at?: number;
}

/**
 * Read the registry and return only the instances whose owning Neovim is still alive, newest
 * first. Registry files belonging to dead processes are unlinked on the way past.
 *
 * @returns Live instances, or an empty array when the registry directory does not exist
 */
export async function listLiveInstances(): Promise<InstanceInfo[]> {
  const registryPath = getRegistryPath();

  try {
    await fs.access(registryPath);
  } catch {
    // Registry directory doesn't exist - no instances
    return [];
  }

  const files = await fs.readdir(registryPath);
  const instances: InstanceInfo[] = [];

  for (const file of files) {
    if (!file.endsWith('.json')) {
      continue;
    }

    const filePath = path.join(registryPath, file);
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const data = JSON.parse(content);

      if (data && data.pid) {
        // Check if process is still alive
        try {
          process.kill(data.pid, 0); // Signal 0: existence check
          instances.push(data);
        } catch (e) {
          // Process is dead, clean up stale registry file
          try {
            // Check if file still exists before attempting deletion
            await fs.access(filePath);
            await fs.unlink(filePath);
          } catch (unlinkErr) {
            // File already deleted or permission denied - ignore
          }
        }
      }
    } catch (e) {
      // Ignore files that can't be read or parsed
      continue;
    }
  }

  // Sort by started_at (newest first)
  instances.sort((a, b) => {
    return (b.started_at || 0) - (a.started_at || 0);
  });

  return instances;
}
