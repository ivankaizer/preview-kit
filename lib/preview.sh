#!/usr/bin/env bash
# Creates, updates or removes the Dokploy preview stack for one pull request.
# Run from the root of an onboarded repository (`preview onboard`):
#
#   preview.sh deploy   # create the stack on first run, then redeploy; prints the URL
#   preview.sh destroy  # remove the stack and its volumes
#   preview.sh url      # print the URL without touching anything
#
# Env:
#   DOKPLOY_URL, DOKPLOY_API_KEY  required (CI secrets; ~/.env for local agents)
#   PR_NUMBER, BRANCH             default to the PR of the checked-out branch (needs gh)
#   REPO                          owner/name; defaults to GITHUB_REPOSITORY or gh
#   PREVIEW_CONFIG                default .preview/config.json
#   PREVIEW_DOMAIN                default deployment.lat
#
# Config (.preview/config.json):
#   { "project": "playdex", "compose": "docker-compose.preview.yml",
#     "routes": [{"service": "ui", "port": 5056, "path": "/"}, {"service": "app", "port": 3000, "path": "/api"}],
#     "healthcheck": ["/", "/api/"], "env": "KEY=value\nOTHER=1" }
set -euo pipefail

: "${DOKPLOY_URL:?set DOKPLOY_URL (e.g. source ~/.env)}" "${DOKPLOY_API_KEY:?set DOKPLOY_API_KEY (e.g. source ~/.env)}"
config="${PREVIEW_CONFIG:-.preview/config.json}"
[[ -f $config ]] || { echo "Missing $config; is this repo onboarded to preview-kit?" >&2; exit 1; }
domain="${PREVIEW_DOMAIN:-deployment.lat}"
project=$(jq -r '.project' "$config")
compose_path=$(jq -r '.compose // "docker-compose.preview.yml"' "$config")
REPO="${REPO:-${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}}"
if [[ -z ${PR_NUMBER:-} || -z ${BRANCH:-} ]]; then
  read -r PR_NUMBER BRANCH <<<"$(gh pr view --json number,headRefName --jq '"\(.number) \(.headRefName)"')"
fi
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-1500}"

name="pr-${PR_NUMBER}"
# DNS label: lowercase alphanumerics and dashes, at most 40 chars, no edge dashes.
slug=$(printf '%s' "$BRANCH" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//' | cut -c1-40 | sed -E 's/-+$//')
host="${slug:-$name}.${project}.${domain}"
url="https://${host}"

api() { # api <GET|POST> <procedure> [json]
  local method=$1 proc=$2 body=${3:-}
  if [[ $method == GET ]]; then
    curl -fsS --retry 3 -H "x-api-key: ${DOKPLOY_API_KEY}" "${DOKPLOY_URL}/api/${proc}"
  else
    curl -fsS --retry 3 -H "x-api-key: ${DOKPLOY_API_KEY}" -H "Content-Type: application/json" \
      -d "$body" "${DOKPLOY_URL}/api/${proc}"
  fi
}

environment_id() {
  api GET project.all | jq -r --arg p "$project" \
    '[.[] | select(.name == $p) | .environments[] | select(.name == "previews") | .environmentId][0] // empty'
}

find_compose_id() {
  api GET "environment.one?environmentId=$1" |
    jq -r --arg n "$name" '[.compose[]? | select(.name == $n)][0].composeId // empty'
}

latest_deployment() { # prints "<id> <status>"
  api GET "deployment.allByCompose?composeId=$1" |
    jq -r 'sort_by(.createdAt) | last | if . then "\(.deploymentId) \(.status)" else "" end'
}

create_compose() {
  local env_id=$1 key_id id
  key_id=$(api GET sshKey.all | jq -r --arg n "github-${REPO#*/}-deploy" '[.[] | select(.name == $n)][0].sshKeyId // empty')
  [[ -n $key_id ]] || { echo "No Dokploy SSH key github-${REPO#*/}-deploy; run 'preview onboard'" >&2; exit 1; }

  id=$(api POST compose.create "$(jq -nc --arg n "$name" --arg e "$env_id" --arg d "PR #${PR_NUMBER} · ${BRANCH}" \
    '{name: $n, environmentId: $e, composeType: "docker-compose", sourceType: "git", description: $d}')" |
    jq -r .composeId)

  api POST compose.update "$(jq -nc --arg id "$id" --arg url "git@github.com:${REPO}.git" --arg b "$BRANCH" \
    --arg key "$key_id" --arg path "./${compose_path#./}" --arg env "$(jq -r '.env // ""' "$config")" \
    '{composeId: $id, sourceType: "git", customGitUrl: $url, customGitBranch: $b,
      customGitSSHKeyId: $key, composePath: $path, autoDeploy: false, isolatedDeployment: true,
      env: ("COMPOSE_PARALLEL_LIMIT=1\n" + $env)}')" >/dev/null

  jq -c '.routes[]' "$config" | while read -r route; do
    api POST domain.create "$(jq -nc --arg id "$id" --arg h "$host" --argjson r "$route" \
      '{composeId: $id, host: $h, serviceName: $r.service, port: $r.port, path: ($r.path // "/"),
        stripPath: ($r.stripPath // false), https: true, certificateType: "letsencrypt",
        domainType: "compose"}')" >/dev/null
  done
  echo "$id"
}

