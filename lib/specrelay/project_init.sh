#!/usr/bin/env bash
# project_init.sh — `specrelay init`: initialize a consumer repository for
# SpecRelay (spec 0086, sections 14-19).
#
# init is a PROJECT-side operation: it writes .specrelay/config.yml (from the
# tool's built-in template), creates the spec root, and adds a safe,
# idempotent .gitignore entry for the runtime evidence directory. It never
# overwrites an existing config unless --force is given, and it derives the
# tool's own template location from the executable's install root (self_dir),
# never from the consumer project (sections 7-8).

# specrelay::init::_template_path <specrelay-home>
# Prints the path to the bundled generic project-config template, resolved
# from SpecRelay's own install/source root (never from the consumer project).
specrelay::init::_template_path() {
  local home="$1"
  printf '%s/templates/project/config.yml\n' "$home"
}

# specrelay::init::_resolve_root <target-dir>
# Prints the project root to initialize: the git top-level if <target-dir> is
# inside a git working tree, else <target-dir> itself (absolute). Refuses a
# clearly-unsafe location (a non-existent dir, or the filesystem root / the
# user's HOME directly). Returns non-zero on refusal.
specrelay::init::_resolve_root() {
  local target="$1" abs root
  if [ ! -d "$target" ]; then
    specrelay::out::err "init: target directory does not exist: $target"
    return 1
  fi
  abs="$(cd "$target" && pwd -P)" || return 1

  if root="$(cd "$abs" && git rev-parse --show-toplevel 2>/dev/null)"; then
    root="$(cd "$root" && pwd -P)"
  else
    root="$abs"
  fi

  # Minimal unsafe-location guard: never initialize the filesystem root or the
  # user's HOME directory itself (spec section 14, item 2).
  if [ "$root" = "/" ]; then
    specrelay::out::err "init: refusing to initialize the filesystem root (/)"
    return 1
  fi
  if [ -n "${HOME:-}" ] && [ "$root" = "$(cd "$HOME" 2>/dev/null && pwd -P)" ]; then
    specrelay::out::err "init: refusing to initialize your HOME directory directly ($root); run inside a project instead"
    return 1
  fi
  printf '%s\n' "$root"
}

# specrelay::init::_gitignore_add <project-root> <entry>
# Idempotently ensures <entry> is present in <project-root>/.gitignore. Only
# appends when the exact line is absent; never rewrites or reorders existing
# content. No-op (and no file created) if the project is not a git repo AND a
# .gitignore does not already exist — a plain non-git directory has nothing to
# ignore-for-git.
specrelay::init::_gitignore_add() {
  local root="$1" entry="$2" gi="$1/.gitignore"
  if [ ! -e "$gi" ]; then
    # Only create a .gitignore if this is actually a git repo.
    if [ ! -d "$root/.git" ] && ! (cd "$root" && git rev-parse --show-toplevel >/dev/null 2>&1); then
      return 0
    fi
    printf '%s\n' "$entry" > "$gi"
    return 0
  fi
  if grep -Fqx -- "$entry" "$gi" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$entry" >> "$gi"
}

# specrelay::init::run <specrelay-home> [--path <dir>] [--force]
specrelay::init::run() {
  local home="$1"; shift
  local target="$PWD" force=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path)
        [ "$#" -ge 2 ] || { specrelay::out::err "--path requires a value"; return 2; }
        target="$2"; shift 2 ;;
      --force)
        force=1; shift ;;
      -*)
        specrelay::out::err "unknown option: $1"; return 2 ;;
      *)
        specrelay::out::err "unexpected argument: $1"; return 2 ;;
    esac
  done

  local root
  root="$(specrelay::init::_resolve_root "$target")" || return 1

  local template config
  template="$(specrelay::init::_template_path "$home")"
  if [ ! -f "$template" ]; then
    specrelay::out::err "init: bundled template not found: $template"
    return 1
  fi
  config="$root/.specrelay/config.yml"

  if [ -f "$config" ] && [ "$force" -ne 1 ]; then
    echo "SpecRelay is already initialized here:"
    echo "  $config"
    echo "Nothing was changed. Re-run with --force to overwrite the config from the template."
    return 0
  fi

  mkdir -p "$root/.specrelay" || return 1

  # Render the template: substitute the project-name token with the project
  # directory's basename using literal (non-regex) replacement, so an
  # arbitrary directory name can never inject a pattern.
  local name content
  name="$(basename "$root")"
  content="$(cat "$template")"
  content="${content//__SPECRELAY_PROJECT_NAME__/$name}"
  printf '%s' "$content" > "$config" || return 1

  # Create the configured spec root (default: specs) so `specrelay run` and
  # `doctor` have a real directory to work with.
  local spec_root
  spec_root="$(specrelay::task::spec_root "$root")"
  mkdir -p "$spec_root" || return 1

  # Ignore the runtime evidence directory by default (conservative: generated
  # per-run evidence is not source). This is configurable — a project that
  # wants durable, versioned task records can remove this entry (see
  # docs/configuration.md, ".gitignore guidance").
  local runs_root_rel
  runs_root_rel="$(specrelay::config::get "$root" "tasks.runs_root" ".specrelay-runs/tasks")"
  # Ignore the top-level runtime dir, not just the tasks subdir.
  local ignore_dir="${runs_root_rel%%/*}/"
  specrelay::init::_gitignore_add "$root" "$ignore_dir"

  echo "Initialized SpecRelay in: $root"
  echo "  created: .specrelay/config.yml"
  echo "  created: ${spec_root#"$root"/}/ (spec root)"
  echo "  gitignore: $ignore_dir (runtime evidence)"
  echo
  echo "Next steps:"
  echo "  1. Edit .specrelay/config.yml (set your executor/reviewer providers)."
  echo "  2. Add a spec at ${spec_root#"$root"/}/0001-example/spec.md"
  echo "  3. Run: specrelay run ${spec_root#"$root"/}/0001-example/spec.md"
  return 0
}
