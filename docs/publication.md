# Publishing SpecRelay (future, human-only)

SpecRelay now has a configured remote — `origin` points to
`git@github.com:SpecRelay/SpecRelay.git` and the default branch `main` tracks
`origin/main`. No tag or package has been published, and **open-source
licensing is still pending a human decision** (see `LICENSE.TODO`). This
document records the remaining steps a human would take **later**, once a
license is confirmed, to publish a release. Nothing here is executed
automatically, and no tool in this repository performs any of it.

## Remote readiness metadata

- **Recommended repository slug:** `specrelay`
- **Default branch:** `main`
- **License:** see `LICENSE.TODO` — publication is **blocked** until a human
  explicitly chooses and commits a real `LICENSE`. Do not publish without it.

## Future human steps

1. Confirm and commit a real `LICENSE` (replace `LICENSE.TODO`). Until then,
   **do not publish** — the project is `LICENSE_BLOCKED_PENDING_HUMAN_DECISION`.
2. The repository already exists on the hosting provider (GitHub). Creating it
   is therefore done; a fresh clone needs no `git remote add`.
3. The remote is already configured (`origin` →
   `git@github.com:SpecRelay/SpecRelay.git`); confirm it before publishing:
   ```sh
   git remote -v
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
