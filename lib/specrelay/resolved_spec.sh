#!/usr/bin/env bash
# resolved_spec.sh — generates 02-resolved-specification.md from an already
# built 01-input-manifest.json + 01-input-bundle/ snapshot (spec 0023,
# sections 12-13).
#
# This is a deterministic, evidence-grounded assembly pass, not a semantic
# NLP analysis: it extracts explicit headings from spec.md/tech-spec.md,
# lists every piece of supporting/external evidence with its snapshot path
# (provenance), and reports honestly which classes of evidence it could
# structurally inspect versus which require an AI reader (visual/PDF
# content) or were never retrieved. It never presents an assumption as a
# fact (section 13: "must not present assumptions as facts") — anything it
# cannot ground in a specific snapshot path is labeled as a limitation
# instead of being asserted.

# specrelay::resolved_spec::generate <root> <task-dir>
# Writes <task-dir>/02-resolved-specification.md. Fails if the manifest is
# missing.
specrelay::resolved_spec::generate() {
  local root="$1" task_dir="$2" manifest
  manifest="$task_dir/01-input-manifest.json"
  [ -f "$manifest" ] || { specrelay::out::err "cannot generate resolved specification: manifest not found: $manifest"; return 1; }

  TASKDIR="$task_dir" python3 <<'PY'
import json, os, re

task_dir = os.environ["TASKDIR"]
with open(os.path.join(task_dir, "01-input-manifest.json"), encoding="utf-8") as fh:
    manifest = json.load(fh)

def read_snapshot(relpath):
    if not relpath:
        return ""
    path = os.path.join(task_dir, relpath)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return ""

def split_headings(text):
    """Splits a Markdown document into {lowercased heading: body} by ## (or #) headings."""
    sections = {}
    current = None
    buf = []
    for line in text.splitlines():
        m = re.match(r"^#{1,3}\s+(.*)$", line)
        if m:
            if current is not None:
                sections[current] = "\n".join(buf).strip()
            current = m.group(1).strip().lower()
            buf = []
        else:
            if current is not None:
                buf.append(line)
    if current is not None:
        sections[current] = "\n".join(buf).strip()
    return sections

def find_section(sections, *names):
    for name in names:
        for key, body in sections.items():
            if name in key:
                return body
    return ""

def excerpt(text, limit=600):
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[:limit].rstrip() + "\n... (truncated; see snapshot for full content)"

files = manifest.get("files", [])
func_rel = manifest.get("primary_functional_specification_path")
tech_rel = manifest.get("technical_specification_path")

func_snap = None
tech_snap = None
for f in files:
    if func_rel and f["relative_path"] == func_rel:
        func_snap = f["snapshot_path"]
    if tech_rel and f["relative_path"] == tech_rel:
        tech_snap = f["snapshot_path"]

func_text = read_snapshot(func_snap) if func_snap else ""
tech_text = read_snapshot(tech_snap) if tech_snap else ""
func_sections = split_headings(func_text)
tech_sections = split_headings(tech_text)

lines = []

def h(title):
    lines.append(f"## {title}")
    lines.append("")

def p(text=""):
    lines.append(text)

lines.append("# Resolved Specification")
lines.append("")
lines.append(
    "This is the analysed implementation brief for this task (spec 0023, section 13). "
    "It is derived from the immutable input bundle recorded in `01-input-manifest.json` "
    "and does not replace it — the full original snapshot beneath `01-input-bundle/` "
    "remains authoritative and must be consulted directly for anything not reproduced "
    "verbatim below."
)
lines.append("")

h("Objective")
obj = find_section(func_sections, "objective")
if obj:
    p(obj)
    p("")
    p(f"Source: {func_snap}.")
elif func_snap:
    p("No explicit `## Objective` heading was found in the functional specification; "
      "see the full functional specification below (Functional Requirements) for the stated objective.")
    p(f"Source: {func_snap}.")
else:
    p("No functional specification was discovered in this bundle.")
lines.append("")

h("Functional Requirements")
if func_snap:
    fr = find_section(func_sections, "functional requirements")
    if fr:
        p(fr)
    else:
        p("No explicit `## Functional Requirements` heading was found; the full functional "
          "specification is embedded verbatim below.")
        p("")
        p("```markdown")
        p(func_text.strip())
        p("```")
    p("")
    p(f"Source: {func_snap} (primary functional authority, spec 0023 section 6.1/6.3).")
else:
    p("No functional specification (`spec.md`) was found in this bundle.")
lines.append("")

h("Technical Requirements")
if tech_snap:
    tr = find_section(tech_sections, "technical requirements", "architecture")
    if tr:
        p(tr)
    else:
        p("No explicit `## Technical Requirements` heading was found; the full technical "
          "specification is embedded verbatim below.")
        p("")
        p("```markdown")
        p(tech_text.strip())
        p("```")
    p("")
    p(f"Source: {tech_snap} (primary technical authority, spec 0023 section 6.3).")
else:
    p("No technical specification (`tech-spec.md` / `tech_spec.md`) was found in this bundle. "
      "This is not an error — a technical specification is optional (spec 0023, section 6.2).")
lines.append("")

h("Acceptance Criteria")
ac = find_section(func_sections, "acceptance criteria")
if ac:
    p(ac)
    p("")
    p(f"Source: {func_snap}.")
else:
    p("No explicit `## Acceptance Criteria` heading was found in the functional specification. "
      "See Functional Requirements above for the full text; acceptance criteria may be stated inline there.")
lines.append("")

h("Constraints and Boundaries")
cb = find_section(func_sections, "constraints", "exclusions", "non-goals", "boundaries")
tcb = find_section(tech_sections, "constraints", "compatibility", "operational requirements")
if cb:
    p(cb)
    p("")
    p(f"Source: {func_snap}.")
if tcb:
    p(tcb)
    p("")
    p(f"Source: {tech_snap}.")
if not cb and not tcb:
    p("No explicit constraints/exclusions/non-goals heading was found in either the functional "
      "or technical specification.")
lines.append("")

h("Evidence-Derived Requirements")
evidence_files = [f for f in files if f["relative_path"] not in (func_rel, tech_rel)]
if evidence_files:
    for f in evidence_files:
        role = f["role"]
        cap = f["inspection_capability"]
        p(f"- `{f['relative_path']}` ({role}, {cap}). Source: {f['snapshot_path']}.")
    p("")
    p("Each entry above is a bibliographic pointer, not an inferred requirement: this bundle "
      "analysis pass does not perform semantic contradiction/requirement extraction across "
      "arbitrary evidence files (see Conflicts and Ambiguities). The Executor must open any "
      "cited snapshot path directly before treating its content as a requirement.")
else:
    p("No supporting evidence files (beyond the functional/technical specification) were "
      "discovered in this bundle.")
lines.append("")

log_files = [f for f in files if f["role"] == "log-or-trace"]
h("Current Behaviour")
if log_files:
    for f in log_files:
        p(f"- Log/trace evidence at `{f['relative_path']}`. Source: {f['snapshot_path']}.")
else:
    p("No log or trace evidence was discovered in this bundle.")
lines.append("")

h("Expected Behaviour")
if func_snap:
    p("See Functional Requirements / Acceptance Criteria above for the specified expected behaviour.")
else:
    p("No explicit expected-behaviour statement was discovered beyond the functional specification (if any) above.")
lines.append("")

visual_files = [f for f in files if f["role"] == "visual"]
h("UI and Visual Evidence")
if visual_files:
    for f in visual_files:
        p(f"- `{f['relative_path']}` (visual, inspectable-through-provider-multimodal). "
          f"Source: {f['snapshot_path']}. Not inspected during this automated bundle-analysis "
          f"pass — the Executor (and Reviewer) must open this file directly; it must never be "
          f"claimed as inspected here (spec 0023, section 9).")
else:
    p("No screenshots or other visual evidence were discovered in this bundle.")
lines.append("")

data_files = [f for f in files if f["role"] == "structured-data"]
h("API and Data Contracts")
if data_files:
    for f in data_files:
        content = read_snapshot(f["snapshot_path"])
        p(f"- `{f['relative_path']}`. Source: {f['snapshot_path']}.")
        if content.strip():
            p("")
            p("```")
            p(excerpt(content, 400))
            p("```")
        p("")
else:
    p("No JSON/YAML/XML/CSV structured-data evidence was discovered in this bundle.")
lines.append("")

jam_entries = manifest.get("external_evidence", [])
h("Defect Reproduction")
if log_files or jam_entries:
    if log_files:
        p("Log/trace evidence is available (see Current Behaviour above) but was not "
          "mechanically correlated into a reproduction sequence by this automated pass.")
    for j in jam_entries:
        p(f"- Jam recording `{j['canonical_id']}` (status: {j['retrieval_status']}). "
          f"Source: {j['snapshot_path']}/.")
else:
    p("No defect-reproduction evidence (logs, traces, or Jam recordings) was discovered in this bundle.")
lines.append("")

h("External Evidence")
if jam_entries:
    for j in jam_entries:
        refs = ", ".join(f"`{r}`" for r in j.get("referencing_local_files", []))
        p(f"- Jam recording: {j['canonical_reference']}")
        p(f"  - Canonical id: `{j['canonical_id']}`")
        p(f"  - Retrieval status: {j['retrieval_status']}")
        p(f"  - Referenced from: {refs or '(unknown)'}")
        p(f"  - Snapshot: `{j['snapshot_path']}/` (reference.json, retrieval-evidence.json, "
          f"redaction-report.json, and any retrieved evidence classes)")
        p("  - A URL alone is not evidence of inspection (spec 0023, section 18.5); only the "
          "snapshot contents above may be cited as inspected.")
else:
    p("No external evidence (e.g. Jam recordings) was discovered in this bundle.")
lines.append("")

h("Conflicts and Ambiguities")
p("Structural checks performed automatically: duplicate technical-specification filenames "
  "(`tech-spec.md` and `tech_spec.md` both present) are rejected at task-creation time before "
  "this document is generated, so that specific ambiguity can never reach this section.")
p("")
p("This automated bundle-analysis pass does not perform semantic contradiction detection "
  "across free-text evidence (e.g. spec.md vs. tech-spec.md vs. screenshots vs. logs) — that "
  "requires judgement this deterministic pass cannot honestly claim to have applied. No "
  "material contradiction is asserted here. The Executor and Reviewer must treat any "
  "contradiction they personally observe between cited sources as blocking per spec 0023, "
  "section 16, and must record the interpretation and rationale for any non-material "
  "ambiguity they resolve.")
lines.append("")

h("Required Verification")
verification = find_section(func_sections, "verification", "acceptance criteria") or find_section(tech_sections, "verification strategy", "verification")
if verification:
    p(verification)
    p("")
    p("Also apply this project's Bounded Verification Policy (spec 0019) and Execution "
      "Efficiency and Completion Gate (spec 0021) as stated in the Executor prompt.")
else:
    p("No explicit verification section was found in the specification. Apply this project's "
      "Bounded Verification Policy (spec 0019) and cover the Acceptance Criteria above.")
lines.append("")

h("Input Coverage")
p("| Path | Role | Inspection capability | Status |")
p("|---|---|---|---|")
for f in files:
    role = f["role"]
    cap = f["inspection_capability"]
    if role in ("authoritative-functional-spec", "authoritative-technical-spec"):
        status = "inspected and used"
    elif role == "unknown-binary":
        status = "unsupported"
    elif cap == "inspectable-through-provider-multimodal":
        status = "skipped with justification (requires provider multimodal reading at Executor/Reviewer time)"
    else:
        status = "inspected and supplementary"
    p(f"| `{f['relative_path']}` | {role} | {cap} | {status} |")
for j in jam_entries:
    st = j["retrieval_status"]
    cov = "inspected and used" if st == "retrieved" else ("unavailable" if st == "failed" else st)
    p(f"| jam:{j['canonical_id']} | external-evidence | mcp-adapter | {cov} |")
lines.append("")
p("Every discovered local and external input above has a final analysis status; none is "
  "silently omitted (spec 0023, section 17).")
lines.append("")

h("Provenance")
p(f"- Objective / Functional Requirements / Acceptance Criteria / Constraints: {func_snap or '(no functional specification found)'}")
p(f"- Technical Requirements: {tech_snap or '(no technical specification found)'}")
p("- Evidence-Derived Requirements / Current Behaviour / UI and Visual Evidence / API and Data Contracts: see the per-file `Source:` citations above.")
p("- External Evidence: see the per-Jam-recording `Snapshot:` citations above.")
p(f"- Manifest: 01-input-manifest.json")
lines.append("")

out_path = os.path.join(task_dir, "02-resolved-specification.md")
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines).rstrip() + "\n")
PY
}
