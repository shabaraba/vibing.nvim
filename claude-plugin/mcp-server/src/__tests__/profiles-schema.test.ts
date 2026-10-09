import { describe, expect, it } from 'vitest';
import { allTools } from '../tools/index.js';
import { withProfiles } from '../tools/profiles.js';

const BUILTINS = [
  { name: 'default', description: 'Ordinary chat: everything loaded' },
  { name: 'worker', description: 'Driven by another chat' },
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
      { name: 'implementer', description: 'Implements a change', agent: 'claude', model: 'sonnet' },
      BUILTINS[1],
    ]);

    const schema = profileSchema(tools);
    expect(schema.enum).toEqual(['default', 'implementer', 'worker']);
    expect(schema.description).toContain('- implementer: Implements a change (claude/sonnet)');
    // The original guidance stays in front of the list
    expect(schema.description.startsWith(profileSchema(allTools).description)).toBe(true);
  });

  it('touches no other tool and does not mutate the static list', () => {
    const before = JSON.stringify(allTools);
    const tools = withProfiles(allTools, [...BUILTINS, { name: 'reviewer' }]);

    expect(JSON.stringify(allTools)).toBe(before);
    for (const [index, tool] of tools.entries()) {
      if (tool.name !== 'nvim_chat_create') {
        expect(tool).toBe(allTools[index]);
      }
    }
    expect(profileSchema(tools).description).toContain('- reviewer: no description');
  });

  it('is deterministic for the same input', () => {
    const profiles = [...BUILTINS, { name: 'implementer', model: 'sonnet' }];
    expect(JSON.stringify(withProfiles(allTools, profiles))).toBe(
      JSON.stringify(withProfiles(allTools, profiles))
    );
  });
});
