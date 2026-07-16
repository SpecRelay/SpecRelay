"""ui_verification_lib.py — deterministic UI runtime verification engine
(spec 0028, "UI Runtime Verification and Compact Review Evidence").

This module is the deterministic core described by the spec's architectural
decision (section 6): a browser automation provider (Playwright, or the
deterministic fake provider used by this project's OWN test suite) supplies
RAW execution facts (step/assertion outcomes, console/network events, raw
screenshot bytes); this module alone owns configuration parsing/validation,
scenario-schema validation, UI-impact detection, scenario selection,
screenshot cropping/dedup/size policy, console/network redaction, expected-
reference comparison, PASS/FAIL/BLOCKED classification, runtime-artifact
writing, compact publication, and the Reviewer/completion-gate check. AI
never fabricates a screenshot, a browser result, or a successful step — every
fact recorded here traces back to a provider call this module made itself.

Architecture note (mirrors verification_policy_lib.py's division of labor):
YAML parsing of both `.specrelay/config.yml`'s `verification.ui` section and
the scenario manifest happens in Ruby (config.sh /
ui_verification.sh, using YAML.safe_load); this module receives already-
parsed JSON and owns everything past that point.

CLI convention: every subcommand takes a single JSON object on stdin (never
positional argv for structured data) plus a few argv flags, mirroring
verification_policy_lib.py / coordinator_lib.py.
"""

import hashlib
import http.client
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zlib
from datetime import datetime, timezone

SCHEMA_VERSION = 1

RUNTIME_DIRNAME = "29-ui-verification"
PLAN_JSON = "plan.json"
ENVIRONMENT_JSON = "environment.json"
RUNTIME_LOG = "runtime.log"
SUMMARY_JSON = "summary.json"
SUMMARY_MD = "summary.md"
CONSOLE_ERRORS_JSON = "console-errors.json"
NETWORK_ERRORS_JSON = "network-errors.json"

ENABLED_MODES = ("true", "false", "auto")  # normalized string form; YAML bool True/False also accepted
PROVIDERS = ("playwright", "fake")
KNOWN_BROWSERS = ("chromium", "firefox", "webkit")
SCREENSHOT_MODES = ("checkpoints", "off")
CROP_MODES = ("important-region", "full-viewport", "full-page")
SCREENSHOT_FORMATS = ("png", "jpeg")
VIDEO_MODES = ("off", "on-failure", "explicit")
TRACE_MODES = ("off", "on-failure", "always")
CONSOLE_LEVELS = ("error", "warning")
REFERENCE_POLICIES = ("ignore", "compare-when-present", "required")
PUBLICATION_DESTINATIONS = ("spec-directory",)

KNOWN_STEP_ACTIONS = ("goto", "click", "fill", "select", "check", "uncheck", "hover", "press", "wait_for")
KNOWN_ASSERTION_TYPES = ("visible", "absent", "text", "value", "url", "count")

RESULTS = ("PASS", "FAIL", "BLOCKED")

# Specification-language signals (spec section 12.3): pages, forms, buttons,
# links, views, layouts, browser behaviour, screenshots, Playwright, CSS,
# JavaScript, templates, or visual acceptance criteria.
UI_KEYWORDS = (
    "page", "pages", "form", "forms", "button", "buttons", "link", "links",
    "view", "views", "layout", "layouts", "browser", "screenshot",
    "screenshots", "playwright", "css", "javascript", "template",
    "templates", "visual",
)

_SECRET_KEY_MARKERS = (
    "authorization", "cookie", "token", "session", "apikey", "api_key",
    "secret", "password", "credential",
)


