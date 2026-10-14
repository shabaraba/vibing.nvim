import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { withRpcPort } from './common.js';

export const dapTools: Tool[] = [
  // The three reads are one tool; the breakpoint and evaluate stay their own, because both change
  // something (evaluate runs code in the debuggee) and a rule naming a tool must still be able to
  // single those out.
  {
    name: 'nvim_dap_inspect',
    description:
      'Read the debug session. `state` (call it first): whether a session is running and where it ' +
      'is stopped — the other reads need a stopped program, and this says so plainly instead of ' +
      'failing. `stack_trace`: frames of the stopped thread, innermost first. `variables`: a ' +
      "frame's variables by scope, top level only; use nvim_dap_evaluate to look inside a value.",
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        what: { type: 'string', enum: ['state', 'stack_trace', 'variables'] },
        thread_id: {
          type: 'number',
          description: 'stack_trace only. Defaults to the thread that is stopped.',
        },
        frame_id: {
          type: 'number',
          description: 'variables only. Defaults to the frame the debugger is stopped in.',
        },
      }),
      required: ['what'],
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
      required: ['file', 'line'],
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
      required: ['expression'],
    },
  },
];
