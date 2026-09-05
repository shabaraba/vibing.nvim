import { callNeovim } from '../rpc.js';
import {
  validateBoolean,
  validateBufferParams,
  validateChatTarget,
  validateFilePath,
  validatePositiveInteger,
  validateRequired,
} from '../validation/schema.js';

const CHAT_STATUS_TEXT: Record<string, string> = {
  responding:
    'vibing.nvim chat buffer status: responding. A reply is being streamed into this buffer ' +
    'right now, so what you just read is incomplete. Read it again later to see the finished ' +
    'response.',
  idle: 'vibing.nvim chat buffer status: idle. No request is in flight for this buffer, so what you just read is the complete transcript so far.',
  waiting_approval:
    'vibing.nvim chat buffer status: waiting_approval. The chat stopped on a tool-approval ' +
    'prompt and will not continue until someone answers it. Its task is not done.',
  asked_question:
    'vibing.nvim chat buffer status: asked_question. The chat stopped to ask a question and ' +
    'is waiting for an answer. Its task is not done.',
  error:
    'vibing.nvim chat buffer status: error. The last turn ended with an error. Read the tail ' +
    'of the transcript for the message before treating its task as done.',
};

/**
 * Retrieve the contents of a Neovim buffer and return them as a single text node.
 *
 * For a vibing.nvim chat buffer a second text node reports whether a reply is currently being
 * streamed into it. That is what lets an orchestrator poll a worker chat for completion
 * (see the `vibing-orchestrate` skill) instead of guessing from the transcript's shape — a
 * turn that ended in an error, or one still running silent tool calls, both look "finished"
 * to a text heuristic.
 *
 * It is a separate content block rather than a line appended to the transcript so it can never
 * be mistaken for something the buffer actually contains.
 *
 * A chat can be named by `file_path` instead — the form that survives a Neovim restart, since a
 * bufnr only means anything in the session that issued it. The Lua side opens the chat if it is
 * closed (`application/chat/chat_locator.lua`).
 *
 * A large buffer (a long-running chat, easily hundreds of thousands of lines) can be read as just
 * its tail (`tail_lines`) or just its last section (`last_section`, cut at the last `## ...`
 * heading) instead of in full — reading "all of it" is the same as "none of it" once it no longer
 * fits (#694). Whichever way it was asked for, the result reports the buffer's real total line
 * count so the caller still learns the overall scale even when it only saw the tail.
 *
 * @param args - An object with `bufnr` or `file_path` naming what to retrieve, optional
 *   `tail_lines` / `last_section` to window a large buffer, and optional `rpc_port`.
 * @returns An object with `content` containing the buffer's contents (lines joined with `\n`),
 *   plus a chat-status node when the buffer is a vibing.nvim chat, plus a total-line-count node
 *   when the result was windowed down from the buffer's full size.
 */
