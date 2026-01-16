/**
 * Utilities for detecting vibing.nvim installation path
 */
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { existsSync } from 'fs';

/**
 * Find vibing.nvim installation path
 *
 * Detection strategy:
 * 1. Check VIBING_NVIM_PATH environment variable (if explicitly set)
 * 2. Resolve from __dirname (bin/lib/ -> project root)
 * 3. Fallback to null if not found
 *
 * @returns vibing.nvim installation path or null
 */
export function findVibingNvimInstallPath(): string | null {
  // Strategy 1: Environment variable
  if (process.env.VIBING_NVIM_PATH && existsSync(process.env.VIBING_NVIM_PATH)) {
    return process.env.VIBING_NVIM_PATH;
  }

  // Strategy 2: Resolve from current module location
  // This file is at: <vibing-root>/bin/lib/vibing-path.ts
  // Or when compiled: <vibing-root>/dist/bin/lib/vibing-path.js
  try {
    const __filename = fileURLToPath(import.meta.url);
    const __dirname = dirname(__filename);

    // From dist/bin/lib/ -> go up 3 levels to project root
    // From bin/lib/ -> go up 2 levels to project root
    let rootPath = join(__dirname, '..', '..', '..');

    // Check if this is the compiled dist version
    if (__dirname.includes('/dist/')) {
      // We're already 3 levels deep, this is correct
    } else {
      // We're in source bin/lib/, go up 2 levels
      rootPath = join(__dirname, '..', '..');
    }

    // Verify it's a vibing.nvim installation by checking for marker files
    if (existsSync(join(rootPath, 'package.json')) && existsSync(join(rootPath, 'lua', 'vibing'))) {
      return rootPath;
    }
  } catch (error) {
    // Failed to resolve from module location
  }

  return null;
}
