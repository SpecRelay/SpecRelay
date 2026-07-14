#!/usr/bin/env python3
"""update_state_lib.py — daily update-discovery cache (spec 0022, section 5).
Atomic read/write of <home>/update-state.json, mirroring state_lib.py's
temp-file-then-replace pattern.
"""
import json
import os
import sys
import tempfile

SCHEMA_VERSION = 1


def path_for(home):
    return os.path.join(home, "update-state.json")


def atomic_write(path, data):
    dir_name = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".update-state.", suffix=".json.tmp")
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


def cmd_write():
    home = os.environ["HOME_DIR"]
    data = {
        "schema_version": SCHEMA_VERSION,
        "last_checked_at": os.environ.get("CHECKED_AT", ""),
        "last_available_version": os.environ.get("AVAILABLE", ""),
        "ignored_version": os.environ.get("IGNORED", ""),
        "last_check_status": os.environ.get("STATUS", ""),
    }
    atomic_write(path_for(home), data)
    return 0


def cmd_read_field():
    home = os.environ["HOME_DIR"]
    field = os.environ.get("FIELD", "")
    try:
        with open(path_for(home), "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError, json.JSONDecodeError):
        return 1
    if not isinstance(data, dict) or field not in data:
        return 1
    value = data[field]
    print("" if value is None else value)
    return 0


def main(argv):
    if not argv:
        sys.stderr.write("usage: update_state_lib.py <write|read-field>\n")
        return 2
    cmd = argv[0]
    if cmd == "write":
        return cmd_write()
    if cmd == "read-field":
        return cmd_read_field()
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
