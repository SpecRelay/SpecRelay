#!/usr/bin/env bash
# lock.sh — safe protection against two SpecRelay processes mutating the same
# task at once (spec section 51, "Task locking"), extended by spec 0029
# section 21 ("Execution-owner lease") with a durable lease that defeats PID
# reuse and hung-process ambiguity.
#
# Uses `mkdir` for lock acquisition: creating a directory is atomic on every
# POSIX filesystem this project runs on (no `flock` dependency, which is not
# reliably available on macOS bash without an extra binary). The lock
# directory holds a single `owner` file recording the holding process's
# lease (spec 0029, section 21) as JSON (schema_version 1): pid, hostname,
# acquisition time, pid_start_time (defeats PID reuse), invocation_id,
# owner_token (defeats a stale process stomping a lease another process
# later reacquired), provider_pgid (once known), and a heartbeat the owning
# process refreshes while it holds the task (defeats hung/zombie ambiguity).
#
# Layout: <runs-root>/.specrelay-locks/<task-id>.lock/owner

specrelay::lock::_dir() {
  local root="$1" task_id="$2" runs_root
  runs_root="$(specrelay::task::runs_root "$root")"
  printf '%s/.specrelay-locks/%s.lock\n' "$runs_root" "$task_id"
}

specrelay::lock::_owner_file() {
  printf '%s/owner\n' "$1"
}

# specrelay::lock::_pid_alive <pid>
specrelay::lock::_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# specrelay::lock::_pid_start_time <pid>
# A portable, opaque "process start" marker (spec 0029, section 21: "process
# start time — defeats PID reuse"). `ps -o lstart=` works on both macOS and
# Linux without any third-party dependency, so it is used uniformly rather
# than parsing /proc directly; the VALUE is never interpreted, only compared
# for equality against a later read of the same pid. Empty if the pid cannot
# be inspected (process gone, or `ps` unavailable).
specrelay::lock::_pid_start_time() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  ps -o lstart= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# specrelay::lock::_owner_field <lock-dir> <field>
# Reads one field from the owner lease JSON. Empty (never fatal) if the file
# is missing, unreadable, or the field is absent.
specrelay::lock::_owner_field() {
  local lock_dir="$1" field="$2" owner_file
  owner_file="$(specrelay::lock::_owner_file "$lock_dir")"
  [ -f "$owner_file" ] || return 1
  FIELD="$field" python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
val = data.get(os.environ["FIELD"])
if val is None:
    sys.exit(1)
print(val)
' "$owner_file" 2>/dev/null
}

specrelay::lock::_read_owner_pid() {
  specrelay::lock::_owner_field "$1" pid
}

specrelay::lock::_read_owner_host() {
  specrelay::lock::_owner_field "$1" host
}

# specrelay::lock::_heartbeat_interval <project-root>
specrelay::lock::_heartbeat_interval() {
  local root="$1" v
  v="$(specrelay::config::get "$root" "executor_finalization.supervision.heartbeat_interval_seconds" "15" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) v=15 ;; esac
  printf '%s\n' "$v"
}

