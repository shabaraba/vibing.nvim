/**
 * vibing.nvim's permission bridge for the Pi coding agent.
 *
 * Pi is the one supported backend with **no tool-approval mechanism of its own**: its own
 * documentation states it "does not ask for approval before every tool call", and print/JSON/RPC
 * modes cannot show even the built-in trust prompt. So unlike claude, codex, copilot and grok —
 * where vibing.nvim's gate is an extra layer over the CLI's — here it is the only layer. Without
 * this extension loaded, selecting `agent: pi` would silently void every `permissions.deny` rule
 * and every bundled destructive-command rule the user configured, and Pi's `bash` would run
 * unrestrained. `pi_command_builder.permission_args` therefore takes the writing tools away from
 * any turn that could not load this file, rather than letting it run at full capability.
 *
 * Pi has no external-process hook, only in-process TypeScript handlers, so the bridge is this file.
 * What it deliberately does NOT do is re-implement the decision: it spawns the same
 * `bin/hooks/pre-tool-use.sh` every other backend uses and reads its exit code under the same
 * `claude` dialect. A second implementation of "what a permission decision means" is the failure
 * the shared script exists to prevent.
 *
 * @see lua/vibing/infrastructure/hooks/pi_settings_generator.lua — how this file is located
 * @see lua/vibing/infrastructure/adapter/modules/pi_tool_vocabulary.lua — reads the payload below
 */

import { spawn } from 'node:child_process';

/** Absolute path to `bin/hooks/pre-tool-use.sh`, put here by `pi.apply_env`. */
const SCRIPT_VAR = 'VIBING_PI_HOOK_SCRIPT';

/**
 * The extension's own deadline, in seconds.
 *
 * Every other backend registers a PreToolUse timeout with its CLI, and the ordering
 * `approval_wait_sec < script wait < CLI timeout` keeps a slow approval from becoming an ungated
 * tool call — because past its own timeout **every CLI measured fails open**. Pi imposes no
 * timeout on an extension handler at all, so there is nothing to order against unless this file
 * supplies it. It does, from the same derivation (`hooks/wait_budget.lua`), with one difference
 * that matters: expiry here **fails closed**. So the inequality holds with the safe side on the
 * outside, which is the opposite of every other backend.
 */
const TIMEOUT_VAR = 'VIBING_PI_HOOK_TIMEOUT_SEC';

/** Set by `rpc_environment.bind`. Absent means this Pi was not started by vibing.nvim. */
const PORT_VAR = 'VIBING_NVIM_RPC_PORT';

const FALLBACK_TIMEOUT_SEC = 990;

interface Verdict {
  block?: boolean;
  reason?: string;
}

/** Returning nothing from a `tool_call` handler is how Pi is told to proceed. */
const ALLOW = undefined;

function blocked(reason: string): Verdict {
  return { block: true, reason };
}

function timeoutSec(): number {
  const raw = Number(process.env[TIMEOUT_VAR]);
  return Number.isFinite(raw) && raw > 0 ? raw : FALLBACK_TIMEOUT_SEC;
}

/**
 * Run the shared hook script and translate its exit status.
 *
 * The three decisions are the script's, not ours (`bin/hooks/pre-tool-use.sh`):
 *   exit 2            → deny, reason on stderr
 *   exit 0 + stdout   → an explicit allow
 *   exit 0, silent    → defer: "no opinion", leave it to the CLI's own gate
 *
 * `allow` and `defer` are the same act here and only here, because Pi has no gate to defer *to*.
 * Anything else — a spawn failure, a signal, a non-zero status that is not 2 — is a bridge that
 * did not work, and a bridge that did not work must not read as permission.
 */
function askNeovim(
  script: string,
  payload: unknown,
  signal?: AbortSignal
): Promise<Verdict | undefined> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(script, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    } catch (err) {
      resolve(blocked(`vibing.nvim permission bridge could not start: ${String(err)}`));
      return;
    }

    let stderr = '';
    let settled = false;
    const finish = (verdict: Verdict | undefined) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      resolve(verdict);
    };

    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(blocked(`vibing.nvim permission check timed out after ${timeoutSec()}s`));
    }, timeoutSec() * 1000);

    const onAbort = () => {
      child.kill('SIGKILL');
      finish(blocked('Cancelled'));
    };
    signal?.addEventListener('abort', onAbort, { once: true });

    child.stderr?.on('data', (chunk) => {
      stderr += String(chunk);
    });
    child.on('error', (err) =>
      finish(blocked(`vibing.nvim permission bridge failed: ${err.message}`))
    );
    child.on('close', (code) => {
      if (code === 0) {
        finish(ALLOW);
        return;
      }
      if (code === 2) {
        finish(blocked(stderr.trim() || 'Denied by vibing.nvim'));
        return;
      }
      finish(
        blocked(`vibing.nvim permission bridge exited with ${String(code)}: ${stderr.trim()}`)
      );
    });

    child.stdin?.on('error', () => {
      /* the script exited before reading; `close` above carries the verdict */
    });
    child.stdin?.end(JSON.stringify(payload));
  });
}

export default function (pi: {
  on: (event: string, handler: (event: any, ctx: any) => Promise<Verdict | undefined>) => void;
}) {
  pi.on('tool_call', async (event, ctx) => {
    // Not launched by vibing.nvim: there is nothing to ask, and refusing every tool call would
    // break a plain `pi` session that happened to load this extension. The shared script makes
    // the same judgement from the same variable.
    if (!process.env[PORT_VAR]) return ALLOW;

    const script = process.env[SCRIPT_VAR];
    if (!script) {
      return blocked(
        `vibing.nvim permission bridge is not configured (${SCRIPT_VAR} unset), so this tool call cannot be checked`
      );
    }

    // Pi's own vocabulary, verbatim. `pi_tool_vocabulary.normalize_payload` translates
    // `toolName`/`input` into the `tool_name`/`tool_input` the permission handler reads, which is
    // what that module is for — inventing claude's spelling here would move the translation into
    // a file the Lua side cannot see.
    const verdict = await askNeovim(
      script,
      {
        hookEventName: 'PreToolUse',
        toolName: event.toolName,
        input: event.input,
        toolCallId: event.toolCallId,
        cwd: ctx?.cwd,
      },
      ctx?.signal
    );

    return verdict?.block ? verdict : ALLOW;
  });
}
