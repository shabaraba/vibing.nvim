import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { withRpcPort, requireRpcPort } from './common.js';

/**
 * Chat-related MCP tools
 */

/**
 * Window positions nvim_chat_create accepts, mirroring `lua/vibing/core/constants/chat.lua`.
 * Exported so the handler's zod schema validates against the same list the advertised schema
 * offers — otherwise the two can drift and a value one accepts the other rejects.
 */
export const CHAT_POSITIONS = ['back', 'current', 'right', 'left', 'top', 'bottom'] as const;

/**
 * The four answers a tool-approval prompt accepts, mirroring `APPROVAL_OPTIONS` in
 * `lua/vibing/infrastructure/rpc/handlers/permission.lua` and the vocabulary
 * `presentation/chat/modules/approval_parser.lua` reads back out of the buffer.
 */
export const APPROVAL_ACTIONS = [
  'allow_once',
  'deny_once',
  'allow_for_session',
  'deny_for_session',
] as const;

export const chatTools: Tool[] = [
  {
    name: 'nvim_chat_create',
    description:
      'Create a new vibing.nvim chat buffer and return its bufnr and chat file path. ' +
      'Use it to spawn worker chats you then drive with nvim_chat_send_message — the ' +
      'multi-agent orchestration workflow (see the vibing-orchestrate skill). ' +
      'A chat is for work that must survive a turn, own a branch/worktree, or take a human ' +
      "approval — one-shot delegated work inside your own turn is a subagent's job instead " +
      '(see "Chat or subagent?" in the vibing-orchestrate skill). ' +
      'Leave position at its "back" default for workers: that creates the buffer without ' +
      "opening a window, so the user's layout is untouched. " +
      'The new chat starts empty and shares nothing with yours, so every message you send it ' +
      'must be self-contained.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        position: {
          type: 'string',
          enum: [...CHAT_POSITIONS],
          description:
            'Where to put the chat window (default "back": buffer only, no window). ' +
            'Same values as :VibingChat.',
        },
        working_dir: {
          type: 'string',
          description:
            'Optional working directory for the chat, as a path relative to the git root ' +
            '(e.g. ".vibing/worktrees/fix-auth"). Must already exist. Omit to use the ' +
            "Neovim instance's own working directory.",
        },
        from_bufnr: {
          type: 'number',
          description:
            'Your own chat: the exact "Current vibing.nvim chat buffer number" from your ' +
            'system prompt THIS turn — never a number remembered from earlier in the ' +
            'conversation, which a Neovim restart silently invalidates. Pass it whenever you ' +
            'create a worker — it records the relationship in both chat files, which survives ' +
            'renames and restarts. A number that names no chat buffer fails the call.',
        },
        task: {
          type: 'string',
          description:
            'One free-text line describing what you are asking this new chat to do, e.g. ' +
            '"PR #688 — review fixes, merge, cleanup". Recorded on YOUR OWN chat\'s frontmatter ' +
            '(next to the new link this call creates), not on the new chat itself, and returned ' +
            'by nvim_chat_list — so a restart or context compaction does not lose the ' +
            'bufnr ↔ PR/issue ↔ assignment mapping for every worker you drive. ' +
            'Requires from_bufnr: with no from_bufnr there is nowhere to record it and it is ' +
            'dropped with a warning. Use the task argument on nvim_chat_send_message instead of ' +
            'repeating this call to update the assignment later.',
        },
      }),
      required: requireRpcPort([]),
    },
  },
  {
    name: 'nvim_chat_send_message',
    description:
      'Programmatically send a message to a chat buffer and trigger AI request. ' +
      'Useful for multi-agent workflows where one Claude instance sends messages to another. ' +
      'Name the target with either file_path or bufnr, not both. Prefer file_path: a buffer ' +
      'number only means anything in the Neovim session that issued it, while the chat file ' +
      'path is what the chats record in their own frontmatter, so it still reaches the right ' +
      'chat after a restart — and a chat that is not open is opened for you.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        file_path: {
          type: 'string',
          description:
            'Chat file of the target chat, as returned by nvim_chat_create or written in ' +
            'frontmatter (git-root-relative, absolute, or ~-prefixed). Opened in the background ' +
            'if it is not already open. Must name a vibing.nvim chat file.',
        },
        bufnr: {
          type: 'number',
          description:
            'Buffer number of the target chat buffer. Only valid within this Neovim session — ' +
            'use file_path instead when you have one.',
        },
        message: {
          type: 'string',
          description: 'Message content to send',
        },
        sender: {
          type: 'string',
          description:
            'Optional sender identifier (default: "User"). Future: supports "Alpha", "Bravo", etc.',
        },
        from_bufnr: {
          type: 'number',
          description:
            'Your own chat: the exact "Current vibing.nvim chat buffer number" from your ' +
            'system prompt THIS turn — never a number remembered from earlier in the ' +
            'conversation, which a Neovim restart silently invalidates. Pass it whenever you ' +
            'drive another chat — it records the relationship in both chat files, which ' +
            'survives renames and restarts. A number that names no chat buffer fails the call.',
        },
        queue_if_busy: {
          type: 'boolean',
          description:
            'Queue the message instead of failing when it cannot be delivered right now — the ' +
            'target chat is already responding, or the editor is at its configured limit on how ' +
            'many chats may respond at once (default false, which reports an error). A queued ' +
            'message is delivered as a new ' +
            'turn the moment that chat stops, and several queued messages arrive coalesced ' +
            'into one turn. Use it for anything the other chat must receive whether or not it ' +
            'happens to be busy right now — a completion report to your orchestrator, an ' +
            'answer to a question it asked you.',
        },
        task: {
          type: 'string',
          description:
            'Replace the one-line task you recorded for this chat when you created or last ' +
            "briefed it (see nvim_chat_create's task argument) with the latest instruction — " +
            'e.g. "PR #688 — now also update the docs". Recorded on YOUR OWN chat\'s frontmatter, ' +
            'next to the link for this target, and requires from_bufnr for the same reason. Omit ' +
            'it for an ordinary follow-up (a status check, an approval, "go ahead") so it does ' +
            'not overwrite a good assignment summary with something that is not one.',
        },
      }),
      // Neither bufnr nor file_path is required on its own; the handler enforces that exactly one
      // arrives. JSON Schema could say that with oneOf, but the advertised schema is flattened
      // into the model's tool list, and a required-list of two mutually exclusive keys reads as
      // "pass both".
      required: requireRpcPort(['message']),
    },
  },
  {
    name: 'nvim_ask_user_question',
    description:
      'Ask the user one or more multiple-choice questions directly in the vibing.nvim chat buffer. ' +
      'Use this instead of asking questions in free text, and instead of the native AskUserQuestion ' +
      'tool (which is unavailable in headless CLI mode). ' +
      'IMPORTANT: calling this tool renders the questions as an editable choice list in the chat ' +
      'buffer and then immediately cancels/kills your current turn — you will NOT get a normal ' +
      'tool_result back, and you cannot do anything else after calling it. The user edits the list ' +
      "(deleting unwanted options) and sends it. Your NEXT invocation's prompt IS the user's answer " +
      'to this question, delivered as a fresh turn — treat it as such rather than waiting for a ' +
      'tool response. ' +
      'You MUST pass chat_bufnr using the exact "Current vibing.nvim chat buffer number" value ' +
      'given to you in your system prompt — it identifies which chat buffer to render the ' +
      'question in.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        chat_bufnr: {
          type: 'number',
          description:
            'The exact "Current vibing.nvim chat buffer number" given to you in your system ' +
            'prompt. Required to associate this question with the correct chat buffer.',
        },
        questions: {
          type: 'array',
          description: 'One or more questions to present to the user',
          items: {
            type: 'object',
            properties: {
              question: {
                type: 'string',
                description: 'The question text',
              },
              multiSelect: {
                type: 'boolean',
                description: 'Whether multiple options can be selected (default: false)',
              },
              options: {
                type: 'array',
                description: 'The choices offered to the user',
                items: {
                  type: 'object',
                  properties: {
                    label: {
                      type: 'string',
                      description: 'The option text shown to the user',
                    },
                    description: {
                      type: 'string',
                      description: 'Optional additional detail shown under the option',
                    },
                  },
                  required: ['label'],
                },
              },
            },
            required: ['question', 'options'],
          },
        },
      }),
      required: requireRpcPort(['chat_bufnr', 'questions']),
    },
  },
  {
    name: 'nvim_chat_answer_approval',
    description:
      "Answer another chat's pending tool-approval prompt — the one that leaves it stuck at " +
      'status waiting_approval, unable to continue or even to report back. Read what it is ' +
      'stuck on with nvim_get_buffer first; the prompt names the tool and its input. ' +
      'This is off unless the user turned it on ' +
      '(agent.orchestration.delegated_approval), and the call fails with an explanation when it ' +
      'is off — then the only thing to do is tell the user which chat is blocked and on what. ' +
      'When it is on, you are standing in for the user on a decision they asked to be consulted ' +
      'about: answer only when the tool is plainly within the task you briefed that chat with, ' +
      'and put anything else to the user instead. Your answer is recorded in that chat as coming ' +
      'from you. It can only be answered once, and only while it is pending.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        file_path: {
          type: 'string',
          description:
            'Chat file of the blocked chat (git-root-relative, absolute, or ~-prefixed). ' +
            'Opened in the background if it is not already open. Prefer this over bufnr.',
        },
        bufnr: {
          type: 'number',
          description:
            'Buffer number of the blocked chat. Only valid within this Neovim session — use ' +
            'file_path instead when you have one.',
        },
        action: {
          type: 'string',
          enum: [...APPROVAL_ACTIONS],
          description:
            'Which of the four options to choose. The "_once" pair applies to this one call; ' +
            'the "_for_session" pair is written into that chat\'s frontmatter and applies to ' +
            'every later call in it, so prefer allow_once unless the chat will clearly need the ' +
            'tool repeatedly.',
        },
        from_bufnr: {
          type: 'number',
          description:
            'Your own chat: the exact "Current vibing.nvim chat buffer number" from your ' +
            'system prompt THIS turn — never a number remembered from earlier in the ' +
            'conversation, which a Neovim restart silently invalidates. Required here (unlike ' +
            'on the other chat tools): answering an approval is recorded as your decision, and ' +
            'a call that cannot say whose decision it was is refused.',
        },
      }),
      // bufnr/file_path stay out of the required list for the same reason as on
      // nvim_chat_send_message: the handler enforces that exactly one arrives, and listing both
      // as required would read as "pass both".
      required: requireRpcPort(['action', 'from_bufnr']),
    },
  },
  {
    name: 'nvim_chat_list',
    description:
      'List every open vibing.nvim chat buffer with its status in one call, instead of polling ' +
      'each with nvim_get_buffer one at a time. For each chat, reports bufnr, file_path, ' +
      'chat_status (responding/idle/waiting_approval/asked_question/error), context_size (the ' +
      "chat's last measured context size in tokens, or omitted if it has not completed a turn " +
      'yet), updated_at (frontmatter timestamp of the last write), orchestrated_by (the ' +
      "chat file paths of this chat's orchestrator(s), if any), and task (the one-line " +
      "assignment its orchestrator gave it via nvim_chat_create/nvim_chat_send_message's task " +
      "argument, projected from the orchestrator's own frontmatter — present only when that " +
      'orchestrator is also open in this session, omitted otherwise). Use this to check on ' +
      'several worker chats at once in a multi-agent workflow (see the vibing-orchestrate ' +
      'skill). Only chats currently open in this Neovim session are listed — a chat file that ' +
      'was never opened this session is not included.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({}),
      required: [],
    },
  },
  {
    name: 'nvim_chat_conflicts',
    description:
      'Warn about files that 2+ live chats have modified on their own branch/worktree — a ' +
      'quiet way for a change in one worker to break an assumption another worker already ' +
      "relied on, without either one's own tests catching it (e.g. one PR renames a marker a " +
      'second PR still parses by the old name). For each contested file, reports the chats ' +
      'that touched it (bufnr, file_path, and task if its orchestrator is open this session). ' +
      'File-level only (no hunk detail) and warning-only — nothing here blocks a merge; use it ' +
      'to decide whether to look closer before merging or briefing further work. Only chats ' +
      'open in this Neovim session are compared, and only those with their own working_dir ' +
      "(worktree/branch) — a chat using the instance's own working directory has nothing of " +
      "its own to diff against the base branch. Diffs each chat's worktree against main/master " +
      '(three-dot, against HEAD), so it needs no branch name of its own. A chat whose worktree ' +
      "could not be diffed is listed under `skipped` with git's reason, and a repository with " +
      'neither main nor master returns a `warning` — an empty `conflicts` never means "not compared".',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({}),
      required: [],
    },
  },
];
