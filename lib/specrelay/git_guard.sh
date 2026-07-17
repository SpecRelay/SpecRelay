#!/usr/bin/env bash
# git_guard.sh — dirty-working-tree baseline and task-owned-change tracking
# (spec sections 30-33), so a task's own still-uncommitted round-1 diff can be
# distinguished from a genuinely unrelated change and the automated requeue
# retry path never gets stuck (docs/current-workflow-contract.md, section 9).
#
# Model:
#   - BASELINE (.git-baseline.txt, captured once at task creation, BEFORE any
#     task file is written): the working-tree paths that were already dirty
#     before this task existed. Never re-captured; it is a fact about the
#     moment the task was created.
#   - OWNED SNAPSHOT (.git-owned-snapshot.txt, captured after every
#     successful evidence capture): the working-tree paths that are the
#     task's OWN accumulated, legitimate changes so far (round 1 diff, round
#     2 diff, ...). This is what makes iteration 2 possible: it is the
#     working tree the PREVIOUS iteration intentionally left behind, so it
#     must never be misclassified as "unrelated."
#   - Before claiming any iteration, the guard computes the current
#     tree's changed paths and requires them to be a subset of
#     BASELINE ∪ OWNED SNAPSHOT. Anything outside that set is an unexpected
#     external change (Case 3) and blocks the claim, listing exact paths.
#   - If this is the FIRST iteration (no owned snapshot yet) and BASELINE
#     itself is non-empty (Case 2: pre-existing unrelated dirt), the claim is
#     also blocked UNLESS the task was explicitly created with
#     allow_pre_existing_dirty=true — an explicit, evidence-recorded policy
#     choice, never a silent default.
#   - Two path prefixes are ALWAYS treated as "related" (excluded from every
#     snapshot) (docs/current-workflow-contract.md, section 9):
#       1. the configured task-runs root (e.g. .specrelay-runs/tasks/) — the
#          engine's own bookkeeping;
#       2. this task's recorded spec source's containing directory (e.g.
#          docs/sdd/<task-id>/) — an uncommitted spec file is the whole
#          reason the task exists, not an unrelated change. In this
#          repository the runs root is also gitignored, but neither
#          exclusion relies on that.

# specrelay::git_guard::_paths <project-root> [task-dir]
# Prints the sorted list of paths currently reported by `git status
# --porcelain`, one per line (for a rename "old -> new" both sides are
# listed, so a guard comparison is conservative rather than clever),
# EXCLUDING the task-runs root and (if a task-dir with a recorded
# spec_source is given) that spec's containing directory.
specrelay::git_guard::_paths() {
  local root="$1" task_dir="${2:-}" runs_root runs_root_rel extra_rel=""
  runs_root="$(specrelay::task::runs_root "$root")"
  runs_root_rel="${runs_root#"$root"/}"

  if [ -n "$task_dir" ]; then
    local state_file spec_source
    state_file="$(specrelay::state::path "$task_dir")"
    if [ -f "$state_file" ]; then
      spec_source="$(specrelay::state::get "$state_file" "spec_source" 2>/dev/null)"
      [ -n "$spec_source" ] && extra_rel="$(dirname "$spec_source")"
    fi
  fi

  (cd "$root" && git status --porcelain --untracked-files=all) | sed -E 's/^.. //' | sed -E 's/^"(.*)"$/\1/' \
    | awk '{ n=split($0, parts, " -> "); for (i=1;i<=n;i++) print parts[i] }' \
    | awk -v prefix="$runs_root_rel/" -v extra="${extra_rel:+$extra_rel/}" \
        '$0 != "" && index($0, prefix) != 1 && (extra == "" || index($0, extra) != 1)' \
    | sort -u
}

specrelay::git_guard::_baseline_file() {
  printf '%s/.git-baseline.txt\n' "$1"
}

specrelay::git_guard::_owned_file() {
  printf '%s/.git-owned-snapshot.txt\n' "$1"
}

