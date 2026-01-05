import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

/**
 * List all running Neovim instances with vibing.nvim RPC servers
 *
 * Reads instance registry from ~/.local/share/nvim/vibing-instances
 * and returns information about each running instance including PID, port, cwd, and start time.
 *
 * @param args - Unused, accepts any arguments for MCP compatibility
 * @returns Object with content array containing JSON-formatted instances list
 */
export async function handleListInstances(args: any) {
  const registryPath = path.join(os.homedir(), '.local/share/nvim/vibing-instances');

  if (!fs.existsSync(registryPath)) {
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify({ instances: [] }, null, 2),
        },
      ],
    };
  }

  const files = fs.readdirSync(registryPath);
  const instances = [];

  for (const file of files) {
    if (!file.endsWith('.json')) {
      continue;
    }

    const filePath = path.join(registryPath, file);
    try {
      const content = fs.readFileSync(filePath, 'utf-8');
      const data = JSON.parse(content);

      if (data && data.pid) {
        // Check if process is still alive
        try {
          process.kill(data.pid, 0); // Signal 0: existence check
          instances.push(data);
        } catch (e) {
          // Process is dead, clean up stale registry file
          try {
            fs.unlinkSync(filePath);
          } catch (unlinkErr) {
            // Ignore unlink errors
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
