#!/usr/bin/env python3
"""Real Claude background-agent lifetime probe; never part of npm test.

VIBING_PERF=1 python3 tests/perf/background_subagent_lifetime.py
Uses three launches (oneshot, duplex EOF, live duplex) and two resume turns.
The two exit cells use the CLI's idle ceiling, not a signal: ordinary print mode
waits for its agents. A surviving Bash/sleep is NOT evidence of an agent: the
completion marker must come from a later, separate Write tool call.
Raw streams, process samples, transcript copies and a summary stay in OUT.
"""
import argparse
import json
import os
import re
import shlex
import signal
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid

MODEL = "claude-haiku-4-5-20251001"
INPUT_LIMIT = 300000
OUTPUT_LIMIT = 10000
CELL_INPUT_RESERVE = 120000
RECOVERY_INPUT_RESERVE = 50000
REQUEST_INPUT_RESERVE = 20000
OUTPUT_RESERVE = 1500
WAIT = 35
OBSERVE = 90
CEILING = 2000


def rows(path):
    if not path.exists():
        return []
    result = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            result.append(json.loads(line))
        except ValueError:
            pass  # a currently-being-written final line is sampled again later
    return result


def usage(paths):
    # API message ids deduplicate transcript/stdout/replay copies. Final modelUsage
    # is cumulative across --resume; take its per-session high-water mark, not a
    # sum of results. Streaming output_tokens can still be provisional (e.g. 4).
    messages, billed = {}, {}
    for path in paths:
        for row in rows(path):
            session = row.get("session_id", row.get("sessionId"))
            message = row.get("message", {})
            if row.get("type") == "assistant" and message.get("id"):
                key = message["id"]
                counts = message.get("usage", {})
                previous = messages.get(key, (session, {}))[1]
                messages[key] = (session, {k: max(previous.get(k, 0) or 0, counts.get(k, 0) or 0)
                                          for k in ("input_tokens", "cache_creation_input_tokens",
                                                    "cache_read_input_tokens", "output_tokens")})
            if row.get("type") == "result" and row.get("modelUsage"):
                models = row["modelUsage"].values()
                counts = {"input": sum(sum(m.get(k, 0) or 0 for k in
                                           ("inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"))
                                       for m in models),
                          "output": sum(m.get("outputTokens", 0) or 0 for m in models)}
                previous = billed.setdefault(session, {"input": 0, "output": 0})
                for k in counts:
                    previous[k] = max(previous[k], counts[k])
    sessions = {}
    for session, counts in messages.values():
        totals = sessions.setdefault(session, {"input": 0, "output": 0})
        totals["input"] += sum(counts.get(k, 0) for k in
                               ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
        totals["output"] += counts.get("output_tokens", 0)
    for session, counts in billed.items():
        totals = sessions.setdefault(session, {"input": 0, "output": 0})
        for k in counts:
            totals[k] = max(totals[k], counts[k])
    return {"input": sum(c["input"] for c in sessions.values()),
            "output": sum(c["output"] for c in sessions.values()),
            "messages": len(messages), "sessions": sessions, "final_model_usage": billed}


def classify(report):
    """Decide only from observed work, never from a recoverable old transcript."""
    if report["forced"] or report["exit_code"] != 0:
        return "inconclusive: forced or failed exit"
    if not report["background_started"] or not report["started"]:
        return "inconclusive: no confirmed background work"
    if report["done_at_exit"]:
        return "inconclusive: completed before exit"
    if report["done_after_exit"]:
        return "continued: separate Write after parent exit"
    return "no continuation observed within window"


def background_agents(events):
    return {e["task_id"] for e in events if e.get("subtype") == "task_started"
            and e.get("is_backgrounded") and e.get("subagent_type") and e.get("task_id")}


def agent_completed(events):
    ids = background_agents(events)
    return any(e.get("subtype") == "task_notification" and e.get("status") == "completed"
               and e.get("task_id") in ids for e in events)


def stop_process(process):
    """Bound cleanup even when the CLI ignores TERM; no repeated signals in the loop."""
    running = process.poll() is None
    if running:
        process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    return running


class Probe:
    def __init__(self, out, priors=()):
        self.out = out
        self.transcripts = set()
        self.streams = []
        self.reports = (
            json.loads((out / "summary.json").read_text()) if (out / "summary.json").exists() else [])
        for root in [out, *priors]:
            self.streams.extend(root.rglob("stream.jsonl"))
            self.streams.extend(root.rglob("resume*.jsonl"))
            for timeline in root.rglob("timeline.jsonl"):
                for row in rows(timeline):
                    self.transcripts.update(Path(p) for p in row.get("transcripts", {}))

    def paths(self):
        return self.streams + list(self.transcripts)

    def budget(self, reserve=0):
        # CLI usage is observable only after a model request starts/completes.
        # Reserve a whole request in-flight and the measured worst-case cell.
        # This is a conservative stop guard, NOT an exact upstream token cap.
        total = usage(self.paths())
        if total["input"] + reserve > INPUT_LIMIT or total["output"] > OUTPUT_LIMIT - OUTPUT_RESERVE:
            raise RuntimeError(f"token budget requires approval before continuing: {total}")
        return total

    def cell(self, name):
        self.budget(reserve=CELL_INPUT_RESERVE)
        folder = self.out / name
        folder.mkdir()
        session = str(uuid.uuid4())
        token = "LIFETIME_DONE_" + uuid.uuid4().hex
        started = folder / "started.txt"
        done = folder / "done.txt"
        agent_task = (f"Use Write to create {started} containing STARTED. Then use Bash to run "
                      f"sleep {WAIT} in the FOREGROUND (timeout 60000, never run_in_background). "
                      f"After Bash returns use a SEPARATE Write tool call to create {done} "
                      f"containing {token}. Finally reply with exactly {token}. "
                      "Do nothing else. Do not let Bash write the completion file.")
        prompt = ("Launch exactly ONE Agent using subagent_type general-purpose, model haiku, "
                  "run_in_background true, description lifetime probe, with this task: "
                  + agent_task + ". After launch use Bash in foreground to wait for its STARTED "
                  f"file: for i in $(seq 1 100); do test -f {started} && break; sleep 0.1; done. "
                  "Then immediately end your turn saying LAUNCHED. Do not collect, wait for, "
                  "or resume the agent. If notified later reply ACK only.")
        base = ["claude", "-p", "--model", MODEL, "--output-format", "stream-json", "--verbose",
                "--strict-mcp-config", "--setting-sources", "project", "--permission-mode",
                "bypassPermissions", "--tools", "Agent,Bash,Write,Read,TaskOutput,SendMessage",
                "--forward-subagent-text"]
        env = os.environ.copy()
        # Isolate from the invoking chat's hook/agent state. Keep authentication.
        for key in list(env):
            if key.startswith("VIBING_") or key in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
                env.pop(key)
        env["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"] = str(CEILING)
        argv = base + ["--session-id", session]
        if name != "oneshot":
            argv += ["--input-format", "stream-json"]
        else:
            argv += [prompt]
        stream = folder / "stream.jsonl"
        self.streams.append(stream)
        events = []
        lock = threading.Lock()
        stderr = open(folder / "stderr.log", "w")
        process = subprocess.Popen(argv, cwd=folder, env=env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=stderr, text=True, bufsize=1)
        begin = time.monotonic()
        timeline = open(folder / "timeline.jsonl", "w")

        def record(kind, **details):
            with lock:
                timeline.write(json.dumps({"t": round(time.monotonic() - begin, 3),
                                           "kind": kind, **details}) + "\n")
                timeline.flush()

        def read():
            with open(stream, "w") as output:
                for line in process.stdout:
                    output.write(line)
                    output.flush()
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    events.append(event)
                    record("event", type=event.get("type"), subtype=event.get("subtype"))

        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        record("spawn", pid=process.pid, argv=argv, ceiling_ms=CEILING)
        if name == "oneshot":
            process.stdin.close()
        else:
            process.stdin.write(json.dumps({"type": "user", "uuid": "lifetime-launch",
                                            "message": {"role": "user", "content": prompt}}) + "\n")
            process.stdin.flush()
        project = Path.home() / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(folder))
        known = set()
        forced = False
        closed = name == "oneshot"
        live_pending = False
        exit_time = None
        done_at_exit = None
        done_while_alive = False
        failure = None
        try:
            while True:
                self.transcripts.update(project.glob(f"{session}/subagents/agent-*.jsonl"))
                self.transcripts.add(project / f"{session}.jsonl")
                table = subprocess.check_output(["ps", "-axo", "pid=,ppid=,stat=,comm="], text=True)
                processes = {}
                for line in table.splitlines():
                    fields = line.strip().split(None, 3)
                    if len(fields) == 4:
                        processes[int(fields[0])] = (int(fields[1]), fields[2], fields[3])
                # Track descendants after reparenting too. PID + short lifetime window;
                # names and state are retained so a zombie is not mistaken for a worker.
                branch = {process.pid}
                while True:
                    added = {pid for pid, value in processes.items() if value[0] in branch} - branch
                    if not added:
                        break
                    branch.update(added)
                known.update(branch)
                record("sample", parent_alive=process.poll() is None,
                       processes={pid: processes[pid] for pid in known if pid in processes},
                       started=started.exists(), done=done.exists(),
                       transcripts={str(p): p.stat().st_size for p in self.transcripts if p.exists()})
                done_while_alive = done_while_alive or (done.exists() and process.poll() is None)
                self.budget(reserve=REQUEST_INPUT_RESERVE)
                result = any(e.get("type") == "result" for e in events)
                if name == "duplex-eof" and result and not closed:
                    record("stdin_eof", started=started.exists(), done=done.exists())
                    process.stdin.close()
                    closed = True
                if name == "duplex-live" and result and started.exists() and not done.exists():
                    live_pending = True
                if (name == "duplex-live" and done.exists() and result and not closed
                        and agent_completed(events)):
                    record("control_completed_before_eof", pending_after_result=live_pending)
                    process.stdin.close()
                    closed = True
                if process.poll() is not None and exit_time is None:
                    exit_time = time.monotonic()
                    done_at_exit = done.exists()
                    record("parent_exit", code=process.returncode, done=done_at_exit)
                if exit_time is not None and time.monotonic() - exit_time >= OBSERVE:
                    break
                if time.monotonic() - begin > 180 and exit_time is None:
                    forced = True
                    failure = "probe timed out"
                    record("forced_timeout")
                    break
                time.sleep(0.5)
        except (RuntimeError, KeyboardInterrupt) as err:
            failure = str(err) or "supervisor stopped the probe"
        finally:
            forced = stop_process(process) or forced
            reader.join(timeout=5)
            stderr.close()
            timeline.close()
        report = dict(name=name, session=session, pid=process.pid, forced=forced,
                      exit_code=process.returncode, started=started.exists(),
                      background_started=bool(background_agents(events)),
                      done_at_exit=done_at_exit, done_after_exit=done.exists(),
                      live_pending_after_result=live_pending,
                      agent_notification_completed=agent_completed(events),
                      notifications=[e for e in events if e.get("subtype") == "task_notification"],
                      done_while_parent_alive=done_while_alive, failure=failure,
                      usage=usage(self.paths()))
        report["verdict"] = classify(report)
        if name == "duplex-live":
            report["verdict"] = ("control passed" if live_pending and done_at_exit and not forced
                                 and report["background_started"] and report["agent_notification_completed"]
                                 else "control failed")
        # Before resume, preserve the transcript. Resuming must not count as work
        # done by a supposedly surviving agent during the observation window.
        for path in self.transcripts:
            if path.exists() and session in str(path):
                (folder / path.name).write_bytes(path.read_bytes())
        self.reports.append(report)
        self.save()
        print(json.dumps(report), flush=True)
        if failure:
            raise RuntimeError(failure)
        if name != "duplex-live":
            self.resume(report, folder, base, env)

    def resume(self, report, folder, base=None, env=None):
        self.budget(reserve=RECOVERY_INPUT_RESERVE)
        session = report["session"]
        base = base or ["claude", "-p", "--model", MODEL, "--output-format", "stream-json", "--verbose",
                        "--strict-mcp-config", "--setting-sources", "project",
                        "--permission-mode", "bypassPermissions", "--tools", "Bash,Read"]
        env = env or os.environ.copy()
        for key in list(env):
            if key.startswith("VIBING_") or key in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"):
                env.pop(key)
        env["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"] = str(CEILING)
        events = rows(folder / "stream.jsonl")
        task_ids = sorted(background_agents(events))
        # Use the plugin's actual recovery reader. TaskOutput is absent from
        # 2.1.286's advertised tools; SendMessage resumes a stopped agent and
        # therefore would measure NEW work rather than collecting its old answer.
        recovery = folder / "recover.lua"
        root = Path(__file__).resolve().parents[2]
        recovery.write_text(
            "vim.opt.runtimepath:append(" + json.dumps(str(root)) + ")\n"
            "local m = require('vibing.infrastructure.adapter.modules.claude_subagent_transcript')\n"
            "local tasks = {}\n" +
            "\n".join("table.insert(tasks, {task_id = " + json.dumps(t) + "})" for t in task_ids) +
            "\nprint(vim.json.encode(m.recover(tasks, " + json.dumps(str(folder)) + ", " +
            json.dumps(session) + ")))\n")
        command = "nvim --headless -u NONE -i NONE -l " + shlex.quote(str(recovery))
        resume_prompt = ("Use the Bash tool ONCE to execute this exact command to collect the "
                         "previous agent's saved answer using vibing's transcript reader: " + command +
                         ". Report the returned JSON briefly. Do not continue, resume or re-dispatch "
                         "the agent. Do not call SendMessage. Do not create any files.")
        resume_path = folder / ("resume-recovery.jsonl" if (folder / "resume.jsonl").exists()
                                else "resume.jsonl")
        self.streams.append(resume_path)
        with open(resume_path, "w") as stdout, open(folder / "resume-stderr.log", "w") as err:
            resumed = subprocess.run(base + ["--resume", session, resume_prompt], cwd=folder,
                                     env=env, stdin=subprocess.DEVNULL, stdout=stdout,
                                     stderr=err, timeout=90)
        report["resume_exit_code"] = resumed.returncode
        report["resume_tool_results"] = [r for r in rows(resume_path) if r.get("type") == "user"]
        report["usage"] = self.budget()
        self.save()
        print("resume " + json.dumps({"name": report["name"], "usage": report["usage"]}), flush=True)

    def save(self):
        (self.out / "summary.json").write_text(json.dumps(self.reports, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--prior", type=Path, action="append", default=[])
    parser.add_argument("--resume-cell", choices=("oneshot", "duplex-eof"))
    parser.add_argument("--cell", choices=("oneshot", "duplex-eof", "duplex-live"))
    args = parser.parse_args()
    if os.environ.get("VIBING_PERF") != "1":
        print("This spends real tokens; set VIBING_PERF=1 only after approval.")
        return
    out = (args.out or Path(tempfile.mkdtemp(prefix="vibing-agent-lifetime-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    print(f"Evidence: {out}", flush=True)
    (out / "version.txt").write_text(subprocess.check_output(["claude", "--version"], text=True))
    probe = Probe(out, args.prior)
    # A supervisor stop must terminate the active CLI too, preserving raw evidence.
    def stopped(*_):
        raise KeyboardInterrupt("supervisor stopped the probe")
    signal.signal(signal.SIGTERM, stopped)
    if args.resume_cell:
        report = next(r for r in probe.reports if r["name"] == args.resume_cell)
        probe.resume(report, out / args.resume_cell)
        return
    for name in ([args.cell] if args.cell else ["oneshot", "duplex-eof", "duplex-live"]):
        probe.cell(name)
    print("Total observed usage: " + json.dumps(probe.budget()), flush=True)


if __name__ == "__main__":
    main()
