#!/usr/bin/env bash
# lock.sh — safe protection against two SpecRelay processes mutating the same
# task at once (spec section 51, "Task locking").
#
# Uses `mkdir` for lock acquisition: creating a directory is atomic on every
# POSIX filesystem this project runs on (no `flock` dependency, which is not
# reliably available on macOS bash without an extra binary). The lock
# directory holds a single `owner` file recording the holding process's PID,
# hostname, and acquisition time, so a stale lock (owning process no longer
# alive, same host) can be safely detected and recovered without a permanent
# deadlock after a crash.
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

# specrelay::lock::_read_owner_pid <lock-dir>
specrelay::lock::_read_owner_pid() {
  local owner_file
  owner_file="$(specrelay::lock::_owner_file "$1")"
  [ -f "$owner_file" ] || return 1
  grep -m1 '^pid=' "$owner_file" 2>/dev/null | cut -d= -f2
}

specrelay::lock::_read_owner_host() {
  local owner_file
  owner_file="$(specrelay::lock::_owner_file "$1")"
  [ -f "$owner_file" ] || return 1
  grep -m1 '^host=' "$owner_file" 2>/dev/null | cut -d= -f2
}

# specrelay::lock::acquire <project-root> <task-id>
# Acquires the lock for this process ($$). Reclaims a stale lock (same host,
# owning PID no longer alive) automatically. Prints nothing on success;
# prints a clear error and returns 1 if the task is genuinely held by a live
# process (possibly on another host, which cannot be liveness-checked and is
# therefore always treated as live).
specrelay::lock::acquire() {
  local root="$1" task_id="$2" lock_dir owner_file this_host
  lock_dir="$(specrelay::lock::_dir "$root" "$task_id")"
  owner_file="$(specrelay::lock::_owner_file "$lock_dir")"
  this_host="$(hostname 2>/dev/null || echo unknown-host)"

  mkdir -p "$(dirname "$lock_dir")"

  if mkdir "$lock_dir" 2>/dev/null; then
    : # acquired on first attempt
  else
    local owner_pid owner_host
    owner_pid="$(specrelay::lock::_read_owner_pid "$lock_dir" || true)"
    owner_host="$(specrelay::lock::_read_owner_host "$lock_dir" || true)"

    if [ "$owner_host" = "$this_host" ] && ! specrelay::lock::_pid_alive "$owner_pid"; then
      specrelay::out::err "reclaiming stale lock for task '$task_id' (owner pid $owner_pid is no longer running on $owner_host)"
      rm -rf "$lock_dir"
      if ! mkdir "$lock_dir" 2>/dev/null; then
        specrelay::out::err "failed to reclaim stale lock for task '$task_id' (lost a race with another process)"
        return 1
      fi
    else
      specrelay::out::err "task '$task_id' is locked by another process (pid ${owner_pid:-unknown} on ${owner_host:-unknown host})"
      specrelay::out::err "if that process crashed, remove the stale lock manually: rm -rf '$lock_dir'"
      return 1
    fi
  fi

  {
    printf 'pid=%s\n' "$$"
    printf 'host=%s\n' "$this_host"
    printf 'acquired_at=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "$owner_file"
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
