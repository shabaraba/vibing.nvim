import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { withRpcPort } from './common.js';

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
        delegated_scope: {
          type: 'array',
          items: { type: 'string' },
          description:
            'Tool/command patterns (same syntax as the permissions_allow frontmatter field, ' +
            'e.g. "Bash(npm:*)", "Read") that you may auto-approve on this new chat\'s behalf ' +
            'with nvim_chat_answer_approval, once agent.orchestration.delegated_approval is set ' +
            'to "scoped". Recorded on the NEW chat\'s own frontmatter as delegated_scope — it is ' +
            'what is being asked, not who is allowed to answer for it, which stays a config ' +
            'decision. Denials are always answerable regardless of this list; only allow_once / ' +
            'allow_for_session answers are checked against it. Has no effect unless ' +
            'delegated_approval is "scoped" (and none at all if it is unset or true/false).',
        },
      }),
      required: [],
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
            'answer to a question it asked you. One target is never queued however you set this: ' +
            'a chat reporting chat_status "asked_question" is waiting on your answer inside a ' +
            'turn it cannot leave, so the message is delivered straight into that turn. Queueing ' +
            'it would hold the answer until the question had already timed out and been denied. ' +
            'That applies to a message you send DOWN the link (a brief or an answer to a worker); ' +
            'a completion report sent UP to your orchestrator is never treated as the answer to a ' +
            'question that orchestrator asked its own user, and is queued like any other message.',
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
      required: ['message'],
    },
  },
  {
    name: 'nvim_ask_user_question',
    description:
      'Ask the user one or more multiple-choice questions directly in the vibing.nvim chat buffer. ' +
      'Use this instead of asking questions in free text, and instead of the native AskUserQuestion ' +
      'tool (which is unavailable in headless CLI mode). ' +
      'The questions render as an editable choice list in the chat buffer; the user deletes the ' +
      'options they do not want and sends what is left. ' +
      'IMPORTANT: this call blocks until a human answers, so it may take many minutes — that is ' +
      'normal, not a hang. How their answer reaches you depends on the backend. Usually it ' +
      "comes back as this call's ordinary tool_result, and THAT RESULT IS THE ANSWER: act on it " +
      'immediately, and never reply that you are still waiting for one. On a backend that cannot ' +
      'hold the call open, your turn is cancelled instead and you get no result at all; there the ' +
      "user's next message IS the answer, delivered as a fresh turn. Either way, do not call this " +
      'tool again to re-ask the same question. ' +
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
      required: ['chat_bufnr', 'questions'],
    },
  },
  {
    name: 'nvim_chat_answer_approval',
    description:
      "Answer another chat's pending tool-approval prompt — the one that leaves it stuck at " +
      'status waiting_approval, unable to continue or even to report back. Read what it is ' +
      'stuck on with nvim_get_buffer first; the prompt names the tool and its input. ' +
      'This is off unless the user turned it on (agent.orchestration.delegated_approval), and ' +
      'the call fails with an explanation when it is off — then the only thing to do is tell ' +
      'the user which chat is blocked and on what. When it is set to true, you are standing in ' +
      'for the user on a decision they asked to be consulted about: answer only when the tool ' +
      'is plainly within the task you briefed that chat with, and put anything else to the ' +
      'user instead. When it is set to "scoped", the call itself enforces this: an allow_once ' +
      "or allow_for_session answer only succeeds if the tool matches that chat's declared " +
      'delegated_scope (see nvim_chat_create), so it is fine to just try it — a denial ' +
      '(deny_once/deny_for_session) always succeeds either way. Your answer is recorded in ' +
      'that chat as coming from you. It is answered exactly once. An expired prompt is still ' +
      'answerable — the wait limit denied that one tool call, not the decision — but the answer ' +
      'reaches the chat as a new turn instead of releasing the call that was blocked on it.',
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
        request_id: {
          type: 'string',
          description:
            'Which prompt you are answering. A chat can be sitting on several tool-approval ' +
            'prompts at once, because a CLI runs its tool calls — and their permission hooks — ' +
            'in parallel. Omit it only when exactly one is waiting; with more than one the call ' +
            'is refused rather than guessing. Get the ids from waiting_approvals, reported by ' +
            'nvim_chat_list and by nvim_get_buffer with include_chat_status — it is the live set, ' +
            'so one read tells you which are still blocking a call and which already expired. ' +
            'Both are answerable; only an unexpired one releases the call in place.',
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
      required: ['action', 'from_bufnr'],
    },
  },
  {
    name: 'nvim_chat_list',
    description:
      'List every open vibing.nvim chat buffer with its status in one call, instead of polling ' +
      'each with nvim_get_buffer one at a time. For each chat, reports bufnr, file_path, ' +
      'chat_status (responding/idle/waiting_approval/asked_question/error), waiting_approvals ' +
      '(present only while the chat is sitting on tool-approval prompts: one entry per prompt ' +
      'with its request_id, tool and whether it already expired — this is where the request_id ' +
      'for nvim_chat_answer_approval comes from), context_size (the ' +
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
