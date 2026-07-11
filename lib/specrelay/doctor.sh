#!/usr/bin/env bash
# doctor.sh — `specrelay doctor`: read-only readiness diagnostics (spec
# sections 17 and 55).
#
# Every check here is READ-ONLY: it inspects the filesystem, PATH, and
# .specrelay/config.yml, and never mutates any task or repository state.
# Prints a ✓/✗ line per check and returns non-zero if any MANDATORY check
# failed (spec: "Return non-zero if mandatory readiness checks fail").

specrelay::doctor::_ok() {
  printf '\xe2\x9c\x93 %s\n' "$1"
}

specrelay::doctor::_fail() {
  printf '\xe2\x9c\x97 %s\n' "$1"
  DOCTOR_FAILED=1
}

specrelay::doctor::_info() {
  printf '\xe2\x9c\x93 %s\n' "$1"
}

# specrelay::doctor::run <self-dir>
specrelay::doctor::run() {
  local self_dir="$1"
  DOCTOR_FAILED=0

  # --- Git repository detected ------------------------------------------
  local git_root=""
  if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    specrelay::doctor::_ok "Git repository ($git_root)"
  else
    specrelay::doctor::_fail "Git repository: not inside a git working tree"
  fi

  # --- Project root --------------------------------------------------------
  local root=""
  if root="$(specrelay::project::root 2>/dev/null)"; then
    specrelay::doctor::_ok "Project root ($root)"
  else
    specrelay::doctor::_fail "Project root: could not be discovered"
    # Nothing below can run meaningfully without a root.
    [ "$DOCTOR_FAILED" -ne 0 ] && return 1
  fi

  # --- Config readable ------------------------------------------------------
  local config_ok=1
  if specrelay::config::exists "$root"; then
    if specrelay::config::validate "$root" >/dev/null 2>&1; then
      specrelay::doctor::_ok "SpecRelay config (.specrelay/config.yml readable)"
    else
      specrelay::doctor::_fail "SpecRelay config: .specrelay/config.yml exists but is malformed"
      config_ok=0
    fi
  else
    specrelay::doctor::_fail "SpecRelay config: .specrelay/config.yml not found"
    config_ok=0
  fi

  # --- Spec root exists -----------------------------------------------------
  local spec_root
  spec_root="$(specrelay::task::spec_root "$root")"
  if [ -d "$spec_root" ]; then
    specrelay::doctor::_ok "Spec root ($spec_root)"
  else
    specrelay::doctor::_fail "Spec root: $spec_root does not exist"
  fi

  # --- Task runtime root accessible -----------------------------------------
  local runs_root
  runs_root="$(specrelay::task::runs_root "$root")"
  if [ -d "$runs_root" ] && [ -r "$runs_root" ] && [ -w "$runs_root" ]; then
    specrelay::doctor::_ok "Task runtime root ($runs_root)"
  elif [ ! -e "$runs_root" ]; then
    # A fresh project may not have run anything yet; the parent being
    # writable is what actually matters (the directory itself is created
    # lazily on first task creation).
    local parent
    parent="$(dirname "$runs_root")"
    if [ -d "$parent" ] && [ -w "$parent" ]; then
      specrelay::doctor::_ok "Task runtime root ($runs_root; not yet created, parent is writable)"
    else
      specrelay::doctor::_fail "Task runtime root: $runs_root does not exist and cannot be created"
    fi
  else
    specrelay::doctor::_fail "Task runtime root: $runs_root exists but is not readable/writable"
  fi

  # --- Executor / reviewer provider available -------------------------------
  local executor_provider reviewer_provider
  executor_provider="$(specrelay::workflow::executor_provider "$root")"
  reviewer_provider="$(specrelay::workflow::reviewer_provider "$root")"

  case "$executor_provider" in
    fake)
      specrelay::doctor::_ok "Executor provider: fake (deterministic, always available)"
      ;;
    claude)
      if command -v "$(specrelay::provider::claude::_bin)" >/dev/null 2>&1; then
        specrelay::doctor::_ok "Executor provider: claude ($(command -v "$(specrelay::provider::claude::_bin)"))"
      else
        specrelay::doctor::_fail "Executor provider: claude — '$(specrelay::provider::claude::_bin)' not found on PATH"
      fi
      ;;
    *)
      specrelay::doctor::_fail "Executor provider: unsupported provider '$executor_provider'"
      ;;
  esac

  case "$reviewer_provider" in
    manual)
      specrelay::doctor::_info "Reviewer provider: manual (a human decides accept/request-changes)"
      ;;
    fake)
      specrelay::doctor::_ok "Reviewer provider: fake (deterministic, always available)"
      ;;
    claude|claude-subagent)
      if command -v "$(specrelay::provider::claude::_bin)" >/dev/null 2>&1; then
        specrelay::doctor::_ok "Reviewer provider: $reviewer_provider ($(command -v "$(specrelay::provider::claude::_bin)"))"
      else
        specrelay::doctor::_fail "Reviewer provider: $reviewer_provider — '$(specrelay::provider::claude::_bin)' not found on PATH"
      fi
      ;;
    *)
      specrelay::doctor::_fail "Reviewer provider: unsupported provider '$reviewer_provider'"
      ;;
  esac

  # --- Context capability adapter available ---------------------------------
  local context_adapter context_required
  context_adapter="$(specrelay::workflow::context_adapter "$root")"
  context_required="$(specrelay::workflow::context_required "$root")"
  case "$context_adapter" in
    none)
      specrelay::doctor::_info "Context capability: none (no context adapter configured)"
      ;;
    contextplus)
      specrelay::doctor::_ok "Context capability: contextplus (adapter registered; required=$context_required)"
      ;;
    *)
      specrelay::doctor::_fail "Context capability: unknown adapter '$context_adapter'"
      ;;
  esac

  # --- Current engine mode --------------------------------------------------
  local shim_lib="$root/.ai/scripts/internal/lib/specrelay-shim.sh"
  local engine_mode=""
  if [ -f "$shim_lib" ]; then
    # shellcheck disable=SC1090
    . "$shim_lib"
    if engine_mode="$(specrelay_shim::engine "$root" 2>/dev/null)"; then
      if [ "$engine_mode" = "specrelay" ]; then
        specrelay::doctor::_ok "Current engine mode: specrelay (active)"
      else
        specrelay::doctor::_fail "Current engine mode: legacy (rollback mode — SpecRelay is not the active engine)"
      fi
    else
      specrelay::doctor::_fail "Current engine mode: could not be determined (ambiguous SPECRELAY_ENGINE or config value)"
    fi
  else
    specrelay::doctor::_fail "Current engine mode: compatibility shim helper not found ($shim_lib)"
  fi

  # --- Compatibility shims installed ----------------------------------------
  local expected_bin shim_missing=0 f
  expected_bin="$root/tools/specrelay/bin/specrelay"
  for f in start-spec-task.sh start-ai-task.sh approve-task.sh run-ai-loop.sh show-task.sh; do
    local shim_file="$root/.ai/scripts/$f"
    if [ ! -f "$shim_file" ]; then
      shim_missing=1
      continue
    fi
    if ! grep -q "specrelay-shim.sh" "$shim_file" 2>/dev/null; then
      shim_missing=1
    fi
  done
  if [ "$shim_missing" -eq 0 ]; then
    specrelay::doctor::_ok "Compatibility shims installed (targeting $expected_bin)"
  else
    specrelay::doctor::_fail "Compatibility shims: one or more of .ai/scripts/{start-spec-task,start-ai-task,approve-task,run-ai-loop,show-task}.sh is missing or not wired to specrelay-shim.sh"
  fi

  # --- No shim-loop (legacy/ copies must not re-invoke the shims) -----------
  local loop_found=0
  if [ -d "$root/.ai/scripts/legacy" ]; then
    if grep -rl "tools/specrelay/bin/specrelay" "$root/.ai/scripts/legacy" >/dev/null 2>&1; then
      loop_found=1
    fi
  fi
  if [ "$loop_found" -eq 0 ]; then
    specrelay::doctor::_ok "No shim-loop detected (legacy/ rollback copies do not call back into specrelay)"
  else
    specrelay::doctor::_fail "Shim-loop risk: a file under .ai/scripts/legacy/ references tools/specrelay/bin/specrelay"
  fi

  # --- Rollback engine exists ------------------------------------------------
  if [ -d "$root/.ai/scripts/legacy" ] && [ -f "$root/.ai/scripts/legacy/start-spec-task.sh" ]; then
    specrelay::doctor::_ok "Rollback engine exists (.ai/scripts/legacy/, SPECRELAY_ENGINE=legacy)"
  else
    specrelay::doctor::_fail "Rollback engine: .ai/scripts/legacy/ (frozen legacy copies) not found"
  fi

  # --- No obvious conflicting active engine lock ----------------------------
  local locks_dir="$runs_root/.specrelay-locks"
  local conflicting=0
  if [ -d "$locks_dir" ]; then
    local lock_dir
    for lock_dir in "$locks_dir"/*.lock; do
      [ -d "$lock_dir" ] || continue
      local owner_pid
      owner_pid="$(grep -m1 '^pid=' "$lock_dir/owner" 2>/dev/null | cut -d= -f2)"
      if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        conflicting=1
      fi
    done
  fi
  if [ "$conflicting" -eq 0 ]; then
    specrelay::doctor::_ok "No conflicting active engine lock"
  else
    specrelay::doctor::_fail "Conflicting active engine lock: a live SpecRelay lock holder was found under $locks_dir"
  fi

  echo
  if [ "$DOCTOR_FAILED" -ne 0 ]; then
    specrelay::out::err "doctor: one or more mandatory checks failed"
    return 1
  fi
  echo "specrelay doctor: all checks passed."
  return 0
}