# specrelay::lock::_owner_token
# A 128-bit random hex token (spec 0029, section 21). Falls back to a
# best-effort (still unpredictable-enough for this defensive purpose, never
# security-critical) value when neither python3's secrets module nor
# /dev/urandom is available, so acquisition never hard-fails on a minimal host.
specrelay::lock::_owner_token() {
  python3 -c 'import secrets; print(secrets.token_hex(16))' 2>/dev/null || \
    (od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n') || \
    printf '%s%s\n' "$$" "$(date +%s%N 2>/dev/null || date +%s)"
}

# specrelay::lock::acquire <project-root> <task-id> [invocation-id]
# Acquires the lock for this process ($$), writing a fresh lease (spec 0029,
# section 21). Reclaims a stale lock (same host, owning PID no longer alive,
# OR same PID but a mismatched pid_start_time — PID reuse) automatically.
# Prints nothing on success; prints a clear error and returns 1 if the task
# is genuinely held by a live process (possibly on another host, which
# cannot be liveness-checked and is therefore always treated as live).
specrelay::lock::acquire() {
  local root="$1" task_id="$2" invocation_id="${3:-}" lock_dir owner_file this_host
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  owner_file="$(specrelay::lock::_owner_file "$lock_dir")"
  this_host="$(hostname 2>/dev/null || echo unknown-host)"

  mkdir -p "$(dirname "$lock_dir")"

  if mkdir "$lock_dir" 2>/dev/null; then
    : # acquired on first attempt
  else
    # Classify via the single spec 0029 section 21.2 lease classifier (never
    # duplicate this logic here) so every caller — including automatic
    # in-loop recovery (workflow::drive, AC-14/M12) — sees the SAME
    # live/stale-dead-pid/suspect-hung/foreign-host/absent decision. Only
    # stale-dead-pid (dead pid, or a live pid that is a PID-reuse of the
    # recorded owner) is ever reclaimed automatically; live, suspect-hung,
    # and foreign-host all refuse with an explicit, classification-specific
    # message — a live-but-hung owner (stale heartbeat) is never treated as
    # equivalent to a genuinely dead one (AC-23).
    local classification owner_pid owner_host
    classification="$(specrelay::lock::lease_classify "$root" "$task_id")"
    owner_pid="$(specrelay::lock::_read_owner_pid "$lock_dir" || true)"
    owner_host="$(specrelay::lock::_read_owner_host "$lock_dir" || true)"

    case "$classification" in
      stale-dead-pid|absent)
        specrelay::out::err "reclaiming stale lock for task '$task_id' (owner pid $owner_pid is no longer running on $owner_host)"
        rm -rf "$lock_dir"
        if ! mkdir "$lock_dir" 2>/dev/null; then
          specrelay::out::err "failed to reclaim stale lock for task '$task_id' (lost a race with another process)"
          return 1
        fi
        ;;
      suspect-hung)
        specrelay::out::err "task '$task_id' is locked by another process (pid ${owner_pid:-unknown} on ${owner_host:-unknown host}), classified suspect-hung (spec 0029, section 21.2): the owning process is still alive but its heartbeat is stale, so it may be hung rather than genuinely working. Auto-recovery refuses this lease; an explicit human decision is required."
        specrelay::out::err "if you have confirmed that process is not actually working on this task, remove the stale lock manually: rm -rf '$lock_dir'"
        return 1
        ;;
      foreign-host)
        specrelay::out::err "task '$task_id' is locked by another process (pid ${owner_pid:-unknown} on ${owner_host:-unknown host}), classified foreign-host (spec 0029, section 21.2): a lock held on a different host cannot be liveness-checked from here, so it is conservatively treated as live. Auto-recovery refuses this lease; an explicit human decision is required."
        specrelay::out::err "if you have confirmed that host is not actually working on this task, remove the stale lock manually: rm -rf '$lock_dir'"
        return 1
        ;;
      *)
        specrelay::out::err "task '$task_id' is locked by another process (pid ${owner_pid:-unknown} on ${owner_host:-unknown host})"
        specrelay::out::err "if that process crashed, remove the stale lock manually: rm -rf '$lock_dir'"
        return 1
        ;;
    esac
  fi

  local now interval pid_start token
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  interval="$(specrelay::lock::_heartbeat_interval "$root" 2>/dev/null || echo 15)"
  pid_start="$(specrelay::lock::_pid_start_time "$$")"
  token="$(specrelay::lock::_owner_token)"

  PID="$$" HOST="$this_host" ACQUIRED_AT="$now" PID_START="$pid_start" \
  INVOCATION_ID="$invocation_id" TOKEN="$token" HEARTBEAT_AT="$now" INTERVAL="$interval" \
  python3 -c '
import json, os
d = {
    "schema_version": 1,
    "pid": int(os.environ["PID"]),
    "host": os.environ["HOST"],
    "acquired_at": os.environ["ACQUIRED_AT"],
    "pid_start_time": os.environ.get("PID_START") or None,
    "invocation_id": os.environ.get("INVOCATION_ID") or None,
    "owner_token": os.environ["TOKEN"],
    "provider_pgid": None,
    "heartbeat_at": os.environ["HEARTBEAT_AT"],
    "heartbeat_interval_seconds": int(os.environ["INTERVAL"]),
}
print(json.dumps(d))
' > "$owner_file"
  return 0
}

# specrelay::lock::release <project-root> <task-id>
# Releases the lock ONLY if it is currently held by this process's PID
# (defense against a stale/reclaimed lock being released by the wrong owner).
specrelay::lock::release() {
  local root="$1" task_id="$2" lock_dir owner_pid
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  [ -d "$lock_dir" ] || return 0
  owner_pid="$(specrelay::lock::_read_owner_pid "$lock_dir" || true)"
  if [ "$owner_pid" = "$$" ]; then
    rm -rf "$lock_dir"
  fi
  return 0
}

# specrelay::lock::is_locked <project-root> <task-id>
specrelay::lock::is_locked() {
  local root="$1" task_id="$2" lock_dir
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  [ -d "$lock_dir" ]
}

