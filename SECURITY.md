# Security Policy

SpecRelay is a workflow tool that **invokes external AI/provider commands** and
runs a spec-driven executor/reviewer loop. This document describes its trust
assumptions and how to report a vulnerability.

> Maintainer note: replace the reporting contact below with a real, monitored
> address or private disclosure channel before publishing this project. Do not
> ship a placeholder contact as if it were real.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately**, not in a public issue.

- Preferred: a private security advisory / private disclosure channel on the
  project's hosting platform, once the project is published.
- Until a public repository and contact exist, report to the maintainer through
  the same private channel you use to reach them for this project.

`<MAINTAINER: configure a private security contact here>`

Please include: affected version (see the `VERSION` file), a description, and
reproduction steps. We aim to acknowledge reports and coordinate a fix and
disclosure timeline.

## Trust model and assumptions

- **Provider commands are trusted code you configure.** SpecRelay runs the
  executor/reviewer provider commands you select in `.specrelay/config.yml`
  (e.g. the Claude CLI). Treat configuring a provider as granting it the
  ability to run and modify code in your project, exactly as if you ran that
  tool yourself.
- **Project config is trusted, not a sandbox.** `.specrelay/config.yml` selects
  which commands run. Only use configs you trust. SpecRelay parses YAML with a
  safe loader (`YAML.safe_load`) and does not evaluate arbitrary objects, but a
  malicious config can still point roles at malicious provider commands.
- **No credentials in config.** SpecRelay does not store provider credentials
  in its configuration. Provider authentication is the provider CLI's
  responsibility (e.g. the Claude CLI's own login/token handling), outside
  SpecRelay's config and state.

## Secret handling and evidence sensitivity

- Do not put secrets, tokens, or credentials in `.specrelay/config.yml`, specs,
  or task evidence. SpecRelay does not intentionally write credentials to logs.
- **Evidence and logs may be sensitive.** Task runtime directories capture
  diffs, command output, and provider stdout/stderr. Treat them as you would
  any build log: review before sharing, and decide deliberately whether to
  commit them (the runtime evidence directory is `.gitignore`d by default in
  freshly-initialized projects).
- Prompt/evidence files can contain your source and spec text. Do not paste
  them into untrusted places.

## Safety properties SpecRelay tries to preserve

- The executor cannot self-approve: the review submission requires a
  short-lived, single-use authorization the executor process cannot obtain.
- A human always performs the final review before a task is done.
- Task state is written only through audited transitions.
- Task IDs and runtime paths are validated; path traversal (e.g. `../`) is
  refused.
- Locking uses atomic `mkdir` (no dependence on `flock`), and temporary files
  use `mktemp` rather than predictable names.

## Scope

This policy covers the SpecRelay tool itself. It does not cover the security of
the external AI providers you configure, nor of the projects SpecRelay operates
on. This is a young, incubating project; the properties above are engineering
goals backed by tests, not a claim of a completed formal security audit.