export async function handleGetBuffer(args: any) {
  // Collapse an explicit null to "not given", matching nvim_chat_send_message.
  const bufnr = args?.bufnr ?? undefined;
  const file_path = args?.file_path ?? undefined;
  const tail_lines = args?.tail_lines ?? undefined;
  const last_section = args?.last_section ?? undefined;

  if (bufnr !== undefined) {
    validateBufferParams({ bufnr });
  }
  if (tail_lines !== undefined) {
    validatePositiveInteger(tail_lines, 'tail_lines');
  }
  if (last_section !== undefined) {
    validateBoolean(last_section, 'last_section');
  }
  // Neither is fine here — it falls back to the current buffer, unlike a send.
  validateChatTarget({ bufnr, file_path });
  const result = await callNeovim(
    'buf_get_lines',
    { bufnr, file_path, include_chat_status: true, tail_lines, last_section },
    args?.rpc_port
  );

  // A Neovim running an older plugin version ignores include_chat_status (and, with it,
  // tail_lines/last_section/total_lines) and answers with the bare line array this tool used to
  // get.
  const lines: string[] = Array.isArray(result) ? result : result.lines;
  const state: string | undefined = Array.isArray(result) ? undefined : result.chat_status;
  const totalLines: number | undefined = Array.isArray(result) ? undefined : result.total_lines;

  // Refuse rather than hand back the wrong buffer's text. A Neovim too old to know `file_path`
  // ignores it and answers for `bufnr or 0` — the current buffer — which reads as a perfectly
  // healthy transcript of the chat that was asked for, reported `idle`. Only a Neovim that
  // understands the argument reports which buffer it read, so its absence is the signal.
  if (file_path !== undefined && (Array.isArray(result) || result?.bufnr === undefined)) {
    throw new Error(
      'This Neovim is too old to address a chat by file_path — it answered without saying which ' +
        'buffer it read. Update vibing.nvim, or pass bufnr instead.'
    );
  }

  const content = [{ type: 'text', text: lines.join('\n') }];
  if (totalLines !== undefined && totalLines !== lines.length) {
    // Only reported when the result was actually windowed down — a full read already says its
    // own size, and repeating it would just be noise.
    content.push({
      type: 'text',
      text: `Showing ${lines.length} of ${totalLines} total lines in this buffer.`,
    });
  }
  if (state) {
    // A status this server has no wording for still gets a line. Rendering nothing is the worst
    // available answer for `error` or `waiting_approval` — silence reads as a healthy chat, which
    // is the same silent-ignore failure the plugin-manifest check exists to prevent.
    content.push({
      type: 'text',
      text:
        CHAT_STATUS_TEXT[state] ??
        `vibing.nvim chat buffer status: ${state}. This server has no description for that ` +
          `status; read the tail of the transcript before treating the chat's task as done.`,
    });
  }
  return { content };
}

/**
 * Update a Neovim buffer's lines.
 *
 * @param args - Object containing `lines` (array of strings), optional `bufnr` (buffer number), and optional `rpc_port`; `lines` are the new buffer contents.
 * @returns An object with content confirming the buffer was updated, including file path metadata.
 * @throws Error if `lines` is missing on `args`.
 */
export async function handleSetBuffer(args: any) {
  validateRequired(args?.lines, 'lines');
  if (args?.bufnr !== undefined) {
    validateBufferParams({ bufnr: args.bufnr });
  }

  const result = await callNeovim(
    'buf_set_lines',
    {
      lines: args.lines,
      bufnr: args.bufnr,
    },
    args?.rpc_port
  );

  // Include file path in response metadata for tracking modified files
  const metadata = result.filename
    ? { filename: result.filename, bufnr: result.bufnr }
    : { bufnr: result.bufnr };

  return {
    content: [
      {
        type: 'text',
        text: `Buffer updated successfully${result.filename ? ` (${result.filename})` : ''}`,
      },
    ],
    _meta: metadata, // Include metadata for agent-wrapper to track
  };
}

/**
 * Retrieve current file information from Neovim and return it as pretty-printed JSON in a content payload.
 *
 * @param args - Object with optional `rpc_port` to target specific Neovim instance.
 * @returns An object with a `content` array containing a single text node whose `text` is the JSON-formatted current file information.
 */
export async function handleGetInfo(args: any) {
  const info = await callNeovim('get_current_file', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(info, null, 2) }],
  };
}

/**
 * Get a pretty-printed JSON representation of all Neovim buffers.
 *
 * @param args - Object with optional `rpc_port` to target specific Neovim instance.
 * @returns An object with a `content` array containing one text node whose `text` is the pretty-printed JSON list of buffers.
 */
export async function handleListBuffers(args: any) {
  const buffers = await callNeovim('list_buffers', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(buffers, null, 2) }],
  };
}

/**
 * Load a file into a Neovim buffer and return the operation result as pretty-printed JSON.
 *
 * @param args - Object containing parameters for loading the buffer.
 * @param args.filepath - Path to the file to load into the buffer; required.
 * @param args.rpc_port - Optional RPC port to target specific Neovim instance.
 * @returns An object with a `content` array containing a single text node with the JSON-formatted result.
 * @throws Error if `args` is missing or `args.filepath` is not provided or invalid.
 */
export async function handleLoadBuffer(args: any) {
  validateRequired(args?.filepath, 'filepath');
  validateFilePath({ filepath: args.filepath });

  const result = await callNeovim('load_buffer', { filepath: args.filepath }, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