# specrelay::git_guard::snapshot_now <project-root> [spec-rel-path]
# Prints the current guard-relevant path snapshot (for a caller that needs to
# capture it BEFORE the task's own state.json/directory exist — see
# transitions::create, which calls this before `mkdir` and writes the result
# with write_baseline after). Pass the about-to-be-recorded spec_source
# directly since state.json cannot be read yet at this point.
specrelay::git_guard::snapshot_now() {
  local root="$1" spec_rel="${2:-}" runs_root runs_root_rel extra_rel=""
  runs_root="$(specrelay::task::runs_root "$root")"
  runs_root_rel="${runs_root#"$root"/}"
  [ -n "$spec_rel" ] && extra_rel="$(dirname "$spec_rel")"

  (cd "$root" && git status --porcelain --untracked-files=all) | sed -E 's/^.. //' | sed -E 's/^"(.*)"$/\1/' \
    | awk '{ n=split($0, parts, " -> "); for (i=1;i<=n;i++) print parts[i] }' \
    | awk -v prefix="$runs_root_rel/" -v extra="${extra_rel:+$extra_rel/}" \
        '$0 != "" && index($0, prefix) != 1 && (extra == "" || index($0, extra) != 1)' \
    | sort -u
}

# specrelay::git_guard::write_baseline <task-dir> <snapshot-text>
# Writes a PRE-CAPTURED snapshot (see snapshot_now above) as the baseline. A
# no-op if a baseline already exists (the baseline is a fact about
# task-creation time, never refreshed).
specrelay::git_guard::write_baseline() {
  local task_dir="$1" snapshot="$2" file
  file="$(specrelay::git_guard::_baseline_file "$task_dir")"
  [ -f "$file" ] && return 0
  printf '%s\n' "$snapshot" | sed '/^$/d' > "$file"
}

# specrelay::git_guard::capture_baseline <project-root> <task-dir>
# Convenience form for a caller that does NOT need the spec-directory
# exclusion resolved ahead of time (e.g. a test capturing a baseline for a
# task directory created moments before via some other path). Prefer
# snapshot_now + write_baseline around task creation itself.
specrelay::git_guard::capture_baseline() {
  local root="$1" task_dir="$2" file
  file="$(specrelay::git_guard::_baseline_file "$task_dir")"
  [ -f "$file" ] && return 0
  specrelay::git_guard::_paths "$root" "$task_dir" > "$file"
}

# specrelay::git_guard::snapshot_owned <project-root> <task-dir>
# Records the current working-tree paths as "owned by this task" — call
# this AFTER a successful evidence capture (i.e. after an executor iteration
# that will be submitted for review), so the NEXT claim's guard check allows
# this iteration's accumulated diff to persist.
specrelay::git_guard::snapshot_owned() {
  local root="$1" task_dir="$2" file
  file="$(specrelay::git_guard::_owned_file "$task_dir")"
  specrelay::git_guard::_paths "$root" "$task_dir" > "$file"
}

# specrelay::git_guard::check <project-root> <task-dir>
# Prints nothing and returns 0 if the working tree is safe to claim against.
# Returns 1 with a clear listing on stderr otherwise.
specrelay::git_guard::check() {
  local root="$1" task_dir="$2"
  local baseline_file owned_file current_file allow_dirty
  baseline_file="$(specrelay::git_guard::_baseline_file "$task_dir")"
  owned_file="$(specrelay::git_guard::_owned_file "$task_dir")"

  # Defensive: a baseline should already exist (written at task creation
  # time); capture one now if it is somehow missing rather than fail.
  [ -f "$baseline_file" ] || specrelay::git_guard::capture_baseline "$root" "$task_dir"

  current_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-guard.XXXXXX")"
  specrelay::git_guard::_paths "$root" "$task_dir" > "$current_file"

  local allowed_file
  allowed_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-guard-allowed.XXXXXX")"
  if [ -f "$owned_file" ]; then
    cat "$baseline_file" "$owned_file" | sort -u > "$allowed_file"
  else
    sort -u "$baseline_file" > "$allowed_file"
  fi

  local unexpected
  unexpected="$(comm -23 "$current_file" "$allowed_file")"

  if [ -n "$unexpected" ]; then
    specrelay::out::err "refusing: unexpected working-tree changes outside this task's known baseline/owned paths:"
    printf '%s\n' "$unexpected" | sed 's/^/  - /' >&2
    rm -f "$current_file" "$allowed_file"
    return 1
  fi
  rm -f "$current_file" "$allowed_file"

  if [ ! -f "$owned_file" ]; then
    local state_file
    state_file="$(specrelay::state::path "$task_dir")"
    allow_dirty="$(specrelay::state::get "$state_file" "allow_pre_existing_dirty" 2>/dev/null)"
    if [ -s "$baseline_file" ] && [ "$allow_dirty" != "True" ] && [ "$allow_dirty" != "true" ]; then
      specrelay::out::err "refusing: the working tree already had unrelated pre-existing changes when this task was created:"
      sed 's/^/  - /' "$baseline_file" >&2
      specrelay::out::err "recreate the task with allow_pre_existing_dirty=true if this is intentional (spec section 30-32 policy)"
      return 1
    fi
  fi

  return 0
}

