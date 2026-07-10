/**
 * List available commands/skills for the chat buffer's `/` completion picker.
 *
 * This scans installed plugin skill directories directly instead of going
 * through the Agent SDK's `query().supportedCommands()`, which silently
 * drops plugins whose plugin.json contains fields like $schema/displayName
 * and requires spinning up a full CLI subprocess just to enumerate local
 * files. Project/user skills (.claude/skills/) are scanned separately on
 * the Lua side (see skills.lua) and are not duplicated here.
 *
 * Outputs JSON array of {name, description, argumentHint} objects.
 */

import { readdir, readFile } from 'fs/promises';
import { join } from 'path';
import { safeJsonStringify } from './lib/utils.js';
import { resolveInstalledPlugins } from './lib/plugin-loader.js';

interface CommandEntry {
  name: string;
  description: string;
  argumentHint: string;
}

// Built-in CLI slash commands are not backed by files, so they can't be
// discovered by scanning the filesystem. This list rarely changes.
const BUILTIN_COMMANDS: CommandEntry[] = [
  {
    name: 'compact',
    description:
      'Clear conversation history but keep a summary in context. Optional: /compact [instructions for summarization]',
    argumentHint: '<optional custom summarization instructions>',
  },
  { name: 'context', description: 'Show current context usage', argumentHint: '' },
  {
    name: 'cost',
    description: 'Show the total cost and duration of the current session',
    argumentHint: '',
  },
  {
    name: 'init',
    description: 'Initialize a new CLAUDE.md file with codebase documentation',
    argumentHint: '',
  },
  { name: 'pr-comments', description: 'Get comments from a GitHub pull request', argumentHint: '' },
  { name: 'release-notes', description: 'View release notes', argumentHint: '' },
  { name: 'review', description: 'Review a pull request', argumentHint: '' },
  {
    name: 'security-review',
    description: 'Complete a security review of the pending changes on the current branch',
    argumentHint: '',
  },
];

/** Parse a SKILL.md file's YAML frontmatter for name/description. */
async function parseSkillFrontmatter(
  skillMdPath: string
): Promise<{ name: string; description: string } | null> {
  let content: string;
  try {
    content = await readFile(skillMdPath, 'utf8');
  } catch {
    return null;
  }

  const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---/);
  if (!frontmatterMatch) return null;

  const nameMatch = frontmatterMatch[1].match(/^name:\s*(.+)$/m);
  if (!nameMatch) return null;
  const descMatch = frontmatterMatch[1].match(/^description:\s*(.+)$/m);

  return {
    name: nameMatch[1].trim(),
    description: descMatch ? descMatch[1].trim() : '',
  };
}

/**
 * Derive a plugin's short name from its registry id, e.g.
 * "vibing-nvim@vibing-nvim" -> "vibing-nvim", "document-skills@anthropic-agent-skills" -> "document-skills".
 * This is how Claude Code itself namespaces skill invocations ("plugin:skill"),
 * and it's reliable even for plugins nested in a marketplace repo that don't
 * ship their own .claude-plugin/plugin.json (e.g. document-skills).
 */
function pluginShortName(id: string): string {
  return id.split('@')[0];
}

/** Scan a plugin's skills/ directory for SKILL.md files, namespaced as "pluginName:skillName". */
async function scanPluginSkills(pluginPath: string, pluginName: string): Promise<CommandEntry[]> {
  const skillsDir = join(pluginPath, 'skills');
  let entries;
  try {
    entries = await readdir(skillsDir, { withFileTypes: true });
  } catch {
    return [];
  }

  const parsed = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => parseSkillFrontmatter(join(skillsDir, entry.name, 'SKILL.md')))
  );

  return parsed
    .filter((skill): skill is { name: string; description: string } => skill !== null)
    .map((skill) => ({
      name: `${pluginName}:${skill.name}`,
      description: skill.description,
      argumentHint: '',
    }));
}

async function listCommands() {
  try {
    const plugins = await resolveInstalledPlugins();

    const pluginSkillLists = await Promise.all(
      plugins.map((plugin) => scanPluginSkills(plugin.path, pluginShortName(plugin.id)))
    );

    const commands: CommandEntry[] = [...pluginSkillLists.flat(), ...BUILTIN_COMMANDS];

    // Write output and wait for stdout to flush before exiting.
    // process.exit() called immediately after console.log() can truncate output
    // when stdout is a pipe and the data exceeds the 65536-byte OS pipe buffer.
    await new Promise<void>((resolve, reject) => {
      process.stdout.write(safeJsonStringify(commands) + '\n', (err) => {
        if (err) reject(err);
        else resolve();
      });
    });

    process.exit(0);
  } catch (error) {
    console.error(safeJsonStringify({ error: String(error) }));
    process.exit(1);
  }
}

listCommands();
