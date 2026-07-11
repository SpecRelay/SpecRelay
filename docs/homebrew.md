# Homebrew packaging plan (not yet published)

This document is the Homebrew readiness plan required by spec 0008 (section 7).
It describes a **phased** approach and a **sample** formula. Nothing here is
published, and **no Homebrew tap is available today.**

> **No official tap exists.** There is no `SpecRelay/tap`, no `brew install
> specrelay`, and no Homebrew-core formula. Do not run any `brew` command
> expecting to install SpecRelay yet — it will not work. Until a tap is created
> and tested (an explicit, human-authorized follow-up), install from source per
> [installation.md](installation.md). This document plans that future; it does
> not enable it.

## Why Homebrew is not enabled yet

Homebrew installs a formula by downloading a **release archive** at a **fixed
version tag** and verifying it against a recorded **sha256** checksum. SpecRelay
has none of those preconditions today:

- no version tag has been published (the repository has no tags);
- no release archive/tarball is published anywhere;
- therefore there is no real, stable sha256 to record;
- and open-source **licensing is still pending a human decision** (see
  [`../LICENSE.TODO`](../LICENSE.TODO)), which publication depends on.

A formula that pointed at a non-existent tarball, or that carried a fake
sha256, would be an untested, misleading artifact. So the formula in this
repository is a clearly-marked **template**, not a working install channel.

## Recommended phased approach

1. **Start with an organization/user tap** — for example a separate repository
   `SpecRelay/homebrew-tap` (installed as the tap `SpecRelay/tap`). A tap is the
   right first step: it is fully under the project's control, needs no approval
   from Homebrew maintainers, and can be iterated on freely while adoption is
   still small. The user-facing commands would eventually be:

   ```sh
   brew tap SpecRelay/tap
   brew install specrelay
   ```

   Neither of these works yet — the tap repository does not exist.

2. **Consider Homebrew core only later** — submitting to `homebrew-core` should
   happen only **after** stable public adoption and only once SpecRelay
   satisfies Homebrew's expectations for core formulae (notable/stable project,
   a real license, versioned release tarballs with checksums, no unusual build
   requirements, and passing `brew audit --strict`). This is a much higher bar
   than a tap and is deliberately deferred.

The tap repository is **not created in this task**, and must not be created
unless a maintainer explicitly requests it (spec 0008, section 7 and non-goals).

## What a tag, release archive, and sha256 are for

A Homebrew formula's `url` points at a tarball for one exact version, and its
`sha256` pins that tarball's contents so an install is reproducible and
tamper-evident. Concretely, once a real tag `vX.Y.Z` and its GitHub-generated
source tarball exist, the formula would reference:

```
url    "https://github.com/SpecRelay/SpecRelay/archive/refs/tags/vX.Y.Z.tar.gz"
sha256 "<the sha256 of that exact tarball>"
```

Both fields are meaningless until a real tag and archive are published, which is
why the sample formula below leaves them as placeholders.

## How to calculate a sha256 (once an archive exists)

```sh
# From a downloaded archive:
shasum -a 256 SpecRelay-X.Y.Z.tar.gz          # macOS / BSD
sha256sum   SpecRelay-X.Y.Z.tar.gz            # GNU/Linux

# Or directly from the release URL:
curl -fsSL https://github.com/SpecRelay/SpecRelay/archive/refs/tags/vX.Y.Z.tar.gz \
  | shasum -a 256
```

Homebrew's own helper, `brew fetch --build-from-source specrelay` (once the
formula resolves), also prints the downloaded archive's sha256.

## How to test a formula locally (before publishing)

Once a real tag/archive/sha256 exist and the sample formula is filled in, a
maintainer would validate it locally before any tap is published:

```sh
# Audit the formula for style/correctness:
brew audit --strict --new packaging/homebrew/specrelay.rb

# Install straight from the local formula file (no tap needed):
brew install --build-from-source packaging/homebrew/specrelay.rb

# Exercise the installed binary and run the formula's test block:
specrelay version
brew test specrelay
```

Only after a clean local install/test/audit against a **real** tarball with a
**real** sha256 should the formula be promoted from "template" to a published
tap formula.

## User-facing install command, once the tap exists

For reference only — this is what installation via a future tap would look
like; it does **not** work today:

```sh
brew tap SpecRelay/tap
brew install specrelay
specrelay version
```

Until then, the supported install path is source-based `install/install.sh`
(see [installation.md](installation.md)).

## The sample formula

A **sample/template** formula lives at
[`../packaging/homebrew/specrelay.rb`](../packaging/homebrew/specrelay.rb). It
is marked as a template in its header, uses placeholder `url`/`sha256` values,
and is **not** validated against a real release tarball. It exists to show the
intended shape only. It must not be treated as an official or working formula
until it targets a real published release tarball with a real sha256.
