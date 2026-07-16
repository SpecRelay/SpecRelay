"""verification_policy_lib.py — configurable verification-policy engine
(spec 0026, "Configurable Verification Policy and Multi-Service Execution").

This module is the deterministic core described by the spec's "Product
decision" (section 5): AI roles may recommend or request a verification
level/check set, but this module alone owns configuration parsing/validation,
changed-path matching, service/check selection, dependency ordering, bounded
parallel execution, timeout enforcement, required/optional semantics, result
classification, and durable per-check evidence. Nothing here ever executes
AI-supplied shell text — only `command:` strings that already came from the
project's own `.specrelay/config.yml` (spec section 37, "Security rules").

Architecture note (deliberate division of labor with config.sh): YAML parsing
stays in Ruby (config.sh's `verification_engine_raw`, using YAML.safe_load —
the same "never deserialize arbitrary objects" rule as every other config
section in this project) because that is the one part of this pipeline that
must be. Everything past that — schema validation, duplicate/uniqueness
checks, safe-path checks, dependency-graph/cycle validation, changed-path
matching, level/flexible resolution, execution, evidence, and reporting — is
implemented here, in Python, because the schema has arrays of nested mappings
(services -> checks) that do not fit this project's existing flat
`key=value` config-accessor convention, and graph/cycle validation is far
more naturally (and testably) expressed here than in a `ruby -e` heredoc.

CLI convention: every subcommand takes a single JSON object on stdin (never
many positional argv fields prone to shell-quoting mistakes) plus a small
number of argv flags, and mirrors the other python libs in this project
(command_timing_lib.py, coordinator_lib.py): usage/parse errors go to stderr
with exit 2; everything else is plain stdout text or `--json`.
"""

import fnmatch
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

SCHEMA_VERSION = 1

LEVELS = ("changed", "full", "flexible")
PLACEMENT_VALUES = ("none", "changed", "targeted", "full", "flexible")
KNOWN_KINDS = (
    "unit", "lint", "typecheck", "build", "integration", "contract",
    "smoke", "security", "custom",
    # "ui" is a deterministic UI-runtime-verification check (spec 0028,
    # section 32): its `command:` is executed exactly like any other check
    # here (this engine has no UI-specific execution branch — the command is
    # typically `specrelay ui run --plan effective`), and the UI-specific
    # detection/scenario/evidence engine lives entirely in
    # py/ui_verification_lib.py.
    "ui",
)

REQUIRED_TERMINAL_STATUSES = (
    "PASSED", "FAILED", "TIMED_OUT", "BLOCKED", "BLOCKED_BY_DEPENDENCY",
    "CONFIGURATION_ERROR",
)
OPTIONAL_TERMINAL_STATUSES = (
    "PASSED", "FAILED_OPTIONAL", "TIMED_OUT_OPTIONAL", "BLOCKED_OPTIONAL",
)

PLAN_FILENAME = "26-verification-plan.json"
SUMMARY_JSON_FILENAME = "27-verification-summary.json"
SUMMARY_MD_FILENAME = "28-verification-summary.md"
EVIDENCE_DIRNAME = "verification"
SELECTION_FILENAME = "selection.json"
EFFECTIVE_CONFIG_FILENAME = "effective-config.json"
RUN_LEDGER_FILENAME = "run-ledger.json"

_SECRET_NAME_MARKERS = (
    "SECRET", "TOKEN", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "CREDENTIAL",
    "PRIVATE_KEY", "ACCESS_KEY", "CLIENT_SECRET", "DATABASE_URL",
)


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _atomic_write(path, text):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".verification-", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _write_json(path, obj):
    _atomic_write(path, json.dumps(obj, indent=2, sort_keys=True) + "\n")


def _is_unsafe_path(rel_path):
    """True when a repo-relative path is absolute or escapes the repo root
    via a '..' segment (spec section 37, "reject absolute/traversing service
    roots and check working directories")."""
    if not isinstance(rel_path, str) or not rel_path.strip():
        return True
    if rel_path.startswith("/") or rel_path.startswith("~"):
        return True
    # A Windows-style absolute path (e.g. "C:\\x") is also rejected, even on
    # a POSIX host, since configuration is meant to be portable/reviewable.
    if re.match(r"^[A-Za-z]:[\\/]", rel_path):
        return True
    parts = re.split(r"[\\/]+", rel_path)
    return any(p == ".." for p in parts)


def _secret_shaped(name):
    upper = (name or "").upper()
    return any(marker in upper for marker in _SECRET_NAME_MARKERS)


class ConfigError(Exception):
    pass


# --- normalization / validation (spec sections 12-14, 22, 36) ---------------

def _legacy_normalized(legacy_command, defaults, placement):
    """Translates the legacy `validation.full_test_command` into the
    effective legacy service/check spec section 22 requires — same shape as
    a normal configured check, so every other function in this module (path
    matching, selection, execution, evidence) treats it identically."""
    check = {
        "name": "full-test",
        "kind": "custom",
        "command": legacy_command,
        "cwd": ".",
        "timeout_seconds": defaults["timeout_seconds"],
        "required": True,
        "levels": ["full"],
        "parallel_group": None,
        "depends_on": [],
        "enabled": True,
        "environment": [],
        "evidence": {},
        "identity": "project.full-test",
    }
    service = {
        "name": "project",
        "root": ".",
        "affected_paths": [],
        "always_affected_by": [],
        "checks": [check],
    }
    return {
        "mode": "legacy",
        "version": 1,
        "defaults": defaults,
        "placement": placement,
        "services": [service],
        "risk_rules": [],
        "warnings": [],
    }


def _default_defaults():
    return {
        "level": "changed",
        "changed_fallback": "full",
        "concurrency": 4,
        "timeout_seconds": 900,
        "shell": "bash",
    }


def _default_placement():
    return {"executor": "changed", "reviewer": "targeted", "final_gate": "full"}


def _validate_defaults(raw, base):
    if raw is None:
        return dict(base), []
    if not isinstance(raw, dict):
        raise ConfigError("verification.defaults is not a mapping (got %s)" % type(raw).__name__)
    known = ("level", "changed_fallback", "concurrency", "timeout_seconds", "shell")
    unknown = [k for k in raw if k not in known]
    if unknown:
        raise ConfigError(
            "verification.defaults has unknown key(s) %s; recognized keys: %s"
            % (", ".join(sorted(unknown)), ", ".join(known))
        )
    out = dict(base)
    if "level" in raw:
        if raw["level"] not in LEVELS:
            raise ConfigError("verification.defaults.level must be one of %s (got %r)" % (LEVELS, raw["level"]))
        out["level"] = raw["level"]
    if "changed_fallback" in raw:
        if raw["changed_fallback"] not in ("changed", "full"):
            raise ConfigError(
                "verification.defaults.changed_fallback must be one of changed, full (got %r)" % (raw["changed_fallback"],)
            )
        out["changed_fallback"] = raw["changed_fallback"]
    if "concurrency" in raw:
        v = raw["concurrency"]
        if not isinstance(v, int) or isinstance(v, bool) or v < 1:
            raise ConfigError("verification.defaults.concurrency must be a positive integer (got %r)" % (v,))
        out["concurrency"] = v
    if "timeout_seconds" in raw:
        v = raw["timeout_seconds"]
        if not isinstance(v, (int, float)) or isinstance(v, bool) or v <= 0:
            raise ConfigError("verification.defaults.timeout_seconds must be a positive number (got %r)" % (v,))
        out["timeout_seconds"] = v
    if "shell" in raw:
        v = raw["shell"]
        if not isinstance(v, str) or not v.strip():
            raise ConfigError("verification.defaults.shell must be a non-empty string (got %r)" % (v,))
        out["shell"] = v
    return out, []


