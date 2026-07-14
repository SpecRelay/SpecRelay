#!/usr/bin/env bash
# context/capability.sh — context-adapter CAPABILITY dispatch (spec 0015).
#
# This is the CENTRAL adapter dispatcher: generic workflow/CLI/doctor code
# calls ONLY the specrelay::context::* functions below and never contains
# adapter-specific branches (no `if adapter == contextplus` outside this
# file). All adapter-specific knowledge lives in the adapter files
# (context/none.sh, context/fake.sh, context/contextplus.sh); adding a new
# adapter means adding case arms here plus its adapter file — never touching
# workflow.sh, doctor.sh, or contexts.sh.
#
# Context adapters are deliberately independent from AI providers (spec 0015,
# "Provider Independence"): any adapter may be combined with any executor or
# reviewer provider, and nothing here consults providers/*.sh.
#
# Adapter contract (each adapter implements the functions its capabilities
# declare; the dispatcher never calls a function an adapter did not declare):
#
#   describe                       one-line human description
#   availability <root>            prints "available" (exit 0) or
#                                  "unavailable" + a reason line (exit 1);
#                                  NEVER performs a billable provider call
#   capability_level               none | preflight | prepared | indexed |
#                                  freshness  (honest — never inferred from
#                                  the adapter's name or branding)
#   capabilities                   key=value lines: preflight, prepare,
#                                  durable_artifact, role_isolation, network,
#                                  freshness_check (values yes|no)
#   supported_roles                space-separated roles (executor reviewer)
#   validate_config <root> <role>  adapter-specific config validation
#   preflight <role> <root> <task-id> <provider>
#                                  observable, non-secret progress; 0 when the
#                                  capability requirement is satisfied. NO
#                                  SILENT FALLBACK: non-zero means the caller
#                                  must apply the required/optional policy.
#   prepare <role> <root> <task-dir> <task-id> <provider>
#                                  (only when capabilities report prepare=yes)
#                                  on success prints a structured result as
#                                  key=value lines: status, artifact_kind,
#                                  artifact_reference, freshness, warnings;
#                                  non-zero on failure
#   reuse_decision <role> <root> <task-dir> <artifact_kind> <artifact_reference> <freshness>
#                                  resume policy for a previously prepared
#                                  artifact: prints exactly one of
#                                  reuse | reprepare — never silent
#   freshness_mandatory            exit 0 when a stale artifact must block a
#                                  REQUIRED role (adapter policy), 1 otherwise

# specrelay::context::adapters
# Built-in adapter names known to this SpecRelay version, one per line.
specrelay::context::adapters() {
  printf 'none\nfake\ncontextplus\n'
}

# specrelay::context::known <adapter>
specrelay::context::known() {
  case "$1" in
    none|fake|contextplus) return 0 ;;
    *) return 1 ;;
  esac
}

# --- dispatch ----------------------------------------------------------------

specrelay::context::describe() {
  case "$1" in
    none) specrelay::context::none::describe ;;
    fake) specrelay::context::fake::describe ;;
    contextplus) specrelay::context::contextplus::describe ;;
    *) return 1 ;;
  esac
}

# specrelay::context::availability <adapter> <root>
# Prints "available" (exit 0) or "unavailable" plus a reason line (exit 1).
# Read-only and never billable — safe for `contexts`, `doctor`, and preflight.
specrelay::context::availability() {
  case "$1" in
    none) specrelay::context::none::availability "$2" ;;
    fake) specrelay::context::fake::availability "$2" ;;
    contextplus) specrelay::context::contextplus::availability "$2" ;;
    *)
      printf 'unavailable\n'
      printf "no context adapter is defined for '%s'\n" "$1"
      return 1
      ;;
  esac
}

specrelay::context::capability_level() {
  case "$1" in
    none) specrelay::context::none::capability_level ;;
    fake) specrelay::context::fake::capability_level ;;
    contextplus) specrelay::context::contextplus::capability_level ;;
    *) return 1 ;;
  esac
}

specrelay::context::capabilities() {
  case "$1" in
    none) specrelay::context::none::capabilities ;;
    fake) specrelay::context::fake::capabilities ;;
    contextplus) specrelay::context::contextplus::capabilities ;;
    *) return 1 ;;
  esac
}

specrelay::context::supported_roles() {
  case "$1" in
    none) specrelay::context::none::supported_roles ;;
    fake) specrelay::context::fake::supported_roles ;;
    contextplus) specrelay::context::contextplus::supported_roles ;;
    *) return 1 ;;
  esac
}

# specrelay::context::capability <adapter> <key>
# One capability value (yes|no) from the adapter's capabilities report.
specrelay::context::capability() {
  local adapter="$1" key="$2" line
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#"$key"=}"; return 0 ;;
    esac
  done < <(specrelay::context::capabilities "$adapter")
  printf 'no\n'
}

