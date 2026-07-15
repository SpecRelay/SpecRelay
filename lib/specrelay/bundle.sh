#!/usr/bin/env bash
# bundle.sh — specification input classification, directory-bundle discovery,
# content classification, and the immutable manifest/snapshot layout
# (spec 0023, sections 4-11).
#
# A specification input is either a single regular file or a directory
# ("bundle root"). This module never mutates the live source; it only reads
# it, then copies accepted files into the task's immutable snapshot beneath
# 01-input-bundle/local/ and records everything in 01-input-manifest.json.

# --- digests / sizes ---------------------------------------------------------

# specrelay::bundle::_sha256 <file>
specrelay::bundle::_sha256() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    specrelay::out::err "no sha256 utility found (need shasum or sha256sum)"
    return 1
  fi
}

# specrelay::bundle::_size <file>
specrelay::bundle::_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

# --- input kind classification (spec section 5) -----------------------------

# specrelay::bundle::classify_input <path>
# Prints "file" or "directory" on success. Fails (non-zero, message on
# stderr) for a missing, unreadable, or special (socket/device/FIFO) path —
# this covers section 5's "must fail before task creation" rule.
specrelay::bundle::classify_input() {
  local p="$1"
  if [ -L "$p" ] && [ ! -e "$p" ]; then
    specrelay::out::err "input path is a broken symlink: $p"
    return 1
  fi
  if [ ! -e "$p" ]; then
    specrelay::out::err "input path does not exist: $p"
    return 1
  fi
  if [ -f "$p" ]; then
    printf 'file\n'
    return 0
  fi
  if [ -d "$p" ]; then
    printf 'directory\n'
    return 0
  fi
  specrelay::out::err "input path is neither a regular file nor a directory (special filesystem entry rejected): $p"
  return 1
}

# --- directory convention (spec section 6) -----------------------------------

# specrelay::bundle::tech_spec_name <bundle-root-abs>
# Prints the accepted technical-spec filename found at the bundle root, if
# any. Fails with an explicit ambiguity error when BOTH accepted variants
# exist (section 6.2: "SpecRelay must never silently choose one").
specrelay::bundle::tech_spec_name() {
  local root="$1" has_dash=0 has_underscore=0
  [ -f "$root/tech-spec.md" ] && has_dash=1
  [ -f "$root/tech_spec.md" ] && has_underscore=1
  if [ "$has_dash" -eq 1 ] && [ "$has_underscore" -eq 1 ]; then
    specrelay::out::err "ambiguous technical specification: both tech-spec.md and tech_spec.md exist at the bundle root; SpecRelay never silently chooses one (spec 0023, section 6.2) — remove one"
    return 1
  fi
  if [ "$has_dash" -eq 1 ]; then
    printf 'tech-spec.md\n'
  elif [ "$has_underscore" -eq 1 ]; then
    printf 'tech_spec.md\n'
  fi
  return 0
}

# specrelay::bundle::require_functional_spec <root>
# Prints "true"/"false" (default true — spec 0023 section 6.1: "project
# policy should require spec.md ... must not silently accept a missing
# spec.md and guess").
specrelay::bundle::require_functional_spec() {
  local root="$1"
  if specrelay::config::exists "$root"; then
    specrelay::config::get "$root" "bundle.require_functional_spec" "true"
  else
    printf 'true\n'
  fi
}

# --- default exclusions (spec section 8) -------------------------------------

# specrelay::bundle::_default_excludes
# One glob/name pattern per line.
specrelay::bundle::_default_excludes() {
  printf '%s\n' '.git' '.specrelay-runs' 'node_modules' '.DS_Store' '*.tmp' '*.swp'
}

# specrelay::bundle::_configured_excludes <root>
# Additional configured exclusion patterns (spec section 8: "may support
# configurable exclusions"), a comma-separated list at bundle.exclude.
specrelay::bundle::_configured_excludes() {
  local root="$1" raw
  specrelay::config::exists "$root" || return 0
  raw="$(specrelay::config::get "$root" "bundle.exclude" "")"
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | tr ',' '\n' | sed -E 's/^\s+|\s+$//g' | sed '/^$/d'
}