def _validate_placement(raw, base):
    if raw is None:
        return dict(base)
    if not isinstance(raw, dict):
        raise ConfigError("verification.placement is not a mapping (got %s)" % type(raw).__name__)
    known = ("executor", "reviewer", "final_gate")
    unknown = [k for k in raw if k not in known]
    if unknown:
        raise ConfigError(
            "verification.placement has unknown key(s) %s; recognized keys: %s"
            % (", ".join(sorted(unknown)), ", ".join(known))
        )
    out = dict(base)
    for key in known:
        if key in raw:
            v = raw[key]
            if v not in PLACEMENT_VALUES:
                raise ConfigError(
                    "verification.placement.%s must be one of %s (got %r)" % (key, PLACEMENT_VALUES, v)
                )
            out[key] = v
    return out


_CHECK_FIELDS = (
    "name", "kind", "command", "cwd", "timeout_seconds", "required", "levels",
    "parallel_group", "depends_on", "enabled", "environment", "evidence",
)


def _validate_check(raw, service_name, service_root, defaults):
    if not isinstance(raw, dict):
        raise ConfigError("a check under service %r is not a mapping (got %s)" % (service_name, type(raw).__name__))
    unknown = [k for k in raw if k not in _CHECK_FIELDS]
    if unknown:
        raise ConfigError(
            "check under service %r has unknown key(s) %s; recognized keys: %s"
            % (service_name, ", ".join(sorted(unknown)), ", ".join(_CHECK_FIELDS))
        )
    name = raw.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ConfigError("service %r has a check with a missing or empty name" % (service_name,))

    kind = raw.get("kind", "custom")
    if kind not in KNOWN_KINDS:
        raise ConfigError(
            "%s.%s has unknown kind %r; recognized kinds: %s (use kind: custom for anything uncategorized)"
            % (service_name, name, kind, ", ".join(KNOWN_KINDS))
        )

    command = raw.get("command")
    if not isinstance(command, str) or not command.strip():
        raise ConfigError("%s.%s is missing a non-empty command" % (service_name, name))

    cwd = raw.get("cwd", service_root)
    if not isinstance(cwd, str) or _is_unsafe_path(cwd):
        raise ConfigError("%s.%s has an invalid cwd %r (must be repository-relative, no absolute path or '..')" % (service_name, name, cwd))

    timeout_seconds = raw.get("timeout_seconds", defaults["timeout_seconds"])
    if not isinstance(timeout_seconds, (int, float)) or isinstance(timeout_seconds, bool) or timeout_seconds <= 0:
        raise ConfigError("%s.%s has an invalid timeout_seconds %r (must be a positive number)" % (service_name, name, timeout_seconds))

    required = raw.get("required", True)
    if not isinstance(required, bool):
        raise ConfigError("%s.%s.required must be a boolean (got %r)" % (service_name, name, required))

    # No spec-mandated default for `levels` exists; defaulting a check that
    # omits it to changed+full (rather than rejecting the config outright) is
    # a documented interpretation (see 08-executor-summary.md, "Selection and
    # Dependency Rules") — every value must still be a recognized level.
    levels = raw.get("levels", ["changed", "full"])
    if not isinstance(levels, list) or not levels or any(l not in LEVELS for l in levels):
        raise ConfigError("%s.%s.levels must be a non-empty list drawn from %s (got %r)" % (service_name, name, LEVELS, levels))

    parallel_group = raw.get("parallel_group")
    if parallel_group is not None and not isinstance(parallel_group, str):
        raise ConfigError("%s.%s.parallel_group must be a string (got %r)" % (service_name, name, parallel_group))

    depends_on = raw.get("depends_on", [])
    if not isinstance(depends_on, list) or any(not isinstance(d, str) or not d for d in depends_on):
        raise ConfigError("%s.%s.depends_on must be a list of check identity strings (got %r)" % (service_name, name, depends_on))

    enabled = raw.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ConfigError("%s.%s.enabled must be a boolean (got %r)" % (service_name, name, enabled))

    environment = raw.get("environment", [])
    if not isinstance(environment, list) or any(not isinstance(e, str) or not e for e in environment):
        raise ConfigError("%s.%s.environment must be a list of environment variable NAMES (got %r)" % (service_name, name, environment))

    evidence = raw.get("evidence", {})
    if not isinstance(evidence, dict):
        raise ConfigError("%s.%s.evidence must be a mapping (got %r)" % (service_name, name, evidence))

    return {
        "name": name,
        "kind": kind,
        "command": command,
        "cwd": cwd,
        "timeout_seconds": timeout_seconds,
        "required": required,
        "levels": list(levels),
        "parallel_group": parallel_group,
        "depends_on": list(depends_on),
        "enabled": enabled,
        "environment": list(environment),
        "evidence": evidence,
        "identity": "%s.%s" % (service_name, name),
    }


_SERVICE_FIELDS = ("name", "root", "affected_paths", "always_affected_by", "checks")


def _validate_service(raw, defaults):
    if not isinstance(raw, dict):
        raise ConfigError("a configured service is not a mapping (got %s)" % type(raw).__name__)
    unknown = [k for k in raw if k not in _SERVICE_FIELDS]
    if unknown:
        raise ConfigError(
            "a service has unknown key(s) %s; recognized keys: %s" % (", ".join(sorted(unknown)), ", ".join(_SERVICE_FIELDS))
        )
    name = raw.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ConfigError("a service is missing a non-empty name")
    root = raw.get("root", ".")
    if not isinstance(root, str) or _is_unsafe_path(root):
        raise ConfigError("service %r has an invalid root %r (must be repository-relative, no absolute path or '..')" % (name, root))
    affected_paths = raw.get("affected_paths", [])
    if not isinstance(affected_paths, list) or any(not isinstance(p, str) or not p for p in affected_paths):
        raise ConfigError("service %r.affected_paths must be a list of glob strings (got %r)" % (name, affected_paths))
    always_affected_by = raw.get("always_affected_by", [])
    if not isinstance(always_affected_by, list) or any(not isinstance(p, str) or not p for p in always_affected_by):
        raise ConfigError("service %r.always_affected_by must be a list of glob strings (got %r)" % (name, always_affected_by))
    checks_raw = raw.get("checks", [])
    if not isinstance(checks_raw, list):
        raise ConfigError("service %r.checks must be a list (got %r)" % (name, checks_raw))

    checks = [_validate_check(c, name, root, defaults) for c in checks_raw]
    check_names = [c["name"] for c in checks]
    dupes = sorted({n for n in check_names if check_names.count(n) > 1})
    if dupes:
        raise ConfigError("service %r has duplicate check name(s): %s" % (name, ", ".join(dupes)))

    return {
        "name": name,
        "root": root,
        "affected_paths": list(affected_paths),
        "always_affected_by": list(always_affected_by),
        "checks": checks,
    }


