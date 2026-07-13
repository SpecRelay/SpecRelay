#!/usr/bin/env bash
# context/fake.sh — deterministic context adapter for tests (spec 0015, "Fake
# Context Adapter"). Never touches the network and never invokes any provider;
# every behavior is driven by environment knobs, so tests can simulate the
# full capability matrix (available/unavailable, preflight and preparation
# success/failure, fresh/stale artifacts, reuse policy, required blocking,
# optional degradation) without any remote service.
#
# Env knobs (all optional; the default is a fully working adapter):
#   SPECRELAY_FAKE_CONTEXT_AVAILABLE            1 (default) | 0 = unavailable
#   SPECRELAY_FAKE_CONTEXT_PREFLIGHT            ok (default) | fail
#   SPECRELAY_FAKE_CONTEXT_PREPARE              ok (default) | fail
#   SPECRELAY_FAKE_CONTEXT_ARTIFACT             ok (default) | missing = report a
#                                               prepared artifact reference whose
#                                               file does NOT exist (simulates a
#                                               missing/unreadable artifact)
#   SPECRELAY_FAKE_CONTEXT_FRESHNESS            fresh (default) | stale | unknown
#   SPECRELAY_FAKE_CONTEXT_REUSABLE             1 (default) | 0 = never reuse
#   SPECRELAY_FAKE_CONTEXT_FRESHNESS_MANDATORY  0 (default) | 1 = stale blocks a
#                                               required role
#
# Every knob has a per-role override so a single run can give the executor and
# reviewer DIFFERENT behavior (isolation tests):
#   SPECRELAY_FAKE_CONTEXT_EXECUTOR_<KNOB> / SPECRELAY_FAKE_CONTEXT_REVIEWER_<KNOB>
# e.g. SPECRELAY_FAKE_CONTEXT_REVIEWER_PREPARE=fail fails only the reviewer's
# preparation. The role-specific value wins over the global one.

# specrelay::context::fake::_knob <role> <KNOB> <default>
# Role-specific env override first, then the global knob, then the default.
specrelay::context::fake::_knob() {
  local role="$1" knob="$2" default="$3" role_var global_var role_uc
  role_uc="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  role_var="SPECRELAY_FAKE_CONTEXT_${role_uc}_${knob}"
  global_var="SPECRELAY_FAKE_CONTEXT_${knob}"
  if [ -n "${!role_var:-}" ]; then
    printf '%s\n' "${!role_var}"
  elif [ -n "${!global_var:-}" ]; then
    printf '%s\n' "${!global_var}"
  else
    printf '%s\n' "$default"
  fi
}

specrelay::context::fake::describe() {
  printf 'Deterministic fake context adapter for tests (env-driven, no network).\n'
}

specrelay::context::fake::availability() {
  if [ "${SPECRELAY_FAKE_CONTEXT_AVAILABLE:-1}" = "0" ]; then
    printf 'unavailable\n'
    printf 'simulated unavailability (SPECRELAY_FAKE_CONTEXT_AVAILABLE=0)\n'
    return 1
  fi
  printf 'available\n'
}

specrelay::context::fake::capability_level() {
  printf 'prepared\n'
}

specrelay::context::fake::capabilities() {
  printf 'preflight=yes\n'
  printf 'prepare=yes\n'
  printf 'durable_artifact=yes\n'
  printf 'role_isolation=yes\n'
  printf 'network=no\n'
  printf 'freshness_check=yes\n'
}

specrelay::context::fake::supported_roles() {
  printf 'executor reviewer\n'
}

specrelay::context::fake::validate_config() {
  return 0
}

specrelay::context::fake::preflight() {
  local role="$1"
  if [ "$(specrelay::context::fake::_knob "$role" AVAILABLE 1)" = "0" ]; then
    specrelay::out::err "[$role] fake-context: simulated unavailability (SPECRELAY_FAKE_CONTEXT_AVAILABLE=0)"
    return 1
  fi
  if [ "$(specrelay::context::fake::_knob "$role" PREFLIGHT ok)" = "fail" ]; then
    specrelay::out::err "[$role] fake-context: simulated preflight failure (SPECRELAY_FAKE_CONTEXT_PREFLIGHT=fail)"
    return 1
  fi
  echo "[$role] fake-context: preflight ok"
  return 0
}

# specrelay::context::fake::prepare <role> <root> <task-dir> <task-id> <provider>
# Writes a ROLE-SPECIFIC durable artifact (a small deterministic file in the
# task's own runtime directory — metadata only, never credentials) and prints
# the structured preparation result. The artifact content names the role so a
# test can prove executor/reviewer isolation by inspecting what each provider
# invocation actually received.
specrelay::context::fake::prepare() {
  local role="$1" root="$2" task_dir="$3" task_id="$4" provider="$5"
  if [ "$(specrelay::context::fake::_knob "$role" PREPARE ok)" = "fail" ]; then
    specrelay::out::err "[$role] fake-context: simulated preparation failure (SPECRELAY_FAKE_CONTEXT_PREPARE=fail)"
    return 1
  fi

  local artifact_abs artifact_rel freshness
  artifact_abs="$task_dir/fake-context-$role.txt"
  artifact_rel="${artifact_abs#"$root"/}"
  freshness="$(specrelay::context::fake::_knob "$role" FRESHNESS fresh)"
  case "$freshness" in
    fresh|stale|unknown) : ;;
    *) freshness="unknown" ;;
  esac

  if [ "$(specrelay::context::fake::_knob "$role" ARTIFACT ok)" = "missing" ]; then
    # Simulated missing artifact: report a prepared reference whose file does
    # not exist, so the caller's artifact-readability check has something real
    # to catch.
    rm -f "$artifact_abs"
  else
    {
      printf 'fake context artifact\n'
      printf 'role=%s\n' "$role"
      printf 'task=%s\n' "$task_id"
      printf 'provider=%s\n' "$provider"
    } > "$artifact_abs"
  fi

  printf 'status=prepared\n'
  printf 'artifact_kind=file\n'
  printf 'artifact_reference=%s\n' "$artifact_rel"
  printf 'freshness=%s\n' "$freshness"
  printf 'warnings=\n'
  return 0
}

# specrelay::context::fake::reuse_decision <role> <root> <task-dir> <kind> <ref> <freshness>
# Deterministic, documented resume policy (spec 0015, "Resume Behavior"):
#   reprepare when the artifact reference is missing/invalid, when the adapter
#             is told not to reuse (SPECRELAY_FAKE_CONTEXT_REUSABLE=0), or when
#             the CURRENT freshness report is stale;
#   reuse     otherwise.
specrelay::context::fake::reuse_decision() {
  local role="$1" root="$2" task_dir="$3" kind="$4" ref="$5" freshness="$6"
  if [ "$(specrelay::context::fake::_knob "$role" REUSABLE 1)" = "0" ]; then
    printf 'reprepare\n'
    return 0
  fi
  if [ -z "$ref" ] || [ "$kind" != "file" ] || [ ! -f "$root/$ref" ]; then
    printf 'reprepare\n'
    return 0
  fi
  if [ "$(specrelay::context::fake::_knob "$role" FRESHNESS fresh)" = "stale" ]; then
    printf 'reprepare\n'
    return 0
  fi
  printf 'reuse\n'
}

specrelay::context::fake::freshness_mandatory() {
  [ "${SPECRELAY_FAKE_CONTEXT_FRESHNESS_MANDATORY:-0}" = "1" ]
}
