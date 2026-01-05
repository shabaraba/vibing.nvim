import { promises as fs } from 'fs';
import * as path from 'path';
import * as os from 'os';

/**
 * Get platform-aware registry directory path
 * - Linux/macOS: $XDG_DATA_HOME/nvim/vibing-instances or ~/.local/share/nvim/vibing-instances
 * - Windows: %LOCALAPPDATA%\nvim-data\vibing-instances
 * @returns Registry directory path
 */
function getRegistryPath(): string {
  const platform = os.platform();

  if (platform === 'win32') {
    // Windows: use %LOCALAPPDATA%\nvim-data\vibing-instances
    const localAppData = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    return path.join(localAppData, 'nvim-data', 'vibing-instances');
  } else {
    // Linux/macOS: use XDG_DATA_HOME or ~/.local/share
    const xdgDataHome = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
    return path.join(xdgDataHome, 'nvim', 'vibing-instances');
  }
}

/**
 * List all running Neovim instances with vibing.nvim RPC servers
 *
 * Reads instance registry from platform-specific data directory
 * and returns information about each running instance including PID, port, cwd, and start time.
 *
 * @param args - Unused, accepts any arguments for MCP compatibility
 * @returns Object with content array containing JSON-formatted instances list
 */
export async function handleListInstances(args: any) {
  const registryPath = getRegistryPath();

  try {
    await fs.access(registryPath);
  } catch {
    // Registry directory doesn't exist - no instances
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify({ instances: [] }, null, 2),
        },
      ],
    };
  }

  const files = await fs.readdir(registryPath);
  const instances = [];

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

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify({ instances }, null, 2),
      },
    ],
  };
}
