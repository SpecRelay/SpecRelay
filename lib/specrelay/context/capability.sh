#!/usr/bin/env bash
# context/capability.sh — context-capability adapter dispatch (spec section
# 24). Core lifecycle code calls ONLY specrelay::context::preflight; it never
# hardcodes "Context Plus" or any other branded provider. A project that
# configures `context.required: false` or a different adapter name changes
# behavior purely through .specrelay/config.yml, with no engine change.
#
# Adapter contract: preflight <role> <project-root> <task-id> <provider>
#   Prints observable, non-secret progress (checking -> available ->
#   initialized -> retrieval) and returns 0 if the capability requirement is
#   satisfied (or not applicable), non-zero otherwise. NO SILENT FALLBACK:
#   a non-zero return means the caller (workflow.sh) must not proceed to
#   launch that role's provider for substantive work.

specrelay::context::preflight() {
  local adapter="$1" role="$2" root="$3" task_id="$4" provider="$5"
  case "$adapter" in
    none)
      specrelay::context::none::preflight "$role"
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