# specrelay::bundle::_excluded <basename> <excludes...>
specrelay::bundle::_excluded() {
  local name="$1"; shift
  local pat
  for pat in "$@"; do
    [ -n "$pat" ] || continue
    case "$name" in
      "$pat"|"${pat%/}") return 0 ;;
    esac
    case "$name" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# --- discovery (spec section 8) ----------------------------------------------

# specrelay::bundle::discover <bundle-root-abs> <root>
# Prints one normalized relative path per line, deterministically sorted, for
# every accepted local file beneath the bundle root. Directory exclusions
# (default + configured) are pruned before descent so excluded subtrees are
# never even visited. Fails clearly on a broken symlink, an escaping symlink,
# or a special filesystem entry found anywhere in the tree — never silently
# omitting it (section 8: "Partial silent ingestion is forbidden").
specrelay::bundle::discover() {
  local bundle_root="$1" root="$2"
  local -a excludes=()
  local line
  while IFS= read -r line; do [ -n "$line" ] && excludes+=("$line"); done < <(specrelay::bundle::_default_excludes)
  while IFS= read -r line; do [ -n "$line" ] && excludes+=("$line"); done < <(specrelay::bundle::_configured_excludes "$root")

  local bundle_root_real
  bundle_root_real="$(cd "$bundle_root" && pwd -P)" || return 1

  local -a raw=()
  while IFS= read -r line; do [ -n "$line" ] && raw+=("$line"); done < <(cd "$bundle_root_real" && find . -mindepth 1 \( -type d -o -type f -o -type l \) -print | sed 's#^\./##' | LC_ALL=C sort)

  local relpath abspath base parent_excluded entry
  local -a accepted=()
  for relpath in "${raw[@]:-}"; do
    base="$(basename "$relpath")"
    if specrelay::bundle::_excluded "$base" "${excludes[@]}"; then
      continue
    fi
    parent_excluded=0
    local prefix="$relpath"
    while : ; do
      case "$prefix" in
        */*) prefix="${prefix%/*}" ;;
        *) break ;;
      esac
      if specrelay::bundle::_excluded "$(basename "$prefix")" "${excludes[@]}"; then
        parent_excluded=1
        break
      fi
    done
    [ "$parent_excluded" -eq 1 ] && continue

    abspath="$bundle_root_real/$relpath"
    if [ -L "$abspath" ]; then
      if [ ! -e "$abspath" ]; then
        specrelay::out::err "broken symlink rejected: $relpath"
        return 1
      fi
      local resolved
      resolved="$(python3 -c '
import os, sys
p = sys.argv[1]
print(os.path.realpath(p))
' "$abspath" 2>/dev/null)"
      case "$resolved" in
        "$bundle_root_real"/*|"$bundle_root_real") : ;;
        *)
          specrelay::out::err "symlink escapes the input root, rejected: $relpath -> $resolved"
          return 1
          ;;
      esac
      if [ -d "$abspath" ]; then
        continue
      fi
      if [ ! -f "$abspath" ]; then
        specrelay::out::err "symlink target is not a regular file or directory, rejected: $relpath"
        return 1
      fi
      accepted+=("$relpath")
      continue
    fi
    if [ -d "$abspath" ]; then
      continue
    fi
    if [ -f "$abspath" ]; then
      accepted+=("$relpath")
      continue
    fi
    specrelay::out::err "special filesystem entry rejected: $relpath"
    return 1
  done

  local f
  for f in "${accepted[@]:-}"; do
    printf '%s\n' "$f"
  done
}

# --- size / count limits (spec section 8) ------------------------------------

# specrelay::bundle::check_limits <bundle-root-abs> <root> <relpaths...>
# Fails clearly, reporting bundle root, file count, total size, and the
# applicable limit, when a configured limit is exceeded. Defaults are
# generous (bundle.max_files=2000, bundle.max_total_bytes=209715200 / 200MiB)
# so ordinary bundles are never affected.
specrelay::bundle::check_limits() {
  local bundle_root="$1" root="$2"; shift 2
  local max_files max_bytes count=0 total=0 f
  max_files="$(specrelay::config::exists "$root" && specrelay::config::get "$root" "bundle.max_files" "2000" || echo 2000)"
  max_bytes="$(specrelay::config::exists "$root" && specrelay::config::get "$root" "bundle.max_total_bytes" "209715200" || echo 209715200)"

  for f in "$@"; do
    count=$((count + 1))
    total=$((total + $(specrelay::bundle::_size "$bundle_root/$f")))
  done

  if [ "$count" -gt "$max_files" ]; then
    specrelay::out::err "bundle exceeds the configured file-count limit: path=$bundle_root file_count=$count limit=$max_files"
    return 1
  fi
  if [ "$total" -gt "$max_bytes" ]; then
    specrelay::out::err "bundle exceeds the configured size limit: path=$bundle_root bundle_size=$total limit=$max_bytes"
    return 1
  fi
  return 0
}

# --- content classification (spec section 9) ---------------------------------

# specrelay::bundle::classify_content <relpath> <is-bundle-root-level 0|1>
specrelay::bundle::classify_content() {
  local relpath="$1" root_level="$2" base ext
  base="$(basename "$relpath")"
  if [ "$root_level" -eq 1 ]; then
    case "$base" in
      spec.md) printf 'authoritative-functional-spec\n'; return 0 ;;
      tech-spec.md|tech_spec.md) printf 'authoritative-technical-spec\n'; return 0 ;;
    esac
  fi
  ext="${base##*.}"
  [ "$ext" = "$base" ] && ext=""
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    md|txt) printf 'text-readable\n' ;;
    json|yaml|yml|xml|csv) printf 'structured-data\n' ;;
    log|trace) printf 'log-or-trace\n' ;;
    png|jpg|jpeg|webp) printf 'visual\n' ;;
    pdf) printf 'document\n' ;;
    sh|bash|zsh|rb|py|js|ts|tsx|jsx|go|java|rs|c|h|cpp|hpp|ini|toml|conf|env|cfg) printf 'source-or-config\n' ;;
    *)
      case "$relpath" in
        */log/*|*/logs/*) printf 'log-or-trace\n' ;;
        *) printf 'unknown-binary\n' ;;
      esac
      ;;
  esac
}

# specrelay::bundle::inspection_capability <content-class>
specrelay::bundle::inspection_capability() {
  case "$1" in
    authoritative-functional-spec|authoritative-technical-spec|text-readable|structured-data|source-or-config|log-or-trace)
      printf 'directly-inspectable\n' ;;
    visual|document)
      printf 'inspectable-through-provider-multimodal\n' ;;
    external-reference-container)
      printf 'inspectable-through-configured-adapter\n' ;;
    *)
      printf 'unsupported\n' ;;
  esac
}

# specrelay::bundle::media_type <relpath>
specrelay::bundle::media_type() {
  local base ext
  base="$(basename "$1")"
  ext="${base##*.}"
  [ "$ext" = "$base" ] && ext=""
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    md) printf 'text/markdown\n' ;;
    txt|log|trace) printf 'text/plain\n' ;;
    json) printf 'application/json\n' ;;
    yaml|yml) printf 'application/x-yaml\n' ;;
    xml) printf 'application/xml\n' ;;
    csv) printf 'text/csv\n' ;;
    png) printf 'image/png\n' ;;
    jpg|jpeg) printf 'image/jpeg\n' ;;
    webp) printf 'image/webp\n' ;;
    pdf) printf 'application/pdf\n' ;;
    *) printf 'application/octet-stream\n' ;;
  esac
}

# --- manifest + snapshot (spec sections 10-11) -------------------------------

# specrelay::bundle::build <root> <task-dir> <input-kind> <bundle-root-abs> <original-arg>
# Snapshots every accepted file beneath 01-input-bundle/local/, then writes
# 01-input-manifest.json. Prints nothing on success; non-zero + stderr
# message on any validation failure (nothing is partially written into the
# task dir's bundle location in that case).
specrelay::bundle::build() {
  local root="$1" task_dir="$2" input_kind="$3" bundle_root_abs="$4" original_arg="$5"
  local bundle_dir="$task_dir/01-input-bundle"
  local local_dir="$bundle_dir/local"
  local manifest="$task_dir/01-input-manifest.json"
  local records_jsonl
  records_jsonl="$(mktemp "${TMPDIR:-/tmp}/specrelay-bundle-records.XXXXXX")"

  mkdir -p "$local_dir"

  local -a relpaths=()
  local functional_spec="" technical_spec=""

  if [ "$input_kind" = "file" ]; then
    local base
    base="$(basename "$bundle_root_abs")"
    relpaths=("$base")
  else
    local tech_name
    tech_name="$(specrelay::bundle::tech_spec_name "$bundle_root_abs")" || { rm -f "$records_jsonl"; return 1; }

    if [ "$(specrelay::bundle::require_functional_spec "$root")" = "true" ] && [ ! -f "$bundle_root_abs/spec.md" ]; then
      specrelay::out::err "specification directory is missing required spec.md (bundle.require_functional_spec is true): $bundle_root_abs"
      rm -f "$records_jsonl"
      return 1
    fi

    local out
    out="$(specrelay::bundle::discover "$bundle_root_abs" "$root")" || { rm -f "$records_jsonl"; return 1; }
    while IFS= read -r line; do [ -n "$line" ] && relpaths+=("$line"); done <<< "$out"

    if [ "${#relpaths[@]}" -eq 0 ]; then
      specrelay::out::err "specification directory contains no eligible files: $bundle_root_abs"
      rm -f "$records_jsonl"
      return 1
    fi

    specrelay::bundle::check_limits "$bundle_root_abs" "$root" "${relpaths[@]}" || { rm -f "$records_jsonl"; return 1; }
  fi

  local rp abspath class capability media size digest snap_rel snap_abs snap_parent root_level
  local jam_pairs_file
  jam_pairs_file="$(mktemp "${TMPDIR:-/tmp}/specrelay-bundle-jam-pairs.XXXXXX")"
  for rp in "${relpaths[@]}"; do
    if [ "$input_kind" = "file" ]; then
      abspath="$bundle_root_abs"
    else
      abspath="$bundle_root_abs/$rp"
    fi
    case "$rp" in
      */*) root_level=0 ;;
      *) root_level=1 ;;
    esac
    if [ "$input_kind" = "file" ]; then
      # Section 5.1: "the file is the primary specification" — always, and
      # regardless of its name (a single-file input need not be spec.md).
      class="authoritative-functional-spec"
    else
      class="$(specrelay::bundle::classify_content "$rp" "$root_level")"
    fi
    capability="$(specrelay::bundle::inspection_capability "$class")"
    media="$(specrelay::bundle::media_type "$rp")"
    size="$(specrelay::bundle::_size "$abspath")"
    digest="$(specrelay::bundle::_sha256 "$abspath")" || { rm -f "$records_jsonl"; return 1; }

    snap_rel="local/$rp"
    snap_abs="$local_dir/$rp"
    snap_parent="$(dirname "$snap_abs")"
    mkdir -p "$snap_parent"
    cp "$abspath" "$snap_abs"
    chmod 444 "$snap_abs" 2>/dev/null || true

    case "$class" in
      authoritative-functional-spec) functional_spec="$rp" ;;
      authoritative-technical-spec) technical_spec="$rp" ;;
    esac

    local -a file_refs=()
    if [ "$capability" = "directly-inspectable" ]; then
      while IFS= read -r line; do
        if [ -n "$line" ]; then
          file_refs+=("$line")
          printf '%s\t%s\n' "$rp" "$line" >> "$jam_pairs_file"
        fi
      done < <(specrelay::jam::extract_refs "$abspath" 2>/dev/null)
    fi

    REL="$rp" SRC="${bundle_root_abs}/${rp}" SNAP="01-input-bundle/$snap_rel" ROLE="$class" MEDIA="$media" SIZE="$size" DIGEST="$digest" CAP="$capability" \
      python3 -c '
