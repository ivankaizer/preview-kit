# Changelog

## v1.0.0 — 2026-10-04

First release.

- `preview` CLI: `init`, `onboard`, `deploy`, `demo`, `url`, `status`, `prune`, `destroy`.
- Reusable workflows `preview.yml` (deploy → demo → sticky PR comment) and `cleanup.yml`.
- Demo recorder:
  - Playwright tour from `.preview/tour.json`, with login steps, sessions and masks.
  - Frozen browser clock.
  - Before/after comparison per step, with a changes video, GIF and inline PR images.
  - Same-platform guard.
- Demos published to an orphan `demos/pr-<n>` branch, force-pushed as one commit and deleted with
  the PR.
- Domain and Dokploy URL come from `.preview/config.json`; nothing is hardcoded.
- Branch-slug collisions get a `-pr<n>` suffix, and the deploy re-points to the PR's current head
  branch.
