#!/usr/bin/env python3
"""render_agent_events.py — provider-neutral semantic agent-event renderer.

This is SpecRelay's OWN standalone runtime (spec 0006). It reads a provider's
STRUCTURED JSONL event stream on stdin and renders concise, human-readable
agent activity to stdout, one line per meaningful event:

    [executor] tool: Bash
    [executor] command: git status --short
    [executor] reading: docs/providers.md

It is the SEMANTIC layer on top of the generic live transport from spec 0003
(specrelay::provider::run_streamed). The conceptual model is:

    raw provider event -> provider adapter -> normalized agent event -> renderer

Provider adapters are runtime details; the workflow stays role-based. Adding a
new provider means adding one adapter function to ADAPTERS — the SpecRelay
provider adapters and workflow code do not change.

This module references NO `.ai/` paths and is not tied to any host repository;
it is a standalone SpecRelay runtime resource located next to state_lib.py.

Guarantees:
  - Raw JSON is never the normal output; only short human-readable lines.
  - Private/internal reasoning fields (thinking blocks, reasoning items) are
    NEVER rendered.
  - Large payloads are truncated (MAX_FIELD chars per rendered field).
  - Malformed lines and unknown events are skipped with a warning, never fatal.
  - The renderer never stops consuming stdin because of a render problem, so
    the provider process is never killed by SIGPIPE due to a rendering bug.
  - Exit code 0 after consuming the stream (warnings included); non-zero only
    for usage errors or catastrophic failures. The SHELL wrapper treats the
    provider's exit code as authoritative either way.

Usage:
  render_agent_events.py --role <role> --provider <claude|codex>
                         [--raw-events <file>] [--final-stdout <file>]
                         [--repo-root <dir>]

  --role          Prefix for every rendered line, e.g. "executor" or
                  "reviewer:claude".
  --provider      Which provider adapter parses the incoming events.
  --raw-events    Persist every raw incoming line to this file (truncated per
                  run). Best-effort: a write failure warns and disables capture.
  --final-stdout  Write the extracted final agent output text to this file at
                  EOF (truncated per run), so the numbered stdout capture files
                  (12-executor-stdout.txt / 15-reviewer-stdout.txt) keep working
                  and the reviewer decision marker stays parseable.
  --repo-root     Repository root for project-relative display-path rendering.

This module never changes task state and never commits.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# Shared color policy (mode resolution, NO_COLOR, escape codes) lives beside
# this file. It is optional: if it cannot be imported for any reason, the
# renderer degrades to plain text rather than failing — rendering must never
# break because of a color problem.
try:
    import color as _color
except Exception:  # pragma: no cover - color is an optional sibling module
    _color = None

# Maximum characters rendered for any single payload field (command text, file
# path, message snippet). Larger payloads are truncated with an ellipsis so a
# huge tool input never floods the terminal.
MAX_FIELD = 160

# Private-reasoning markers. Events/blocks of these kinds are never rendered.
PRIVATE_CLAUDE_BLOCK_TYPES = {"thinking", "redacted_thinking"}
PRIVATE_CODEX_ITEM_TYPES = {"reasoning"}
PRIVATE_CODEX_MSG_PREFIXES = ("agent_reasoning",)

# --- display-path formatting --------------------------------------------------
# Repository-local absolute paths are rendered project-relative in human-readable
# output ONLY; raw event data (persisted to the events file) is never touched.
# Set once by main() via configure_paths() before the stdin loop starts (never
# re-derived per event); tests may call configure_paths() directly to exercise
# repo-relative rendering deterministically. None means "no repo/home context
# available" and every path is left exactly as the provider reported it.
REPO_ROOT = None
HOME_DIR = None


def configure_paths(repo_root=None, home_dir=None):
    """Set the repo root / home directory used by to_display_path() and
    compact_command_display(). repo_root/home_dir should already be absolute,
    normalized strings (or None to disable that compaction)."""
    global REPO_ROOT, HOME_DIR
    REPO_ROOT = repo_root
    HOME_DIR = home_dir


def to_display_path(raw_path):
    """Render an absolute, repository-local path as project-relative.

    Already-relative paths are returned unchanged (never round-tripped through
    an absolute form). External absolute paths are returned unchanged, except
    for optional "~/..." compaction inside the user's home directory. Uses
    lexical normalization (os.path.normpath) only — symlinks are never
    resolved. Path-boundary checks (exact match or "<root>/") prevent a
    sibling directory like "/repo-old" from being mistaken for "/repo".
    """
    if not isinstance(raw_path, str) or not raw_path:
        return raw_path
    if not raw_path.startswith("/"):
        return raw_path
    try:
        normalized = os.path.normpath(raw_path)
        if REPO_ROOT:
            root = REPO_ROOT.rstrip("/") or "/"
            if normalized == root:
                return "."
            prefix = root if root == "/" else root + "/"
            if normalized.startswith(prefix):
                return normalized[len(prefix):]
        if HOME_DIR:
            home = HOME_DIR.rstrip("/") or "/"
            if normalized == home:
                return "~"
            prefix = home if home == "/" else home + "/"
            if normalized.startswith(prefix):
                return "~/" + normalized[len(prefix):]
        return normalized
    except Exception:
        # Never let a display-formatting bug crash the renderer or hide a
        # path; fall back to the original, truthful value.
        return raw_path


# A repo-root occurrence in a displayed command is only compacted when it sits
# at a safe token boundary: preceded by the start of the string, whitespace, a
# quote character, or '=' (e.g. "--file=/repo/x"); followed by '/', whitespace,
# a quote, or the end of the string. This is display-only: it never rewrites
# the raw command that was/will be executed.
_CMD_BOUNDARY_BEFORE = r'[ \t"\'=]'
_CMD_BOUNDARY_AFTER = r'[ \t"\']'


def compact_command_display(cmd):
    """Best-effort, display-only compaction of repo-root absolute paths inside
    a shell command string. Leaves the command unchanged when there is no safe
    match (e.g. uncertain boundaries) so a rewritten command is never
    misleading."""
    if not isinstance(cmd, str) or not cmd or not REPO_ROOT:
        return cmd
    try:
        root = REPO_ROOT.rstrip("/")
        if not root or root not in cmd:
            return cmd
        pattern = re.compile(
            r'(?:(?<=' + _CMD_BOUNDARY_BEFORE + r')|^)'
            + re.escape(root)
            + r'(/|(?=' + _CMD_BOUNDARY_AFTER + r'|$))'
        )

        def repl(match):
            return "" if match.group(1) == "/" else "."

        return pattern.sub(repl, cmd)
    except Exception:
        return cmd


def clip(value, limit=MAX_FIELD):
    """Collapse any value into one short, single-line string."""
    if value is None:
        return ""
    if not isinstance(value, str):
        try:
            value = json.dumps(value, ensure_ascii=False)
        except Exception:
            value = str(value)
    value = re.sub(r"\s+", " ", value).strip()
    if len(value) > limit:
        value = value[: limit - 1] + "…"
    return value


# --- optional ANSI color (terminal-only, never written into evidence) ---------
# Colors are applied ONLY to the human-readable live lines written to this
# process's stdout (which the shell wraps to the operator terminal). The raw
# events file (--raw-events) and the final stdout file (--final-stdout) are
# NEVER colorized — those are evidence and stay plain text.
#
# Mode is chosen by SPECRELAY_COLOR (auto|always|never) via the shared color
# module, defaulting to auto (color only on a TTY, honoring NO_COLOR). An
# unrecognized value is treated as auto (with a stderr warning). CI / non-TTY
# output therefore stays plain text by default.
#
# When color is enabled the plain verb strings the adapters emit ("command: X",
# "reading: X", ...) are re-laid-out into a Claude-Code-like view: a distinct,
# aligned, colored tool label followed by the (plain, readable) argument; long
# Bash commands wrap onto an indented continuation line; result/started lines
# get a "●" marker. When color is DISABLED the output is byte-for-byte the
# historical plain form, so evidence, greps, and existing tests are unaffected.
COLOR_ENABLED = False

# Aligned tool rows: plain-message prefix -> (label, color). The label is padded
# to _LABEL_WIDTH so successive rows line up like Claude Code's tool list.
_LABEL_WIDTH = 5
_BASH_INLINE_MAX = 60
if _color is not None:
    _TOOL_ROWS = (
        ("reading: ", "Read", _color.BLUE),
        ("writing: ", "Write", _color.MAGENTA),
        ("editing: ", "Edit", _color.MAGENTA),
        ("searching web: ", "Web", _color.BLUE),
        ("searching: ", "Grep", _color.BLUE),
        ("globbing: ", "Glob", _color.BLUE),
        ("fetching: ", "Fetch", _color.BLUE),
    )
else:  # pragma: no cover - color module unavailable
    _TOOL_ROWS = ()


def configure_color(enabled):
    """Set the module-level color flag. main() derives the value from the
    environment; tests may call this directly for deterministic rendering."""
    global COLOR_ENABLED
    COLOR_ENABLED = bool(enabled) and _color is not None


def _label(name, code):
    """A colored, width-padded tool label, e.g. a yellow 'Bash '."""
    return _color.paint(name.ljust(_LABEL_WIDTH), code, True)


def format_rendered_line(role, message):
    """Build the physical output for one rendered event.

    With color disabled: exactly "[role] message" (the historical plain form).
    With color enabled: a dimmed "[role]" prefix plus a scannable, colored
    layout. May return multiple physical lines (each role-prefixed) when a long
    Bash command wraps."""
    plain_prefix = "[%s]" % role
    if not COLOR_ENABLED:
        return "%s %s" % (plain_prefix, message)

    prefix = _color.paint(plain_prefix, _color.DIM, True)

    # Bash: a distinct 'Bash' label; short commands inline, long ones on an
    # indented continuation line (still role-prefixed so every line greps).
    if message.startswith("command: "):
        detail = message[len("command: "):]
        label = _label("Bash", _color.YELLOW)
        if len(detail) <= _BASH_INLINE_MAX:
            return "%s %s %s" % (prefix, label, detail)
        indent = " " * (_LABEL_WIDTH + 1)
        return "%s %s\n%s %s%s" % (prefix, label, prefix, indent, detail)

    # Other command lines ("command finished: exit N", "running a command").
    if message.startswith("command"):
        return "%s %s" % (prefix, _color.paint(message, _color.YELLOW, True))

    # Aligned file/search tool rows: colored label + plain argument.
    for kw, name, code in _TOOL_ROWS:
        if message.startswith(kw):
            return "%s %s %s" % (prefix, _label(name, code), message[len(kw):])

    # Assistant text.
    if message.startswith("says: "):
        detail = message[len("says: "):]
        return "%s %s %s" % (prefix, _color.paint("says", _color.GREEN, True), detail)

    # Result / started lines get a marker so they stand out in the stream.
    if message.startswith("result:"):
        code = _color.RED if "error" in message else _color.GREEN
        return "%s %s" % (prefix, _color.paint("● " + message, code, True))
    if message.startswith("started"):
        return "%s %s" % (prefix, _color.paint("● " + message, _color.CYAN, True))

    # Errors / failures.
    if message.startswith(("error", "turn failed", "tool finished with an error")):
        return "%s %s" % (prefix, _color.paint(message, _color.RED, True))

    # Everything else (tool: X, subagent: X, updating task list, ...) stays
    # plain-bodied under the dimmed prefix.
    return "%s %s" % (prefix, message)


class Rendering:
    """Human-readable lines (without the role prefix) plus optional final text."""

    def __init__(self):
        self.lines = []
        self.final_text = None


# --- Claude Code adapter ------------------------------------------------------
# Parses `claude --print --verbose --output-format stream-json` events:
#   {"type":"system","subtype":"init",...}
#   {"type":"assistant","message":{"content":[{"type":"tool_use"|"text"...}]}}
#   {"type":"user","message":{"content":[{"type":"tool_result",...}]}}
#   {"type":"result","subtype":"success"|... ,"result":"<final text>",...}
# Anything else (rate_limit_event, stream_event, unknown) is not rendered.

def _claude_tool_line(name, tool_input):
    inp = tool_input if isinstance(tool_input, dict) else {}
    if name == "Bash":
        cmd = clip(compact_command_display(inp.get("command")))
        return "command: %s" % cmd if cmd else "tool: Bash"
    if name in ("Read", "NotebookRead"):
        path = clip(to_display_path(inp.get("file_path") or inp.get("notebook_path")))
        return "reading: %s" % path if path else "tool: %s" % name
    if name == "Write":
        path = clip(to_display_path(inp.get("file_path")))
        return "writing: %s" % path if path else "tool: Write"
    if name in ("Edit", "MultiEdit", "NotebookEdit"):
        path = clip(to_display_path(inp.get("file_path") or inp.get("notebook_path")))
        return "editing: %s" % path if path else "tool: %s" % name
    if name == "Grep":
        pattern = clip(inp.get("pattern"))
        return "searching: %s" % pattern if pattern else "tool: Grep"
    if name == "Glob":
        pattern = clip(inp.get("pattern"))
        return "globbing: %s" % pattern if pattern else "tool: Glob"
    if name == "WebSearch":
        query = clip(inp.get("query"))
        return "searching web: %s" % query if query else "tool: WebSearch"
    if name == "WebFetch":
        url = clip(inp.get("url"))
        return "fetching: %s" % url if url else "tool: WebFetch"
    if name == "TodoWrite":
        return "updating task list"
    if name == "Task":
        description = clip(inp.get("description"))
        return "subagent: %s" % description if description else "tool: Task"
    return "tool: %s" % clip(name)


def claude_adapter(event):
    out = Rendering()
    etype = event.get("type")
    if etype == "system":
        if event.get("subtype") == "init":
            model = clip(event.get("model"))
            out.lines.append("started" + (" (model: %s)" % model if model else ""))
        return out
    if etype == "assistant":
        message = event.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype in PRIVATE_CLAUDE_BLOCK_TYPES:
                continue  # private reasoning is never rendered
            if btype == "tool_use":
                out.lines.append(
                    _claude_tool_line(str(block.get("name") or "?"), block.get("input"))
                )
            elif btype == "text":
                text = clip(block.get("text"))
                if text:
                    out.lines.append("says: %s" % text)
        return out
    if etype == "user":
        message = event.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        for block in content if isinstance(content, list) else []:
            if (
                isinstance(block, dict)
                and block.get("type") == "tool_result"
                and block.get("is_error")
            ):
                out.lines.append("tool finished with an error")
        return out
    if etype == "result":
        status = "error" if event.get("is_error") else (clip(event.get("subtype")) or "done")
        details = []
        duration_ms = event.get("duration_ms")
        if isinstance(duration_ms, (int, float)):
            details.append("%.0fs" % (duration_ms / 1000.0))
        num_turns = event.get("num_turns")
        if isinstance(num_turns, int):
            details.append("%d turns" % num_turns)
        suffix = " (%s)" % ", ".join(details) if details else ""
        out.lines.append("result: %s%s" % (status, suffix))
        result_text = event.get("result")
        if isinstance(result_text, str) and result_text:
            out.final_text = result_text
        return out
    return out


# --- Codex CLI adapter --------------------------------------------------------
# Parses `codex exec --json` events. Two shapes are recognized defensively:
#   Shape A: {"type":"thread.started"|"turn.started"|"turn.completed"|"turn.failed"}
#            {"type":"item.started"|"item.updated"|"item.completed","item":{...}}
#            item kinds: agent_message, reasoning (private), command_execution,
#                        file_change, mcp_tool_call, web_search, todo_list, error
#   Shape B (older proto events):
#            {"id":..., "msg":{"type":"task_started"|"agent_message"|
#                              "exec_command_begin"|"exec_command_end"|
#                              "agent_reasoning*" (private)|"task_complete"|"error"}}
# Codex is not a shipped SpecRelay provider today, but this adapter is retained
# so the renderer stays honestly provider-neutral: a future codex adapter needs
# no renderer change. Unknown events are not rendered.

def _codex_item_lines(phase, item):
    itype = item.get("type") or item.get("item_type")
    lines = []
    final_text = None
    if itype in PRIVATE_CODEX_ITEM_TYPES:
        return lines, None  # private reasoning is never rendered
    if itype == "agent_message":
        if phase == "completed":
            text = item.get("text")
            shown = clip(text)
            if shown:
                lines.append("says: %s" % shown)
            if isinstance(text, str) and text:
                final_text = text
    elif itype == "command_execution":
        if phase == "started":
            cmd = clip(compact_command_display(item.get("command")))
            lines.append("command: %s" % cmd if cmd else "running a command")
        elif phase == "completed":
            exit_code = item.get("exit_code")
            lines.append(
                "command finished: exit %s" % exit_code
                if exit_code is not None
                else "command finished"
            )
    elif itype == "file_change":
        if phase == "completed":
            paths = []
            changes = item.get("changes")
            for change in changes if isinstance(changes, list) else []:
                if isinstance(change, dict) and change.get("path"):
                    paths.append(to_display_path(str(change["path"])))
            lines.append("editing: %s" % clip(", ".join(paths)) if paths else "editing files")
    elif itype == "mcp_tool_call":
        if phase == "started":
            name = ".".join(str(x) for x in (item.get("server"), item.get("tool")) if x)
            lines.append("tool: %s" % clip(name) if name else "tool call")
    elif itype == "web_search":
        if phase == "started":
            query = clip(item.get("query"))
            lines.append("searching web: %s" % query if query else "searching the web")
    elif itype == "todo_list":
        if phase == "started":
            lines.append("updating plan")
    elif itype == "error":
        message = clip(item.get("message"))
        lines.append("error: %s" % message if message else "error")
    return lines, final_text


def codex_adapter(event):
    out = Rendering()
    etype = event.get("type")
    if etype == "thread.started":
        out.lines.append("started")
        return out
    if etype in ("item.started", "item.updated", "item.completed"):
        item = event.get("item")
        if isinstance(item, dict):
            lines, final_text = _codex_item_lines(etype.split(".", 1)[1], item)
            out.lines.extend(lines)
            if final_text:
                out.final_text = final_text
        return out
    if etype == "turn.failed":
        error = event.get("error")
        message = clip(error.get("message")) if isinstance(error, dict) else ""
        out.lines.append("turn failed" + (": %s" % message if message else ""))
        return out
    if etype == "error":
        out.lines.append("error: %s" % clip(event.get("message")))
        return out
    msg = event.get("msg")
    if isinstance(msg, dict):
        mtype = str(msg.get("type") or "")
        if mtype.startswith(PRIVATE_CODEX_MSG_PREFIXES):
            return out  # private reasoning is never rendered
        if mtype == "task_started":
            out.lines.append("started")
        elif mtype == "agent_message":
            text = msg.get("message")
            shown = clip(text)
            if shown:
                out.lines.append("says: %s" % shown)
            if isinstance(text, str) and text:
                out.final_text = text
        elif mtype == "exec_command_begin":
            cmd = msg.get("command")
            if isinstance(cmd, list):
                cmd = " ".join(str(part) for part in cmd)
            cmd = clip(compact_command_display(cmd))
            out.lines.append("command: %s" % cmd if cmd else "running a command")
        elif mtype == "exec_command_end":
            exit_code = msg.get("exit_code")
            out.lines.append(
                "command finished: exit %s" % exit_code
                if exit_code is not None
                else "command finished"
            )
        elif mtype == "task_complete":
            out.lines.append("result: done")
            last = msg.get("last_agent_message")
            if isinstance(last, str) and last:
                out.final_text = last
        elif mtype == "error":
            out.lines.append("error: %s" % clip(msg.get("message")))
        return out
    return out


ADAPTERS = {"claude": claude_adapter, "codex": codex_adapter}

FINAL_TEXT_MISSING_NOTICE = (
    "(no final result text was found in the structured event stream; "
    "see the raw events file for this run)\n"
)


def _resolve_repo_root(explicit):
    """Resolve the repository root for display-path rendering: an explicit
    --repo-root argument first, then the SPECRELAY_REPO_ROOT env var, then a
    single, one-time 'git rev-parse --show-toplevel' call. Returns "" (no
    repo-relative rendering) rather than raising if none of these succeed — a
    renderer that cannot find a repo root must still render, just without
    compaction."""
    if explicit:
        return explicit
    env_root = os.environ.get("SPECRELAY_REPO_ROOT", "")
    if env_root:
        return env_root
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
        )
        if proc.returncode == 0:
            return proc.stdout.decode("utf-8", "replace").strip()
    except Exception:
        pass
    return ""


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Render a provider JSONL agent-event stream as human-readable lines."
    )
    parser.add_argument("--role", required=True, help="line prefix, e.g. executor or reviewer:claude")
    parser.add_argument("--provider", required=True, choices=sorted(ADAPTERS))
    parser.add_argument("--raw-events", default="", help="persist raw event lines to this file")
    parser.add_argument(
        "--final-stdout", default="", help="write the extracted final agent text to this file"
    )
    parser.add_argument(
        "--repo-root", default="",
        help="repository root for project-relative display-path rendering "
             "(falls back to SPECRELAY_REPO_ROOT, then 'git rev-parse --show-toplevel')",
    )
    args = parser.parse_args(argv)

    role = args.role
    adapter = ADAPTERS[args.provider]

    repo_root = _resolve_repo_root(args.repo_root)
    home_dir = os.environ.get("HOME", "")
    if not home_dir:
        try:
            home_dir = os.path.expanduser("~")
        except Exception:
            home_dir = ""
    if home_dir == "~":
        home_dir = ""  # expanduser could not resolve a real home; disable compaction
    configure_paths(repo_root=repo_root or None, home_dir=home_dir or None)

    def warn(text):
        try:
            sys.stderr.write("[%s] %s\n" % (role, text))
            sys.stderr.flush()
        except OSError:
            pass

    if _color is not None:
        color_on, color_invalid = _color.enabled_from_env(sys.stdout)
        if color_invalid:
            warn(
                "warning: unrecognized SPECRELAY_COLOR=%s (expected auto|always|never); using 'auto'"
                % os.environ.get("SPECRELAY_COLOR", "")
            )
        configure_color(color_on)

    raw_fh = None
    if args.raw_events:
        try:
            raw_fh = open(args.raw_events, "w", encoding="utf-8")
        except OSError as exc:
            warn(
                "warning: cannot write raw event file %s (%s); continuing without raw capture"
                % (args.raw_events, exc)
            )

    final_text = None
    problem_count = 0
    for raw_line in sys.stdin.buffer:
        line = raw_line.decode("utf-8", "replace")
        if raw_fh is not None:
            try:
                raw_fh.write(line if line.endswith("\n") else line + "\n")
                raw_fh.flush()
            except OSError as exc:
                warn("warning: raw event capture failed (%s); capture disabled" % exc)
                try:
                    raw_fh.close()
                except OSError:
                    pass
                raw_fh = None
        stripped = line.strip()
        if not stripped:
            continue
        try:
            event = json.loads(stripped)
            if not isinstance(event, dict):
                raise ValueError("event is not a JSON object")
        except ValueError:
            problem_count += 1
            if problem_count <= 3:
                warn("warning: skipped an unparseable event line")
            continue
        try:
            rendering = adapter(event)
        except Exception:
            problem_count += 1
            if problem_count <= 3:
                warn("warning: skipped an event the renderer could not process")
            continue
        if rendering.final_text is not None:
            final_text = rendering.final_text
        for text in rendering.lines:
            try:
                sys.stdout.write(format_rendered_line(role, text) + "\n")
                sys.stdout.flush()
            except OSError:
                # Terminal consumer is gone; keep consuming stdin so the
                # provider process is never killed by a rendering problem.
                pass

    if problem_count > 3:
        warn("warning: %d event lines were skipped in total (unparseable or unprocessable)" % problem_count)
    if raw_fh is not None:
        try:
            raw_fh.close()
        except OSError:
            pass
    if args.final_stdout:
        try:
            with open(args.final_stdout, "w", encoding="utf-8") as fh:
                if final_text is not None:
                    fh.write(final_text if final_text.endswith("\n") else final_text + "\n")
                else:
                    fh.write(FINAL_TEXT_MISSING_NOTICE)
        except OSError as exc:
            warn("warning: cannot write final output file %s (%s)" % (args.final_stdout, exc))
    return 0


if __name__ == "__main__":
    try:
        exit_code = main()
    except BrokenPipeError:
        exit_code = 0
    except KeyboardInterrupt:
        exit_code = 130
    except Exception as exc:  # noqa: BLE001 — catastrophic renderer failure:
        # keep draining stdin so the provider is never killed by SIGPIPE, then
        # report the failure (the shell wrapper keeps the provider exit code
        # authoritative either way).
        try:
            sys.stderr.write("render_agent_events.py: fatal error: %s\n" % exc)
            for _ in sys.stdin.buffer:
                pass
        except Exception:
            pass
        exit_code = 1
    sys.exit(exit_code)
