"""proc_supervisor.py — portable process/session-group supervision (spec 0029,
section 22, "Portable process-group supervision").

Uses OS process APIs directly (os.setsid, os.killpg) rather than assuming an
external GNU `setsid` binary exists (it is absent on macOS). Supported on
macOS and Linux (spec 0029, section 22.2); Windows is not supported and
`cmd_available` honestly reports that rather than approximating POSIX
process-group semantics with single-PID termination.

CLI usage:
  proc_supervisor.py available
      Prints "yes" if this platform supports process-group supervision
      (os.setsid + os.killpg), else "no" (spec 0029, section 22.1 — the
      honest foreground-fallback trigger).

  proc_supervisor.py run-in-group --pgid-file <path> -- <cmd> [args...]
      Runs <cmd> as a NEW session/process-group leader (os.setsid) so its
      pgid equals its own pid. Writes that pid/pgid to <pgid-file>
      immediately (before the command necessarily starts doing real work),
      then waits synchronously and exits with the command's real exit code
      — the group leader's status remains the authoritative exit code (spec
      0029, section 22 note). On an unsupported platform, runs the command
      directly (no new session) and still exits with its real code; no pgid
      file is written (nothing to supervise by group).

  proc_supervisor.py terminate-group <pgid> [grace-seconds]
      Terminates an entire process group: SIGTERM -> bounded grace -> SIGKILL.
      Prints one of: already-dead | terminated-gracefully | killed.

  proc_supervisor.py list-group <pgid> [exclude-pid...]
      Prints the live PIDs currently in <pgid>, one per line, excluding any
      pid named in exclude-pid (typically the already-`wait`ed group leader).
      Used for provider-spawned-orphan detection (spec 0029, section 19.1.2).
"""

import os
import signal
import subprocess
import sys
import time


def available():
    return hasattr(os, "setsid") and hasattr(os, "killpg") and os.name == "posix"


def cmd_available(argv):
    print("yes" if available() else "no")
    return 0


def cmd_run_in_group(argv):
    pgid_file = None
    i = 0
    while i < len(argv):
        if argv[i] == "--pgid-file":
            pgid_file = argv[i + 1]
            i += 2
            continue
        if argv[i] == "--":
            i += 1
            break
        i += 1
    cmd = argv[i:]
    if not cmd:
        sys.stderr.write("run-in-group: no command given\n")
        return 2

    preexec = os.setsid if available() else None
    try:
        proc = subprocess.Popen(cmd, preexec_fn=preexec)
    except FileNotFoundError as exc:
        sys.stderr.write(f"run-in-group: {exc}\n")
        return 127

    if pgid_file and available():
        try:
            with open(pgid_file, "w", encoding="utf-8") as fh:
                fh.write(str(proc.pid))
        except OSError:
            pass

    try:
        return proc.wait()
    except KeyboardInterrupt:
        proc.wait()
        return 130


def _all_pgids():
    """Yields (pid, pgid) for every process this host's `ps` can see. Uses the
    portable `-eo pid=,pgid=` form (supported by both macOS/BSD ps and
    Linux/procps ps) rather than a platform-specific `-g <pgid>` filter."""
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid=,pgid="], capture_output=True, text=True, check=False
        )
    except Exception:
        return
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            yield int(parts[0]), int(parts[1])
        except ValueError:
            continue


def _group_alive(pgid):
    return any(g == pgid for _pid, g in _all_pgids())


def cmd_terminate_group(argv):
    pgid = int(argv[0])
    grace = float(argv[1]) if len(argv) > 1 and argv[1] else 10.0
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        print("already-dead")
        return 0
    except PermissionError as exc:
        sys.stderr.write(f"terminate-group: {exc}\n")
        print("already-dead")
        return 0

    deadline = time.time() + grace
    while time.time() < deadline:
        if not _group_alive(pgid):
            print("terminated-gracefully")
            return 0
        time.sleep(0.2)

    try:
        os.killpg(pgid, signal.SIGKILL)
        print("killed")
    except ProcessLookupError:
        print("already-dead")
    return 0


def cmd_list_group(argv):
    pgid = int(argv[0])
    exclude = set()
    for tok in argv[1:]:
        if tok:
            try:
                exclude.add(int(tok))
            except ValueError:
                pass
    for pid, g in _all_pgids():
        if g == pgid and pid not in exclude:
            print(pid)
    return 0


def main(argv):
    if not argv:
        sys.stderr.write(
            "Usage: proc_supervisor.py <available|run-in-group|terminate-group|list-group> ...\n"
        )
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "available":
        return cmd_available(rest)
    if cmd == "run-in-group":
        return cmd_run_in_group(rest)
    if cmd == "terminate-group":
        return cmd_terminate_group(rest)
    if cmd == "list-group":
        return cmd_list_group(rest)
    sys.stderr.write(f"Unknown proc_supervisor command: {cmd}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
