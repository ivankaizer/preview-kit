#!/usr/bin/env bash
# Scaffolds preview-kit files into the current repository. Never overwrites existing files.
set -euo pipefail
: "${PREVIEW_KIT_REPO:?run through bin/preview}" "${PREVIEW_KIT_REF:?run through bin/preview}"
if [[ -f $HOME/.env ]]; then
  # shellcheck disable=SC1091
  set -a; source "$HOME/.env"; set +a
fi
domain=${PREVIEW_DOMAIN:-previews.example.com}
dokploy=${DOKPLOY_URL:-https://dokploy.example.com}

project=${1:-$(basename "$(git rev-parse --show-toplevel)" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g')}

write() { # write <path>  (content on stdin)
  if [[ -e $1 ]]; then
    echo "• exists, skipped: $1"
    cat >/dev/null
  else
    mkdir -p "$(dirname "$1")"
    cat >"$1"
    echo "✓ created $1"
  fi
}

write .preview/config.json <<EOF
{
  "project": "${project}",
  "domain": "${domain}",
  "dokploy": "${dokploy}",
  "compose": "docker-compose.preview.yml",
  "routes": [
    { "service": "app", "port": 3000, "path": "/" }
  ],
  "healthcheck": ["/"]
}
EOF

write .preview/tour.json <<'EOF'
{
  "sessions": [
    {
      "name": "visitor",
      "steps": [
        { "name": "home", "visit": "/" }
      ]
    }
  ]
}
EOF

write docker-compose.preview.yml <<'EOF'
# Preview stack deployed per PR by preview-kit (https://<branch>.<project>.<domain>).
# Rules: build production images, publish no host ports (Traefik routes by .preview/config.json),
# set mem_limit on every service (all previews share one server), seed demo data once.
services:
  app:
    build: .
    restart: unless-stopped
    mem_limit: 256m
EOF

write .github/workflows/preview-cleanup.yml <<EOF
name: Preview cleanup

on:
  pull_request:
    types: [closed]

jobs:
  cleanup:
    if: github.event.pull_request.head.repo.full_name == github.repository
    uses: ${PREVIEW_KIT_REPO}/.github/workflows/cleanup.yml@${PREVIEW_KIT_REF}
    permissions:
      contents: write
    secrets: inherit
EOF

cat <<EOF

Next:
  1. Edit docker-compose.preview.yml, .preview/config.json (domain, dokploy, routes) and .preview/tour.json.
  2. Add this job to the workflow that runs your tests on pull_request, after the test job:

  preview:
    needs: test   # your test job id
    if: github.event.pull_request.head.repo.full_name == github.repository
    uses: ${PREVIEW_KIT_REPO}/.github/workflows/preview.yml@${PREVIEW_KIT_REF}
    permissions:
      contents: write
      pull-requests: write
    secrets: inherit

  3. Run 'preview onboard' once, push, and open a PR.
EOF
