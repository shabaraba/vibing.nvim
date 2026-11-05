import { withRpcPort } from './common.js';

export const PERMISSION_PROMPT_TOOL = 'nvim_permission_prompt';

export const permissionTools = [
  {
    name: PERMISSION_PROMPT_TOOL,
    description:
      'Internal to vibing.nvim: the target of `--permission-prompt-tool`. Claude Code calls it when ' +
      'its own permission gate needs a human, and vibing.nvim shows the question in the chat. ' +
      'vibing.nvim also lists it in --disallowedTools, so a model never calls it.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        tool_name: { type: 'string' as const, description: 'Tool the CLI is asking about.' },
        input: { type: 'object' as const, description: 'That tool call input.' },
        tool_use_id: { type: 'string' as const, description: 'Id of that tool call.' },
      }),
      required: ['tool_name', 'input'],
    },
  },
];
