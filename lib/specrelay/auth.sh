#!/usr/bin/env bash
# auth.sh — runner-owned transition authorization for EXECUTOR_RUNNING ->
# READY_FOR_REVIEW (spec section 11, "Runner-owned transitions"). See
# docs/current-workflow-contract.md, section 5:
#
#   - A random, single-use token is minted into a file OUTSIDE the task's own
#     folder (<runs-root>/.transition-auth/<task-id>.json, mode 0600, parent
#     dir 0700), so it never appears in captured task evidence and is never
#     part of a reviewed diff (the whole runs-root is gitignored).
#   - The token is only minted by the ORCHESTRATOR (workflow.sh), and only
#     AFTER the executor provider subprocess has already exited — it is never
#     passed into that subprocess's environment, so an executor agent with
#     unrestricted shell access has no way to obtain it.
#   - Consuming the token deletes the file immediately (single use).
#   - A trap in the orchestrator deletes the file on every exit path, so a
#     capability never outlives one submission attempt even on a crash.
#
# This is a prompt/process-ownership contract, not an OS-level sandbox: it
# does not defend against a process that ignores its instructions and
# directly edits state.json or calls a lower-level function with a
# forged/stolen token file. That limitation is accepted and documented (see
# docs/current-workflow-contract.md, "Runner-owned transitions").

# specrelay::auth::file <project-root> <task-id>
specrelay::auth::file() {
  local root="$1" task_id="$2" runs_root
  runs_root="$(specrelay::task::runs_root "$root")"
  printf '%s/.transition-auth/%s.json\n' "$runs_root" "$task_id"
}

# specrelay::auth::mint <project-root> <task-id>
# Prints the minted token on stdout (capture into a variable; never log it).
specrelay::auth::mint() {
  local root="$1" task_id="$2" auth_file auth_dir
  auth_file="$(specrelay::auth::file "$root" "$task_id")"
  auth_dir="$(dirname "$auth_file")"
  mkdir -p "$auth_dir"
  chmod 700 "$auth_dir" 2>/dev/null || true

  AUTH_FILE="$auth_file" TASK_ID="$task_id" python3 - <<'PY'
import json, os, secrets

path = os.environ["AUTH_FILE"]
token = secrets.token_hex(32)
data = {"task_id": os.environ["TASK_ID"], "token": token}

fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
    fh.write("\n")

print(token)
PY
}

# specrelay::auth::consume <project-root> <task-id> <token>
# Validates the token against the on-disk file and deletes it on a match
# (single-use). Returns 0 on a valid match, 1 otherwise.
specrelay::auth::consume() {
  local root="$1" task_id="$2" token="${3:-}" auth_file
  auth_file="$(specrelay::auth::file "$root" "$task_id")"
  [ -n "$token" ] || return 1
  [ -f "$auth_file" ] || return 1

  AUTH_FILE="$auth_file" TOKEN="$token" TASK_ID="$task_id" python3 - <<'PY'
import json, os, sys

path = os.environ["AUTH_FILE"]
token = os.environ["TOKEN"]
task_id = os.environ["TASK_ID"]

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

if not isinstance(data, dict) or data.get("token") != token or data.get("task_id") != task_id:
    sys.exit(1)

try:
    os.remove(path)
except OSError:
    pass
sys.exit(0)
PY
}

# specrelay::auth::cleanup <project-root> <task-id>
# Best-effort removal of any still-outstanding authorization file (used in a
# trap so a capability never outlives one submission attempt).
specrelay::auth::cleanup() {
  local root="$1" task_id="$2" auth_file
  auth_file="$(specrelay::auth::file "$root" "$task_id")"
  rm -f "$auth_file" 2>/dev/null || true
}