class ConfigError(Exception):
    pass


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _atomic_write(path, text):
    dir_name = os.path.dirname(path) or "."
    os.makedirs(dir_name, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".ui-verification.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _atomic_write_bytes(path, data):
    dir_name = os.path.dirname(path) or "."
    os.makedirs(dir_name, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dir_name, prefix=".ui-verification.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _write_json(path, obj):
    _atomic_write(path, json.dumps(obj, indent=2, sort_keys=True) + "\n")


# --- configuration -----------------------------------------------------------

def _default_ui_config():
    return {
        "enabled": "auto",
        "required_when_detected": True,
        "provider": "playwright",
        "browsers": ["chromium"],
        "detection": {"paths": []},
        "runtime": {
            "start_command": None,
            "working_directory": ".",
            "ready_url": None,
            "ready_timeout_seconds": 120,
            "stop_command": None,
        },
        "scenarios": {"manifest": ".specrelay/ui-scenarios.yml"},
        "screenshots": {
            "mode": "checkpoints",
            "retain_source": False,
            "crop": "important-region",
            "max_width": 1600,
            "max_height": 1200,
            "max_file_bytes": 750000,
            "format": "png",
        },
        "video": {"mode": "off"},
        "trace": {"mode": "on-failure"},
        "console": {"fail_on": ["error"]},
        "network": {"fail_on_status": ["500-599"]},
        "expected_references": {"policy": "compare-when-present"},
        "publication": {"enabled": True, "destination": "spec-directory", "path": "verification/ui"},
    }


def _merge(defaults, override):
    if not isinstance(override, dict):
        return defaults
    out = dict(defaults)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(defaults.get(k), dict):
            out[k] = _merge(defaults[k], v)
        else:
            out[k] = v
    return out


def _require_keys(mapping, allowed, where):
    if not isinstance(mapping, dict):
        raise ConfigError("%s is not a mapping (got %s)" % (where, type(mapping).__name__))
    unknown = [k for k in mapping.keys() if k not in allowed]
    if unknown:
        raise ConfigError(
            "%s has unknown key(s) %s; recognized keys: %s"
            % (where, ", ".join(repr(k) for k in unknown), ", ".join(allowed))
        )


def normalize_ui_config(raw):
    """Validates and normalizes `verification.ui` (spec section 10). Raises
    ConfigError on any structural problem. Returns the merged, normalized
    mapping — missing configuration resolves entirely to the documented
    defaults (backward compatible with projects that configure nothing)."""
    defaults = _default_ui_config()
    if raw in (None, {}):
        return defaults
    if not isinstance(raw, dict):
        raise ConfigError("verification.ui is not a mapping (got %s)" % type(raw).__name__)

    _require_keys(raw, list(defaults.keys()), "verification.ui")
    cfg = _merge(defaults, raw)

    enabled = cfg["enabled"]
    if isinstance(enabled, bool):
        pass
    elif enabled != "auto":
        raise ConfigError("verification.ui.enabled must be true, false, or 'auto' (got %r)" % (enabled,))

    if not isinstance(cfg["required_when_detected"], bool):
        raise ConfigError("verification.ui.required_when_detected must be a boolean")

    if cfg["provider"] not in PROVIDERS:
        raise ConfigError("verification.ui.provider must be one of %s (got %r)" % (", ".join(PROVIDERS), cfg["provider"]))

    if not isinstance(cfg["browsers"], list) or not cfg["browsers"]:
        raise ConfigError("verification.ui.browsers must be a non-empty list")
    for b in cfg["browsers"]:
        if b not in KNOWN_BROWSERS:
            raise ConfigError("verification.ui.browsers has unknown browser %r; recognized: %s" % (b, ", ".join(KNOWN_BROWSERS)))

    _require_keys(cfg["detection"], ["paths"], "verification.ui.detection")
    if not isinstance(cfg["detection"]["paths"], list):
        raise ConfigError("verification.ui.detection.paths must be a list")

    runtime = cfg["runtime"]
    _require_keys(runtime, ["start_command", "working_directory", "ready_url", "ready_timeout_seconds", "stop_command"], "verification.ui.runtime")
    if runtime["start_command"] is not None and not isinstance(runtime["start_command"], str):
        raise ConfigError("verification.ui.runtime.start_command must be a string or null")
    if not isinstance(runtime["working_directory"], str) or not runtime["working_directory"]:
        raise ConfigError("verification.ui.runtime.working_directory must be a non-empty string")
    if runtime["ready_url"] is not None and not isinstance(runtime["ready_url"], str):
        raise ConfigError("verification.ui.runtime.ready_url must be a string or null")
    if not isinstance(runtime["ready_timeout_seconds"], int) or isinstance(runtime["ready_timeout_seconds"], bool) or runtime["ready_timeout_seconds"] <= 0:
        raise ConfigError("verification.ui.runtime.ready_timeout_seconds must be a positive integer")
    if runtime["stop_command"] is not None and not isinstance(runtime["stop_command"], str):
        raise ConfigError("verification.ui.runtime.stop_command must be a string or null")

    _require_keys(cfg["scenarios"], ["manifest"], "verification.ui.scenarios")
    if not isinstance(cfg["scenarios"]["manifest"], str) or not cfg["scenarios"]["manifest"]:
        raise ConfigError("verification.ui.scenarios.manifest must be a non-empty string")

    shots = cfg["screenshots"]
    _require_keys(shots, ["mode", "retain_source", "crop", "max_width", "max_height", "max_file_bytes", "format"], "verification.ui.screenshots")
    if shots["mode"] not in SCREENSHOT_MODES:
        raise ConfigError("verification.ui.screenshots.mode must be one of %s" % ", ".join(SCREENSHOT_MODES))
    if not isinstance(shots["retain_source"], bool):
        raise ConfigError("verification.ui.screenshots.retain_source must be a boolean")
    if shots["crop"] not in CROP_MODES:
        raise ConfigError("verification.ui.screenshots.crop must be one of %s" % ", ".join(CROP_MODES))
    for k in ("max_width", "max_height", "max_file_bytes"):
        if not isinstance(shots[k], int) or isinstance(shots[k], bool) or shots[k] <= 0:
            raise ConfigError("verification.ui.screenshots.%s must be a positive integer" % k)
    if shots["format"] not in SCREENSHOT_FORMATS:
        raise ConfigError("verification.ui.screenshots.format must be one of %s" % ", ".join(SCREENSHOT_FORMATS))

    _require_keys(cfg["video"], ["mode"], "verification.ui.video")
    if cfg["video"]["mode"] not in VIDEO_MODES:
        raise ConfigError("verification.ui.video.mode must be one of %s" % ", ".join(VIDEO_MODES))

    _require_keys(cfg["trace"], ["mode"], "verification.ui.trace")
    if cfg["trace"]["mode"] not in TRACE_MODES:
        raise ConfigError("verification.ui.trace.mode must be one of %s" % ", ".join(TRACE_MODES))

    _require_keys(cfg["console"], ["fail_on"], "verification.ui.console")
    if not isinstance(cfg["console"]["fail_on"], list):
        raise ConfigError("verification.ui.console.fail_on must be a list")
    for lvl in cfg["console"]["fail_on"]:
        if lvl not in CONSOLE_LEVELS:
            raise ConfigError("verification.ui.console.fail_on has unknown level %r; recognized: %s" % (lvl, ", ".join(CONSOLE_LEVELS)))

    _require_keys(cfg["network"], ["fail_on_status"], "verification.ui.network")
    if not isinstance(cfg["network"]["fail_on_status"], list):
        raise ConfigError("verification.ui.network.fail_on_status must be a list")
    for pat in cfg["network"]["fail_on_status"]:
        if not _valid_status_pattern(pat):
            raise ConfigError("verification.ui.network.fail_on_status has invalid entry %r (use e.g. '500-599' or '404')" % (pat,))

    _require_keys(cfg["expected_references"], ["policy"], "verification.ui.expected_references")
    if cfg["expected_references"]["policy"] not in REFERENCE_POLICIES:
        raise ConfigError("verification.ui.expected_references.policy must be one of %s" % ", ".join(REFERENCE_POLICIES))

    pub = cfg["publication"]
    _require_keys(pub, ["enabled", "destination", "path"], "verification.ui.publication")
    if not isinstance(pub["enabled"], bool):
        raise ConfigError("verification.ui.publication.enabled must be a boolean")
    if pub["destination"] not in PUBLICATION_DESTINATIONS:
        raise ConfigError("verification.ui.publication.destination must be one of %s" % ", ".join(PUBLICATION_DESTINATIONS))
    if not isinstance(pub["path"], str) or not pub["path"]:
        raise ConfigError("verification.ui.publication.path must be a non-empty string")

    return cfg


def _valid_status_pattern(pat):
    if isinstance(pat, int) and not isinstance(pat, bool):
        return 100 <= pat <= 599
    if not isinstance(pat, str):
        return False
    if re.fullmatch(r"\d{3}-\d{3}", pat):
        lo, hi = (int(x) for x in pat.split("-"))
        return lo <= hi
    return bool(re.fullmatch(r"\d{3}", pat))


def _status_matches(status, patterns):
    for pat in patterns:
        if isinstance(pat, int):
            if status == pat:
                return True
            continue
        if "-" in pat:
            lo, hi = (int(x) for x in pat.split("-"))
            if lo <= status <= hi:
                return True
        elif str(status) == pat:
            return True
    return False


def enabled_is_true(cfg):
    return cfg["enabled"] is True


def enabled_is_false(cfg):
    return cfg["enabled"] is False


# --- scenario schema (spec section 13) ---------------------------------------

def validate_scenarios(raw_list):
    """Validates a scenario manifest (a list of scenario mappings). Returns
    (scenarios, warnings) on success; raises ConfigError with the FIRST
    structural problem found (never invents unbounded browser exploration —
    every scenario field is closed-vocabulary or explicitly typed)."""
    if not isinstance(raw_list, list):
        raise ConfigError("scenario manifest must be a list of scenario mappings (got %s)" % type(raw_list).__name__)

    scenarios = []
    seen_ids = set()
    for idx, raw in enumerate(raw_list):
        where = "scenario[%d]" % idx
        if not isinstance(raw, dict):
            raise ConfigError("%s is not a mapping" % where)
        sid = raw.get("id")
        if not isinstance(sid, str) or not sid:
            raise ConfigError("%s is missing a non-empty 'id'" % where)
        if sid in seen_ids:
            raise ConfigError("duplicate scenario id %r" % sid)
        seen_ids.add(sid)
        where = "scenario '%s'" % sid

        title = raw.get("title")
        if not isinstance(title, str) or not title:
            raise ConfigError("%s is missing a non-empty 'title'" % where)

        ac = raw.get("acceptance_criteria")
        if not isinstance(ac, list) or not ac or not all(isinstance(a, str) and a for a in ac):
            raise ConfigError("%s must have a non-empty 'acceptance_criteria' list of strings" % where)

        steps = raw.get("steps")
        if not isinstance(steps, list) or not steps:
            raise ConfigError("%s must have a non-empty 'steps' list" % where)
        for si, step in enumerate(steps):
            if not isinstance(step, dict) or "action" not in step:
                raise ConfigError("%s step[%d] must be a mapping with an 'action'" % (where, si))
            if step["action"] not in KNOWN_STEP_ACTIONS:
                raise ConfigError("%s step[%d] has unknown action %r; recognized: %s" % (where, si, step["action"], ", ".join(KNOWN_STEP_ACTIONS)))

        assertions = raw.get("assertions", [])
        if not isinstance(assertions, list):
            raise ConfigError("%s 'assertions' must be a list" % where)
        for ai, a in enumerate(assertions):
            if not isinstance(a, dict) or "type" not in a:
                raise ConfigError("%s assertion[%d] must be a mapping with a 'type'" % (where, ai))
            if a["type"] not in KNOWN_ASSERTION_TYPES:
                raise ConfigError("%s assertion[%d] has unknown type %r; recognized: %s" % (where, ai, a["type"], ", ".join(KNOWN_ASSERTION_TYPES)))

        checkpoints = raw.get("checkpoints", [])
        if not isinstance(checkpoints, list):
            raise ConfigError("%s 'checkpoints' must be a list" % where)
        seen_cp = set()
        for ci, cp in enumerate(checkpoints):
            if not isinstance(cp, dict) or "id" not in cp:
                raise ConfigError("%s checkpoint[%d] must be a mapping with an 'id'" % (where, ci))
            if cp["id"] in seen_cp:
                raise ConfigError("%s has duplicate checkpoint id %r" % (where, cp["id"]))
            seen_cp.add(cp["id"])

        service = raw.get("service")
        if service is not None and not isinstance(service, str):
            raise ConfigError("%s 'service' must be a string" % where)
        browser = raw.get("browser")
        if browser is not None and browser not in KNOWN_BROWSERS:
            raise ConfigError("%s 'browser' must be one of %s" % (where, ", ".join(KNOWN_BROWSERS)))
        optional = bool(raw.get("optional", False))

        scenarios.append({
            "id": sid, "title": title, "acceptance_criteria": ac, "service": service,
            "browser": browser or "chromium", "steps": steps, "assertions": assertions,
            "checkpoints": checkpoints, "optional": optional,
            "fixture": raw.get("fixture", {}),  # fake-provider-only test directive; ignored by the playwright adapter
        })
    return scenarios


# --- UI-impact detection (spec section 12) -----------------------------------

def _match_any_paths(paths, patterns):
    import fnmatch
    hits = []
    for p in paths or []:
        for pat in patterns or []:
            if fnmatch.fnmatch(p, pat):
                hits.append(p)
                break
    return hits


def detect_ui_impact(cfg, changed_paths, spec_text, explicit_ui_task, has_expected_references):
    """Deterministic, explainable UI-impact detection (spec section 12). The
    detection RESULT and its REASONS are always recorded — this function
    never silently decides; every branch returns why."""
    if enabled_is_true(cfg):
        return {
            "required": True, "detected": True, "enabled_mode": True, "signals": ["explicit"],
            "reasons": ["verification.ui.enabled is explicitly true"],
        }

    if enabled_is_false(cfg):
        if explicit_ui_task and cfg["required_when_detected"]:
            raise ConfigError(
                "verification.ui.enabled=false conflicts with an explicitly UI-impacting task while "
                "required_when_detected=true (spec 0028, section 12.2) — UI verification must not be "
                "silently skipped for a task explicitly marked UI-impacting"
            )
        return {
            "required": False, "detected": False, "enabled_mode": False, "signals": [],
            "reasons": ["verification.ui.enabled is explicitly false"],
        }

    # auto
    signals = []
    reasons = []
    path_hits = _match_any_paths(changed_paths, cfg["detection"]["paths"])
    if path_hits:
        signals.append("changed_paths")
        reasons.append("changed path(s) matched configured verification.ui.detection.paths: %s" % ", ".join(sorted(set(path_hits))))

    kw_hits = sorted({w for w in UI_KEYWORDS if spec_text and re.search(r"\b%s\b" % re.escape(w), spec_text, re.IGNORECASE)})
    if kw_hits:
        signals.append("spec_language")
        reasons.append("specification language matched UI keyword(s): %s" % ", ".join(kw_hits))

    if has_expected_references:
        signals.append("expected_references")
        reasons.append("expected visual reference(s) supplied in the immutable input bundle")

    if explicit_ui_task:
        signals.append("explicit_metadata")
        reasons.append("task explicitly marked UI-impacting")

    detected = bool(signals)
    # A bare "spec_language" match is deliberately NOT sufficient to make a
    # task un-acceptable on its own: ordinary English requirement prose
    # frequently contains isolated UI-adjacent words ("form", "page", "view",
    # "button", "visual", ...) with no actual user-visible surface changing
    # (independent review of this task found exactly this: real, already-
    # merged, non-UI tasks were newly blocked by keyword-only detection).
    # Requiring at least one OTHER, more deliberate signal --
    # project-configured changed-path match, an actual supplied expected
    # visual reference, or explicit UI-task metadata -- keeps detection
    # honestly reported (still "detected", still explained) without letting
    # incidental vocabulary alone block `task accept` for a task that isn't
    # really UI-impacting.
    corroborated = any(s != "spec_language" for s in signals)
    required = corroborated and bool(cfg["required_when_detected"])
    if detected and not corroborated:
        reasons.append(
            "detected but NOT required: only isolated specification-language keyword(s) matched, "
            "with no corroborating signal (changed UI path, supplied expected reference, or explicit "
            "UI-task metadata) -- keyword-only matches are advisory, never blocking, on their own"
        )
    if not reasons:
        reasons.append("no configured UI-impact signal matched (auto mode)")

    return {"required": required, "detected": detected, "enabled_mode": "auto", "signals": signals, "reasons": reasons}


# --- scenario selection (spec section 14) ------------------------------------

def select_scenarios(scenarios, acceptance_criteria_text, changed_paths, selected_services):
    """Deterministic, explainable scenario selection. Returns
    (selected, not_selected, fallback_used)."""
    selected = []
    not_selected = []
    have_criteria_text = bool((acceptance_criteria_text or "").strip())
    for sc in scenarios:
        matched_ac = [ac for ac in sc["acceptance_criteria"] if have_criteria_text and ac.lower() in acceptance_criteria_text.lower()]
        service_match = bool(sc.get("service") and selected_services and sc["service"] in selected_services)
        if matched_ac or service_match:
            reason = []
            if matched_ac:
                reason.append("acceptance criterion match: %s" % "; ".join(matched_ac))
            if service_match:
                reason.append("service '%s' selected" % sc["service"])
            selected.append({"scenario": sc, "reason": " / ".join(reason)})
        else:
            not_selected.append({"id": sc["id"], "reason": "no acceptance-criterion or service match"})

    fallback_used = False
    if not selected and scenarios and not have_criteria_text and not selected_services:
        # No discriminating signal was supplied at all: fall back to the full
        # configured set rather than silently selecting nothing (spec section
        # 14: "whether selection fell back to a broader set").
        selected = [{"scenario": sc, "reason": "fallback: no acceptance-criteria text or service filter supplied"} for sc in scenarios]
        not_selected = []
        fallback_used = True

    return selected, not_selected, fallback_used


def coverage_complete(required_acceptance_criteria, selected):
    """Whether every material UI acceptance criterion supplied by the caller
    is covered by at least one selected scenario (spec section 14/31)."""
    if not required_acceptance_criteria:
        return True, []
    covered = set()
    for entry in selected:
        for ac in entry["scenario"]["acceptance_criteria"]:
            covered.add(ac.lower())
    missing = [ac for ac in required_acceptance_criteria if ac.lower() not in covered]
    return (len(missing) == 0), missing


# --- runtime readiness (spec section 15) -------------------------------------

def _playwright_available(cfg, root):
    if cfg["provider"] == "fake":
        return True, "fake provider (deterministic, no real browser required)"
    node = shutil.which("node")
    if not node:
        return False, "node executable not found on PATH"
    try:
        subprocess.run(
            [node, "-e", "require.resolve('playwright')"],
            cwd=root, capture_output=True, timeout=10,
        ).check_returncode()
    except Exception as exc:
        return False, "playwright npm package not resolvable from %s: %s" % (root, exc)
    return True, "playwright resolvable from %s" % root


def check_runtime_readiness(cfg, root, env):
    """Structural readiness projection (spec section 15) — used by `plan`
    (never executes anything) and re-verified for real by `run`."""
    env = env or {}
    checks = []
    ok = True

    runtime = cfg["runtime"]
    has_start = bool(runtime.get("start_command"))
    external = bool(env.get("external_runtime"))
    c_ok = has_start or external
    checks.append({"check": "start_command_or_external", "ok": c_ok, "detail": runtime.get("start_command") or ("external" if external else "none configured")})
    ok = ok and c_ok

    wd_abs = os.path.join(root, runtime["working_directory"])
    wd_ok = os.path.isdir(wd_abs)
    checks.append({"check": "working_directory", "ok": wd_ok, "detail": wd_abs})
    ok = ok and wd_ok

    url_ok = bool(runtime.get("ready_url"))
    checks.append({"check": "ready_url_configured", "ok": url_ok, "detail": runtime.get("ready_url") or ""})
    ok = ok and url_ok

    provider_ok, provider_detail = _playwright_available(cfg, root)
    checks.append({"check": "provider_available", "ok": provider_ok, "detail": provider_detail})
    ok = ok and provider_ok

    creds_ok = bool(env.get("credentials_available", True))
    checks.append({"check": "credentials", "ok": creds_ok, "detail": "" if creds_ok else "required credentials not available"})
    ok = ok and creds_ok

    data_ok = bool(env.get("test_data_available", True))
    checks.append({"check": "test_data", "ok": data_ok, "detail": "" if data_ok else "required test data not available"})
    ok = ok and data_ok

    return {"ok": ok, "checks": checks}


def _wait_for_ready_url(url, timeout_seconds):
    deadline = time.time() + timeout_seconds
    last_error = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                if 200 <= resp.status < 400:
                    return True, None
                last_error = "HTTP %s" % resp.status
        except (urllib.error.URLError, socket.timeout, http.client.HTTPException, ConnectionError) as exc:
            last_error = str(exc)
        time.sleep(1)
    return False, last_error or "timed out waiting for %s" % url


# --- deterministic fixture PNG codec (fake provider ONLY) --------------------
#
# Real screenshots always come from the browser session under test (spec
# section 18.6); this codec exists SOLELY so the fake provider's deterministic
# test fixtures are REAL, readable PNG files that the SAME byte-level policy
# functions below (dedup-by-digest, size limits, dimension checks) can operate
# on without a browser — the fake provider never claims these bytes came from
# a real page. PNG's mandated layout (signature, then IHDR as the FIRST chunk)
# means _png_dimensions works on ANY well-formed PNG, including real ones a
# Playwright adapter would produce.

def _chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def make_fixture_png(width, height, seed):
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)  # grayscale, 8-bit
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter: none
        for x in range(width):
            raw.append((seed * 31 + x + y) % 256)
    idat = zlib.compress(bytes(raw), 9)
    return sig + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", idat) + _chunk(b"IEND", b"")


def _png_dimensions(data):
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("not a well-formed PNG (missing signature/IHDR)")
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def _is_fixture_png(data):
    try:
        if len(data) < 26:
            return False
        color_type = data[25]
        bit_depth = data[24]
        return color_type == 0 and bit_depth == 8
    except Exception:
        return False


def _downscale_fixture_png(data, max_width, max_height):
    """Best-effort optimization for oversized screenshots (spec section
    18.5). Only meaningful for this module's own grayscale fixture PNGs
    (which it can deterministically regenerate at a smaller size); a real
    Playwright screenshot cannot be safely re-encoded without an image
    library, so this returns None for anything else and the caller must
    BLOCK rather than silently guess (spec: 'must not make the evidence
    unreadable')."""
    if not _is_fixture_png(data):
        return None
    width, height = _png_dimensions(data)
    new_w, new_h = min(width, max_width), min(height, max_height)
    if new_w <= 0 or new_h <= 0:
        return None
    seed = data[26] if len(data) > 26 else 0
    return make_fixture_png(new_w, new_h, seed)


# --- screenshot evidence policy (spec section 18) ----------------------------

def process_screenshot(raw_bytes, cfg_screenshots, seen_digests, out_dir, name):
    """Applies the compact-evidence policy to one raw screenshot (spec
    section 18): exact-digest dedup, then dimension/byte-size limits with a
    bounded optimization attempt, else BLOCKED. Returns a result dict; never
    writes a file for a duplicate or a still-oversized image."""
    digest = hashlib.sha256(raw_bytes).hexdigest()
    if digest in seen_digests:
        return {"status": "duplicate", "digest": digest, "reference": seen_digests[digest]}

    try:
        width, height = _png_dimensions(raw_bytes)
    except ValueError as exc:
        return {"status": "blocked", "reason": "screenshot could not be stored safely: %s" % exc}

    max_w = cfg_screenshots["max_width"]
    max_h = cfg_screenshots["max_height"]
    max_bytes = cfg_screenshots["max_file_bytes"]
    final_bytes = raw_bytes
    optimized = False
    oversized = width > max_w or height > max_h or len(raw_bytes) > max_bytes
    if oversized:
        optimized_bytes = _downscale_fixture_png(raw_bytes, max_w, max_h)
        if optimized_bytes is None or len(optimized_bytes) > max_bytes:
            return {
                "status": "blocked",
                "reason": (
                    "screenshot (%dx%d, %d bytes) exceeds configured limits "
                    "(max %dx%d, %d bytes) and cannot be optimized without making the evidence unreadable"
                ) % (width, height, len(raw_bytes), max_w, max_h, max_bytes),
            }
        final_bytes = optimized_bytes
        optimized = True

    path = os.path.join(out_dir, name)
    _atomic_write_bytes(path, final_bytes)
    seen_digests[digest] = name
    return {"status": "ok", "path": path, "name": name, "digest": hashlib.sha256(final_bytes).hexdigest(), "bytes": len(final_bytes), "optimized": optimized}


# --- console / network capture + redaction (spec section 21) ----------------

def _redact_value(key, value):
    if isinstance(value, dict):
        return {k: _redact_value(k, v) for k, v in value.items()}
    if isinstance(value, list):
        return [_redact_value(key, v) for v in value]
    if any(marker in str(key).lower() for marker in _SECRET_KEY_MARKERS):
        return "REDACTED"
    return value


def redact_events(events):
    return [{k: _redact_value(k, v) for k, v in (e or {}).items()} for e in events or []]


def fatal_console_events(events, fail_on):
    return [e for e in (events or []) if e.get("level") in (fail_on or [])]


def fatal_network_events(events, fail_on_status):
    out = []
    for e in events or []:
        status = e.get("status")
        if isinstance(status, int) and _status_matches(status, fail_on_status or []):
            out.append(e)
    return out


# --- expected-reference comparison (spec section 22/23) ----------------------

def compare_reference(actual_path, expected_path):
    """Real byte-level comparison of actual vs. expected reference (never a
    claimed-but-unperformed comparison — spec section 22: 'never claim visual
    equivalence when no comparison was performed'). This reference
    implementation's comparison method is exact-digest equality; a
    pixel-tolerance diff would need an image library this project does not
    depend on, so `method` is always recorded honestly as 'sha256-exact'."""
    with open(actual_path, "rb") as f:
        actual_bytes = f.read()
    with open(expected_path, "rb") as f:
        expected_bytes = f.read()
    match = hashlib.sha256(actual_bytes).hexdigest() == hashlib.sha256(expected_bytes).hexdigest()
    return {"performed": True, "match": match, "method": "sha256-exact", "tolerance": 0}


# --- fake provider (spec section 40) -----------------------------------------
#
# Deterministic, no network, no real browser. Every behavior is driven by the
# scenario's own `fixture` mapping so tests can simulate the full matrix
# (PASS, failed assertion, blocked credentials, console error, network 500,
# checkpoint/crop/oversized/duplicate screenshot, ...) without any external
# service — mirrors context/fake.sh and providers/fake.sh's env-knob pattern,
# scoped per-scenario instead of per-process since scenarios are this
# capability's unit of execution.

def _fake_run_scenario(scenario, screenshots_cfg):
    fixture = scenario.get("fixture") or {}
    kind = fixture.get("case", "pass")

    steps_result = [{"index": i, "action": s["action"], "ok": True} for i, s in enumerate(scenario["steps"])]
    assertions_result = [{"index": i, **a, "ok": True} for i, a in enumerate(scenario["assertions"])]
    console_events = list(fixture.get("console_events", []))
    network_events = list(fixture.get("network_events", []))
    screenshots = []
    blocked_reason = None

    if kind == "blocked_credentials":
        return {"blocked_reason": "required credentials are not available", "steps": steps_result, "assertions": assertions_result, "console_events": [], "network_events": [], "screenshots": []}
    if kind == "blocked_test_data":
        return {"blocked_reason": "required test data is not available", "steps": steps_result, "assertions": assertions_result, "console_events": [], "network_events": [], "screenshots": []}
    if kind == "blocked_runtime_timeout":
        return {"blocked_reason": "application runtime did not become ready in time", "steps": steps_result, "assertions": assertions_result, "console_events": [], "network_events": [], "screenshots": []}
    if kind == "invalid_scenario":
        return {"blocked_reason": "scenario definition is invalid for this run", "steps": steps_result, "assertions": assertions_result, "console_events": [], "network_events": [], "screenshots": []}

    if kind == "failed_assertion" and assertions_result:
        assertions_result[0]["ok"] = False
        assertions_result[0]["detail"] = fixture.get("detail", "expected element was not in the claimed state")

    if kind == "console_error":
        console_events.append({"level": "error", "text": fixture.get("text", "Uncaught TypeError: simulated console error"), "url": fixture.get("url", "about:blank")})

    if kind == "network_500":
        network_events.append({"status": 500, "method": "GET", "url": fixture.get("url", "https://example.test/api/simulated"), "headers": {"authorization": "Bearer secret-token-should-be-redacted"}})

    if screenshots_cfg["mode"] == "checkpoints":
        for i, cp in enumerate(scenario.get("checkpoints", [])):
            spec = (fixture.get("screenshots") or {}).get(cp["id"], {})
            width = spec.get("width", 40)
            height = spec.get("height", 30)
            seed = spec.get("seed", (sum(ord(c) for c in scenario["id"]) + i))
            screenshots.append({
                "checkpoint_id": cp["id"],
                "raw_bytes": make_fixture_png(width, height, seed),
            })

    return {
        "blocked_reason": blocked_reason, "steps": steps_result, "assertions": assertions_result,
        "console_events": console_events, "network_events": network_events, "screenshots": screenshots,
    }


# --- playwright provider (real adapter) --------------------------------------
#
# Shells out to the bundled Node/Playwright driver (js/ui_playwright_runner.js)
# with the scenario + base URL as JSON on stdin, and reads back structured
# JSON on stdout (spec section 16: "The provider adapter must return
# structured results to the deterministic engine"). This project's own test
# suite never exercises this path for real (SpecRelay itself has no browser
# UI to point it at) — it always runs under provider: fake; a consuming
# project supplies its own Playwright installation and application runtime.

def _js_runner_path():
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "js", "ui_playwright_runner.js")