# specrelay::lock::owner_liveness <project-root> <task-id>
# Read-only classification of the current lock's owning process, used by the
# SpecRelay-native interrupted-task recovery command (SDD 0085B, section 3.2)
# to decide whether recovery is safe WITHOUT mutating anything. Prints exactly
# one of:
#   none         - no lock directory exists (nothing owns the task)
#   stale        - lock exists, owner is on THIS host, and its pid is not alive
#   live-local   - lock exists, owner is on THIS host, and its pid is alive
#   live-foreign - lock exists, owner is on ANOTHER host (cannot be
#                  liveness-checked, so it is conservatively treated as live)
# A recovery command must REFUSE for live-local / live-foreign (never
# force-remove a live lock), and may safely proceed for none / stale (a stale
# lock is reclaimed by specrelay::lock::acquire using the same dead-pid check).
# Kept as the pre-0029 read-only surface used by existing callers/tests;
# specrelay::lock::lease_classify (below) is the finer-grained spec 0029
# classification (adds stale-dead-pid / suspect-hung / foreign-host) used by
# automatic in-loop recovery.
specrelay::lock::owner_liveness() {
  local root="$1" task_id="$2" lock_dir owner_pid owner_host this_host
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  this_host="$(hostname 2>/dev/null || echo unknown-host)"

  if [ ! -d "$lock_dir" ]; then
    printf 'none\n'
    return 0
  fi

  owner_pid="$(specrelay::lock::_read_owner_pid "$lock_dir" || true)"
  owner_host="$(specrelay::lock::_read_owner_host "$lock_dir" || true)"

  if [ "$owner_host" = "$this_host" ]; then
    if specrelay::lock::_pid_alive "$owner_pid"; then
      printf 'live-local\n'
    else
      printf 'stale\n'
    fi
  else
    printf 'live-foreign\n'
  fi
  return 0
}

# specrelay::lock::owner_description <project-root> <task-id>
# Prints a short human-readable "pid <p> on <host>" description of the current
# lock owner (best-effort; empty if there is no lock). For messages only.
specrelay::lock::owner_description() {
  local root="$1" task_id="$2" lock_dir owner_pid owner_host
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  [ -d "$lock_dir" ] || return 0
  owner_pid="$(specrelay::lock::_read_owner_pid "$lock_dir" || true)"
  owner_host="$(specrelay::lock::_read_owner_host "$lock_dir" || true)"
  printf 'pid %s on %s\n' "${owner_pid:-unknown}" "${owner_host:-unknown-host}"
}

# --- execution-owner lease (spec 0029, section 21) --------------------------

# specrelay::lock::lease_classify <project-root> <task-id>
# Prints exactly one of (spec 0029, section 21.2):
#   live | stale-dead-pid | suspect-hung | foreign-host | absent
# Automatic recovery (workflow::drive/resume) may proceed ONLY for
# stale-dead-pid or absent; every other classification refuses and requires
# an explicit human decision (never trusts PID existence alone — AC-11).
specrelay::lock::lease_classify() {
  local root="$1" task_id="$2" lock_dir this_host owner_host owner_pid owner_start current_start heartbeat_at interval now age
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  this_host="$(hostname 2>/dev/null || echo unknown-host)"

  if [ ! -d "$lock_dir" ]; then
    printf 'absent\n'
    return 0
  fi

  owner_host="$(specrelay::lock::_read_owner_host "$lock_dir" || true)"
  if [ "$owner_host" != "$this_host" ]; then
    printf 'foreign-host\n'
    return 0
  fi

  owner_pid="$(specrelay::lock::_read_owner_pid "$lock_dir" || true)"
  if ! specrelay::lock::_pid_alive "$owner_pid"; then
    printf 'stale-dead-pid\n'
    return 0
  fi

  owner_start="$(specrelay::lock::_owner_field "$lock_dir" pid_start_time || true)"
  current_start="$(specrelay::lock::_pid_start_time "$owner_pid")"
  if [ -n "$owner_start" ] && [ -n "$current_start" ] && [ "$owner_start" != "$current_start" ]; then
    # PID reuse: the live process at this pid is NOT the recorded owner.
    printf 'stale-dead-pid\n'
    return 0
  fi

  heartbeat_at="$(specrelay::lock::_owner_field "$lock_dir" heartbeat_at || true)"
  interval="$(specrelay::lock::_owner_field "$lock_dir" heartbeat_interval_seconds || true)"
  case "$interval" in ''|*[!0-9]*) interval=15 ;; esac

  if [ -z "$heartbeat_at" ]; then
    printf 'live\n'
    return 0
  fi

  now="$(date -u +%s 2>/dev/null || echo 0)"
  age="$(HEARTBEAT_AT="$heartbeat_at" python3 -c '