_RISK_RULE_FIELDS = ("name", "paths", "force_level", "require_checks", "rationale")


def _validate_risk_rule(raw, index):
    if not isinstance(raw, dict):
        raise ConfigError("risk_rules[%d] is not a mapping (got %s)" % (index, type(raw).__name__))
    unknown = [k for k in raw if k not in _RISK_RULE_FIELDS]
    if unknown:
        raise ConfigError(
            "risk_rules[%d] has unknown key(s) %s; recognized keys: %s" % (index, ", ".join(sorted(unknown)), ", ".join(_RISK_RULE_FIELDS))
        )
    name = raw.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ConfigError("risk_rules[%d] is missing a non-empty name" % index)
    paths = raw.get("paths", [])
    if not isinstance(paths, list) or not paths or any(not isinstance(p, str) or not p for p in paths):
        raise ConfigError("risk_rules[%r].paths must be a non-empty list of glob strings" % (name,))
    force_level = raw.get("force_level")
    if force_level is not None and force_level not in LEVELS:
        raise ConfigError("risk_rules[%r].force_level must be one of %s (got %r)" % (name, LEVELS, force_level))
    require_checks = raw.get("require_checks", [])
    if not isinstance(require_checks, list) or any(not isinstance(c, str) or not c for c in require_checks):
        raise ConfigError("risk_rules[%r].require_checks must be a list of check identity strings" % (name,))
    rationale = raw.get("rationale")
    if rationale is not None and not isinstance(rationale, str):
        raise ConfigError("risk_rules[%r].rationale must be a string" % (name,))
    return {
        "name": name,
        "paths": list(paths),
        "force_level": force_level,
        "require_checks": list(require_checks),
        "rationale": rationale,
    }


def _dependency_cycle(services):
    """Kahn's algorithm over every configured check's depends_on edges.
    Returns a cycle (list of identities) or None. Runs over ALL configured
    checks (not just ones selected for a run) — spec section 17: "reject
    cycles before execution", i.e. before any selection/execution happens at
    all, regardless of which level was requested."""
    identities = set()
    edges = {}
    for svc in services:
        for chk in svc["checks"]:
            identities.add(chk["identity"])
            edges[chk["identity"]] = list(chk["depends_on"])

    indegree = {i: 0 for i in identities}
    for i, deps in edges.items():
        for d in deps:
            if d not in identities:
                raise ConfigError("check %r depends on unknown check %r" % (i, d))
            indegree[i] += 1

    queue = [i for i in identities if indegree[i] == 0]
    visited = 0
    remaining_edges = {i: set(edges[i]) for i in identities}
    while queue:
        n = queue.pop()
        visited += 1
        for i in identities:
            if n in remaining_edges[i]:
                remaining_edges[i].discard(n)
                indegree[i] -= 1
                if indegree[i] == 0:
                    queue.append(i)
    if visited != len(identities):
        cyclic = sorted(i for i in identities if indegree[i] > 0)
        return cyclic
    return None


_ENGINE_TOP_FIELDS = ("version", "defaults", "placement", "services", "risk_rules")


def _validate_new(verification_section):
    if not isinstance(verification_section, dict):
        raise ConfigError("verification configuration is not a mapping (got %s)" % type(verification_section).__name__)

    # "executor"/"reviewer" belong to the UNRELATED spec-0019 bounded-run-
    # count policy sharing this same `verification:` mapping (see config.sh)
    # — silently ignored here, never treated as unknown, never validated by
    # this module.
    unknown_top = [k for k in verification_section if k not in _ENGINE_TOP_FIELDS and k not in ("executor", "reviewer")]
    if unknown_top:
        raise ConfigError(
            "verification configuration has unknown key(s) %s; recognized keys: %s"
            % (", ".join(sorted(unknown_top)), ", ".join(_ENGINE_TOP_FIELDS))
        )

    version = verification_section.get("version", 1)
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        raise ConfigError("verification.version must be a positive integer (got %r)" % (version,))

    defaults, warnings = _validate_defaults(verification_section.get("defaults"), _default_defaults())
    placement = _validate_placement(verification_section.get("placement"), _default_placement())

    services_raw = verification_section.get("services", [])
    if not isinstance(services_raw, list):
        raise ConfigError("verification.services must be a list (got %r)" % (services_raw,))
    services = [_validate_service(s, defaults) for s in services_raw]

    svc_names = [s["name"] for s in services]
    dupe_services = sorted({n for n in svc_names if svc_names.count(n) > 1})
    if dupe_services:
        raise ConfigError("duplicate service name(s): %s" % ", ".join(dupe_services))

    all_identities = [c["identity"] for s in services for c in s["checks"]]
    dupe_identities = sorted({i for i in all_identities if all_identities.count(i) > 1})
    if dupe_identities:
        raise ConfigError("duplicate check identity(ies): %s" % ", ".join(dupe_identities))

    cycle = _dependency_cycle(services)
    if cycle:
        raise ConfigError("dependency cycle detected among check(s): %s" % ", ".join(cycle))

    risk_rules_raw = verification_section.get("risk_rules", [])
    if not isinstance(risk_rules_raw, list):
        raise ConfigError("verification.risk_rules must be a list (got %r)" % (risk_rules_raw,))
    risk_rules = [_validate_risk_rule(r, idx) for idx, r in enumerate(risk_rules_raw)]
    for rule in risk_rules:
        for identity in rule["require_checks"]:
            if identity not in all_identities:
                raise ConfigError("risk_rules[%r].require_checks references unknown check %r" % (rule["name"], identity))

    if placement["executor"] == "full" and placement["reviewer"] == "full" and placement["final_gate"] == "full":
        warnings.append(
            "placement configures the full suite for executor, reviewer, AND final_gate with no distinct "
            "rationale — this is likely wasteful (spec 0026, section 21.4); consider 'changed' for executor "
            "and 'targeted' for reviewer."
        )

    return {
        "mode": "new",
        "version": version,
        "defaults": defaults,
        "placement": placement,
        "services": services,
        "risk_rules": risk_rules,
        "warnings": warnings,
    }


def normalize_config(raw):
    """raw: {"legacy_full_test_command": str|None, "verification": mapping|list|None}
    Returns a normalized config dict with mode in {"new", "legacy", "absent"}.
    Raises ConfigError (mode "invalid") on any structural problem, including
    the simultaneous legacy+new ambiguity (spec section 22)."""
    legacy_command = raw.get("legacy_full_test_command")
    verification_section = raw.get("verification")

    new_keys = ("version", "defaults", "placement", "services", "risk_rules")
    new_present = isinstance(verification_section, dict) and any(k in verification_section for k in new_keys)

    if legacy_command and new_present:
        raise ConfigError(
            "both legacy `validation.full_test_command` and the new `verification:` engine configuration "
            "(version/defaults/placement/services/risk_rules) are present; this is an ambiguity, not a "
            "silently-resolved default (spec 0026, section 22) — remove one of the two configurations"
        )

    if new_present:
        return _validate_new(verification_section)

    if legacy_command:
        return _legacy_normalized(legacy_command, _default_defaults(), _default_placement())

    return {
        "mode": "absent",
        "version": 1,
        "defaults": _default_defaults(),
        "placement": _default_placement(),
        "services": [],
        "risk_rules": [],
        "warnings": [],
    }