def _playwright_run_scenario(scenario, cfg, root, base_url):
    node = shutil.which("node")
    if not node:
        return {"blocked_reason": "node executable not found on PATH", "steps": [], "assertions": [], "console_events": [], "network_events": [], "screenshots": []}
    runner = _js_runner_path()
    if not os.path.isfile(runner):
        return {"blocked_reason": "playwright runner script is missing: %s" % runner, "steps": [], "assertions": [], "console_events": [], "network_events": [], "screenshots": []}

    payload = json.dumps({
        "scenario": scenario, "base_url": base_url, "browser": scenario.get("browser", "chromium"),
        "trace_mode": cfg["trace"]["mode"],
    })
    try:
        proc = subprocess.run(
            [node, runner], input=payload, capture_output=True, text=True, cwd=root, timeout=120,
        )
    except subprocess.TimeoutExpired:
        return {"blocked_reason": "playwright runner timed out", "steps": [], "assertions": [], "console_events": [], "network_events": [], "screenshots": []}
    if proc.returncode != 0:
        return {"blocked_reason": "playwright runner failed: %s" % (proc.stderr or "").strip()[:500], "steps": [], "assertions": [], "console_events": [], "network_events": [], "screenshots": []}
    try:
        result = json.loads(proc.stdout)
    except ValueError:
        return {"blocked_reason": "playwright runner produced non-JSON output", "steps": [], "assertions": [], "console_events": [], "network_events": [], "screenshots": []}
    for shot in result.get("screenshots", []):
        if "raw_bytes_b64" in shot:
            import base64
            shot["raw_bytes"] = base64.b64decode(shot.pop("raw_bytes_b64"))
    return result