import json, os, sys
refs = [r for r in sys.argv[1:] if r]
print(json.dumps({
    "relative_path": os.environ["REL"],
    "source_path": os.environ["SRC"],
    "snapshot_path": os.environ["SNAP"],
    "role": os.environ["ROLE"],
    "media_type": os.environ["MEDIA"],
    "byte_size": int(os.environ["SIZE"]),
    "sha256": os.environ["DIGEST"],
    "inspection_capability": os.environ["CAP"],
    "analysis_status": "pending",
    "exclusion_reason": None,
    "external_references": refs,
}))
' "${file_refs[@]:-}" >> "$records_jsonl"
  done

  local created_at
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

  ROOT="$input_kind" ORIG="$original_arg" SRCROOT="$bundle_root_abs" FUNC="$functional_spec" TECH="$technical_spec" CREATED="$created_at" RECORDS="$records_jsonl" \
    python3 -c '
import json, os

records = []
with open(os.environ["RECORDS"], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            records.append(json.loads(line))

total_size = sum(r["byte_size"] for r in records)
manifest = {
    "schema_version": 1,
    "input_kind": os.environ["ROOT"],
    "original_input_path": os.environ["ORIG"],
    "normalized_source_root": os.environ["SRCROOT"],
    "primary_functional_specification_path": os.environ["FUNC"] or None,
    "technical_specification_path": os.environ["TECH"] or None,
    "bundle_file_count": len(records),
    "bundle_total_size": total_size,
    "created_at": os.environ["CREATED"],
    "files": records,
    "external_evidence": [],
}
print(json.dumps(manifest, indent=2, sort_keys=False))
' > "$manifest"

  rm -f "$records_jsonl"

  if [ -s "$jam_pairs_file" ]; then
    specrelay::jam::record_references "$root" "$task_dir" "$manifest" "$jam_pairs_file" || { rm -f "$jam_pairs_file"; return 1; }
  fi
  rm -f "$jam_pairs_file"

  return 0
}