def config_digest(normalized):
    """A canonical digest of the EFFECTIVE verification configuration (spec
    section 51, "Effective configuration capture") — sufficient to detect
    drift between the configuration a task captured at first planning and
    the project's current configuration."""
    blob = json.dumps(
        {k: v for k, v in normalized.items() if k != "warnings"},
        sort_keys=True,
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# --- changed-path matching (spec section 15) --------------------------------

def _match_any(path, patterns):
    return any(fnmatch.fnmatchcase(path, pat) for pat in patterns)


def match_services(services, changed_paths):
    """Returns (matched_service_names, match_detail, unmatched_paths).
    match_detail: {service_name: [matched paths]}. A changed path may match
    more than one service (spec section 15.2, "shared path")."""
    match_detail = {}
    matched_names = []
    for svc in services:
        patterns = list(svc["affected_paths"]) + list(svc["always_affected_by"])
        hits = [p for p in changed_paths if _match_any(p, patterns)]
        if hits:
            matched_names.append(svc["name"])
            match_detail[svc["name"]] = hits

    unmatched = [
        p for p in changed_paths
        if not any(p in hits for hits in match_detail.values())
    ]
    return matched_names, match_detail, unmatched


def evaluate_risk_rules(risk_rules, changed_paths):
    """Returns (matched_rules, forced_level, forced_check_identities).
    Rules are evaluated in declared order (spec section 16, "deterministic
    and ordered"); when multiple rules match, the STRICTEST resulting
    selection wins (full beats changed) — force_level=None never downgrades
    a level another matched rule already forced up."""
    matched = []
    forced_level = None
    forced_checks = []
    for rule in risk_rules:
        if _match_any_paths(changed_paths, rule["paths"]):
            matched.append(rule)
            if rule["force_level"] == "full":
                forced_level = "full"
            elif rule["force_level"] and forced_level != "full":
                forced_level = rule["force_level"]
            forced_checks.extend(rule["require_checks"])
    return matched, forced_level, sorted(set(forced_checks))


def _match_any_paths(changed_paths, patterns):
    return any(_match_any(p, patterns) for p in changed_paths)


# --- level / selection resolution (spec sections 11, 20, 21) ----------------

def resolve_effective_level(normalized, requested_level, changed_paths, prior_summary=None):
    """Returns (effective_level, fallback_reason, matched_risk_rules,
    matched_services, match_detail, unmatched_paths). `requested_level` may
    be None (use defaults.level)."""
    defaults = normalized["defaults"]
    services = normalized["services"]
    level = requested_level or defaults["level"]
    if level not in LEVELS:
        raise ConfigError("requested_level must be one of %s (got %r)" % (LEVELS, level))

    matched_services, match_detail, unmatched = match_services(services, changed_paths)
    matched_rules, forced_level, forced_checks = evaluate_risk_rules(normalized["risk_rules"], changed_paths)

    fallback_reason = None
    effective = level

    if level == "changed":
        if unmatched:
            effective = defaults["changed_fallback"]
            fallback_reason = (
                "%d changed path(s) matched no configured service (%s); falling back to the configured "
                "changed_fallback level '%s' (spec 0026, section 15.3/11.1)"
                % (len(unmatched), ", ".join(sorted(unmatched)[:5]), defaults["changed_fallback"])
            )
        if forced_level == "full" and effective != "full":
            effective = "full"
            fallback_reason = (fallback_reason or "") + (
                " " if fallback_reason else ""
            ) + "escalated to 'full' by matched risk rule(s): %s" % ", ".join(r["name"] for r in matched_rules if r["force_level"] == "full")

    elif level == "flexible":
        # Deterministic resolution (spec section 11.3): documented rule
        # order — see 08-executor-summary.md, "Selection and Dependency
        # Rules" for the full rationale. 1) start from `changed` resolution
        # (itself already fallback/risk-aware); 2) any matched risk rule
        # forcing full wins outright; 3) more than one distinct affected
        # service escalates to full (cross-service change risk); 4) a prior
        # recorded required-check failure for this task escalates to full;
        # 5) otherwise stay at the `changed` resolution.
        base_effective, base_reason, matched_rules, matched_services, match_detail, unmatched = resolve_effective_level(
            normalized, "changed", changed_paths, prior_summary
        )
        effective = base_effective
        reasons = [base_reason] if base_reason else []
        if forced_level == "full":
            effective = "full"
            reasons.append(
                "flexible: escalated to 'full' by matched risk rule(s): %s"
                % ", ".join(r["name"] for r in matched_rules if r["force_level"] == "full")
            )
        elif len(matched_services) > 1 and effective != "full":
            effective = "full"
            reasons.append(
                "flexible: escalated to 'full' because %d distinct services were affected by this change"
                % len(matched_services)
            )
        elif prior_summary and _has_prior_required_failure(prior_summary) and effective != "full":
            effective = "full"
            reasons.append("flexible: escalated to 'full' because a prior recorded required check failed for this task")
        if not reasons:
            reasons.append("flexible: no escalation condition matched; resolved to '%s'" % effective)
        fallback_reason = " | ".join(reasons)

    return effective, fallback_reason, matched_rules, matched_services, match_detail, unmatched


def _has_prior_required_failure(prior_summary):
    for chk in prior_summary.get("checks", []):
        if chk.get("required") and chk.get("status") not in ("PASSED",):
            return True
    return False


def _by_identity(services):
    out = {}
    for svc in services:
        for chk in svc["checks"]:
            out[chk["identity"]] = (svc, chk)
    return out


def select_checks(normalized, phase, requested_level, changed_paths, prior_summary=None):
    """Full selection algorithm (spec sections 11, 20, 21). Returns a dict
    with everything 26-verification-plan.json needs plus the internal
    execution order."""
    placement = normalized["placement"]
    services = normalized["services"]
    by_identity = _by_identity(services)

    phase_placement = placement.get(phase, "changed") if phase else requested_level

    if requested_level:
        working_level = requested_level
        targeted_narrowing = False
    elif phase_placement == "none":
        return {
            "requested_level": requested_level,
            "effective_level": "none",
            "phase": phase,
            "changed_paths": list(changed_paths),
            "matched_risk_rules": [],
            "selected_services": [],
            "selected_checks": [],
            "skipped_checks": [
                {"identity": c["identity"], "reason": "placement for phase '%s' is 'none'" % phase}
                for s in services for c in s["checks"]
            ],
            "fallback_reason": None,
            "concurrency": normalized["defaults"]["concurrency"],
            "changed_path_service_matches": {},
            "unmatched_paths": [],
            "_execution_order": [],
        }
    elif phase_placement == "targeted":
        working_level = "changed"
        targeted_narrowing = True
    else:
        working_level = phase_placement
        targeted_narrowing = False

    effective_level, fallback_reason, matched_rules, matched_services, match_detail, unmatched = resolve_effective_level(
        normalized, working_level, changed_paths, prior_summary
    )
    forced_checks = sorted(set(c for r in matched_rules for c in r["require_checks"]))

    selected = set()
    skipped = {}

    for svc in services:
        service_matched = svc["name"] in matched_services or effective_level == "full"
        for chk in svc["checks"]:
            identity = chk["identity"]
            if not chk["enabled"]:
                skipped[identity] = "disabled (enabled: false)"
                continue
            if effective_level not in chk["levels"] and identity not in forced_checks:
                skipped[identity] = "level '%s' not in configured levels %s" % (effective_level, chk["levels"])
                continue
            if effective_level != "full" and not service_matched and identity not in forced_checks:
                skipped[identity] = "service '%s' not affected by changed paths" % svc["name"]
                continue
            if targeted_narrowing and not chk["required"] and identity not in forced_checks:
                skipped[identity] = "optional check excluded by 'targeted' placement narrowing (spec section 21.2)"
                continue
            selected.add(identity)

    # Dependency auto-inclusion (spec section 17: "not start a check before
    # all required dependencies pass") — transitive closure over depends_on.
    changed_by_inclusion = True
    while changed_by_inclusion:
        changed_by_inclusion = False
        for identity in list(selected):
            _, chk = by_identity[identity]
            for dep in chk["depends_on"]:
                if dep not in selected:
                    selected.add(dep)
                    skipped.pop(dep, None)
                    changed_by_inclusion = True

    for identity in selected:
        skipped.pop(identity, None)

    # Deterministic ordering (spec section 18.2): service declaration order,
    # then check declaration order — used as the execution/report order
    # BEFORE dependency-level scheduling reorders execution start times.
    declared_order = []
    for svc in services:
        for chk in svc["checks"]:
            if chk["identity"] in selected:
                declared_order.append(chk["identity"])

    return {
        "requested_level": requested_level,
        "effective_level": effective_level,
        "phase": phase,
        "changed_paths": list(changed_paths),
        "matched_risk_rules": [r["name"] for r in matched_rules],
        "selected_services": sorted({by_identity[i][0]["name"] for i in selected}),
        "selected_checks": declared_order,
        "skipped_checks": [{"identity": k, "reason": v} for k, v in sorted(skipped.items())],
        "fallback_reason": fallback_reason,
        "concurrency": normalized["defaults"]["concurrency"],
        # spec section 11.1: "The engine must explain: which files changed;
        # which service each file matched; ... why the selection was safe."
        "changed_path_service_matches": match_detail,
        "unmatched_paths": unmatched,
        "_execution_order": declared_order,
    }


# --- dependency-respecting bounded parallel execution (spec sections 17-20) -

def _command_json(svc, chk):
    return {
        "service": svc["name"],
        "check": chk["name"],
        "identity": chk["identity"],
        "kind": chk["kind"],
        "command": chk["command"],
        "cwd": chk["cwd"],
        "timeout_seconds": chk["timeout_seconds"],
        "required": chk["required"],
        "dependencies": list(chk["depends_on"]),
        "parallel_group": chk["parallel_group"],
        "environment_names": list(chk["environment"]),
        "redacted_names": sorted(n for n in chk["environment"] if _secret_shaped(n)),
    }


def _run_one_check(root, shell, svc, chk, evidence_dir):
    identity = chk["identity"]
    check_dir = os.path.join(evidence_dir, "services", svc["name"], chk["name"])
    os.makedirs(check_dir, exist_ok=True)
    _write_json(os.path.join(check_dir, "command.json"), _command_json(svc, chk))

    stdout_path = os.path.join(check_dir, "stdout.txt")
    stderr_path = os.path.join(check_dir, "stderr.txt")
    cwd = os.path.join(root, chk["cwd"]) if chk["cwd"] != "." else root

    started_at = _now_iso()
    result = {
        "schema_version": SCHEMA_VERSION,
        "identity": identity,
        "required": chk["required"],
        "started_at": started_at,
        "stdout_path": "stdout.txt",
        "stderr_path": "stderr.txt",
    }

    if not os.path.isdir(cwd):
        result.update({
            "status": "CONFIGURATION_ERROR" if chk["required"] else "BLOCKED_OPTIONAL",
            "exit_code": None,
            "finished_at": _now_iso(),
            "duration_seconds": 0.0,
            "timed_out": False,
            "blocked_by": [],
            "reason": "configured cwd does not exist: %s" % chk["cwd"],
        })
        open(stdout_path, "w").close()
        open(stderr_path, "w").close()
        _write_json(os.path.join(check_dir, "result.json"), result)
        return result

    proc = None
    timed_out = False
    try:
        with open(stdout_path, "w") as out_f, open(stderr_path, "w") as err_f:
            proc = subprocess.Popen(
                [shell, "-c", chk["command"]],
                cwd=cwd,
                stdout=out_f,
                stderr=err_f,
                env=os.environ.copy(),
                start_new_session=True,
            )
            try:
                exit_code = proc.wait(timeout=chk["timeout_seconds"])
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    pass
                proc.wait()
                exit_code = proc.returncode
    except OSError as exc:
        result.update({
            "status": "CONFIGURATION_ERROR" if chk["required"] else "BLOCKED_OPTIONAL",
            "exit_code": None,
            "finished_at": _now_iso(),
            "duration_seconds": 0.0,
            "timed_out": False,
            "blocked_by": [],
            "reason": "failed to launch check: %s" % exc,
        })
        _write_json(os.path.join(check_dir, "result.json"), result)
        return result

    finished_at = _now_iso()
    started_dt = datetime.strptime(started_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    finished_dt = datetime.strptime(finished_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    duration = (finished_dt - started_dt).total_seconds()

    if timed_out:
        status = "TIMED_OUT" if chk["required"] else "TIMED_OUT_OPTIONAL"
    elif exit_code == 0:
        status = "PASSED"
    else:
        status = "FAILED" if chk["required"] else "FAILED_OPTIONAL"

    result.update({
        "status": status,
        "exit_code": exit_code,
        "finished_at": finished_at,
        "duration_seconds": duration,
        "timed_out": timed_out,
        "blocked_by": [],
    })
    _write_json(os.path.join(check_dir, "result.json"), result)
    return result


def execute_checks(normalized, plan, root, evidence_dir):
    """Bounded, dependency-respecting parallel execution (spec sections 17,
    18, 45). Checks with zero pending dependencies are submitted in
    "waves" to a ThreadPoolExecutor bounded by `concurrency` — a check is
    only ever submitted once every dependency has ALREADY finished (never
    submitted-then-blocked-inside-a-worker), so the concurrency bound can
    never deadlock waiting on a dependency that has no free worker."""
    by_identity = _by_identity(normalized["services"])
    selected = list(plan["_execution_order"])
    concurrency = max(1, plan["concurrency"])
    shell = normalized["defaults"]["shell"]

    results = {}
    lock = threading.Lock()
    remaining_deps = {}
    dependents = {i: [] for i in selected}
    for identity in selected:
        _, chk = by_identity[identity]
        deps = [d for d in chk["depends_on"] if d in selected]
        remaining_deps[identity] = len(deps)
        for d in deps:
            dependents[d].append(identity)

    def mark_blocked(identity, blocked_by):
        svc, chk = by_identity[identity]
        status = "BLOCKED_BY_DEPENDENCY" if chk["required"] else "BLOCKED_OPTIONAL"
        result = {
            "schema_version": SCHEMA_VERSION,
            "identity": identity,
            "required": chk["required"],
            "status": status,
            "exit_code": None,
            "started_at": None,
            "finished_at": _now_iso(),
            "duration_seconds": 0.0,
            "timed_out": False,
            "blocked_by": blocked_by,
            "stdout_path": "stdout.txt",
            "stderr_path": "stderr.txt",
        }
        check_dir = os.path.join(evidence_dir, "services", svc["name"], chk["name"])
        os.makedirs(check_dir, exist_ok=True)
        _write_json(os.path.join(check_dir, "command.json"), _command_json(svc, chk))
        open(os.path.join(check_dir, "stdout.txt"), "w").close()
        open(os.path.join(check_dir, "stderr.txt"), "w").close()
        _write_json(os.path.join(check_dir, "result.json"), result)
        results[identity] = result

    ready = [i for i in selected if remaining_deps[i] == 0]

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        pending_futures = {}

        def submit_wave(wave):
            for identity in wave:
                svc, chk = by_identity[identity]
                fut = pool.submit(_run_one_check, root, shell, svc, chk, evidence_dir)
                pending_futures[fut] = identity

        submit_wave(ready)

        while pending_futures:
            done = []
            for fut in list(pending_futures):
                if fut.done():
                    done.append(fut)
            if not done:
                import time
                time.sleep(0.02)
                continue
            newly_ready = []
            for fut in done:
                identity = pending_futures.pop(fut)
                with lock:
                    result = fut.result()
                    results[identity] = result
                    passed = result["status"] == "PASSED"
                    to_cascade = [identity] if not passed else []
                    for dep_child in dependents.get(identity, []):
                        remaining_deps[dep_child] -= 1
                        if not passed:
                            # A failed/blocked dependency cascades to every
                            # transitive dependent, never merely its direct
                            # child (spec section 17).
                            mark_blocked(dep_child, blocked_by=[identity])
                            remaining_deps[dep_child] = -1  # never submit
                            to_cascade.append(dep_child)
                        elif remaining_deps[dep_child] == 0:
                            newly_ready.append(dep_child)
                    # cascade further for any just-blocked dependents
                    frontier = to_cascade
                    while frontier:
                        nxt = []
                        for blocked_id in frontier:
                            for grandchild in dependents.get(blocked_id, []):
                                if remaining_deps.get(grandchild, 0) >= 0:
                                    mark_blocked(grandchild, blocked_by=[blocked_id])
                                    remaining_deps[grandchild] = -1
                                    nxt.append(grandchild)
                        frontier = nxt
            submit_wave(newly_ready)

    return results


# --- overall status classification (spec section 32) -----------------------

def classify_overall(plan, results):
    selected = plan["_execution_order"]
    if not selected:
        return "NOT_REQUIRED"
    required_ids = [i for i in selected if results.get(i, {}).get("required")]
    if not required_ids:
        return "NOT_REQUIRED"
    statuses = [results[i]["status"] for i in required_ids]
    blocking = {"BLOCKED", "BLOCKED_BY_DEPENDENCY", "CONFIGURATION_ERROR"}
    failing = {"FAILED", "TIMED_OUT"}
    if any(s in blocking for s in statuses):
        return "BLOCKED"
    if any(s in failing for s in statuses):
        return "FAILED"
    if all(s == "PASSED" for s in statuses):
        return "PASSED"
    return "FAILED"


# --- effective-configuration capture / drift (spec section 51) -------------

def check_config_drift(task_dir, normalized):
    """Returns None if this is the first planning pass for this task (the
    digest is captured), or if the captured digest still matches. Returns a
    detail string (refusal reason) on drift — the caller must refuse to
    proceed rather than silently switching policy."""
    path = os.path.join(task_dir, EVIDENCE_DIRNAME, EFFECTIVE_CONFIG_FILENAME)
    digest = config_digest(normalized)
    if not os.path.isfile(path):
        _write_json(path, {"schema_version": SCHEMA_VERSION, "digest": digest, "mode": normalized["mode"], "captured_at": _now_iso()})
        return None
    with open(path) as f:
        captured = json.load(f)
    if captured.get("digest") != digest:
        return (
            "the project's verification configuration changed since this task first captured it at %s "
            "(captured mode=%s, digest=%s; current mode=%s, digest=%s) — resume refuses to silently switch "
            "policy (spec 0026, section 51); this requires explicit human recovery (e.g. revert the "
            "configuration change, or remove %s to intentionally re-capture the new policy for this task)"
            % (captured.get("captured_at"), captured.get("mode"), captured.get("digest"), normalized["mode"], digest, path)
        )
    return None


# --- duplicate execution detection (spec section 39) ------------------------

def detect_duplicate(task_dir, task_id, iteration, phase, normalized, tree_digest):
    ledger_path = os.path.join(task_dir, EVIDENCE_DIRNAME, RUN_LEDGER_FILENAME)
    run_key = {
        "task_id": task_id,
        "iteration": iteration,
        "phase": phase,
        "config_digest": config_digest(normalized),
        "tree_digest": tree_digest,
    }
    entries = []
    if os.path.isfile(ledger_path):
        with open(ledger_path) as f:
            entries = json.load(f).get("runs", [])
    duplicate_of = None
    for e in entries:
        if all(e.get(k) == v for k, v in run_key.items()):
            duplicate_of = e.get("recorded_at")
            break
    entries.append(dict(run_key, recorded_at=_now_iso()))
    _write_json(ledger_path, {"schema_version": SCHEMA_VERSION, "runs": entries})
    return duplicate_of


def _tree_digest(root):
    try:
        out = subprocess.run(["git", "-C", root, "status", "--porcelain"], capture_output=True, text=True, timeout=30)
        head = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=30)
        blob = (head.stdout or "") + "\n" + (out.stdout or "")
        return hashlib.sha256(blob.encode("utf-8")).hexdigest()
    except Exception:
        return "unavailable"


# --- selection-request validation (spec sections 23, 24) -------------------

def validate_check_request(normalized, phase, requested_level, requested_checks, changed_paths):
    """A role (Executor/Reviewer/Coordinator) may request a narrower named
    check set, but may never submit arbitrary command text, refer to an
    unknown check, or disable a required check (spec section 23). Returns
    the validated plan (same shape as select_checks) or raises ConfigError."""
    plan = select_checks(normalized, phase, requested_level, changed_paths)
    if not requested_checks:
        return plan

    by_identity = _by_identity(normalized["services"])
    unknown = [c for c in requested_checks if c not in by_identity]
    if unknown:
        raise ConfigError("requested check(s) not configured: %s" % ", ".join(sorted(unknown)))

    required_selected = {i for i in plan["_execution_order"] if by_identity[i][1]["required"]}
    missing_required = required_selected - set(requested_checks)
    if missing_required:
        raise ConfigError(
            "request excludes required check(s) %s that policy selected for this phase/level — a role may "
            "narrow OPTIONAL checks only, never disable a required check (spec section 23)"
            % ", ".join(sorted(missing_required))
        )

    narrowed = [i for i in plan["_execution_order"] if i in requested_checks]
    skipped = list(plan["skipped_checks"])
    for i in plan["_execution_order"]:
        if i not in narrowed:
            skipped.append({"identity": i, "reason": "excluded by an explicit (policy-permitted) narrower check request"})
    plan = dict(plan)
    plan["selected_checks"] = narrowed
    plan["_execution_order"] = narrowed
    plan["selected_services"] = sorted({by_identity[i][0]["name"] for i in narrowed})
    plan["skipped_checks"] = skipped
    return plan


# --- rendering ---------------------------------------------------------------

def render_summary_md(summary):
    lines = []
    lines.append("# Verification Summary")
    lines.append("")
    lines.append("- Requested level: %s" % summary["requested_level"])
    lines.append("- Effective level: %s" % summary["effective_level"])
    lines.append("- Phase: %s" % summary["phase"])
    lines.append("- Overall status: **%s**" % summary["overall_status"])
    lines.append("- Required: %d passed / %d failed" % (summary["required_passed"], summary["required_failed"]))
    lines.append("- Optional: %d passed / %d failed" % (summary["optional_passed"], summary["optional_failed"]))
    lines.append("- Fallback reason: %s" % (summary["fallback_reason"] or "(none)"))
    lines.append("- Matched risk rules: %s" % (", ".join(summary["matched_risk_rules"]) or "(none)"))
    lines.append("- Duplicate of a prior run: %s" % (summary["duplicate_of"] or "no"))
    lines.append("- Started: %s" % summary["started_at"])
    lines.append("- Finished: %s" % summary["finished_at"])
    lines.append("- Duration: %.1fs" % summary["duration_seconds"])
    lines.append("")
    lines.append("| Identity | Required | Status | Exit | Duration | Evidence |")
    lines.append("|---|---|---|---|---|---|")
    for chk in summary["checks"]:
        lines.append(
            "| %s | %s | %s | %s | %.1fs | %s |"
            % (
                chk["identity"], "yes" if chk["required"] else "no", chk["status"],
                chk["exit_code"] if chk["exit_code"] is not None else "-",
                chk.get("duration_seconds") or 0.0, chk["evidence_dir"],
            )
        )
    if summary["skipped_checks"]:
        lines.append("")
        lines.append("## Skipped checks")
        for s in summary["skipped_checks"]:
            lines.append("- %s: %s" % (s["identity"], s["reason"]))
    return "\n".join(lines) + "\n"


def render_report_text(summary):
    lines = []
    lines.append("Verification -- %s" % summary["overall_status"])
    lines.append("  Requested/effective level: %s / %s" % (summary["requested_level"], summary["effective_level"]))
    lines.append("  Phase:                     %s" % summary["phase"])
    lines.append("  Selected services/checks:  %d / %d" % (len(summary["selected_services"]), len(summary["checks"])))
    lines.append("  Required failures:         %d" % summary["required_failed"])
    lines.append("  Optional failures:         %d" % summary["optional_failed"])
    lines.append("  Evidence:                  %s" % summary["evidence_root"])
    return "\n".join(lines) + "\n"


# --- top-level plan / execute orchestration ---------------------------------

def build_plan_artifact(plan):
    return {
        "schema_version": SCHEMA_VERSION,
        "requested_level": plan["requested_level"],
        "effective_level": plan["effective_level"],
        "phase": plan["phase"],
        "changed_paths": plan["changed_paths"],
        "changed_path_service_matches": plan["changed_path_service_matches"],
        "unmatched_paths": plan["unmatched_paths"],
        "matched_risk_rules": plan["matched_risk_rules"],
        "selected_services": plan["selected_services"],
        "selected_checks": plan["selected_checks"],
        "skipped_checks": plan["skipped_checks"],
        "fallback_reason": plan["fallback_reason"],
        "concurrency": plan["concurrency"],
        "generated_at": _now_iso(),
    }


def write_plan_artifacts(task_dir, plan):
    _write_json(os.path.join(task_dir, PLAN_FILENAME), build_plan_artifact(plan))
    _write_json(
        os.path.join(task_dir, EVIDENCE_DIRNAME, SELECTION_FILENAME),
        {
            "schema_version": SCHEMA_VERSION,
            "phase": plan["phase"],
            "requested_level": plan["requested_level"],
            "effective_level": plan["effective_level"],
            "selected_services": plan["selected_services"],
            "selected_checks": plan["selected_checks"],
            "skipped_checks": plan["skipped_checks"],
            "matched_risk_rules": plan["matched_risk_rules"],
            "fallback_reason": plan["fallback_reason"],
            "changed_path_service_matches": plan["changed_path_service_matches"],
            "unmatched_paths": plan["unmatched_paths"],
        },
    )


def build_summary(normalized, plan, results, started_at, finished_at, duplicate_of):
    by_identity = _by_identity(normalized["services"])
    checks = []
    required_passed = required_failed = optional_passed = optional_failed = 0
    for identity in plan["_execution_order"]:
        r = results.get(identity, {})
        svc, chk = by_identity[identity]
        status = r.get("status", "CONFIGURATION_ERROR")
        checks.append({
            "identity": identity,
            "service": svc["name"],
            "check": chk["name"],
            "required": chk["required"],
            "status": status,
            "exit_code": r.get("exit_code"),
            "duration_seconds": r.get("duration_seconds"),
            "timed_out": r.get("timed_out", False),
            "blocked_by": r.get("blocked_by", []),
            "evidence_dir": os.path.join(EVIDENCE_DIRNAME, "services", svc["name"], chk["name"]),
        })
        if chk["required"]:
            if status == "PASSED":
                required_passed += 1
            else:
                required_failed += 1
        else:
            if status == "PASSED":
                optional_passed += 1
            else:
                optional_failed += 1

    overall = classify_overall(plan, results)
    started_dt = datetime.strptime(started_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    finished_dt = datetime.strptime(finished_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

    return {
        "schema_version": SCHEMA_VERSION,
        "requested_level": plan["requested_level"],
        "effective_level": plan["effective_level"],
        "phase": plan["phase"],
        "overall_status": overall,
        "required_passed": required_passed,
        "required_failed": required_failed,
        "optional_passed": optional_passed,
        "optional_failed": optional_failed,
        "selected_services": plan["selected_services"],
        "checks": checks,
        "skipped_checks": plan["skipped_checks"],
        "matched_risk_rules": plan["matched_risk_rules"],
        "fallback_reason": plan["fallback_reason"],
        "duplicate_of": duplicate_of,
        "started_at": started_at,
        "finished_at": finished_at,
        "duration_seconds": (finished_dt - started_dt).total_seconds(),
        "final_gate_satisfied": overall in ("PASSED", "NOT_REQUIRED"),
        "evidence_root": EVIDENCE_DIRNAME + "/",
    }


# --- CLI ----------------------------------------------------------------------

def _read_stdin_json():
    raw = sys.stdin.read()
    try:
        return json.loads(raw) if raw.strip() else {}
    except ValueError as exc:
        print("verification_policy_lib.py: invalid JSON on stdin: %s" % exc, file=sys.stderr)
        sys.exit(2)


def _mode_cmd():
    payload = _read_stdin_json()
    try:
        normalized = normalize_config(payload.get("raw_config", {}))
        print(normalized["mode"])
        for w in normalized.get("warnings", []):
            print("warning: %s" % w)
    except ConfigError as exc:
        print("invalid: %s" % exc)
    return 0


def _doctor_summary_cmd():
    """Read-only structured summary for `specrelay doctor` (spec section
    35) — never executes a configured command."""
    payload = _read_stdin_json()
    try:
        normalized = normalize_config(payload.get("raw_config", {}))
    except ConfigError as exc:
        print(json.dumps({"mode": "invalid", "error": str(exc)}))
        return 0
    service_count = len(normalized["services"])
    check_count = sum(len(s["checks"]) for s in normalized["services"])
    missing_roots = [
        s["name"] for s in normalized["services"]
        if s["root"] != "." and not os.path.isdir(os.path.join(payload.get("root", "."), s["root"]))
    ]
    print(json.dumps({
        "mode": normalized["mode"],
        "version": normalized["version"],
        "defaults": normalized["defaults"],
        "placement": normalized["placement"],
        "service_count": service_count,
        "check_count": check_count,
        "warnings": normalized["warnings"],
        "missing_service_roots": missing_roots,
    }, sort_keys=True))
    return 0


def _plan_cmd(argv):
    as_json = "--json" in argv
    payload = _read_stdin_json()
    try:
        normalized = normalize_config(payload.get("raw_config", {}))
    except ConfigError as exc:
        print("verification plan: INVALID configuration — %s" % exc, file=sys.stderr)
        return 1

    task_dir = payload.get("task_dir")
    if task_dir:
        drift = check_config_drift(task_dir, normalized)
        if drift:
            print("verification plan: refused — %s" % drift, file=sys.stderr)
            return 1

    plan = select_checks(
        normalized, payload.get("phase"), payload.get("requested_level"),
        payload.get("changed_paths", []), payload.get("prior_summary"),
    )
    if task_dir:
        write_plan_artifacts(task_dir, plan)

    artifact = build_plan_artifact(plan)
    if as_json:
        print(json.dumps(artifact, indent=2, sort_keys=True))
    else:
        print("Verification plan")
        print("  requested_level: %s" % artifact["requested_level"])
        print("  effective_level: %s" % artifact["effective_level"])
        print("  phase: %s" % artifact["phase"])
        if artifact["changed_path_service_matches"]:
            print("  changed_path_service_matches:")
            for svc, paths in sorted(artifact["changed_path_service_matches"].items()):
                print("    %s: %s" % (svc, ", ".join(paths)))
        if artifact["unmatched_paths"]:
            print("  unmatched_paths: %s" % ", ".join(artifact["unmatched_paths"]))
        print("  selected_services: %s" % ", ".join(artifact["selected_services"]) or "(none)")
        print("  selected_checks: %s" % (", ".join(artifact["selected_checks"]) or "(none)"))
        print("  skipped_checks: %d" % len(artifact["skipped_checks"]))
        for s in artifact["skipped_checks"]:
            print("    - %s: %s" % (s["identity"], s["reason"]))
        print("  matched_risk_rules: %s" % (", ".join(artifact["matched_risk_rules"]) or "(none)"))
        print("  fallback_reason: %s" % (artifact["fallback_reason"] or "(none)"))
        print("  concurrency: %s" % artifact["concurrency"])
    return 0


def _execute_cmd(argv):
    as_json = "--json" in argv
    payload = _read_stdin_json()
    try:
        normalized = normalize_config(payload.get("raw_config", {}))
    except ConfigError as exc:
        print("verification run: INVALID configuration — %s" % exc, file=sys.stderr)
        return 1

    task_dir = payload["task_dir"]
    root = payload["root"]
    task_id = payload.get("task_id", "")
    iteration = payload.get("iteration", 1)

    drift = check_config_drift(task_dir, normalized)
    if drift:
        print("verification run: refused — %s" % drift, file=sys.stderr)
        return 1

    requested_checks = payload.get("requested_checks") or []
    try:
        if requested_checks:
            plan = validate_check_request(
                normalized, payload.get("phase"), payload.get("requested_level"),
                requested_checks, payload.get("changed_paths", []),
            )
        else:
            plan = select_checks(
                normalized, payload.get("phase"), payload.get("requested_level"),
                payload.get("changed_paths", []), payload.get("prior_summary"),
            )
    except ConfigError as exc:
        print("verification run: rejected request — %s" % exc, file=sys.stderr)
        return 1

    write_plan_artifacts(task_dir, plan)
    evidence_dir = os.path.join(task_dir, EVIDENCE_DIRNAME)

    tree_digest = _tree_digest(root)
    duplicate_of = detect_duplicate(task_dir, task_id, iteration, payload.get("phase"), normalized, tree_digest)

    started_at = _now_iso()
    results = execute_checks(normalized, plan, root, evidence_dir)
    finished_at = _now_iso()

    summary = build_summary(normalized, plan, results, started_at, finished_at, duplicate_of)
    _write_json(os.path.join(task_dir, SUMMARY_JSON_FILENAME), summary)
    _atomic_write(os.path.join(task_dir, SUMMARY_MD_FILENAME), render_summary_md(summary))

    if as_json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(render_report_text(summary))
    return 0 if summary["overall_status"] in ("PASSED", "NOT_REQUIRED") else 1


def _report_cmd(argv):
    positional = [a for a in argv if not a.startswith("--")]
    as_json = "--json" in argv
    if not positional:
        print("usage: verification_policy_lib.py report <task_dir> [--json]", file=sys.stderr)
        return 2
    task_dir = positional[0]
    path = os.path.join(task_dir, SUMMARY_JSON_FILENAME)
    if not os.path.isfile(path):
        if as_json:
            print(json.dumps({"recorded": False}))
        else:
            print("Verification policy: not recorded")
        return 0
    with open(path) as f:
        summary = json.load(f)
    if as_json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(render_report_text(summary))
    return 0


def _check_request_cmd():
    payload = _read_stdin_json()
    try:
        normalized = normalize_config(payload.get("raw_config", {}))
        plan = validate_check_request(
            normalized, payload.get("phase"), payload.get("requested_level"),
            payload.get("requested_checks") or [], payload.get("changed_paths", []),
        )
    except ConfigError as exc:
        print(json.dumps({"valid": False, "error": str(exc)}))
        return 1
    print(json.dumps({"valid": True, "plan": build_plan_artifact(plan)}, sort_keys=True))
    return 0


def main(argv):
    if not argv:
        print("usage: verification_policy_lib.py <mode|doctor-summary|plan|execute|report|check-request> ...", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "mode":
        return _mode_cmd()
    if cmd == "doctor-summary":
        return _doctor_summary_cmd()
    if cmd == "plan":
        return _plan_cmd(rest)
    if cmd == "execute":
        return _execute_cmd(rest)
    if cmd == "report":
        return _report_cmd(rest)
    if cmd == "check-request":
        return _check_request_cmd()
    print("verification_policy_lib.py: unknown command %r" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