specrelay::context::supports_prepare() {
  [ "$(specrelay::context::capability "$1" prepare)" = "yes" ]
}

# specrelay::context::role_supported <adapter> <role>
specrelay::context::role_supported() {
  local adapter="$1" role="$2" r
  for r in $(specrelay::context::supported_roles "$adapter"); do
    [ "$r" = "$role" ] && return 0
  done
  return 1
}

# specrelay::context::validate_config <adapter> <root> <role>
# Adapter-specific configuration validation (structural context-section
# validation is config.sh's job; this hook lets an adapter reject
# configuration keys it does not recognize where strict validation is
# possible).
specrelay::context::validate_config() {
  case "$1" in
    none) specrelay::context::none::validate_config "$2" "$3" ;;
    fake) specrelay::context::fake::validate_config "$2" "$3" ;;
    contextplus) specrelay::context::contextplus::validate_config "$2" "$3" ;;
    *)
      specrelay::out::err "no context-capability adapter is defined for '$1'"
      return 1
      ;;
  esac
}

# specrelay::context::preflight <adapter> <role> <root> <task-id> <provider>
# Kept signature-compatible with the pre-0015 dispatcher.
specrelay::context::preflight() {
  local adapter="$1" role="$2" root="$3" task_id="$4" provider="$5"
  case "$adapter" in
    none)
      specrelay::context::none::preflight "$role" "$root" "$task_id" "$provider"
      ;;
    fake)
      specrelay::context::fake::preflight "$role" "$root" "$task_id" "$provider"
      ;;
    contextplus)
      specrelay::context::contextplus::preflight "$role" "$root" "$task_id" "$provider"
      ;;
    *)
      specrelay::out::err "no context-capability adapter is defined for '$adapter'"
      return 1
      ;;
  esac
}

# specrelay::context::prepare <adapter> <role> <root> <task-dir> <task-id> <provider>
# Role-specific context preparation. Only meaningful for adapters whose
# capabilities report prepare=yes; an adapter without prepare support returns
# 0 with a status=none result (no artifact — nothing was prepared, and the
# caller must not pretend otherwise).
specrelay::context::prepare() {
  local adapter="$1"; shift
  case "$adapter" in
    none)
      printf 'status=none\nartifact_kind=none\nartifact_reference=\nfreshness=not-applicable\nwarnings=\n'
      ;;
    fake)
      specrelay::context::fake::prepare "$@"
      ;;
    contextplus)
      # Preflight-only capability level: proves availability/retrieval but has
      # no durable artifact to hand off (spec 0015, "Preflight Only").
      printf 'status=none\nartifact_kind=none\nartifact_reference=\nfreshness=not-applicable\nwarnings=\n'
      ;;
    *)
      specrelay::out::err "no context-capability adapter is defined for '$adapter'"
      return 1
      ;;
  esac
}

# specrelay::context::reuse_decision <adapter> <role> <root> <task-dir> <kind> <ref> <freshness>
# Deterministic resume policy for a previously prepared artifact: prints
# exactly one of reuse | reprepare (never silent — spec 0015, "Resume
# Behavior"). Adapters that prepare nothing durable always re-run their
# (cheap) no-op preparation.
specrelay::context::reuse_decision() {
  local adapter="$1"; shift
  case "$adapter" in
    none) printf 'reprepare\n' ;;
    fake) specrelay::context::fake::reuse_decision "$@" ;;
    contextplus) printf 'reprepare\n' ;;
    *) return 1 ;;
  esac
}

# specrelay::context::runtime_readiness <adapter> <root>
# Optional richer readiness inspection (spec 0018, "Readiness Inspection
# API"): key=value lines (status, installed, registered, connected,
# project_config, global_detected, selected_source, retrieval_ready, server,
# reason) for adapters that distinguish MORE than plain available/unavailable.
# Returns non-zero for adapters with no such inspection (none, fake) so
# generic callers (contexts.sh, doctor.sh) fall back to the plain capability-
# based rendering — this is the ONLY place that knows contextplus offers this,
# so contexts.sh/doctor.sh never grow a contextplus-specific branch.
specrelay::context::runtime_readiness() {
  case "$1" in
    contextplus) specrelay::context::contextplus::readiness "$2" ;;
    *) return 1 ;;
  esac
}

# specrelay::context::freshness_mandatory <adapter>
# True when the adapter's policy says a STALE artifact must block a REQUIRED
# role (spec 0015, "Context Freshness"). Never guessed: adapters without a
# freshness check answer no.
specrelay::context::freshness_mandatory() {
  case "$1" in
    none) return 1 ;;
    fake) specrelay::context::fake::freshness_mandatory ;;
    contextplus) return 1 ;;
    *) return 1 ;;
  esac
}