# --- scenario execution -------------------------------------------------------

def _origin(url):
    m = re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+", url or "")
    return m.group(0) if m else None


def _disallowed_navigation(scenario, base_url):
    """Spec section 36: 'arbitrary URL navigation outside configured origins
    must be rejected'. A relative `goto` url (the documented scenario style —
    spec section 13's example uses `/companies/...`) always targets the
    application under test and is always allowed. An ABSOLUTE url is only
    allowed when its origin matches the configured base_url (the ONE origin
    this task's runtime configuration actually approves — spec introduces no
    separate origin-allowlist key). Returns the first disallowed url, or
    None."""
    allowed_origin = _origin(base_url) if base_url else None
    for step in scenario.get("steps", []):
        if step.get("action") != "goto":
            continue
        url = step.get("url", "")
        origin = _origin(url)
        if origin is None:
            continue  # relative: same-origin as the application under test
        if allowed_origin is None or origin != allowed_origin:
            return url
    return None


def execute_scenario(scenario, cfg, root, run_dir, index, provider, base_url, expected_refs, digest_context, resume_prior):
    slug = "%02d-%s" % (index, scenario["id"])
    scenario_dir = os.path.join(run_dir, "scenarios", slug)
    screenshots_dir = os.path.join(scenario_dir, "screenshots")
    comparison_dir = os.path.join(scenario_dir, "comparison")

    if resume_prior and resume_prior.get("result") == "PASS" and resume_prior.get("digest_context") == digest_context:
        reused = dict(resume_prior)
        reused["reused"] = True
        reused["reuse_reason"] = "prior PASS evidence matches current config/commit/browser/viewport digest"
        # Persist the reuse decision itself (spec section 38: "record why
        # evidence was reused or invalidated") — the on-disk result.json must
        # reflect the LAST run's decision, not just the in-memory summary.
        _write_json(os.path.join(scenario_dir, "result.json"), reused)
        return reused

    disallowed_url = _disallowed_navigation(scenario, base_url)
    if disallowed_url:
        raw = {
            "blocked_reason": "scenario navigates to an unapproved external origin: %s" % disallowed_url,
            "steps": [], "assertions": [], "console_events": [], "network_events": [], "screenshots": [],
        }
    elif provider == "fake":
        raw = _fake_run_scenario(scenario, cfg["screenshots"])
    else:
        raw = _playwright_run_scenario(scenario, cfg, root, base_url)

    result = "PASS"
    reasons = []
    blocked_reason = raw.get("blocked_reason")
    if blocked_reason:
        result = "BLOCKED"
        reasons.append(blocked_reason)

    failed_steps = [s for s in raw.get("steps", []) if not s.get("ok", True)]
    failed_assertions = [a for a in raw.get("assertions", []) if not a.get("ok", True)]
    if result != "BLOCKED" and (failed_steps or failed_assertions):
        result = "FAIL"
        reasons.append("%d step(s) and %d assertion(s) failed" % (len(failed_steps), len(failed_assertions)))

    console_events = redact_events(raw.get("console_events", []))
    network_events = redact_events(raw.get("network_events", []))
    fatal_console = fatal_console_events(console_events, cfg["console"]["fail_on"])
    fatal_network = fatal_network_events(network_events, cfg["network"]["fail_on_status"])
    if result == "PASS" and (fatal_console or fatal_network):
        result = "FAIL"
        if fatal_console:
            reasons.append("%d fatal console event(s)" % len(fatal_console))
        if fatal_network:
            reasons.append("%d fatal network event(s)" % len(fatal_network))

    screenshots_out = []
    seen_digests = {}
    if result != "BLOCKED":
        for shot in raw.get("screenshots", []):
            name = "step-%02d-%s.png" % (len(screenshots_out) + 1, shot["checkpoint_id"])
            processed = process_screenshot(shot["raw_bytes"], cfg["screenshots"], seen_digests, screenshots_dir, name)
            processed["checkpoint_id"] = shot["checkpoint_id"]
            screenshots_out.append(processed)
            if processed["status"] == "blocked":
                result = "BLOCKED"
                reasons.append(processed["reason"])

    comparisons = []
    ref_policy = cfg["expected_references"]["policy"]
    for shot in screenshots_out:
        cp_id = shot["checkpoint_id"]
        ref = (expected_refs or {}).get(cp_id) or (expected_refs or {}).get(scenario["id"])
        if ref_policy == "ignore":
            continue
        if not ref:
            if ref_policy == "required":
                result = "BLOCKED" if result != "FAIL" else result
                reasons.append("required expected reference missing for checkpoint '%s'" % cp_id)
                comparisons.append({"checkpoint_id": cp_id, "performed": False, "reason": "required reference missing"})
            else:
                comparisons.append({"checkpoint_id": cp_id, "performed": False, "reason": "no expected reference supplied"})
            continue
        if shot.get("status") != "ok":
            continue
        os.makedirs(comparison_dir, exist_ok=True)
        cmp_result = compare_reference(shot["path"], ref["path"])
        cmp_result["checkpoint_id"] = cp_id
        cmp_result["expected_reference"] = ref.get("snapshot_path")
        if not cmp_result["match"] and result == "PASS":
            result = "FAIL"
            reasons.append("visual comparison mismatch for checkpoint '%s'" % cp_id)
        comparisons.append(cmp_result)

    scenario_result = {
        "schema_version": SCHEMA_VERSION,
        "id": scenario["id"],
        "title": scenario["title"],
        "acceptance_criteria": scenario["acceptance_criteria"],
        "service": scenario.get("service"),
        "browser": scenario.get("browser"),
        "optional": scenario.get("optional", False),
        "result": result,
        "reasons": reasons,
        "steps": raw.get("steps", []),
        "assertions": raw.get("assertions", []),
        "screenshots": [{k: v for k, v in s.items() if k != "reference"} for s in screenshots_out],
        "comparisons": comparisons,
        "console_events": console_events,
        "network_events": network_events,
        "digest_context": digest_context,
        "reused": False,
        "trace": None,
    }

    # Trace policy (spec section 20): traces are RUNTIME-only evidence, never
    # published, captured only per configured policy — never merely because
    # the provider happened to support it.
    trace_mode = cfg["trace"]["mode"]
    should_trace = trace_mode == "always" or (trace_mode == "on-failure" and result in ("FAIL", "BLOCKED"))
    if should_trace:
        traces_dir = os.path.join(run_dir, "traces")
        trace_name = "%s.trace" % slug
        if raw.get("trace_b64"):
            import base64
            _atomic_write_bytes(os.path.join(traces_dir, trace_name), base64.b64decode(raw["trace_b64"]))
        else:
            # Fake provider / no real trace available: a deterministic
            # textual substitute (never claimed to be a real Playwright
            # trace archive) so the policy itself is still exercised without
            # a real browser (spec section 40).
            _atomic_write(os.path.join(traces_dir, trace_name), json.dumps({
                "scenario_id": scenario["id"], "result": result, "reasons": reasons,
                "steps": raw.get("steps", []), "assertions": raw.get("assertions", []),
            }, indent=2, sort_keys=True) + "\n")
        scenario_result["trace"] = os.path.join("traces", trace_name)

    os.makedirs(scenario_dir, exist_ok=True)
    _write_json(os.path.join(scenario_dir, "result.json"), scenario_result)
    _atomic_write(os.path.join(scenario_dir, "console-errors.json"), json.dumps(console_events, indent=2, sort_keys=True) + "\n")
    _atomic_write(os.path.join(scenario_dir, "network-errors.json"), json.dumps(network_events, indent=2, sort_keys=True) + "\n")
    _atomic_write(os.path.join(scenario_dir, "report.md"), render_scenario_markdown(scenario_result, slug, ref_policy))
    return scenario_result


