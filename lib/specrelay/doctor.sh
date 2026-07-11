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

# Advisory warning: printed with a warning glyph but does NOT set
# DOCTOR_FAILED, so it never turns a passing `doctor` run non-zero (spec 0002
# acceptance criterion 3: "reports only intentional, documented warnings").
specrelay::doctor::_warn() {
  printf '\xe2\x9a\xa0 %s\n' "$1"
}

# specrelay::doctor::_hook_has_nonascii_shell_punct <hook-file>
# Returns 0 (true) if the given hook file contains non-ASCII shell punctuation
# that is DANGEROUS in a shell command (spec 0002): a Unicode en/em dash used
# as an option prefix (e.g. `git rev-parse ‑abbrev-ref`), or a smart quote
# adjacent to a shell command (sed/grep/git/awk) — the exact classes that
# produce the `fatal: ambiguous argument` / `grep: illegal byte sequence` /
# `sed: invalid command code` noise. Deliberately narrow (dangerous patterns
# only, not any non-ASCII) so legitimate prose — em/en dashes and quotes in a
# hook's comments — does not trigger a false positive (see the "Scope of the
# doctor check" human decision in spec 0002). LC_ALL=C makes grep operate on
# raw bytes and avoids the illegal-byte-sequence failure itself; matching is
# done with portable ERE (no `grep -P`, which BSD/macOS grep lacks).
specrelay::doctor::_hook_has_nonascii_shell_punct() {
  local hook="$1"
  [ -f "$hook" ] || return 1
  local endash emdash ldq rdq lsq rsq
  endash="$(printf '\xe2\x80\x93')"   # U+2013 en dash
  emdash="$(printf '\xe2\x80\x94')"   # U+2014 em dash
  ldq="$(printf '\xe2\x80\x9c')"      # U+201C left double quote
  rdq="$(printf '\xe2\x80\x9d')"      # U+201D right double quote
  lsq="$(printf '\xe2\x80\x98')"      # U+2018 left single quote
  rsq="$(printf '\xe2\x80\x99')"      # U+2019 right single quote
  # Dash-as-option-prefix: en/em dash immediately followed by a letter.
  if LC_ALL=C grep -Eq "(${endash}|${emdash})[A-Za-z]" "$hook" 2>/dev/null; then
    return 0
  fi
  # Smart quote within a short span of a shell command word.
  if LC_ALL=C grep -Eq "(sed|grep|git|awk).{0,40}(${ldq}|${rdq}|${lsq}|${rsq})" "$hook" 2>/dev/null; then
    return 0
  fi
  return 1
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

  # --- Active Git commit hooks free of non-ASCII shell punctuation (advisory) -
  # The commit noise investigated in spec 0002 (`fatal: ambiguous argument
  # '‑abbrev-ref'`, `grep: illegal byte sequence`, `sed: invalid command
  # code`) originates in an ACTIVE Git commit hook — often a developer-global
  # one injected via `core.hooksPath` — that uses non-ASCII shell punctuation
  # (an en/em dash where `--` is required, or smart quotes around a sed/grep
  # script). Such a hook fires on every commit in every repo, so we surface it
  # here as an actionable WARNING (never a hard failure): SpecRelay does not
  # silently rewrite the developer's own hook, but it does point at the file
  # and the ASCII fix so a human can repair it.
  if [ -n "$git_root" ]; then
    local hooks_dir="" candidate_hook h
    hooks_dir="$(git config --get core.hooksPath 2>/dev/null || true)"
    if [ -z "$hooks_dir" ]; then
      hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null || true)"
    fi
    local bad_hooks=""
    if [ -n "$hooks_dir" ] && [ -d "$hooks_dir" ]; then
      for h in prepare-commit-msg commit-msg pre-commit post-commit; do
        candidate_hook="$hooks_dir/$h"
        # Skip Git's shipped *.sample templates (never executed).
        case "$candidate_hook" in *.sample) continue ;; esac
        if specrelay::doctor::_hook_has_nonascii_shell_punct "$candidate_hook"; then
          bad_hooks="$bad_hooks $candidate_hook"
        fi
      done
    fi
    if [ -n "$bad_hooks" ]; then
      specrelay::doctor::_warn "Active Git commit hook contains non-ASCII shell punctuation (breaks commits with 'ambiguous argument' / 'illegal byte sequence' / 'invalid command code'):$bad_hooks"
      specrelay::doctor::_warn "  Fix: replace Unicode en/em dashes used as option prefixes with ASCII '--', and smart quotes (\xe2\x80\x9c \xe2\x80\x9d \xe2\x80\x98 \xe2\x80\x99) with ASCII \" or ' in the file(s) above."
    else
      specrelay::doctor::_ok "Active Git commit hooks: no non-ASCII shell punctuation detected"
    fi
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
    # A fresh project may not have run anything yet, and neither the runs root
    # NOR its immediate parent need exist — they are created lazily (mkdir -p)
    # on first task creation. What actually matters is that the nearest
    # EXISTING ancestor is a writable directory. Walk up to find it.
    local ancestor
    ancestor="$(dirname "$runs_root")"
    while [ -n "$ancestor" ] && [ "$ancestor" != "/" ] && [ ! -e "$ancestor" ]; do
      ancestor="$(dirname "$ancestor")"
    done
    if [ -d "$ancestor" ] && [ -w "$ancestor" ]; then
      specrelay::doctor::_ok "Task runtime root ($runs_root; not yet created, will be created under writable $ancestor)"
    else
      specrelay::doctor::_fail "Task runtime root: $runs_root does not exist and cannot be created (nearest existing ancestor $ancestor is not writable)"
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

  # --- SpecRelay installation (tool) root -----------------------------------
  # Report WHERE SpecRelay itself is installed, kept explicitly distinct from
  # the project root above (spec 0086, sections 7-8). Derived from the
  # executable's own location, never from the consumer project.
  local specrelay_home="$self_dir"
  specrelay::doctor::_info "SpecRelay home ($specrelay_home)"

  # --- Legacy-workflow / host-integration checks (conditional) --------------
  # The checks below (engine mode, compatibility shims, shim-loop, rollback
  # engine) are ONLY meaningful for a repository that hosts a pre-existing
  # `.ai/` workflow SpecRelay is being incubated inside of. A standalone or
  # freshly-initialized consumer project has no `.ai/scripts/`, and MUST NOT
  # be reported as failing for lacking one (spec 0086, section 48). They run
  # as mandatory checks only when a legacy `.ai/scripts/` tree is present.
  if [ ! -d "$root/.ai/scripts" ]; then
    specrelay::doctor::_info "Legacy workflow integration: not present (no .ai/scripts/) — standalone/consumer project"
    echo
    if [ "$DOCTOR_FAILED" -ne 0 ]; then
      specrelay::out::err "doctor: one or more mandatory checks failed"
      return 1
    fi
    echo "specrelay doctor: all checks passed."
    return 0
  fi

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
  # The shims resolve an INSTALLED, versioned executable via specrelay-shim.sh
  # (they do NOT target the in-repo tools/specrelay/ tree). Report the actual
  # resolved target when it is available, rather than a hardcoded path.
  local resolved_bin shim_missing=0 f
  resolved_bin=""
  if command -v specrelay_shim::bin >/dev/null 2>&1; then
    resolved_bin="$(specrelay_shim::bin "$root" 2>/dev/null || true)"
  fi
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
    if [ -n "$resolved_bin" ]; then
      specrelay::doctor::_ok "Compatibility shims installed (resolve the installed executable: $resolved_bin)"
    else
      specrelay::doctor::_ok "Compatibility shims installed (resolve an installed, version-pinned executable)"
    fi
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
