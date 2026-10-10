import type { Tool } from '@modelcontextprotocol/sdk/types.js';

/**
 * A chat profile as `list_profiles` reports it (`core/constants/profiles.lua` → `catalog`).
 */
export interface ProfileEntry {
  name: string;
  description?: string;
  agent?: string;
  model?: string;
  effort?: string;
}

/**
 * The profiles every Neovim has. The static `profile` description already says what each is for,
 * so one of these is only worth listing when the user's config gave it something of its own to
 * run on (`{ name = "focused", model = "haiku" }`) — otherwise the model would assume the
 * user's default, usually as expensive as the orchestrator itself.
 */
const BUILTIN_PROFILES = new Set(['default', 'focused', 'reviewer']);

function worthListing(p: ProfileEntry): boolean {
  return !BUILTIN_PROFILES.has(p.name) || Boolean(p.agent || p.model || p.effort);
}

/**
 * Write the user's configured profiles into `nvim_chat_create`'s `profile` argument.
 *
 * A tool description is static, while `agent.profiles` is whatever this user's config says — so
 * without this an orchestrator only learns the names by calling `nvim_chat_list` first, which
 * nothing guarantees it does. Putting them in the schema means a model that loads the tool sees
 * them, with what each is for and the model it runs on.
 *
 * Returns the tools untouched when only the built-ins exist, as they are. Tool definitions sit at the front of
 * the prompt cache, so the common case must produce exactly the bytes it always did, and the
 * output for a given config must be the same on every call (the Lua side sorts the list).
 */
export function withProfiles(tools: Tool[], profiles: ProfileEntry[]): Tool[] {
  const configured = profiles.filter(worthListing);
  if (configured.length === 0) {
    return tools;
  }

  return tools.map((tool) => {
    if (tool.name !== 'nvim_chat_create') {
      return tool;
    }
    const properties = (tool.inputSchema.properties ?? {}) as Record<string, any>;
    const profile = properties.profile ?? { type: 'string' };
    const lines = configured.map((p) => {
      const runsOn = [p.agent, p.model].filter(Boolean).join('/');
      const what = p.description ?? 'no description';
      return `- ${p.name}: ${what}${runsOn ? ` (${runsOn})` : ''}`;
    });
    return {
      ...tool,
      inputSchema: {
        ...tool.inputSchema,
        properties: {
          ...properties,
          profile: {
            ...profile,
            enum: profiles.map((p) => p.name),
            description: `${profile.description ?? ''}\nConfigured kinds:\n${lines.join('\n')}`,
          },
        },
      },
    };
  });
}