def render_scenario_markdown(sr, slug, ref_policy):
    lines = []
    lines.append("# Scenario %s — %s" % (slug.split("-", 1)[0], sr["title"]))
    lines.append("")
    lines.append("**Acceptance criterion:** %s" % "; ".join(sr["acceptance_criteria"]))
    lines.append("")
    lines.append("## Environment")
    lines.append("")
    lines.append("- Service: %s" % (sr.get("service") or "(none)"))
    lines.append("- Browser: %s" % sr.get("browser"))
    lines.append("- Test data: (see runtime environment.json)")
    lines.append("- Commit/branch: (see runtime environment.json)")
    lines.append("- Scenario definition: %s" % sr["id"])
    lines.append("")
    lines.append("## Steps")
    lines.append("")
    for i, step in enumerate(sr["steps"]):
        lines.append("%d. %s (%s)" % (i + 1, step.get("action"), "ok" if step.get("ok", True) else "failed"))
    shots = [s for s in sr["screenshots"] if s.get("status") == "ok"]
    for s in shots:
        lines.append("   ![Evidence](%s/screenshots/%s)" % (slug, s["name"]))
    lines.append("")
    lines.append("## Browser diagnostics")
    lines.append("")
    lines.append("- Console errors: %s" % ("see console-errors.json" if True else "none"))
    lines.append("- Network errors: %s" % ("see network-errors.json" if True else "none"))
    lines.append("- Trace: %s" % ("captured (runtime-only, not published — spec section 20): %s" % sr["trace"] if sr.get("trace") else "not captured (policy did not require one for this result)"))
    if ref_policy == "ignore":
        lines.append("- Visual reference: not assessed (policy: ignore)")
    elif not sr["comparisons"]:
        lines.append("- Visual reference: Visual equivalence not assessed: no expected reference supplied.")
    else:
        lines.append("- Visual reference: %s" % "; ".join(
            ("match" if c.get("match") else ("not assessed: no expected reference supplied" if not c.get("performed") else "mismatch"))
            for c in sr["comparisons"]
        ))
    lines.append("")
    lines.append("## Result: %s" % sr["result"])
    lines.append("")
    lines.append("; ".join(sr["reasons"]) if sr["reasons"] else "All required steps and assertions completed successfully.")
    lines.append("")
    lines.append("## Reviewer verification")
    lines.append("")
    lines.append("- Evidence integrity: (filled in by the independent Reviewer)")
    lines.append("- Acceptance-criterion coverage: (filled in by the independent Reviewer)")
    lines.append("- Independent checks: (filled in by the independent Reviewer)")
    lines.append("- Reviewer result: (pending)")
    lines.append("")
    return "\n".join(lines)


