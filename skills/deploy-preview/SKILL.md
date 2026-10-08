---
name: deploy-preview
description: Deploy the current branch/PR to its preview environment at https://<branch>.<project>.<domain>, deploy the staging branch to https://<project>.<domain>, set up the server's shared Postgres, record a demo of it, check preview status, tear it down, or onboard a new repo to preview environments. Use when the user asks to deploy/redeploy/spin up a preview or staging env, record a demo/video of a PR, or set up previews for a repo.
---

# Preview environments (preview-kit)

Everything goes through the `preview` CLI from `~/.preview-kit`. Run it from the repo root.

## 0. Make sure the CLI is available

```sh
[ -d ~/.preview-kit ] || gh repo clone ivankaizer/preview-kit ~/.preview-kit
git -C ~/.preview-kit pull -q
PREVIEW=~/.preview-kit/bin/preview
```

The Dokploy URL and domain come from the repo's `.preview/config.json`. The secret `DOKPLOY_API_KEY` lives in `~/.env`, which the CLI loads itself.
Never print, commit or paste the key. If it's missing, stop and ask the user.

## Deploy a preview

1. The server builds from GitHub, not the local tree. Run `git status` and `git log @{u}..` to check
   for uncommitted or unpushed work, and ask before committing or pushing anything. The branch needs
   an open PR (`gh pr view`).
2. If the repo has no `.preview/config.json`, it isn't onboarded; see the onboarding section below.
3. Run `$PREVIEW deploy` in the background. A first build takes 5–10 minutes. The last line of
   output is the URL. For another PR, prefix `PR_NUMBER=<n> BRANCH=<head-branch>`.
4. Verify that `curl -fsS -o /dev/null -w '%{http_code}' <url>/` returns 200, then report the URL.
   Mention any seeded test logins documented in the repo.

CI already does this after tests pass on every PR push. A manual deploy is for skipping the wait or
retrying a failure.

## Staging

Repos whose `.preview/config.json` has a `staging` section also get a long-lived staging stack: the
staging branch (default `dev`) at `https://<project>.<domain>`. CI deploys it on every push to
that branch whose tests pass. For a manual deploy, run `$PREVIEW staging deploy` in the background.
It deploys the branch from GitHub, so first check that the branch is pushed. `$PREVIEW staging url`
prints the URL.

With `"database": "shared"`, staging uses its own database on the server's shared Postgres. The
server needs `$PREVIEW db setup` once; `$PREVIEW db status` shows it. Only run
`$PREVIEW staging destroy` when the user asks: staging is long-lived. It keeps the database.

To add staging to a repo, follow the "Staging" section of `~/.preview-kit/README.md`, then run
`$PREVIEW onboard` again to create the `staging` environment.

## Record a demo

`$PREVIEW demo` records `.preview/tour.json` against the deployed preview and compares it with the
PR's last published demo. It then publishes both to the branch `demos/pr-<n>`, the same as CI does,
and prints the path of a Markdown summary. Report the links from that summary. If a step failed, the
tour file probably needs updating for a UI change; fix it in the PR.

## Other commands

- `$PREVIEW url` prints the URL.
- `$PREVIEW status` lists the project's previews; use it to spot stale ones, since all previews share one server's RAM. `$PREVIEW prune` removes previews whose PR is closed.
- `$PREVIEW destroy` removes the preview and its demos. CI does this when the PR closes.

## Onboard a new repo

1. Run `$PREVIEW init`. This scaffolds `.preview/config.json`, `.preview/tour.json`,
   `docker-compose.preview.yml` and the cleanup workflow.
2. Fill them in from the repo's existing compose file and Dockerfiles. Follow the rules in
   `~/.preview-kit/README.md`: production images, no host ports, `mem_limit` everywhere, one-shot
   seeding, and routes for every public path.
3. Add the `preview` job that `init` prints, after the repo's test job.
4. Run `$PREVIEW onboard`, which is idempotent. Then commit, push, open a PR and watch the run.
