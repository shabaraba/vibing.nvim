import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { withRpcPort, requireRpcPort } from './common.js';

export const dapTools: Tool[] = [
  {
    name: 'nvim_dap_get_state',
    description:
      'Ask whether a debug session is running and where it is stopped. Call this first — the ' +
      'other dap tools need a stopped program, and this says so plainly instead of failing.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({}),
      required: requireRpcPort(),
    },
  },
  {
    name: 'nvim_dap_get_stack_trace',
    description: 'Stack frames of the stopped thread, innermost first.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        thread_id: {
          type: 'number',
          description: 'Defaults to the thread that is stopped.',
        },
      }),
      required: requireRpcPort(),
    },
  },
  {
    name: 'nvim_dap_get_variables',
    description:
      'Variables in a stack frame, grouped by scope (locals, globals, ...). Only the top level of ' +
      'each scope is expanded; use nvim_dap_evaluate to look inside a specific value.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        frame_id: {
          type: 'number',
          description: 'Defaults to the frame the debugger is currently stopped in.',
        },
      }),
      required: requireRpcPort(),
    },
  },
  {
    name: 'nvim_dap_set_breakpoint',
    description:
      'Set a breakpoint. Works whether or not a session is running; a live session picks it up ' +
      'immediately. Does not move the user to the file.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        file: { type: 'string', description: 'Existing file, absolute or relative to the cwd.' },
        line: { type: 'number', description: '1-based line number.' },
        condition: {
          type: 'string',
          description: 'Optional expression; the program only stops when it is true.',
        },
      }),
      required: requireRpcPort(['file', 'line']),
    },
  },
  {
    name: 'nvim_dap_evaluate',
    description:
      'Evaluate an expression in the debug session, in the language being debugged. This runs in ' +
      'the debuggee — an expression with side effects will have them.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        expression: { type: 'string', description: 'Expression in the debuggee language.' },
        frame_id: {
          type: 'number',
          description: 'Defaults to the frame the debugger is currently stopped in.',
        },
      }),
      required: requireRpcPort(['expression']),
    },
  },
];