def classify_overall(scenario_results):
    required = [r for r in scenario_results if not r.get("optional")]
    if any(r["result"] == "BLOCKED" for r in required):
        return "BLOCKED"
    if any(r["result"] == "FAIL" for r in required):
        return "FAIL"
    if not scenario_results:
        return "NOT_REQUIRED"
    return "PASS"


# --- CLI subcommands -----------------------------------------------------------

def _read_stdin_json():
    raw = sys.stdin.read()
    try:
        return json.loads(raw) if raw.strip() else {}
    except ValueError as exc:
        print("ui_verification_lib.py: invalid JSON on stdin: %s" % exc, file=sys.stderr)
        sys.exit(2)


def _digest_context(payload, cfg):
    return hashlib.sha256(json.dumps({
        "config": cfg, "commit": payload.get("commit"), "browser_versions": payload.get("browser_versions"),
        "viewport": payload.get("viewport"),
    }, sort_keys=True).encode("utf-8")).hexdigest()


def _build_plan(payload):
    cfg = normalize_ui_config((payload.get("raw_config") or {}).get("ui") if isinstance(payload.get("raw_config"), dict) else payload.get("ui_config"))
    detection = detect_ui_impact(
        cfg, payload.get("changed_paths", []), payload.get("spec_text", ""),
        bool(payload.get("explicit_ui_task", False)), bool(payload.get("has_expected_references", False)),
    )
    plan = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": _now_iso(),
        "config": cfg,
        "detection": detection,
    }
    if not detection["required"]:
        plan["scenarios"] = {"selected": [], "not_selected": [], "fallback_used": False}
        plan["coverage_complete"] = True
        plan["missing_coverage"] = []
        plan["runtime_readiness"] = None
        return plan

    scenarios_raw = payload.get("scenarios_raw", [])
    scenarios = validate_scenarios(scenarios_raw)
    selected, not_selected, fallback_used = select_scenarios(
        scenarios, payload.get("acceptance_criteria_text", ""), payload.get("changed_paths", []),
        payload.get("selected_services", []),
    )
    complete, missing = coverage_complete(payload.get("required_acceptance_criteria", []), selected)
    root = payload.get("root", ".")
    plan["scenarios"] = {
        "selected": [{"id": e["scenario"]["id"], "title": e["scenario"]["title"], "reason": e["reason"]} for e in selected],
        "not_selected": not_selected,
        "fallback_used": fallback_used,
    }
    plan["coverage_complete"] = complete
    plan["missing_coverage"] = missing
    plan["runtime_readiness"] = check_runtime_readiness(cfg, root, payload.get("environment", {}))
    plan["_selected_full"] = selected  # internal, stripped before printing/writing when requested
    return plan


def _detect_cmd(argv):
    """Detection-only query (no scenario manifest required) — used by
    workflow.sh's executor/reviewer prompt construction to decide whether to
    mention the UI-verification requirement at all, without needing a
    scenario manifest to exist yet."""
    as_json = "--json" in argv
    payload = _read_stdin_json()
    try:
        cfg = normalize_ui_config(payload.get("ui_config"))
        detection = detect_ui_impact(
            cfg, payload.get("changed_paths", []), payload.get("spec_text", ""),
            bool(payload.get("explicit_ui_task", False)), bool(payload.get("has_expected_references", False)),
        )
    except ConfigError as exc:
        print("ui detect: INVALID configuration — %s" % exc, file=sys.stderr)
        return 1
    if as_json:
        print(json.dumps(detection, indent=2, sort_keys=True))
    else:
        print("required: %s" % detection["required"])
        print("detected: %s" % detection["detected"])
        for r in detection["reasons"]:
            print("  - %s" % r)
    return 0


def _plan_cmd(argv):
    as_json = "--json" in argv
    payload = _read_stdin_json()
    try:
        plan = _build_plan(payload)
    except ConfigError as exc:
        print("ui plan: INVALID configuration — %s" % exc, file=sys.stderr)
        return 1
    task_dir = payload.get("task_dir")
    printable = {k: v for k, v in plan.items() if k != "_selected_full"}
    if task_dir:
        os.makedirs(os.path.join(task_dir, RUNTIME_DIRNAME), exist_ok=True)
        _write_json(os.path.join(task_dir, RUNTIME_DIRNAME, PLAN_JSON), printable)
    if as_json:
        print(json.dumps(printable, indent=2, sort_keys=True))
    else:
        print("UI verification plan")
        print("  required: %s" % plan["detection"]["required"])
        print("  detected: %s" % plan["detection"].get("detected"))
        print("  reasons:")
        for r in plan["detection"]["reasons"]:
            print("    - %s" % r)
        if plan["detection"]["required"]:
            print("  selected scenarios: %s" % (", ".join(s["id"] for s in plan["scenarios"]["selected"]) or "(none)"))
            print("  fallback_used: %s" % plan["scenarios"]["fallback_used"])
            print("  coverage_complete: %s" % plan["coverage_complete"])
            if plan["missing_coverage"]:
                print("  missing_coverage: %s" % ", ".join(plan["missing_coverage"]))
            if plan["runtime_readiness"]:
                print("  runtime_readiness.ok: %s" % plan["runtime_readiness"]["ok"])
    return 0


