#!/usr/bin/env bash
# provider.sh — executor/reviewer provider adapter dispatch (spec sections
# 20-22). Core lifecycle code (workflow.sh) calls ONLY the functions below;
# it never knows which concrete CLI/adapter actually ran. Adding a new
# provider means adding a new case arm plus its adapter file — never
# changing workflow.sh.
#
# Adapter contract (both roles):
#   executor_run <project-root> <task-dir> <round> <prompt-file>
#     Must write 03-executor-log.md / 07-tests.txt / 08-executor-summary.md
#     (on success) plus its own stdout/stderr capture files, and return the
#     provider's real exit code (0 = success).
#   reviewer_run <project-root> <task-dir> <round> <prompt-file>
#     Must write 09-consultant-review.md plus EITHER
#     10-business-summary.md (accept) OR 11-next-executor-prompt.md
#     (request changes), plus its own stdout/stderr capture files. On
#     success (exit 0), the LAST line of its OWN stdout (captured by the
#     caller via command substitution, not the redirected capture file) MUST
#     be exactly "ACCEPT" or "REQUEST_CHANGES" (spec section 34: an explicit
#     machine-readable decision, never inferred from prose). A non-zero
#     exit means reviewer failure: no decision, no state change.

specrelay::provider::executor_run() {
  local provider="$1" root="$2" task_dir="$3" round="$4" prompt_file="$5"
  case "$provider" in
    fake)
      specrelay::provider::fake::executor_run "$root" "$task_dir" "$round" "$prompt_file"
      ;;
    claude)
      specrelay::provider::claude::executor_run "$root" "$task_dir" "$round" "$prompt_file"
      ;;
    *)
      specrelay::out::err "unsupported executor provider: $provider"
      return 1
      ;;
  esac
}

specrelay::provider::reviewer_run() {
  local provider="$1" root="$2" task_dir="$3" round="$4" prompt_file="$5"
  case "$provider" in
    fake)
      specrelay::provider::fake::reviewer_run "$root" "$task_dir" "$round" "$prompt_file"
      ;;
    claude|claude-subagent)
      specrelay::provider::claude::reviewer_run "$root" "$task_dir" "$round" "$prompt_file"
      ;;
    *)
      specrelay::out::err "unsupported reviewer provider: $provider"
      return 1
      ;;
  esac
}