# --- round-change ledger + pre-provider snapshot (spec 0029, section 23) ---
#
# The pre-0029 model above records ownership only AFTER a full evidence
# capture succeeds. Spec 0029 fixes the recovery gap this creates (section
# 5.2/23): a round's legitimate diff must be provably task-owned BEFORE the
# completion gate runs, and even before evidence capture if the round crashes
# earlier still. These APIs are ADDITIVE — snapshot_owned above keeps its
# existing whole-tree semantics as a compatibility wrapper for existing
# callers/tests; the ledger is the new authoritative source the workflow
# actually derives the owned snapshot from (git_guard::derive_owned_from_ledger).

specrelay::git_guard::_pre_provider_file() {
  printf '%s/.git-pre-provider-snapshot.json\n' "$1"
}

specrelay::git_guard::_ledger_file() {
  printf '%s/32-round-change-ledger.jsonl\n' "$1"
}

# specrelay::git_guard::_sha256_file <path>
# Portable content digest (python3 hashlib — no platform-specific sha256sum/
# shasum dependency). Prints "deleted" for a path that does not currently
# exist (a guard-relevant path can be a deletion).
specrelay::git_guard::_sha256_file() {
  local root="$1" rel="$2"
  if [ ! -e "$root/$rel" ]; then
    printf 'deleted\n'
    return 0
  fi
  PATHARG="$root/$rel" python3 -c '
import hashlib, os
h = hashlib.sha256()
try:
    with open(os.environ["PATHARG"], "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    print(h.hexdigest())
except Exception:
    print("unreadable")
'
}

# specrelay::git_guard::capture_pre_provider_snapshot <project-root> <task-dir>
# Writes the durable "before" fact a crash-before-evidence-capture recovery
# diffs against (spec 0029, section 23.1): HEAD commit, a digest of the
# current index (staged changes), and a per-path content digest for every
# currently guard-relevant path (already-dirty tracked changes AND untracked
# files). Always overwrites — this is captured fresh before EVERY provider
# launch (unlike the once-only task-creation baseline).
specrelay::git_guard::capture_pre_provider_snapshot() {
  local root="$1" task_dir="$2" out_file head index_digest
  out_file="$(specrelay::git_guard::_pre_provider_file "$task_dir")"
  head="$(cd "$root" && git rev-parse HEAD 2>/dev/null || echo '')"
  index_digest="$(cd "$root" && git diff --cached 2>/dev/null | ISADIGEST=1 python3 -c '
import hashlib, sys
h = hashlib.sha256()
h.update(sys.stdin.buffer.read())
print(h.hexdigest())
' 2>/dev/null || echo '')"

  local -a paths=()
  while IFS= read -r p; do
    [ -n "$p" ] && paths+=("$p")
  done < <(specrelay::git_guard::_paths "$root" "$task_dir")

  local -a untracked=()
  while IFS= read -r u; do
    [ -n "$u" ] && untracked+=("$u")
  done < <(cd "$root" && git ls-files --others --exclude-standard 2>/dev/null)

  {
    printf '{"schema_version": 1, "captured_at": "%s", "head_commit": "%s", "index_digest": "%s", "paths": {' \
      "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$head" "$index_digest"
    local first=1 p digest is_untracked u
    for p in "${paths[@]:-}"; do
      [ -n "$p" ] || continue
      digest="$(specrelay::git_guard::_sha256_file "$root" "$p")"
      is_untracked=false
      for u in "${untracked[@]:-}"; do
        [ "$u" = "$p" ] && { is_untracked=true; break; }
      done
      [ "$first" = "1" ] || printf ','
      first=0
      PJSON="$p" python3 -c 'import json,os; print(json.dumps(os.environ["PJSON"]), end="")'
      printf ': {"digest": '
      DJSON="$digest" python3 -c 'import json,os; print(json.dumps(os.environ["DJSON"]), end="")'
      printf ', "untracked": %s}' "$is_untracked"
    done
    printf '}}\n'
  } > "$out_file"
}

# specrelay::git_guard::record_round_change <project-root> <task-dir> <invocation-id> [source]
# Appends one audited, append-only record to 32-round-change-ledger.jsonl
# (spec 0029, section 23.2): the paths PROVEN changed by this round (the
# current guard-relevant snapshot) and the diff digest, so ownership is
# derivable BEFORE the completion gate runs — a gate-failed or interrupted
# round's legitimate diff is already task-owned. Idempotent in effect (each
# call is its own ledger line; derive_owned_from_ledger unions all lines).
specrelay::git_guard::record_round_change() {
  local root="$1" task_dir="$2" invocation_id="$3" source="${4:-evidence-capture}" ledger_file patch_file diff_digest
  ledger_file="$(specrelay::git_guard::_ledger_file "$task_dir")"
  patch_file="$task_dir/06-git-diff.patch"
  diff_digest=""
  [ -f "$patch_file" ] && diff_digest="$(specrelay::git_guard::_sha256_file "$root" "${patch_file#"$root"/}" 2>/dev/null || true)"
  [ -n "$diff_digest" ] || diff_digest="$(python3 -c '
import hashlib, sys
h = hashlib.sha256()
try:
    with open(sys.argv[1], "rb") as fh:
        h.update(fh.read())
    print(h.hexdigest())
except Exception:
    print("")
' "$patch_file" 2>/dev/null)"

  local -a paths=()
  while IFS= read -r p; do
    [ -n "$p" ] && paths+=("$p")
  done < <(specrelay::git_guard::_paths "$root" "$task_dir")

  PATHS_JSON="$(printf '%s\n' "${paths[@]:-}" | python3 -c '
import json, sys
lines = [l.rstrip("\n") for l in sys.stdin if l.strip()]
print(json.dumps(lines))
')" \
  INVOCATION_ID="$invocation_id" SOURCE="$source" DIFF_DIGEST="$diff_digest" python3 -c '
import json, os
rec = {
    "invocation_id": os.environ["INVOCATION_ID"],
    "timestamp": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "paths": json.loads(os.environ["PATHS_JSON"]),
    "diff_digest": os.environ.get("DIFF_DIGEST") or "",
    "source": os.environ["SOURCE"],
}
print(json.dumps(rec))
' >> "$ledger_file"
}

# specrelay::git_guard::derive_owned_from_ledger <project-root> <task-dir>
# Recomputes .git-owned-snapshot.txt as the baseline-excluded union of every
# ledger entry's paths (spec 0029, section 23.2 — "the ledger is
# authoritative for the owned snapshot"). Safe to call repeatedly; a no-op
# (empty owned set) when the ledger does not exist yet.
specrelay::git_guard::derive_owned_from_ledger() {
  local root="$1" task_dir="$2" ledger_file owned_file baseline_file
  ledger_file="$(specrelay::git_guard::_ledger_file "$task_dir")"
  owned_file="$(specrelay::git_guard::_owned_file "$task_dir")"
  baseline_file="$(specrelay::git_guard::_baseline_file "$task_dir")"

  if [ ! -f "$ledger_file" ]; then
    : > "$owned_file"
    return 0
  fi

  LEDGER="$ledger_file" BASELINE="$baseline_file" python3 -c '
import json, os
owned = set()
with open(os.environ["LEDGER"], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        owned.update(rec.get("paths") or [])
baseline = set()
if os.path.isfile(os.environ["BASELINE"]):
    with open(os.environ["BASELINE"], encoding="utf-8") as fh:
        baseline = {l.strip() for l in fh if l.strip()}
for p in sorted(owned - baseline):
    print(p)
' > "$owned_file"
}

# specrelay::git_guard::reconstruct_round_change_from_snapshot <project-root> <task-dir> <invocation-id>
# Recovery for a crash BEFORE executor_evidence_capture ever ran (spec 0029,
# section 23.4): diffs the CURRENT tree against the pre-provider snapshot
# (section 23.1) to reconstruct the round's proven-owned set without any
# 04/05/06 evidence having been written. Prints the reconstructed owned paths
# (one per line) and appends a synthetic ledger entry
# (source: "reconstructed-from-pre-provider-snapshot") on success (exit 0).
# Refuses (prints nothing to stdout, an "ambiguous: <reason>" line to stderr,
# exit 1) when HEAD moved or the index changed unexpectedly since the
# snapshot was taken — the engine never guesses ownership across a crash
# window it cannot account for; an explicit human decision is required
# instead (section 23.3).
specrelay::git_guard::reconstruct_round_change_from_snapshot() {
  local root="$1" task_dir="$2" invocation_id="$3" snapshot_file
  snapshot_file="$(specrelay::git_guard::_pre_provider_file "$task_dir")"

  if [ ! -f "$snapshot_file" ]; then
    specrelay::out::err "ambiguous: no pre-provider snapshot recorded; cannot reconstruct ownership across this crash window"
    return 1
  fi

  local snap_head snap_index current_head current_index
  snap_head="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("head_commit") or "")' "$snapshot_file" 2>/dev/null)"
  snap_index="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("index_digest") or "")' "$snapshot_file" 2>/dev/null)"
  current_head="$(cd "$root" && git rev-parse HEAD 2>/dev/null || echo '')"
  current_index="$(cd "$root" && git diff --cached 2>/dev/null | python3 -c '
import hashlib, sys
h = hashlib.sha256()
h.update(sys.stdin.buffer.read())
print(h.hexdigest())
' 2>/dev/null || echo '')"

  if [ -n "$snap_head" ] && [ "$snap_head" != "$current_head" ]; then
    specrelay::out::err "ambiguous: HEAD moved since the pre-provider snapshot (was $snap_head, now $current_head); refusing to auto-adopt ownership"
    return 1
  fi
  if [ "$snap_index" != "$current_index" ]; then
    specrelay::out::err "ambiguous: the git index changed unexpectedly since the pre-provider snapshot; refusing to auto-adopt ownership"
    return 1
  fi

  local -a current_paths=()
  while IFS= read -r p; do
    [ -n "$p" ] && current_paths+=("$p")
  done < <(specrelay::git_guard::_paths "$root" "$task_dir")

  local -a owned=()
  local p prior_digest current_digest
  for p in "${current_paths[@]:-}"; do
    [ -n "$p" ] || continue
    prior_digest="$(PJSON="$p" python3 -c '
import json, os, sys
data = json.load(open(sys.argv[1]))
print(data.get("paths", {}).get(os.environ["PJSON"], {}).get("digest", ""))
' "$snapshot_file" 2>/dev/null)"
    current_digest="$(specrelay::git_guard::_sha256_file "$root" "$p")"
    if [ -z "$prior_digest" ]; then
      # Not present in the pre-provider snapshot at all: newly changed/
      # newly untracked during the interval that contains the provider run.
      owned+=("$p")
    elif [ "$prior_digest" != "$current_digest" ]; then
      owned+=("$p")
    fi
  done

  printf '%s\n' "${owned[@]:-}" | sed '/^$/d'

  if [ "${#owned[@]}" -gt 0 ]; then
    PATHS_JSON="$(printf '%s\n' "${owned[@]}" | python3 -c '
import json, sys
print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))
')" \
    INVOCATION_ID="$invocation_id" python3 -c '
import json, os, datetime
rec = {
    "invocation_id": os.environ["INVOCATION_ID"],
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "paths": json.loads(os.environ["PATHS_JSON"]),
    "diff_digest": "",
    "source": "reconstructed-from-pre-provider-snapshot",
}
print(json.dumps(rec))
' >> "$(specrelay::git_guard::_ledger_file "$task_dir")"
  fi
  return 0
}

# specrelay::git_guard::adopt_round_change_from_evidence <project-root> <task-dir> <invocation-id> [evidence-file]
# Adopts a COMPLETED round's proven changed paths into the ledger from the
# durable name-status evidence the round already produced
# (05-changed-files.txt), for the case where the round's ownership was never
# recorded in the ledger during executor_evidence_capture — e.g. a round that
# was interrupted and finalized out-of-band (submitted via a runner
# authorization rather than the evidence-capture phase), or a round produced by
# an engine predating the ledger (spec 0029, section 23.2). Section 23.2 defines
# the ledger's paths as coming "from 05-changed-files.txt + untracked
# additions", so adopting from that same durable evidence is faithful to the
# ledger's own source of truth — NOT the raw dirty tree. Only the paths the
# round actually changed are adopted, so an unrelated external change (absent
# from the evidence) still blocks the guard (section 23.3).
#
# Appends ONE ledger line (source: "adopted-from-evidence") only when the
# evidence names paths the ledger does not already cover; a no-op returning 1
# (appends nothing) when there is no evidence to adopt or the ledger already
# covers every evidence path. The caller runs derive_owned_from_ledger
# afterwards. This is the requeue/claim self-heal that keeps section 23.5's "no
# manual editing of internal guard files is ever required" guarantee intact for
# a round whose ownership was not ledger-recorded at capture time.
specrelay::git_guard::adopt_round_change_from_evidence() {
  local root="$1" task_dir="$2" invocation_id="$3" evidence_file="${4:-}"
  if [ -z "$evidence_file" ]; then
    evidence_file="$task_dir/05-changed-files.txt"
    if [ ! -s "$evidence_file" ]; then
      # Fall back to the most recent archived round's evidence (requeue copies
      # each round's 05-changed-files.txt into iterations/round-N/).
      local archived
      archived="$(ls -1 "$task_dir"/iterations/round-*/05-changed-files.txt 2>/dev/null | sort | tail -1)"
      [ -n "$archived" ] && evidence_file="$archived"
    fi
  fi
  [ -s "$evidence_file" ] || return 1

  local ledger_file
  ledger_file="$(specrelay::git_guard::_ledger_file "$task_dir")"

  # Parse the round's proven paths from the name-status evidence and decide
  # whether the ledger already covers them (renames list both sides).
  local decision
  decision="$(EVIDENCE="$evidence_file" LEDGER="$ledger_file" python3 -c '
import json, os
paths, seen = [], set()
with open(os.environ["EVIDENCE"], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        # name-status format: <STATUS>\t<path>[\t<path2>] (path2 for renames)
        parts = line.split("\t")
        for p in parts[1:]:
            p = p.strip()
            if p and p not in seen:
                seen.add(p)
                paths.append(p)
covered = set()
lf = os.environ["LEDGER"]
if os.path.isfile(lf):
    with open(lf, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            covered.update(rec.get("paths") or [])
has_new = any(p not in covered for p in paths)
print(json.dumps({"paths": paths, "has_new": has_new}))
')"

  local has_new
  has_new="$(printf '%s' "$decision" | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin)["has_new"] else "no")')"
  [ "$has_new" = "yes" ] || return 1

  PATHS_JSON="$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["paths"]))')" \
  INVOCATION_ID="$invocation_id" python3 -c '
import json, os, datetime
rec = {
    "invocation_id": os.environ["INVOCATION_ID"],
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "paths": json.loads(os.environ["PATHS_JSON"]),
    "diff_digest": "",
    "source": "adopted-from-evidence",
}
print(json.dumps(rec))
' >> "$ledger_file"
  return 0
}
