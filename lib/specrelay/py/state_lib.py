"""SpecRelay core task-state read/write helper.

This is SpecRelay's own, independent state module, encoding the canonical
state-machine knowledge documented in docs/current-workflow-contract.md: it
preserves a durable, on-disk state.json shape and transition semantics
(preserving existing persisted state names).

state.json is always a JSON object written atomically (temp file in the same
directory, then os.replace), so a crash mid-write never leaves a half-written
state.json.

CLI usage (each subcommand prints to stdout on success, JSON diagnostics
never required by callers, plain text errors to stderr):

  state_lib.py schema-version
      Prints CURRENT_SCHEMA_VERSION (the schema version written for new tasks).

  state_lib.py get <state-file> <field>
      Prints a top-level field's value (empty line if absent/None).

  state_lib.py init <state-file> <fields-json>
      Creates a new state.json (fails if the file already exists) with the
      given JSON object as its exact initial content.

  state_lib.py set <state-file> <set-json>
      Merges fields into an EXISTING state.json with no transition/state
      validation (not a lifecycle transition — a metadata update).

  state_lib.py transition <state-file> <allowed-states-csv> <target-state> <set-json> [<clear-json>]
      Validates the current (normalized) state is one of allowed-states-csv,
      then sets every key in <set-json> (a JSON object), removes every key
      named in <clear-json> (a JSON array, optional), sets "state" to
      <target-state>, and writes atomically.
      Exit codes: 0 = transitioned, 2 = refused (state not allowed),
      3 = invalid/unreadable JSON, 4 = file not found.

Canonical vs legacy state names: see normalize_state() below. This module
never writes a legacy name; it only ever reads one for backward-compatible
inspection of tasks the OTHER (legacy) engine created.
"""

import json
import os
import sys
import tempfile

# Shared color policy (optional sibling module). Only the human-facing status
# lines below are ever colorized; the machine-parsed command output (get,
# schema-version) is always printed raw so callers can parse it. Color is
# emitted only when stdout is a TTY (auto) or SPECRELAY_COLOR=always, so any
# `$(...)` capture stays plain.
try:
    import color as _color
except Exception:  # pragma: no cover - color is an optional sibling module
    _color = None


def _code(name):
    """An ANSI code from the shared module, or "" when color is unavailable."""
    return getattr(_color, name, "") if _color is not None else ""


def _human(text, code):
    """Print one human-facing status line to stdout, colorized when the shared
    policy says color is enabled for stdout. Never used for parsable output."""
    if _color is not None and code:
        on, _invalid = _color.enabled_from_env(sys.stdout)
        if on:
            text = _color.paint(text, code, True)
    print(text)


DRAFT = "DRAFT"
READY_FOR_EXECUTOR = "READY_FOR_EXECUTOR"
EXECUTOR_RUNNING = "EXECUTOR_RUNNING"
READY_FOR_REVIEW = "READY_FOR_REVIEW"
# An automated reviewer currently owns the task and review execution is in
# progress (spec 0011). Manual reviewers never enter this state — they rest at
# READY_FOR_REVIEW for a human decision. Existing task files without this state
# remain valid; only new automated executions may enter it (no migration).
REVIEWER_RUNNING = "REVIEWER_RUNNING"
CHANGES_REQUESTED = "CHANGES_REQUESTED"
READY_FOR_HUMAN_REVIEW = "READY_FOR_HUMAN_REVIEW"
BLOCKED = "BLOCKED"

# The state.json schema version this engine writes for NEW tasks. This is the
# single source of truth: bash reads it via `state_lib.py schema-version`
# (see state.sh) rather than hardcoding the number. It is an integer that
# increments only when the persisted state.json shape changes in a way the
# compatibility guard must reason about (see
# specrelay::workflow::assert_schema_compat and docs/versioning.md).
#
# Compatibility rules for a task's recorded schema_version:
#   * absent (historical task) -> treated as implicit v1; readable and safe.
#   * <= CURRENT_SCHEMA_VERSION -> compatible (schema is additive within a
#     major engine version; older/current shapes still read).
#   * >  CURRENT_SCHEMA_VERSION -> unknown FUTURE schema; a mutating resume/run
#     is refused with an actionable message (read-only inspection still works).
CURRENT_SCHEMA_VERSION = 1

