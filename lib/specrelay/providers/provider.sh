#!/usr/bin/env bash
# provider.sh — executor/reviewer provider adapter dispatch (spec sections
# 20-22). Core lifecycle code (workflow.sh) calls ONLY the functions below;
# it never knows which concrete CLI/adapter actually ran. Adding a new
# provider means adding a new case arm plus its adapter file — never
# changing workflow.sh.
#
# Adapter contract (both roles):
#   executor_run <project-root> <task-dir> <round> <prompt-file> [label]
#     Must write 03-executor-log.md / 07-tests.txt / 08-executor-summary.md
#     (on success) plus its own stdout/stderr capture files, and return the
#     provider's real exit code (0 = success). The optional <label> (e.g.
#     "executor:claude") is supplied by the dispatch functions below and is
#     the role/provider scope used to prefix live terminal output (spec 0003);
#     adapters pass it straight through to specrelay::provider::run_streamed.
#   reviewer_run <project-root> <task-dir> <round> <prompt-file> [label]
#     Must write 09-consultant-review.md plus EITHER
#     10-business-summary.md (accept) OR 11-next-executor-prompt.md
#     (request changes), plus its own stdout/stderr capture files. On
#     success (exit 0), the LAST line of its OWN stdout (captured by the
#     caller via command substitution, not the redirected capture file) MUST
#     be exactly "ACCEPT" or "REQUEST_CHANGES" (spec section 34: an explicit
#     machine-readable decision, never inferred from prose). A non-zero
#     exit means reviewer failure: no decision, no state change.

# --- live output streaming (spec 0003) --------------------------------------
#
# Provider runs used to be silent at the terminal: an adapter redirected the
# real CLI's stdout/stderr straight into its numbered capture files
# (12/13/15/16), so the operator saw only the phase banners and then nothing
# for however long the provider took. `run_streamed` restores LIVE visibility
# WITHOUT weakening evidence: it streams a role/provider-prefixed copy of each
# line to the operator terminal (fd 2) while STILL writing the raw, unprefixed
# stream to the same capture file the adapter would have written directly.
#
# It lives here — in the provider abstraction layer, not in one adapter — so
# every provider (fake, claude, claude-subagent, and any future adapter) gets
# the identical behavior for free; nothing is hardcoded for a single provider.
#
# Design notes / risks explicitly addressed (spec 0003, "Risks"):
#   * Exit codes: the wrapped command runs with its OWN stdout/stderr
#     redirected to FIFOs (never through a pipe), so `$?` is the command's real
#     exit code — there is NO tee/pipeline in the exit path that could let a
#     failing provider look successful.
#   * Buffering/flakiness: the reader is a line-buffered `read` loop, and
#     run_streamed WAITS for both readers before returning, so the capture
#     files are guaranteed fully flushed before a caller reads them (e.g. the
#     reviewer decision grep). No process-substitution flush race.
#   * Reviewer decision channel: live copies go to fd 2 (stderr). The reviewer
#     adapter's OWN stdout (fd 1) — read by the lifecycle via command
#     substitution to obtain the ACCEPT/REQUEST_CHANGES decision — is never
#     touched by streaming, so the machine-readable decision stays clean.
#   * No TTY required: fd 2 need not be a terminal, and the capture files are
#     written regardless, so redirected/CI runs keep complete evidence.
#   * Plain text only: the prefix is `[<label>] `; no color/escape codes.

# specrelay::provider::_stream_reader <label> <capture-file>
# Reads stdin line by line, appending the RAW line to <capture-file> and
# printing a `[<label>] `-prefixed copy to fd 2. Faithfully preserves a final
# line that has no trailing newline.
specrelay::provider::_stream_reader() {
  local label="$1" capture="$2" line
  : > "$capture"
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$capture"
    printf '[%s] %s\n' "$label" "$line" >&2
  done
  if [ -n "${line:-}" ]; then
    printf '%s' "$line" >> "$capture"
    printf '[%s] %s\n' "$label" "$line" >&2
  fi
}

# specrelay::provider::run_streamed <label> <stdout-file> <stderr-file> <run-dir> [--] cmd [args...]
# Runs `cmd` with its working directory set to <run-dir>, streaming its stdout
# AND stderr live to fd 2 (each line prefixed with "[<label>] ") while
# capturing the raw streams to <stdout-file> / <stderr-file>. Returns the
# command's real exit code. All live output is flushed to the capture files
# before returning.
specrelay::provider::run_streamed() {
  local label="$1" out_file="$2" err_file="$3" run_dir="$4"
  shift 4
  [ "${1:-}" = "--" ] && shift

  local dir out_fifo err_fifo out_pid err_pid rc
  dir="$(mktemp -d "${TMPDIR:-/tmp}/specrelay-stream.XXXXXX")"
  out_fifo="$dir/out"
  err_fifo="$dir/err"
  mkfifo "$out_fifo" "$err_fifo"

  # Readers first (they block opening the FIFO for read until the command
  # below opens it for write). Their own stdout is pointed at fd 2 so they do
  # NOT hold open a command-substitution pipe on fd 1 in the reviewer path.
  specrelay::provider::_stream_reader "$label" "$out_file" < "$out_fifo" >&2 &
  out_pid=$!
  specrelay::provider::_stream_reader "$label" "$err_file" < "$err_fifo" >&2 &
  err_pid=$!

  ( cd "$run_dir" && "$@" ) > "$out_fifo" 2> "$err_fifo"
  rc=$?

  wait "$out_pid" 2>/dev/null || true
  wait "$err_pid" 2>/dev/null || true
  rm -rf "$dir"
  return "$rc"
}

specrelay::provider::executor_run() {
  local provider="$1" root="$2" task_dir="$3" round="$4" prompt_file="$5"
  local label="executor:$provider"
  case "$provider" in
    fake)
      specrelay::provider::fake::executor_run "$root" "$task_dir" "$round" "$prompt_file" "$label"
      ;;
    claude)
      specrelay::provider::claude::executor_run "$root" "$task_dir" "$round" "$prompt_file" "$label"
      ;;
    *)
      specrelay::out::err "unsupported executor provider: $provider"
      return 1
      ;;
  esac
}

specrelay::provider::reviewer_run() {
  local provider="$1" root="$2" task_dir="$3" round="$4" prompt_file="$5"
  local label="reviewer:$provider"
  case "$provider" in
    fake)
      specrelay::provider::fake::reviewer_run "$root" "$task_dir" "$round" "$prompt_file" "$label"
      ;;
    claude|claude-subagent)
      specrelay::provider::claude::reviewer_run "$root" "$task_dir" "$round" "$prompt_file" "$label"
      ;;
    *)
      specrelay::out::err "unsupported reviewer provider: $provider"
      return 1
      ;;
  esac
}