def _run_cmd(argv):
    as_json = "--json" in argv
    payload = _read_stdin_json()
    try:
        plan = _build_plan(payload)
    except ConfigError as exc:
        print("ui run: INVALID configuration — %s" % exc, file=sys.stderr)
        return 1

    task_dir = payload["task_dir"]
    root = payload["root"]
    run_dir = os.path.join(task_dir, RUNTIME_DIRNAME)
    os.makedirs(run_dir, exist_ok=True)

    printable = {k: v for k, v in plan.items() if k != "_selected_full"}
    _write_json(os.path.join(run_dir, PLAN_JSON), printable)

    environment = {
        "generated_at": _now_iso(),
        "commit": payload.get("commit"),
        "browser_versions": payload.get("browser_versions", {}),
        "viewport": payload.get("viewport", {"width": 1280, "height": 800}),
        "provider": plan["config"]["provider"],
        "browsers": plan["config"]["browsers"],
    }
    _write_json(os.path.join(run_dir, ENVIRONMENT_JSON), environment)

    started_at = _now_iso()
    log_lines = ["[%s] UI verification run started" % started_at]

    if not plan["detection"]["required"]:
        log_lines.append("UI verification not required for this task; no browser started.")
        _atomic_write(os.path.join(run_dir, RUNTIME_LOG), "\n".join(log_lines) + "\n")
        summary = build_run_summary(plan, [], started_at, _now_iso(), overall_override="NOT_REQUIRED")
        _write_json(os.path.join(run_dir, SUMMARY_JSON), summary)
        _atomic_write(os.path.join(run_dir, SUMMARY_MD), render_summary_markdown(summary))
        _atomic_write(os.path.join(run_dir, CONSOLE_ERRORS_JSON), "[]\n")
        _atomic_write(os.path.join(run_dir, NETWORK_ERRORS_JSON), "[]\n")
        if as_json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render_report_text(summary))
        return 0

    cfg = plan["config"]
    provider = cfg["provider"]
    readiness = plan["runtime_readiness"]
    base_url = None
    if not readiness["ok"]:
        log_lines.append("runtime readiness FAILED: %s" % json.dumps(readiness["checks"]))
        _atomic_write(os.path.join(run_dir, RUNTIME_LOG), "\n".join(log_lines) + "\n")
        summary = build_run_summary(plan, [], started_at, _now_iso(), overall_override="BLOCKED", blocked_reason="runtime readiness prerequisites were not satisfied")
        _write_json(os.path.join(run_dir, SUMMARY_JSON), summary)
        _atomic_write(os.path.join(run_dir, SUMMARY_MD), render_summary_markdown(summary))
        _atomic_write(os.path.join(run_dir, CONSOLE_ERRORS_JSON), "[]\n")
        _atomic_write(os.path.join(run_dir, NETWORK_ERRORS_JSON), "[]\n")
        if as_json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(render_report_text(summary))
        return 1

    if provider == "playwright" and cfg["runtime"].get("ready_url") and not payload.get("skip_ready_wait"):
        ready, err = _wait_for_ready_url(cfg["runtime"]["ready_url"], cfg["runtime"]["ready_timeout_seconds"])
        if not ready:
            log_lines.append("runtime did not become ready: %s" % err)
            _atomic_write(os.path.join(run_dir, RUNTIME_LOG), "\n".join(log_lines) + "\n")
            summary = build_run_summary(plan, [], started_at, _now_iso(), overall_override="BLOCKED", blocked_reason="application runtime did not become ready: %s" % err)
            _write_json(os.path.join(run_dir, SUMMARY_JSON), summary)
            _atomic_write(os.path.join(run_dir, SUMMARY_MD), render_summary_markdown(summary))
            if as_json:
                print(json.dumps(summary, indent=2, sort_keys=True))
            else:
                print(render_report_text(summary))
            return 1
        base_url = cfg["runtime"]["ready_url"]

    digest_ctx = _digest_context(payload, cfg)
    expected_refs = {}
    for ref in payload.get("expected_references", []):
        expected_refs[ref["checkpoint_id"]] = ref

    resume = bool(payload.get("resume"))
    results = []
    all_console = []
    all_network = []
    for i, entry in enumerate(plan["_selected_full"], start=1):
        scenario = entry["scenario"]
        prior = None
        if resume:
            prior_path = os.path.join(run_dir, "scenarios", "%02d-%s" % (i, scenario["id"]), "result.json")
            if os.path.isfile(prior_path):
                with open(prior_path) as f:
                    prior = json.load(f)
        sr = execute_scenario(scenario, cfg, root, run_dir, i, provider, base_url, expected_refs, digest_ctx, prior)
        results.append(sr)
        all_console.extend(sr.get("console_events") or [])
        all_network.extend(sr.get("network_events") or [])
        log_lines.append("scenario %s: %s" % (scenario["id"], sr["result"]))

    finished_at = _now_iso()
    _atomic_write(os.path.join(run_dir, RUNTIME_LOG), "\n".join(log_lines) + "\n")

    summary = build_run_summary(plan, results, started_at, finished_at)
    _write_json(os.path.join(run_dir, SUMMARY_JSON), summary)
    _atomic_write(os.path.join(run_dir, SUMMARY_MD), render_summary_markdown(summary))
    _atomic_write(os.path.join(run_dir, CONSOLE_ERRORS_JSON), json.dumps(redact_events(all_console), indent=2, sort_keys=True) + "\n")
    _atomic_write(os.path.join(run_dir, NETWORK_ERRORS_JSON), json.dumps(redact_events(all_network), indent=2, sort_keys=True) + "\n")

    if as_json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(render_report_text(summary))
    return 0 if summary["overall_status"] == "PASS" else 1


def build_run_summary(plan, results, started_at, finished_at, overall_override=None, blocked_reason=None):
    overall = overall_override or classify_overall(results)
    return {
        "schema_version": SCHEMA_VERSION,
        "started_at": started_at,
        "finished_at": finished_at,
        "required": plan["detection"]["required"],
        "detection_reasons": plan["detection"]["reasons"],
        "coverage_complete": plan.get("coverage_complete", True),
        "missing_coverage": plan.get("missing_coverage", []),
        "overall_status": overall,
        "blocked_reason": blocked_reason,
        "scenario_count": len(results),
        "pass_count": sum(1 for r in results if r["result"] == "PASS"),
        "fail_count": sum(1 for r in results if r["result"] == "FAIL"),
        "blocked_count": sum(1 for r in results if r["result"] == "BLOCKED"),
        "scenarios": [{"id": r["id"], "title": r["title"], "result": r["result"], "acceptance_criteria": r["acceptance_criteria"], "optional": r.get("optional", False)} for r in results],
        "visual_comparison_performed": any(c.get("performed") for r in results for c in r.get("comparisons", [])),
    }


def render_summary_markdown(summary):
    lines = ["# UI Verification Summary", ""]
    lines.append("- Required: %s" % summary["required"])
    lines.append("- Overall status: %s" % summary["overall_status"])
    if summary.get("blocked_reason"):
        lines.append("- Blocked reason: %s" % summary["blocked_reason"])
    lines.append("- Coverage complete: %s" % summary["coverage_complete"])
    if summary["missing_coverage"]:
        lines.append("- Missing coverage: %s" % ", ".join(summary["missing_coverage"]))
    lines.append("- Visual comparison performed: %s" % summary["visual_comparison_performed"])
    lines.append("")
    lines.append("| Scenario | Acceptance criterion | Result |")
    lines.append("|---|---|---|")
    for s in summary["scenarios"]:
        lines.append("| %s | %s | %s |" % (s["id"], "; ".join(s["acceptance_criteria"]), s["result"]))
    lines.append("")
    return "\n".join(lines)


def render_report_text(summary):
    lines = ["UI verification: %s (required=%s)" % (summary["overall_status"], summary["required"])]
    for s in summary["scenarios"]:
        lines.append("  %s: %s" % (s["id"], s["result"]))
    if summary["missing_coverage"]:
        lines.append("  missing_coverage: %s" % ", ".join(summary["missing_coverage"]))
    return "\n".join(lines)


def _report_cmd(argv):
    positional = [a for a in argv if not a.startswith("--")]
    as_json = "--json" in argv
    if not positional:
        print("usage: ui_verification_lib.py report <task_dir> [--json]", file=sys.stderr)
        return 2
    task_dir = positional[0]
    path = os.path.join(task_dir, RUNTIME_DIRNAME, SUMMARY_JSON)
    if not os.path.isfile(path):
        if as_json:
            print(json.dumps({"recorded": False}))
        else:
            print("UI verification: not recorded")
        return 0
    with open(path) as f:
        summary = json.load(f)
    if as_json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(render_report_text(summary))
    return 0


# --- publication (spec section 25-26, 34.4) ----------------------------------

REQUIRED_REVIEWER_HEADING = "## UI Verification Evidence Review"


def gate_check(payload):
    """The completion-gate check (spec section 31) used by
    transitions.sh::accept and by `ui publish`. Never trusts a role's prose
    claim, and NEVER trusts the mere absence of a prior 'ui plan'/'ui run'
    invocation as proof that verification was not required (spec section
    12.2/31: 'must not silently skip verification') — detection is always
    RECOMPUTED here, independently, from the same inputs 'ui plan'/'ui run'
    use. Only once detection says NOT required does this ever pass without
    durable evidence."""
    task_dir = payload["task_dir"]
    try:
        cfg = normalize_ui_config(payload.get("ui_config"))
        detection = detect_ui_impact(
            cfg, payload.get("changed_paths", []), payload.get("spec_text", ""),
            bool(payload.get("explicit_ui_task", False)), bool(payload.get("has_expected_references", False)),
        )
    except ConfigError as exc:
        return {"ok": False, "reason": "verification.ui configuration is INVALID: %s" % exc}

    if not detection["required"]:
        return {"ok": True, "reason": "UI verification was not required for this task (%s)" % "; ".join(detection["reasons"])}

    summary_path = os.path.join(task_dir, RUNTIME_DIRNAME, SUMMARY_JSON)
    if not os.path.isfile(summary_path):
        return {"ok": False, "reason": "UI verification is required for this task (%s) but was never run (missing %s)" % ("; ".join(detection["reasons"]), os.path.relpath(summary_path, task_dir))}
    with open(summary_path) as f:
        summary = json.load(f)

    if summary["overall_status"] not in ("PASS", "NOT_REQUIRED"):
        return {"ok": False, "reason": "UI verification overall status is %s, not PASS" % summary["overall_status"]}
    if not summary.get("coverage_complete", True):
        return {"ok": False, "reason": "UI scenario selection does not cover required acceptance criteria: %s" % ", ".join(summary.get("missing_coverage", []))}

    review_text = payload.get("review_text", "") or ""
    if REQUIRED_REVIEWER_HEADING not in review_text:
        return {"ok": False, "reason": "Reviewer evidence file is missing the required '%s' section" % REQUIRED_REVIEWER_HEADING}

    return {"ok": True, "reason": "UI verification PASSED with complete coverage and a Reviewer evidence-review section"}


