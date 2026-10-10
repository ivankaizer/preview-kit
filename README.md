# preview-kit

**Per-pull-request preview environments for docker-compose apps on a self-hosted
[Dokploy](https://dokploy.com) server, with a recorded demo of every commit.**

For every pull request in a repo that uses preview-kit:

1. Your CI runs its tests as usual.
2. If they pass, the repo's `docker-compose.preview.yml` is deployed to
   `https://<branch>.<project>.<your-domain>` with HTTPS.
3. A scripted browser tour of the preview is recorded as an MP4, a GIF and one screenshot per step.
4. From the second commit on, each step is compared with the previous commit, and a **changes**
   video shows only the steps that look different: before and after side by side, with the changed
   pixels highlighted.
5. A PR comment carries the URL, the tour and the changes. By default one comment is updated on
   every push; set `comment: new` to post one per push instead.
6. Merging or closing the PR removes the preview and its demos.

It is a set of bash scripts, a small Node/Playwright recorder and GitHub Actions workflows. There is
no service to run besides Dokploy.

### Why

- Dokploy's built-in preview deployments only cover single-Dockerfile applications, not compose
  stacks, and they deploy whether or not the tests pass.
- Reviewing a UI change usually means checking out the branch. A before/after video in the PR shows
  it in seconds, and a clean "no visual changes" result is a useful signal too.

## Requirements

- **A Dokploy server** (one VPS is enough). Its Traefik must be reachable on ports 80 and 443.
- **Wildcard DNS** for your preview domain, e.g. `*.previews.example.com → server IP`. The record
  must be DNS-only, not proxied: proxies such as Cloudflare's free plan don't cover two-level
  subdomains like `branch.project.previews.example.com`. Certificates are issued per host by
  Let's Encrypt over HTTP.
- **A Dokploy API key** with its rate limit disabled. Dokploy's default limit is about 10 requests
  per day, which a single deploy exhausts.
- **GitHub** for the repos. Fork PRs are skipped, because secrets aren't available to them.
- **Locally:** `bash`, `curl`, `jq` and `gh` (authenticated). The `demo` command also needs `node`
  20+ and `ffmpeg`.

## Install the CLI

```sh
gh repo clone ivankaizer/preview-kit ~/.preview-kit
ln -s ~/.preview-kit/bin/preview ~/.local/bin/preview   # any directory on your PATH
```

Put the secret and your defaults in `~/.env`. The CLI loads it, and it must never be committed:

```sh
export DOKPLOY_API_KEY=...                     # the secret
export DOKPLOY_URL=https://dokploy.example.com # default for `preview init`
export PREVIEW_DOMAIN=previews.example.com     # default for `preview init`
```

## Add previews to a repo

```sh
cd my-repo
preview init            # scaffolds the files below; the project name defaults to the repo name
# edit docker-compose.preview.yml, .preview/config.json and .preview/tour.json
preview onboard         # Dokploy project, read-only deploy key, DOKPLOY_API_KEY repo secret
```

Then add the job that `init` prints to the workflow that runs your tests, after the test job:

```yaml
  preview:
    needs: test
    if: github.event.pull_request.head.repo.full_name == github.repository
    uses: ivankaizer/preview-kit/.github/workflows/preview.yml@v1
    permissions:
      contents: write        # publishes demos to the demos/pr-<n> branch
      pull-requests: write   # posts the PR comment
    secrets: inherit
```

Optional inputs, under `with:` in that job:

| Input | Default | Meaning |
|---|---|---|
| `config` | `.preview/config.json` | Preview config path |
| `tour` | `.preview/tour.json` | Demo tour path |
| `demo` | `true` | Record a demo when the tour file exists |
| `comment` | `sticky` | `sticky` edits one PR comment on every push; `new` posts a fresh comment per push, so earlier demos stay in the thread (their files stay on the demos branch until the PR closes) |
| `hide-previous` | `false` | With `comment: new`, collapse earlier preview comments as outdated |
| `runner` | `"ubuntu-latest"` | Where the job runs, as JSON, e.g. `'["self-hosted","macserv"]'`. Also accepted by `staging.yml` and `cleanup.yml`. A self-hosted runner needs `jq`, `curl`, `gh`, Node and, for demos on non-apt distros, `ffmpeg` and Chromium's libraries. Never attach a self-hosted runner to a public repository |

`init` also creates `.github/workflows/preview-cleanup.yml`, which removes the preview when the PR
closes. Push and open a PR.

### `.preview/config.json`

```json
{
  "project": "shop",
  "domain": "previews.example.com",
  "dokploy": "https://dokploy.example.com",
  "compose": "docker-compose.preview.yml",
  "routes": [
    { "service": "web", "port": 8080, "path": "/" },
    { "service": "api", "port": 3000, "path": "/api" }
  ],
  "healthcheck": ["/", "/api/health"],
  "env": "FEATURE_FLAGS=all"
}
```

| Key | Meaning |
|---|---|
| `project` | Subdomain and Dokploy project name (a DNS label) |
| `domain`, `dokploy` | Your preview domain and Dokploy URL. Neither is secret |
| `routes` | Paths on the preview host and the compose services they reach. The longest path wins; `"stripPath": true` removes the prefix before forwarding |
| `healthcheck` | Paths that must answer 2xx–4xx before a deploy counts as successful |
| `env` | Lines written to the stack's `.env`, for compose variable interpolation |
| `tls` | `letsencrypt` (default): Dokploy's Traefik issues the certificates. `edge`: a reverse proxy in front of the Dokploy server terminates TLS and forwards plain HTTP, so domains are created without HTTPS |

### `docker-compose.preview.yml`

A production-like stack:

- Build production images.
- Don't publish host ports; Traefik reaches services over Dokploy's network.
- Set `mem_limit` on every service, since all previews share one server.
- Seed demo data with a one-shot service. To run it only on a preview's first deploy, have it
  write a marker to a volume and skip when the marker exists.

Each PR's stack runs in isolation (`docker compose -p`, a separate network, its own volumes). Its
volumes are deleted with the preview.

### `.preview/tour.json`

The tour is optional; without it, only the preview is deployed.

```json
{
  "viewport": { "width": 1440, "height": 810 },
  "mask": [".live-clock"],
  "sessions": [
    { "name": "customer", "steps": [
      { "name": "home", "visit": "/" },
      { "name": "login", "login": "/login", "email": "demo@example.com", "password": "demo" },
      { "name": "orders", "visit": "/orders", "wait": "text=Recent orders", "mask": [".order-total-today"] }
    ]},
    { "name": "admin", "steps": [
      { "name": "admin-login", "login": "/admin/login", "email": "admin@example.com", "password": "demo" },
      { "name": "admin-users", "visit": "/admin/users" }
    ]}
  ]
}
```

- **Sessions:** each one is a fresh browser context, so admin and user logins don't mix. Sessions
  are recorded back to back into one video.
- **`login` steps:** fill the first email (or text) input and the password input, then submit.
  Override with `emailSelector`, `passwordSelector` or `submitSelector`. Use seeded, preview-only
  accounts, because the credentials live in the repo.
- **Step names:** must be unique; they are how commits are compared.
- **Diff noise:**
  - The browser clock is frozen to the PR's first demo, so client-side relative times stay stable.
  - Server-side live values, such as counters or "today" totals, still change. Hide them with
    `mask` selectors at the tour, session or step level.
  - A step counts as changed when at least 0.2% of its pixels differ (`MIN_CHANGED`).
  - Runs are compared only when they were recorded on the same platform and browser build.

## Staging

Optionally, a project also gets a long-lived **staging** stack: the staging branch (default `dev`),
deployed on every push that passes the tests, at `https://<project>.<your-domain>`. A typical flow
is feature branch (preview) → `dev` (staging) → `main` (production). Pull requests from the
staging branch itself get no preview, since that code is already on staging.

Add a `staging` section to `.preview/config.json`:

```json
"staging": {
  "branch": "dev",
  "compose": "docker-compose.staging.yml",
  "database": "shared"
}
```

| Key | Default | Meaning |
|---|---|---|
| `branch` | `dev` | Branch deployed to staging |
| `compose` | `docker-compose.staging.yml` | Compose file for the staging stack. Same rules as previews |
| `host` | `<project>.<domain>` | Staging host |
| `database` | none | `shared`: give staging its own database on the server's shared Postgres (below) |
| `env` | none | Lines written to the stack's `.env` |

The stack reuses the config's `routes` and `healthcheck`. Run `preview onboard` again to create the
project's `staging` environment, then add a job to a workflow that runs on `push` to the branch:

```yaml
on:
  push:
    branches: [dev]

jobs:
  # ... your test job ...
  staging:
    needs: test
    if: github.event_name == 'push' && github.ref == 'refs/heads/dev'
    uses: ivankaizer/preview-kit/.github/workflows/staging.yml@v1
    secrets: inherit
```

Deploys queue rather than cancel each other, and the job's GitHub environment `staging` links to
the URL. Unlike previews, staging's volumes and data survive deploys.

### Shared Postgres

Instead of a database container per stack, staging stacks can share one Postgres server per
Dokploy host. Create it once per server:

```sh
preview db setup     # Dokploy project "shared", database app "shared-postgres", postgres:18
preview db status
```

With `"database": "shared"`, the first staging deploy creates a login role and database
`<project>_staging` (dashes become underscores) with a random password, and writes
`DATABASE_URL` plus `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and `PGPASSWORD` to the stack's
`.env`. Use them in the compose file, and put the services that need the database on Dokploy's
network as well as their own:

```yaml
services:
  api:
    environment:
      DATABASE_URL: ${DATABASE_URL:?set by preview-kit}
    networks: [default, dokploy-network]

networks:
  dokploy-network:
    external: true
```

- The role is created through a one-off Dokploy server job that runs `psql` inside the Postgres
  container and is deleted afterwards. The superuser password stays in Dokploy.
- Each role owns only its own database, and other roles can't connect to it.
- `preview staging destroy` removes the stack but keeps the database.
- Back up the shared server from its Dokploy page (Backups), since it holds every project's
  staging data.

## Production

A `production` section deploys version tags to the project's `production` environment. Images are
built once, by CI on a self-hosted runner that shares the Dokploy host's Docker, and pushed to a
registry on that host (e.g. `registry:2` bound to `localhost:5000`). Dokploy then runs the compose
file without its `build:` sections, so production runs exactly the images that were built.

```json
"production": {
  "compose": "docker-compose.prod.yml",
  "database": "dedicated",
  "generate": { "SESSION_SECRET": "hex:32" },
  "env": "LOG_LEVEL=info",
  "domains": [
    { "host": "dash.example.com", "service": "web", "port": 8080, "path": "/" },
    { "host": "api.example.com", "service": "api", "port": 3000, "path": "/" }
  ],
  "healthcheck": ["https://dash.example.com/", "https://api.example.com/health"]
}
```

| Key | Meaning |
|---|---|
| `compose` | Default `docker-compose.prod.yml`. Name images `localhost:5000/<project>/<service>:${IMAGE_TAG:?}`; give `build:` only to the service that builds each image, and use plain `${VAR}` for runtime settings, since CI builds without them |
| `database` | `dedicated`: its own Postgres (`<project>-postgres`) in the production environment, passed as `DATABASE_URL` |
| `generate` | Secrets created once when the stack is created: `base64:<bytes>` or `hex:<bytes>` |
| `env` | Extra lines for the stack's `.env` on creation. Set real secrets (SMTP, API keys) in Dokploy |
| `domains` | Hosts, paths and the services they reach |
| `healthcheck` | URLs that must answer 2xx–4xx after the deploy |

The caller runs the reusable workflow on tags:

```yaml
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: ivankaizer/preview-kit/.github/workflows/release.yml@v1
    with:
      runner: '["self-hosted","macserv"]'
    secrets: inherit
```

The deployed tag is `IMAGE_TAG` in the stack's `.env`. To roll back, re-run the release of an older
tag, or `preview prod deploy <old-tag>` while its images are still in the registry.

## CLI reference

Run it inside a repository. `PR_NUMBER` and `BRANCH` default to the PR of the checked-out branch.

| Command | What it does |
|---|---|
| `preview init [project]` | Scaffolds `.preview/`, `docker-compose.preview.yml` and the cleanup workflow. Never overwrites existing files |
| `preview onboard` | One-time setup, idempotent: Dokploy project with a `previews` environment, read-only deploy key, `DOKPLOY_API_KEY` repo secret |
| `preview deploy` | Deploys this branch's PR and prints the URL (CI does this automatically) |
| `preview demo` | Records the tour, compares it with the last published demo and publishes both |
| `preview url` | Prints the preview URL |
| `preview status` | Lists the project's previews |
| `preview prune` | Removes previews whose PR is no longer open (e.g. a cleanup job failed) |
| `preview destroy` | Removes this branch's preview and its demos |
| `preview staging deploy` | Deploys the staging branch and prints the staging URL (CI does this on push) |
| `preview staging url` / `destroy` | Prints the staging URL / removes the staging stack (the database is kept) |
| `preview db setup` / `status` | Creates the server's shared Postgres (once per server) / shows it |
| `preview prod build <tag>` | Builds the production images and pushes them (on the Dokploy host) |
| `preview prod deploy <tag>` / `url` | Deploys `<tag>` to production / prints the production URLs |

## How it works

- **Deploy:** `lib/preview.sh` talks to the Dokploy API. Each PR becomes a compose app `pr-<n>` in
  the project's `previews` environment.
  - Dokploy clones the PR branch over SSH with a read-only deploy key and builds on the server.
  - One domain is created per route.
  - The host is the branch slug. Branches that slug the same get a `-pr<n>` suffix.
- **Demos:** stored on an orphan branch `demos/pr-<n>` in the repo itself.
  - Each run adds a folder for its commit and force-pushes a single commit, so the repo doesn't
    keep old binaries in its history.
  - The branch is deleted with the PR.
  - PR comments link to the files there, so only people with access to the repo can see them.
- **Concurrency:** one deploy per PR at a time; a newer push cancels the older run.

## Limitations

- **One Dokploy server.** Images build on the server, so size it for your largest stack plus a
  couple of concurrent builds. Previews of large apps need several GB of RAM each.
- **GitHub only.** The deploy key, PR comments and demos branch use GitHub APIs.
- **Demos see seeded data only.** The tour runs against whatever the preview's database contains.
- **Generic login.** Login steps fit standard email and password forms. SSO or MFA flows need
  custom selectors, or a preview-only bypass in your app.

## Versioning

Workflows and actions are referenced as `@v1`. The `v1` tag moves with backwards-compatible
releases (`v1.x.y`); breaking changes get `v2`. See [CHANGELOG.md](CHANGELOG.md).

## Layout

```
bin/preview                      CLI entry point
lib/preview.sh                   Dokploy API: deploy / destroy / url
lib/staging.sh                   Dokploy API: the staging stack
lib/shared-db.sh                 shared Postgres: setup, per-project databases
lib/init.sh, lib/onboard.sh      repo setup
lib/demo/                        tour recorder, comparison, publishing (Node + Playwright + ffmpeg)
actions/{deploy,demo,cleanup,staging}/  composite actions wrapping the CLI
.github/workflows/preview.yml    reusable: deploy → demo → PR comment
.github/workflows/cleanup.yml    reusable: remove the preview on PR close
.github/workflows/staging.yml    reusable: deploy the staging branch
skills/deploy-preview/           agent skill (Claude Code); link it into ~/.claude/skills
```

## License

MIT
