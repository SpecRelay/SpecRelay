#!/usr/bin/env bash
# release.sh — release-impact metadata + release plan/prepare/verify/tag
# (spec 0022, sections 8-9). Source-local only: these commands manage the
# SpecRelay repository's OWN VERSION/CHANGELOG.md/tags, never a consumer
# project's. They never commit, push, or create a Git tag automatically
# except 'release tag' itself creating the ONE documented tag on request.

SPECRELAY_RELEASE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/py/release_lib.py"

specrelay::release::_specs_root() {
  printf '%s/docs/specs\n' "$1"
}

# specrelay::release::_require_source_local <home>
specrelay::release::_require_source_local() {
  if ! specrelay::execution_mode::is_source_local "$1"; then
    specrelay::out::err "release commands operate on THIS SpecRelay checkout's own VERSION/CHANGELOG.md and are only meaningful in source-local mode (installed mode has no repository to release)."
    return 1
  fi
  return 0
}

# specrelay::release::_discover_json <home>
specrelay::release::_discover_json() {
  local home="$1" specs_root
  specs_root="$(specrelay::release::_specs_root "$home")"
  python3 "$SPECRELAY_RELEASE_PY" discover "$specs_root" 2>/dev/null
}

specrelay::release::plan() {
  local home="$1" current blob pending_count errors_count highest proposed
  specrelay::release::_require_source_local "$home" || return 1
  current="$(tr -d '[:space:]' < "$home/VERSION")"
  blob="$(specrelay::release::_discover_json "$home")"
  [ -n "$blob" ] || blob='{"pending": [], "errors": []}'

  echo "Current version: $current"

  errors_count="$(printf '%s' "$blob" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("errors",[])))' 2>/dev/null)"
  if [ "${errors_count:-0}" -gt 0 ] 2>/dev/null; then
    echo "Release-impact metadata errors:"
    printf '%s' "$blob" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for e in d.get("errors", []):
    print("  %s: %s" % (e["spec"], e["reason"]))
'
  fi

  pending_count="$(printf '%s' "$blob" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("pending",[])))' 2>/dev/null)"
  if [ "${pending_count:-0}" -eq 0 ] 2>/dev/null; then
    echo "Pending impact: none (no spec after 0022 declares a non-none release: impact yet)"
    echo "Proposed version: $current (unchanged)"
    echo "Source task: (none)"
    return 0
  fi

  echo "Pending impact:"
  printf '%s' "$blob" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in d.get("pending", []):
    print("  %s: %s — %s" % (p["spec"], p["impact"], p["rationale"]))
'
  highest="$(printf '%s' "$blob" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rank = {"patch": 1, "minor": 2, "major": 3}
pending = d.get("pending", [])
print(max((p["impact"] for p in pending), key=lambda i: rank[i]) if pending else "")
')"
  proposed="$(python3 "$SPECRELAY_RELEASE_PY" bump "$current" "$highest" 2>/dev/null)"
  echo "Proposed version: ${proposed:-$current}"
  echo "Source task(s): $(printf '%s' "$blob" | python3 -c 'import json,sys; print(", ".join(p["spec"] for p in json.load(sys.stdin).get("pending",[])))')"
  return 0
}