def _gate_cmd():
    payload = _read_stdin_json()
    result = gate_check(payload)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["ok"] else 1


_PUBLISH_EXCLUDE_SUFFIXES = (".trace.zip", ".webm")


def _publish_cmd(argv):
    dry_run = "--dry-run" in argv
    payload = _read_stdin_json()
    gate = gate_check(payload)
    if not gate["ok"]:
        print(json.dumps({"published": False, "dry_run": dry_run, "reason": gate["reason"]}, sort_keys=True))
        return 1

    task_dir = payload["task_dir"]
    run_dir = os.path.join(task_dir, RUNTIME_DIRNAME)
    dest_dir = payload["destination_dir"]  # <spec-directory>/verification/ui

    with open(os.path.join(run_dir, SUMMARY_JSON)) as f:
        summary = json.load(f)

    manifest = []

    def plan_file(rel_src, rel_dest):
        manifest.append({"src": rel_src, "dest": rel_dest})

    manifest.append({"src": None, "dest": "README.md", "generated": True})
    manifest.append({"src": None, "dest": "summary.md", "generated": True})
    manifest.append({"src": ENVIRONMENT_JSON, "dest": "environment.md", "generated": True})
    if os.path.isfile(os.path.join(run_dir, CONSOLE_ERRORS_JSON)):
        plan_file(CONSOLE_ERRORS_JSON, "console-errors.json")
    if os.path.isfile(os.path.join(run_dir, NETWORK_ERRORS_JSON)):
        plan_file(NETWORK_ERRORS_JSON, "network-errors.json")

    scenarios_root = os.path.join(run_dir, "scenarios")
    scenario_dirs = sorted(os.listdir(scenarios_root)) if os.path.isdir(scenarios_root) else []
    for slug in scenario_dirs:
        sdir = os.path.join(scenarios_root, slug)
        result_path = os.path.join(sdir, "result.json")
        if not os.path.isfile(result_path):
            continue
        manifest.append({"src": os.path.join("scenarios", slug, "report.md"), "dest": "scenarios/%s.md" % slug, "generated": False})
        shots_dir = os.path.join(sdir, "screenshots")
        if os.path.isdir(shots_dir):
            for name in sorted(os.listdir(shots_dir)):
                if name.endswith(_PUBLISH_EXCLUDE_SUFFIXES):
                    continue
                manifest.append({"src": os.path.join("scenarios", slug, "screenshots", name), "dest": "scenarios/%s/%s" % (slug, name), "generated": False})

    total_bytes = 0
    for entry in manifest:
        if entry["src"]:
            p = os.path.join(run_dir, entry["src"])
            if os.path.isfile(p):
                total_bytes += os.path.getsize(p)

    if dry_run:
        print(json.dumps({
            "published": False, "dry_run": True, "destination": dest_dir,
            "files": [e["dest"] for e in manifest], "estimated_bytes": total_bytes,
        }, indent=2, sort_keys=True))
        return 0

    os.makedirs(dest_dir, exist_ok=True)
    os.makedirs(os.path.join(dest_dir, "scenarios"), exist_ok=True)

    for entry in manifest:
        dest_path = os.path.join(dest_dir, entry["dest"])
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        if entry.get("generated"):
            continue
        src_path = os.path.join(run_dir, entry["src"])
        if os.path.isfile(src_path):
            shutil.copyfile(src_path, dest_path)

    _atomic_write(os.path.join(dest_dir, "summary.md"), render_summary_markdown(summary))
    _atomic_write(os.path.join(dest_dir, "environment.md"), _render_environment_md(run_dir))
    _atomic_write(os.path.join(dest_dir, "README.md"), _render_readme_md(payload, summary))

    published_bytes = sum(
        os.path.getsize(os.path.join(dest_dir, e["dest"]))
        for e in manifest if os.path.isfile(os.path.join(dest_dir, e["dest"]))
    )
    print(json.dumps({
        "published": True, "dry_run": False, "destination": dest_dir,
        "files": [e["dest"] for e in manifest], "bytes": published_bytes,
    }, indent=2, sort_keys=True))
    return 0


def _render_environment_md(run_dir):
    env_path = os.path.join(run_dir, ENVIRONMENT_JSON)
    if not os.path.isfile(env_path):
        return "# Environment\n\n(not recorded)\n"
    with open(env_path) as f:
        env = json.load(f)
    lines = ["# Environment", ""]
    for k in sorted(env.keys()):
        lines.append("- %s: %s" % (k, env[k]))
    lines.append("")
    return "\n".join(lines)


def _render_readme_md(payload, summary):
    lines = ["# UI Verification Evidence", ""]
    lines.append("- Task: %s" % payload.get("task_id", "(unknown)"))
    lines.append("- Verification date: %s" % summary.get("finished_at"))
    lines.append("- Overall status: %s" % summary["overall_status"])
    lines.append("- Visual comparison performed: %s" % summary["visual_comparison_performed"])
    lines.append("")
    lines.append("| Scenario | Acceptance criterion | Result | Evidence |")
    lines.append("|---|---|---|---|")
    for s in summary["scenarios"]:
        lines.append("| %s | %s | %s | [Open](scenarios/%s.md) |" % (s["id"], "; ".join(s["acceptance_criteria"]), s["result"], s["id"]))
    lines.append("")
    lines.append("PASS: %d, FAIL: %d, BLOCKED: %d" % (summary["pass_count"], summary["fail_count"], summary["blocked_count"]))
    lines.append("")
    lines.append("Reviewer verification status: see the task's Reviewer evidence-review section.")
    lines.append("")
    return "\n".join(lines)


# --- doctor (spec section 35) -------------------------------------------------

def _doctor_cmd():
    payload = _read_stdin_json()
    try:
        cfg = normalize_ui_config(payload.get("raw_ui_config"))
    except ConfigError as exc:
        print(json.dumps({"config_valid": False, "error": str(exc)}, sort_keys=True))
        return 0
    root = payload.get("root", ".")
    detection = None
    try:
        if payload.get("changed_paths") is not None or payload.get("spec_text") is not None:
            detection = detect_ui_impact(cfg, payload.get("changed_paths", []), payload.get("spec_text", ""), bool(payload.get("explicit_ui_task", False)), bool(payload.get("has_expected_references", False)))
    except ConfigError:
        detection = None
    provider_ok, provider_detail = _playwright_available(cfg, root)
    manifest_path = os.path.join(root, cfg["scenarios"]["manifest"])
    manifest_status = "not configured"
    if os.path.isfile(manifest_path):
        manifest_status = "present"
    print(json.dumps({
        "config_valid": True,
        "enabled": cfg["enabled"],
        "detection": detection,
        "provider": cfg["provider"],
        "browsers": cfg["browsers"],
        "provider_available": provider_ok,
        "provider_detail": provider_detail,
        "runtime_start_command_configured": bool(cfg["runtime"]["start_command"]),
        "scenario_manifest_path": cfg["scenarios"]["manifest"],
        "scenario_manifest_status": manifest_status,
        "expected_reference_policy": cfg["expected_references"]["policy"],
        "publication_destination": cfg["publication"]["destination"],
        "publication_enabled": cfg["publication"]["enabled"],
    }, sort_keys=True))
    return 0


# --- cleanup (spec section 39) ------------------------------------------------

def _clean_cmd(argv):
    dry_run = "--dry-run" in argv
    payload = _read_stdin_json()
    root = payload["root"]
    active_task_dirs = set(payload.get("active_task_dirs", []))
    candidate_task_dirs = payload.get("candidate_task_dirs", [])
    removed = []
    kept = []
    for task_dir in candidate_task_dirs:
        run_dir = os.path.join(task_dir, RUNTIME_DIRNAME)
        if not os.path.isdir(run_dir):
            continue
        if task_dir in active_task_dirs:
            kept.append({"task_dir": task_dir, "reason": "task is still in-flight"})
            continue
        removed.append({"task_dir": task_dir, "path": run_dir})
        if not dry_run:
            shutil.rmtree(run_dir, ignore_errors=True)
    print(json.dumps({"dry_run": dry_run, "removed": removed, "kept": kept}, indent=2, sort_keys=True))
    return 0


def main(argv):
    if not argv:
        print("usage: ui_verification_lib.py <detect|plan|run|report|publish|gate|doctor|clean> ...", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "detect":
            return _detect_cmd(rest)
        if cmd == "plan":
            return _plan_cmd(rest)
        if cmd == "run":
            return _run_cmd(rest)
        if cmd == "report":
            return _report_cmd(rest)
        if cmd == "publish":
            return _publish_cmd(rest)
        if cmd == "gate":
            return _gate_cmd()
        if cmd == "doctor":
            return _doctor_cmd()
        if cmd == "clean":
            return _clean_cmd(rest)
    except ConfigError as exc:
        print("ui_verification_lib.py: %s" % exc, file=sys.stderr)
        return 1
    print("ui_verification_lib.py: unknown command %r" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
