# Publishing SpecRelay (future, human-only)

SpecRelay is currently a **local** standalone repository. It has never been
pushed to a remote, has no configured remote, and no tag or package has been
published. This document records the steps a human would take **later**, once a
license is confirmed, to publish it. Nothing here is executed automatically, and
no tool in this repository performs any of it.

## Remote readiness metadata

- **Recommended repository slug:** `specrelay`
- **Default branch:** `main`
- **License:** see `LICENSE.TODO` — publication is **blocked** until a human
  explicitly chooses and commits a real `LICENSE`. Do not publish without it.

## Future human steps

1. Confirm and commit a real `LICENSE` (replace `LICENSE.TODO`). Until then,
   **do not publish** — the project is `LICENSE_BLOCKED_PENDING_HUMAN_DECISION`.
2. Create the repository on the hosting provider (empty, no auto-generated
   files).
3. Add the remote:
   ```sh
   git remote add origin <url>
   ```
4. Verify visibility/permissions on the hosting provider.
5. Push `main`:
   ```sh
   git push -u origin main
   ```
6. Push tags **only after review** (tags imply a release):
   ```sh
   git push origin --tags
   ```
7. Configure branch protection on `main` (require review, require CI).
8. Enable CI (the workflow in `.github/workflows/ci.yml` runs `scripts/test`).

## Future remote release model (not implemented)

Once published, the intended release model is:

```
version tag  ->  release artifact  ->  checksum  ->  install pinned version
```

This project does **not** implement a fake checksum/release/download flow while
no real artifacts exist. Local, source-based installation (via `install/`) is
the only supported installation path until real signed releases exist.