specrelay::release::prepare() {
  local home="$1" current blob pending_count highest proposed changelog
  specrelay::release::_require_source_local "$home" || return 1
  current="$(tr -d '[:space:]' < "$home/VERSION")"
  blob="$(specrelay::release::_discover_json "$home")"
  [ -n "$blob" ] || blob='{"pending": [], "errors": []}'

  pending_count="$(printf '%s' "$blob" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("pending",[])))' 2>/dev/null)"
  if [ "${pending_count:-0}" -eq 0 ] 2>/dev/null; then
    echo "Nothing to prepare: no spec after 0022 declares a non-none release: impact. VERSION stays $current."
    return 0
  fi

  highest="$(printf '%s' "$blob" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rank = {"patch": 1, "minor": 2, "major": 3}
pending = d.get("pending", [])
print(max((p["impact"] for p in pending), key=lambda i: rank[i]))
')"
  proposed="$(python3 "$SPECRELAY_RELEASE_PY" bump "$current" "$highest" 2>/dev/null)"
  if [ -z "$proposed" ]; then
    specrelay::out::err "release prepare: could not compute a proposed version from $current + $highest"
    return 1
  fi

  printf '%s\n' "$proposed" > "$home/VERSION"

  changelog="$home/CHANGELOG.md"
  local entry
  entry="$(printf '\n## %s\n\n%s\n' "$proposed" "$(printf '%s' "$blob" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in d.get("pending", []):
    print("- %s (%s): %s" % (p["spec"], p["impact"], p["rationale"]))
')")"
  if [ -f "$changelog" ]; then
    { printf '%s\n' "$entry"; cat "$changelog"; } > "$changelog.tmp" && mv "$changelog.tmp" "$changelog"
  else
    printf '%s\n' "$entry" > "$changelog"
  fi

  echo "Prepared: VERSION $current -> $proposed"
  echo "Diff:"
  if command -v git >/dev/null 2>&1 && git -C "$home" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$home" --no-pager diff -- VERSION CHANGELOG.md
  else
    echo "  (git not available to show a diff; VERSION and CHANGELOG.md were updated in place)"
  fi
  echo "Nothing was committed, tagged, or pushed."
  return 0
}

specrelay::release::verify() {
  local home="$1" version ok=1
  specrelay::release::_require_source_local "$home" || return 1
  version="$(tr -d '[:space:]' < "$home/VERSION")"

  if specrelay::semver::valid "$version"; then
    echo "ok - VERSION is valid semantic version syntax ($version)"
  else
    echo "FAIL - VERSION is not valid MAJOR.MINOR.PATCH syntax: '$version'"
    ok=0
  fi

  if command -v git >/dev/null 2>&1 && git -C "$home" rev-parse --git-dir >/dev/null 2>&1; then
    local last_tag last_tag_ver
    last_tag="$(git -C "$home" tag -l 'v*' --sort=-v:refname 2>/dev/null | head -n1)"
    if [ -n "$last_tag" ]; then
      last_tag_ver="${last_tag#v}"
      if specrelay::semver::valid "$last_tag_ver" && specrelay::semver::gt "$version" "$last_tag_ver"; then
        echo "ok - VERSION ($version) is monotonically greater than the last tag ($last_tag)"
      elif [ "$version" = "$last_tag_ver" ]; then
        echo "ok - VERSION ($version) matches the last tag ($last_tag) (already tagged)"
      else
        echo "FAIL - VERSION ($version) is not greater than the last tag ($last_tag)"
        ok=0
      fi
    else
      echo "ok - no prior release tag exists yet; nothing to compare monotonicity against"
    fi
  fi

  if grep -qF "$version" "$home/CHANGELOG.md" 2>/dev/null; then
    echo "ok - CHANGELOG.md mentions $version"
  else
    echo "FAIL - CHANGELOG.md has no entry mentioning $version"
    ok=0
  fi

  local reported
  reported="$("$home/bin/specrelay" version 2>/dev/null)"
  if [ "$reported" = "specrelay $version" ]; then
    echo "ok - source-local 'specrelay version' reports $version"
  else
    echo "FAIL - source-local 'specrelay version' reported '$reported', expected 'specrelay $version'"
    ok=0
  fi

  [ "$ok" -eq 1 ]
}

specrelay::release::tag() {
  local home="$1" version tag_name
  specrelay::release::_require_source_local "$home" || return 1
  command -v git >/dev/null 2>&1 && git -C "$home" rev-parse --git-dir >/dev/null 2>&1 || {
    specrelay::out::err "release tag: $home is not a Git repository"
    return 1
  }

  if [ -n "$(git -C "$home" status --porcelain 2>/dev/null)" ]; then
    specrelay::out::err "release tag: working tree is not clean; commit the release state first (VERSION/CHANGELOG.md)"
    return 1
  fi

  version="$(tr -d '[:space:]' < "$home/VERSION")"
  tag_name="v$version"
  if git -C "$home" rev-parse -q --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
    specrelay::out::err "release tag: $tag_name already exists; refusing to overwrite it"
    return 1
  fi

  git -C "$home" tag -a "$tag_name" -m "SpecRelay $version" || return 1
  echo "Created tag $tag_name at $(git -C "$home" rev-parse HEAD)."
  echo "Nothing was pushed. Push explicitly when ready: git push --tags"
  return 0
}
