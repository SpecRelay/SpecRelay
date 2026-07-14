#!/usr/bin/env python3
"""install_metadata_lib.py — installation metadata read/write (spec 0022,
section 2). Mirrors state_lib.py's atomic-write pattern (temp file in the
same directory, then os.replace). Never persists credentials or tokens.
"""
import json
import os
import sys
import tempfile

SCHEMA_VERSION = 1
FILENAME = "install-metadata.json"
REQUIRED_FIELDS = (
    "schema_version",
    "installation_type",
    "installed_version",
    "installed_commit",
    "installed_at",
    "executable_path",
    "resource_path",
    "update_source",
)


def path_for(home):
    return os.path.join(home, FILENAME)


def atomic_write(path, data):
    dir_name = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".install-metadata.", suffix=".json.tmp")
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
        "installation_type": "source-install",
        "installed_version": os.environ.get("VERSION", ""),
        "installed_commit": os.environ.get("COMMIT", ""),
        "installed_at": os.environ.get("INSTALLED_AT", ""),
        "executable_path": os.environ.get("EXE", ""),
        "resource_path": os.environ.get("RES", ""),
        "update_source": {
            "type": os.environ.get("SRC_TYPE", ""),
            "repository": os.environ.get("SRC_REPO", ""),
            "ref": os.environ.get("SRC_REF", ""),
        },
    }
    atomic_write(path_for(home), data)
    return 0


def _load(home):
    with open(path_for(home), "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("install-metadata.json is not a JSON object")
    return data


def cmd_read_field():
    home = os.environ["HOME_DIR"]
    field = os.environ.get("FIELD", "")
    try:
        data = _load(home)
    except (OSError, ValueError, json.JSONDecodeError):
        return 1
    value = data
    for part in field.split("."):
        if not isinstance(value, dict) or part not in value:
            return 1
        value = value[part]
    if isinstance(value, (dict, list)):
        print(json.dumps(value))
    else:
        print("" if value is None else value)
    return 0


def cmd_validate():
    home = os.environ["HOME_DIR"]
    try:
        data = _load(home)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        sys.stderr.write("unreadable or not valid JSON (%s)\n" % exc)
        return 1
    missing = [f for f in REQUIRED_FIELDS if f not in data]
    if missing:
        sys.stderr.write("missing required field(s): %s\n" % ", ".join(missing))
        return 1
    if data.get("schema_version") != SCHEMA_VERSION:
        sys.stderr.write(
            "unsupported schema_version %r (expected %d)\n" % (data.get("schema_version"), SCHEMA_VERSION)
        )
        return 1
    src = data.get("update_source")
    if not isinstance(src, dict) or "type" not in src:
        sys.stderr.write("update_source is missing or malformed\n")
        return 1
    return 0


def main(argv):
    if not argv:
        sys.stderr.write("usage: install_metadata_lib.py <write|read-field|validate>\n")
        return 2
    cmd = argv[0]
    if cmd == "write":
        return cmd_write()
    if cmd == "read-field":
        return cmd_read_field()
    if cmd == "validate":
        return cmd_validate()
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
