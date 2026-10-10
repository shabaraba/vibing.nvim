import { describe, expect, it } from 'vitest';
import { allTools } from '../tools/index.js';
import { withProfiles } from '../tools/profiles.js';

const BUILTINS = [
  { name: 'default', description: 'Ordinary chat: everything loaded' },
  { name: 'focused', description: 'Six built-in tools' },
  { name: 'reviewer', description: 'Read-only built-in tools' },
];

function profileSchema(tools: typeof allTools): any {
  const create = tools.find((t) => t.name === 'nvim_chat_create');
  return (create?.inputSchema.properties as Record<string, any>).profile;
}

describe('withProfiles', () => {
  // Tool definitions head the prompt cache: with no profile of their own configured, a user's
  // tool list must be the same bytes it always was.
  it('returns the tool list untouched when only the built-ins exist', () => {
    expect(withProfiles(allTools, BUILTINS)).toBe(allTools);
    expect(withProfiles(allTools, [])).toBe(allTools);
  });

  it('names every configured profile, what it is for and what it runs on', () => {
    const tools = withProfiles(allTools, [
      BUILTINS[0],
      BUILTINS[1],
      { name: 'implementer', description: 'Implements a change', agent: 'claude', model: 'sonnet' },
      BUILTINS[2],
    ]);

    const schema = profileSchema(tools);
    expect(schema.enum).toEqual(['default', 'focused', 'implementer', 'reviewer']);
    // Only what the user configured is listed as a kind; the built-ins are in the static text
    expect(schema.description).not.toContain('- focused:');
    expect(schema.description).toContain('- implementer: Implements a change (claude/sonnet)');
    // The original guidance stays in front of the list
    expect(schema.description.startsWith(profileSchema(allTools).description)).toBe(true);
  });

  it('touches no other tool and does not mutate the static list', () => {
    const before = JSON.stringify(allTools);
    const tools = withProfiles(allTools, [...BUILTINS, { name: 'researcher' }]);

    expect(JSON.stringify(allTools)).toBe(before);
    for (const [index, tool] of tools.entries()) {
      if (tool.name !== 'nvim_chat_create') {
        expect(tool).toBe(allTools[index]);
      }
    }
    expect(profileSchema(tools).description).toContain('- researcher: no description');
  });

  it('is deterministic for the same input', () => {
    const profiles = [...BUILTINS, { name: 'implementer', model: 'sonnet' }];
    expect(JSON.stringify(withProfiles(allTools, profiles))).toBe(
      JSON.stringify(withProfiles(allTools, profiles))
    );
  });
});
