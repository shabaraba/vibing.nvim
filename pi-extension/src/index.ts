/**
 * vibing.nvim's Pi extension: the permission gate, and the two web tools Pi does not have.
 *
 * Pi ships exactly seven built-in tools — `bash`, `read`, `write`, `edit`, `ls`, `grep`, `find`
 * (`pi --help`, confirmed against `dist/core/tools/` in 0.87.1). There is no web tool of any kind,
 * where claude and codex both have one, so a Pi chat could not read a linked issue or look
 * anything up. `web_fetch` and `web_search` fill that gap.
 *
 * They are registered here, beside the gate, and not as a separate extension: Pi's `tool_call`
 * hook is installed once per Agent and covers every tool including these, so shipping them
 * together is what guarantees a tool this file adds cannot outlive the gate this file installs.
 * `pi_command_builder` loads the whole file or none of it.
 *
 * @see ./permission_bridge.ts — the gate, and why Pi needs one at all
 * @see ./web_fetch.ts, ./web_search.ts — what each tool copies from claude, and what it cannot
 */

import { decide } from './permission_bridge.js';
import { webFetchTool } from './web_fetch.js';
import { createWebSearchTool, resolveProvider } from './web_search.js';

interface PiApi {
  on: (event: string, handler: (event: any, ctx: any) => unknown) => void;
  registerTool: (tool: unknown) => void;
}

export default function (pi: PiApi) {
  pi.on('tool_call', decide);

  pi.registerTool(webFetchTool);

  // Absent rather than always-failing when no search backend is configured: `web_search.ts`
  // explains why, and `backends.pi.web_search` / the credential env vars are how it is turned on.
  const provider = resolveProvider();
  if (provider) pi.registerTool(createWebSearchTool(provider));
}
