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
import { resolveInstalledPlugins, resolveSessionPluginDirs } from './lib/plugin-loader.js';

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

/** A YAML block scalar header: `|` or `>` plus an optional indent and chomping indicator. */
const BLOCK_SCALAR_HEADER = /^[|>](?:\d[-+]?|[-+]\d?)?$/;

/**
 * Read one top-level frontmatter key, following a YAML block scalar onto its indented
 * continuation lines.
 *
 * A line-anchored `^key:\s*(.+)$` captures the block scalar's own header, so a skill written
 * with `description: >-` had ">-" as its entire description in the `/` picker. Continuation
 * lines are joined with a space for `|` as well as `>`, because the one consumer of this value
 * is a completion menu — `omnifunc`'s `menu` field is a single line, so a literal block's
 * newlines have nowhere to go.
 *
 * @returns the value, or null when the key is absent.
 */
function readFrontmatterScalar(lines: string[], key: string): string | null {
  const prefix = `${key}:`;
  const index = lines.findIndex((line) => line.startsWith(prefix));
  if (index === -1) return null;

  const inline = lines[index].slice(prefix.length).trim();
  if (!BLOCK_SCALAR_HEADER.test(inline)) return inline;

  const continued: string[] = [];
  for (const line of lines.slice(index + 1)) {
    if (line.trim() === '') continue;
    // Back at column 0 is the next top-level key, which ends the block.
    if (!/^\s/.test(line)) break;
    continued.push(line.trim());
  }
  return continued.join(' ');
}

/** Parse a SKILL.md file's YAML frontmatter for name/description/user-invocable. */
async function parseSkillFrontmatter(
  skillMdPath: string
): Promise<{ name: string; description: string; userInvocable: boolean } | null> {
  let content: string;
  try {
    content = await readFile(skillMdPath, 'utf8');
  } catch {
    return null;
  }

  const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---/);
  if (!frontmatterMatch) return null;

  const lines = frontmatterMatch[1].split('\n');
  const name = readFrontmatterScalar(lines, 'name');
  if (!name) return null;
  // Default true, matching Claude Code CLI's own opt-out convention: skills are
  // visible in the slash menu unless they explicitly declare `user-invocable: false`.
  const userInvocable = readFrontmatterScalar(lines, 'user-invocable');

  return {
    name,
    description: readFrontmatterScalar(lines, 'description') ?? '',
    userInvocable: userInvocable === null ? true : userInvocable !== 'false',
  };
}

/**
 * Derive a plugin's short name from its registry id, e.g.
 * "vibing-nvim@vibing" -> "vibing-nvim", "document-skills@anthropic-agent-skills" -> "document-skills".
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
    .filter(
      (skill): skill is { name: string; description: string; userInvocable: boolean } =>
        skill !== null && skill.userInvocable
    )
    .map((skill) => ({
      name: `${pluginName}:${skill.name}`,
      description: skill.description,
      argumentHint: '',
    }));
}

async function listCommands() {
  try {
    // Argv is a list of absolute plugin directories vibing.nvim self-hosts for the session via
    // the CLI's `--plugin-dir`, already resolved by the Lua side. They go first because that is
    // the precedence the CLI itself applies to a duplicate plugin name: the earlier
    // `--plugin-dir` wins, and an installed plugin of the same name never loads.
    const sessionPlugins = await resolveSessionPluginDirs(process.argv.slice(2));
    const installedPlugins = await resolveInstalledPlugins();

    // First occurrence of a plugin name wins, across both lists. The Lua side already
    // deduplicates the directories it passes, but this is also a standalone binary taking a
    // caller's argv, and listing a skill the CLI would not load offers a `/` entry that silently
    // does nothing.
    const seen = new Set<string>();
    const plugins = [...sessionPlugins, ...installedPlugins].filter((plugin) => {
      const name = pluginShortName(plugin.id);
      if (seen.has(name)) return false;
      seen.add(name);
      return true;
    });

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
