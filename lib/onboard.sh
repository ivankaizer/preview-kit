#!/usr/bin/env bash
# One-time setup of a repository for preview-kit. Run from the repo root on a machine with
# `gh` (repo admin) and DOKPLOY_URL/DOKPLOY_API_KEY in the environment (source ~/.env).
# Idempotent: re-running only creates what is missing.
#
#   preview onboard
set -euo pipefail
: "${DOKPLOY_URL:?source ~/.env first}" "${DOKPLOY_API_KEY:?source ~/.env first}"

config=.preview/config.json
[[ -f $config ]] || { echo "Create $config first (see preview-kit README)" >&2; exit 1; }
project=$(jq -r .project "$config")
compose=$(jq -r '.compose // "docker-compose.preview.yml"' "$config")
[[ -f $compose ]] || echo "warning: $compose does not exist yet" >&2
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
key_name="github-${repo#*/}-deploy"

api() {
  if [[ $# -eq 1 ]]; then
    curl -fsS -H "x-api-key: $DOKPLOY_API_KEY" "$DOKPLOY_URL/api/$1"
  else
    curl -fsS -H "x-api-key: $DOKPLOY_API_KEY" -H "Content-Type: application/json" -d "$2" "$DOKPLOY_URL/api/$1"
  fi
}

# 1. Dokploy project with a "previews" environment.
project_id=$(api project.all | jq -r --arg p "$project" '[.[] | select(.name == $p)][0].projectId // empty')
if [[ -z $project_id ]]; then
  project_id=$(api project.create "$(jq -nc --arg p "$project" --arg r "$repo" \
    '{name: $p, description: ("PR previews for " + $r)}')" | jq -r .project.projectId)
  echo "✓ Created Dokploy project $project"
fi
if ! api project.all | jq -e --arg p "$project" '.[] | select(.name == $p) | .environments[] | select(.name == "previews")' >/dev/null; then
  api environment.create "$(jq -nc --arg id "$project_id" '{projectId: $id, name: "previews", description: "Per-PR preview environments"}')" >/dev/null
  echo "✓ Created environment previews"
fi
echo "• Dokploy project $project ready"

# 2. Read-only deploy key so Dokploy can clone the repo.
if ! api sshKey.all | jq -e --arg n "$key_name" '.[] | select(.name == $n)' >/dev/null; then
  org=$(api project.all | jq -r --arg p "$project" '[.[] | select(.name == $p)][0].organizationId')
  pair=$(api sshKey.generate '{"type":"ed25519"}')
  api sshKey.create "$(jq -c --arg n "$key_name" --arg r "$repo" --arg o "$org" \
    '{name: $n, description: ("Read-only deploy key for " + $r), privateKey, publicKey, organizationId: $o}' <<<"$pair")" >/dev/null
  gh repo deploy-key add <(jq -r .publicKey <<<"$pair") -R "$repo" -t "dokploy-staging (read-only)" >/dev/null
  echo "✓ Created deploy key $key_name"
fi
echo "• Deploy key $key_name ready"

# 3. CI secret.
if ! gh secret list -R "$repo" --json name --jq '.[].name' | grep -qx DOKPLOY_API_KEY; then
  gh secret set DOKPLOY_API_KEY -R "$repo" --body "$DOKPLOY_API_KEY"
  echo "✓ Set secret DOKPLOY_API_KEY"
fi
echo "• Secret DOKPLOY_API_KEY ready"

cat <<EOF

Done. Remaining repo changes (see preview-kit README):
  - $compose: production-like stack, no host ports, memory limits, seed data
  - .preview/tour.json: pages the demo visits (optional)
  - a "preview" job after the tests and a cleanup workflow calling ivankaizer/preview-kit
Previews will live at https://<branch>.${project}.deployment.lat
EOF