import datetime, os, sys
try:
    ts = os.environ["HEARTBEAT_AT"].rstrip("Z")
    dt = datetime.datetime.fromisoformat(ts)
    print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))
except Exception:
    print(0)
' 2>/dev/null)"
  if [ "$age" -le 0 ] 2>/dev/null; then
    printf 'live\n'
    return 0
  fi
  local stale_after=$((interval * 3))
  if [ $((now - age)) -gt "$stale_after" ]; then
    printf 'suspect-hung\n'
  else
    printf 'live\n'
  fi
  return 0
}

# specrelay::lock::lease_heartbeat <project-root> <task-id>
# Refreshes heartbeat_at IN PLACE, only when this process's pid AND
# owner_token match the recorded lease (spec 0029, section 21.1 — the token
# guards against a stale process stomping a lease another process later
# reacquired). Silent no-op otherwise (never fatal — a heartbeat failure is
# observed via lease_classify's suspect-hung outcome, never by crashing the
# caller).
specrelay::lock::lease_heartbeat() {
  local root="$1" task_id="$2" lock_dir owner_file owner_pid
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  owner_file="$(specrelay::lock::_owner_file "$lock_dir")"
  [ -f "$owner_file" ] || return 0
  owner_pid="$(specrelay::lock::_read_owner_pid "$lock_dir" || true)"
  [ "$owner_pid" = "$$" ] || return 0

  local now tmp
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/specrelay-lease.XXXXXX")"
  NOW="$now" python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
data["heartbeat_at"] = os.environ["NOW"]
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(data, fh)
' "$owner_file" "$tmp" 2>/dev/null && mv "$tmp" "$owner_file"
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# specrelay::lock::lease_set_provider_pgid <project-root> <task-id> <pgid>
# Records the provider's process-group id once known (spec 0029, section 21),
# so a later inspection can find/terminate any surviving children by group.
specrelay::lock::lease_set_provider_pgid() {
  local root="$1" task_id="$2" pgid="$3" lock_dir owner_file tmp
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  owner_file="$(specrelay::lock::_owner_file "$lock_dir")"
  [ -f "$owner_file" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/specrelay-lease.XXXXXX")"
  PGID="$pgid" python3 -c '
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
data["provider_pgid"] = int(os.environ["PGID"])
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(data, fh)
' "$owner_file" "$tmp" 2>/dev/null && mv "$tmp" "$owner_file"
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# specrelay::lock::lease_field <project-root> <task-id> <field>
specrelay::lock::lease_field() {
  local root="$1" task_id="$2" field="$3" lock_dir
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  specrelay::lock::_owner_field "$lock_dir" "$field"
}

# specrelay::lock::_heartbeat_helper_start <project-root> <task-id>
# Starts a small detached heartbeat-refresh loop (spec 0029, section 21.3: a
# helper process is acceptable for portability as long as the owner
# supervises it and records its terminal status). Prints the helper's pid.
# The caller (workflow.sh) is responsible for stopping it with
# lease_heartbeat_helper_stop once the supervised provider call returns —
# this is the "supervise + record terminal status" contract: the helper never
# outlives a checked stop, and its own liveness is re-verified there.
specrelay::lock::heartbeat_helper_start() {
  local root="$1" task_id="$2" interval
  interval="$(specrelay::lock::_heartbeat_interval "$root" 2>/dev/null || echo 15)"
  # Explicit redirection BEFORE backgrounding is mandatory here: this
  # function is always called via command substitution
  # (`pid="$(specrelay::lock::heartbeat_helper_start ...)"`), which captures
  # output through a pipe. An infinite background loop that inherited that
  # pipe's write end would hold it open forever, and the command
  # substitution would then block waiting for EOF that never arrives —
  # exactly the hang this redirection prevents.
  (
    while :; do
      sleep "$interval"
      specrelay::lock::lease_heartbeat "$root" "$task_id"
    done
  ) </dev/null >/dev/null 2>&1 &
  disown "$!" 2>/dev/null || true
  printf '%s\n' "$!"
}

# specrelay::lock::heartbeat_helper_stop <helper-pid>
# Supervises the helper's terminal status (spec 0029, section 21.3): reports
# whether it was still alive (expected — it runs an infinite loop) or had
# already died (a failure worth knowing about, even though it never blocks
# anything — lease_classify's heartbeat-age check is the authoritative
# hung-detector regardless).
specrelay::lock::heartbeat_helper_stop() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    printf 'stopped\n'
  else
    printf 'already-dead\n'
  fi
}