healthy() {
  local path code
  while read -r path; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${url}${path}" || true)
    [[ $code =~ ^[234] ]] || return 1
  done < <(jq -r '(.healthcheck // ["/"])[]' "$config")
}

deploy() {
  local env_id id previous deployment status
  env_id=$(environment_id)
  [[ -n $env_id ]] || { echo "No Dokploy project '${project}' with a 'previews' environment; run 'preview onboard'" >&2; exit 1; }
  id=$(find_compose_id "$env_id")
  if [[ -z $id ]]; then
    id=$(create_compose "$env_id")
    echo "Created Dokploy compose ${project}/${name} (${id})" >&2
  fi

  previous=$(latest_deployment "$id" | cut -d' ' -f1)
  api POST compose.deploy "$(jq -nc --arg id "$id" --arg t "PR #${PR_NUMBER} @ ${GITHUB_SHA:-manual}" \
    '{composeId: $id, title: $t}')" >/dev/null
  echo "Deploy queued for ${project}/${name}; waiting up to ${DEPLOY_TIMEOUT}s" >&2

  local deadline=$((SECONDS + DEPLOY_TIMEOUT))
  while ((SECONDS < deadline)); do
    sleep 10
    read -r deployment status <<<"$(latest_deployment "$id")" || true
    [[ -z ${deployment:-} || ${deployment} == "$previous" ]] && continue
    case $status in
      done) break ;;
      error) echo "Dokploy deployment ${deployment} failed; see ${DOKPLOY_URL}" >&2; exit 1 ;;
    esac
  done
  [[ ${status:-} == done ]] || { echo "Timed out waiting for deployment" >&2; exit 1; }

  # Traefik needs a moment to pick up routes and issue the certificate.
  for _ in $(seq 1 30); do
    if healthy; then
      echo "$url"
      return
    fi
    sleep 5
  done
  echo "Deployed, but ${url} failed its healthcheck" >&2
  exit 1
}

destroy() {
  local env_id id
  env_id=$(environment_id)
  id=$([[ -n $env_id ]] && find_compose_id "$env_id" || true)
  if [[ -z $id ]]; then
    echo "No preview ${project}/${name} to remove" >&2
    return
  fi
  api POST compose.delete "$(jq -nc --arg id "$id" '{composeId: $id, deleteVolumes: true}')" >/dev/null
  echo "Removed preview ${project}/${name}" >&2
}

case "${1:-}" in
  deploy) deploy ;;
  destroy) destroy ;;
  url) echo "$url" ;;
  *) echo "usage: $0 deploy|destroy|url" >&2; exit 2 ;;
esac
