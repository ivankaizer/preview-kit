# preview-kit

Per-PR preview environments on the staging Dokploy server, with recorded demos.

For every pull request in an onboarded repo:

1. CI runs the repo's tests.
2. If they pass, the repo's `docker-compose.preview.yml` is deployed to
   `https://<branch>.<project>.deployment.lat`.
3. A scripted Playwright tour of the preview is recorded (MP4, GIF and step screenshots). From the
   second commit on, each step is compared with the previous commit and a **changes** video shows
   only the steps that look different (before | after, changed pixels highlighted).
4. One sticky PR comment carries the URL, the tour and the changes.
5. Closing or merging the PR removes the preview and its demos.

Demos are stored on an orphan branch `demos/pr-<n>` in the repo itself. It is force-pushed as a
single commit so the repo doesn't grow, it is deleted with the PR, and it is visible only to people
with access to the repo.

## CLI

```sh
gh repo clone ivankaizer/preview-kit ~/.preview-kit
ln -s ~/.preview-kit/bin/preview ~/.local/bin/preview   # any directory on PATH
```

Run it inside a repository:

| Command | What it does |
|---|---|
| `preview init [project]` | Scaffolds `.preview/`, `docker-compose.preview.yml` and the cleanup workflow (never overwrites) |
| `preview onboard` | One-time setup: Dokploy project + `previews` environment, read-only deploy key, `DOKPLOY_API_KEY` repo secret |
| `preview deploy` | Deploys this branch's PR and prints the URL (CI does this automatically) |
| `preview demo` | Records the tour on the preview, compares with the last published demo, publishes |
| `preview url` | Prints this branch's preview URL |
| `preview status` | Lists the project's previews |
| `preview destroy` | Removes this branch's preview and demos |

Requirements: `bash`, `curl`, `jq`, `gh` (authenticated), plus `node` and `ffmpeg` for `demo`.
Credentials: `DOKPLOY_URL` and `DOKPLOY_API_KEY` from the environment, or `~/.env`. Never commit them.
`PR_NUMBER` and `BRANCH` default to the PR of the checked-out branch.

## Onboarding a repo

```sh
cd my-repo
preview init          # project name defaults to the repo name
# edit docker-compose.preview.yml, .preview/config.json, .preview/tour.json
preview onboard
# add the `preview` job printed by init after your test job; push; open a PR
```

### `.preview/config.json`

```json
{
  "project": "playdex",
  "compose": "docker-compose.preview.yml",
  "routes": [
    { "service": "ui", "port": 5056, "path": "/" },
    { "service": "app", "port": 3000, "path": "/api" }
  ],
  "healthcheck": ["/", "/api/"],
  "env": "SOME_VAR=value"
}
```

- `project` is the subdomain and the Dokploy project name.
- `routes` map paths on the preview host to compose services. The longest path wins, and
  `"stripPath": true` removes the prefix before forwarding.
- `healthcheck` lists paths that must answer 2xx–4xx before the deploy counts as done.
- `env` is written to the stack's `.env` for compose interpolation.

### `docker-compose.preview.yml`

- Build production images.
- Don't publish host ports.
- Set `mem_limit` on every service. The server has 4 GB of RAM shared by all previews.
- Seed demo data with a one-shot service that runs once per preview (see playdex's `seeder` service).

### `.preview/tour.json`

```json
{
  "viewport": { "width": 1440, "height": 810 },
  "sessions": [
    { "name": "user", "steps": [
      { "name": "landing", "visit": "/" },
      { "name": "login", "login": "/login", "email": "user@example.dev", "password": "password" },
      { "name": "dashboard", "visit": "/dashboard", "wait": "text=Today" }
    ]}
  ]
}
```

- Each session gets a fresh browser context, and the sessions are recorded back to back.
- Login steps fill the first email (or text) and password inputs, then submit. Override with
  `emailSelector`, `passwordSelector` or `submitSelector`.
- Use only seeded, preview-only accounts.
- The browser clock is frozen to the first demo's time, so relative times don't count as changes.
  A step counts as changed when at least 0.2% of its pixels differ.

## Layout

```
bin/preview                  CLI entry point
lib/preview.sh               Dokploy API: deploy / destroy / url
lib/onboard.sh, lib/init.sh  repo setup
lib/demo/                    tour recorder, comparison, publishing (Node + Playwright + ffmpeg)
actions/{deploy,demo,cleanup}   composite actions wrapping the CLI
.github/workflows/preview.yml   reusable: deploy → demo → sticky PR comment
.github/workflows/cleanup.yml   reusable: destroy on PR close
skills/deploy-preview/       agent skill (install into ~/.claude/skills)
```

The repo is private. Other repos can use its actions and workflows because of
*Settings → Actions → General → Access: accessible from repositories owned by the user*.
