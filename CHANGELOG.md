# Changelog

## v1.4.0 — 2026-10-10

- `runner` input on `preview.yml`, `staging.yml` and `cleanup.yml`: run the job on a self-hosted
  runner, e.g. `runner: '["self-hosted","macserv"]'`. Default `"ubuntu-latest"`, unchanged.
- The demo action installs ffmpeg and Chromium's system libraries only where `apt-get` exists;
  elsewhere it expects them to be present.

## v1.3.0 — 2026-10-10

- `"tls": "edge"` in `.preview/config.json`: for a Dokploy server behind a TLS-terminating
  reverse proxy. Preview and staging domains are created with `https: false`, so Traefik serves
  plain HTTP and doesn't redirect the proxy's requests. The default (`letsencrypt`) is unchanged.

## v1.2.1 — 2026-10-08

- **Fix:** the `deploy` and `staging` actions reported success when the deploy failed. The URL
  was captured inside `echo`'s argument, so the step's exit status was `echo`'s. Failed deploys
  (build error, Dokploy `error`, failed healthcheck) now fail the job.

## v1.2.0 — 2026-10-08

- **Staging:** a `staging` section in `.preview/config.json` adds a long-lived stack for the
  staging branch (default `dev`) at `https://<project>.<domain>`.
  - `preview staging deploy|url|destroy`, the composite action `actions/staging` and the
    reusable workflow `staging.yml` (deploys queue instead of cancelling).
  - `preview onboard` creates the project's `staging` environment.
  - Pull requests from the staging branch skip the preview deploy and the demo.
- **Shared Postgres:** `preview db setup|status` creates one Postgres per Dokploy server. With
  `"database": "shared"`, staging gets its own role and database on it, passed as `DATABASE_URL`
  and `PG*` variables.

## v1.1.0 — 2026-10-05

- `preview.yml` input `comment`: `sticky` (default, unchanged behavior) or `new`, which posts a
  fresh PR comment on every deploy instead of editing the previous one.
- `preview.yml` input `hide-previous` (default `false`): with `comment: new`, collapses earlier
  preview comments as outdated.

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