# specrelay::bundle::verify_snapshot <task-dir>
# Recomputes every file's digest from its snapshot and compares against the
# manifest-recorded digest (spec section 22: "manifest-to-snapshot integrity
# checks"). Prints nothing and returns 0 when every digest matches.
specrelay::bundle::verify_snapshot() {
  local task_dir="$1" manifest
  manifest="$task_dir/01-input-manifest.json"
  [ -f "$manifest" ] || { specrelay::out::err "manifest not found: $manifest"; return 1; }
  TASKDIR="$task_dir" python3 -c '
import json, hashlib, os, sys

task_dir = os.environ["TASKDIR"]
with open(os.path.join(task_dir, "01-input-manifest.json"), encoding="utf-8") as fh:
    manifest = json.load(fh)

bad = []
for f in manifest.get("files", []):
    snap = os.path.join(task_dir, f["snapshot_path"])
    if not os.path.isfile(snap):
        bad.append((f["relative_path"], "missing snapshot"))
        continue
    h = hashlib.sha256()
    with open(snap, "rb") as sf:
        h.update(sf.read())
    if h.hexdigest() != f["sha256"]:
        bad.append((f["relative_path"], "digest mismatch"))

if bad:
    for rel, reason in bad:
        print(f"specrelay: manifest/snapshot integrity failure: {rel}: {reason}", file=sys.stderr)
    sys.exit(1)
'
}