# Legacy state name -> canonical state name. Read-only backward compatibility;
# SpecRelay never writes a legacy name.
LEGACY_STATE_ALIASES = {
    "READY_FOR_CODEX_REVIEW": READY_FOR_REVIEW,
}


def normalize_state(state):
    if state is None:
        return None
    return LEGACY_STATE_ALIASES.get(state, state)


def state_matches(current, canonical):
    return normalize_state(current) == normalize_state(canonical)


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("state.json is not a JSON object")
    return data


def atomic_write(path, data):
    dir_name = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".state.", suffix=".json.tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2, ensure_ascii=False, sort_keys=True)
            out.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_schema_version(argv):
    """Print the schema version this engine writes for NEW tasks (the single
    source of truth used by state.sh / transitions.sh / workflow.sh)."""
    print(CURRENT_SCHEMA_VERSION)
    return 0


def cmd_get(argv):
    path, field = argv[0], argv[1]
    if not os.path.isfile(path):
        return 4
    data = load(path)
    value = data.get(field)
    if value is None:
        print("")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value))
    else:
        print(value)
    return 0


def cmd_init(argv):
    path, fields_json = argv[0], argv[1]
    if os.path.exists(path):
        sys.stderr.write(f"Refusing to init: already exists: {path}\n")
        return 2
    data = json.loads(fields_json)
    if not isinstance(data, dict):
        sys.stderr.write("init fields must be a JSON object\n")
        return 3
    os.makedirs(os.path.dirname(path), exist_ok=True)
    atomic_write(path, data)
    _human(f"Initialized state: {path}", _code("CYAN"))
    return 0


def cmd_set(argv):
    """Merge fields into an existing state.json WITHOUT a state transition
    (no allowed-source-state check). Used for metadata updates that are not
    lifecycle transitions, e.g. an explicit --allow-dirty-baseline override
    on an already-created task."""
    path = argv[0]
    set_fields = json.loads(argv[1]) if len(argv) > 1 and argv[1] else {}

    if not os.path.isfile(path):
        sys.stderr.write(f"state.json not found: {path}\n")
        return 4
    try:
        data = load(path)
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"Cannot set fields: state.json is missing or invalid ({exc}).\n")
        return 3

    data.update(set_fields)
    atomic_write(path, data)
    _human(f"Updated fields: {', '.join(sorted(set_fields.keys()))}", _code("CYAN"))
    return 0


def cmd_transition(argv):
    path = argv[0]
    allowed = [s for s in argv[1].split(",") if s]
    target = argv[2]
    set_fields = json.loads(argv[3]) if len(argv) > 3 and argv[3] else {}
    clear_fields = json.loads(argv[4]) if len(argv) > 4 and argv[4] else []

    if not os.path.isfile(path):
        sys.stderr.write(f"state.json not found: {path}\n")
        return 4

    try:
        data = load(path)
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"Cannot transition: state.json is missing or invalid ({exc}).\n")
        return 3

    current = data.get("state")
    if not any(state_matches(current, a) for a in allowed):
        sys.stderr.write(
            f"Refusing to transition task in state '{current}'.\n"
            f"Allowed source states: {', '.join(allowed)}.\n"
        )
        return 2

    for key in clear_fields:
        data.pop(key, None)
    data.update(set_fields)
    data["state"] = target

    atomic_write(path, data)
    _human(f"Transitioned: {current} -> {target}", _code("GREEN"))
    return 0


def main(argv):
    if not argv:
        sys.stderr.write("Usage: state_lib.py <schema-version|get|init|set|transition> ...\n")
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "schema-version":
        return cmd_schema_version(rest)
    if cmd == "get":
        return cmd_get(rest)
    if cmd == "init":
        return cmd_init(rest)
    if cmd == "set":
        return cmd_set(rest)
    if cmd == "transition":
        return cmd_transition(rest)
    sys.stderr.write(f"Unknown state_lib command: {cmd}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
