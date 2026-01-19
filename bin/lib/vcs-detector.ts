/**
 * VCS operation detection for mote integration
 * Detects git and jj operations that should trigger mote snapshots
 */

// VCS operations that should trigger snapshot creation
const VCS_OPERATIONS = {
  git: ['checkout', 'switch', 'merge', 'rebase', 'pull', 'stash', 'reset'],
  jj: ['edit', 'new', 'abandon', 'rebase', 'squash', 'restore', 'undo'],
};

/**
 * Check if a command is a VCS operation that should trigger snapshot
 * @param command Full bash command string
 * @returns Operation name if it's a trigger command, null otherwise
 */
export function detectVcsOperation(command: string): string | null {
  const trimmedCommand = command.trim();

  // Check git operations
  for (const op of VCS_OPERATIONS.git) {
    const pattern = new RegExp(`^git\\s+${op}(\\s|$)`);
    if (pattern.test(trimmedCommand)) {
      return `git ${op}`;
    }
  }

  // Check jj operations
  for (const op of VCS_OPERATIONS.jj) {
    const pattern = new RegExp(`^jj\\s+${op}(\\s|$)`);
    if (pattern.test(trimmedCommand)) {
      return `jj ${op}`;
    }
  }

  return null;
}
