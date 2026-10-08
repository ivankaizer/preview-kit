#!/usr/bin/env bash
# Creates, updates or removes the project's long-lived staging stack: the "staging" compose app in
# the Dokploy project's "staging" environment, built from the staging branch and served at
# https://<project>.<domain>. With "database": "shared" in the config it gets its own database on
# the server's shared Postgres (see shared-db.sh), passed to the stack as DATABASE_URL.
# Normally called through `preview staging deploy|destroy|url`.
#
# Env:
#   DOKPLOY_URL, DOKPLOY_API_KEY, REPO  required (bin/preview fills them)
#   PREVIEW_CONFIG                      default .preview/config.json
#   SHA                                 commit being deployed, for the deployment title
#   DEPLOY_TIMEOUT                      seconds to wait for the build, default 1500
set -euo pipefail

kit=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config="${PREVIEW_CONFIG:-.preview/config.json}"
die() { echo "preview: $*" >&2; exit 1; }
[[ -f $config ]] || die "missing $config"
: "${DOKPLOY_URL:?}" "${DOKPLOY_API_KEY:?}" "${REPO:?}"
jq -e '.staging | type == "object"' "$config" >/dev/null || die "no \"staging\" section in $config"

project=$(jq -r '.project // empty' "$config")
domain="${PREVIEW_DOMAIN:-$(jq -r '.domain // empty' "$config")}"
branch=$(jq -r '.staging.branch // "dev"' "$config")
compose_path=$(jq -r '.staging.compose // "docker-compose.staging.yml"' "$config")
host=$(jq -r --arg d "${project}.${domain}" '.staging.host // $d' "$config")
database=$(jq -r '.staging.database // ""' "$config")
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-1500}"
name=staging

api() { # api <GET|POST> <procedure> [json]
  local method=$1 proc=$2 body=${3:-} response
  local args=(-sS --retry 3 --fail-with-body -H "x-api-key: ${DOKPLOY_API_KEY}")
  if [[ $method == POST ]]; then args+=(-H "Content-Type: application/json" -d "$body"); fi
  if ! response=$(curl "${args[@]}" "${DOKPLOY_URL%/}/api/${proc}"); then
    die "Dokploy API ${proc} failed: $(jq -r '.message // .error.json.message // .' <<<"$response" 2>/dev/null | head -c 300)"
  fi
  printf '%s' "$response"
}

environment_id() {
  api GET project.all | jq -r --arg p "$project" \
    '[.[] | select(.name == $p) | .environments[]? | select(.name == "staging") | .environmentId][0] // empty'
}

find_compose() {
  api GET "environment.one?environmentId=$1" | jq -r --arg n "$name" '[.compose[]? | select(.name == $n)][0].composeId // empty'
}

latest_deployment() { # prints "<id> <status>"
  api GET "deployment.allByCompose?composeId=$1" |
    jq -r 'sort_by(.createdAt) | last | if . then "\(.deploymentId) \(.status)" else "" end'
}

# Lines for the stack's .env: the shared database's connection (when configured) and the
# config's own "env". Generated once, when the stack is created; later deploys keep the .env.
stack_env() {
  local lines="COMPOSE_PARALLEL_LIMIT=1"
  if [[ $database == shared ]]; then
    local db_host db_name db_password
    db_host=$("$kit/shared-db.sh" host)
    [[ -n $db_host ]] || die "no shared Postgres on this server; run 'preview db setup' first"
    db_name="$(tr '-' '_' <<<"$project")_staging"
    db_password=$(openssl rand -hex 24)
    "$kit/shared-db.sh" provision "$db_name" "$db_password"
    lines+=$'\n'"DATABASE_URL=postgres://${db_name}:${db_password}@${db_host}:5432/${db_name}"
    lines+=$'\n'"PGHOST=${db_host}"$'\n'"PGPORT=5432"$'\n'"PGDATABASE=${db_name}"
    lines+=$'\n'"PGUSER=${db_name}"$'\n'"PGPASSWORD=${db_password}"
  elif [[ -n $database ]]; then
    die "\"staging.database\" must be \"shared\" or absent, got '$database'"
  fi
  local extra
  extra=$(jq -r '.staging.env // ""' "$config")
  if [[ -n $extra ]]; then lines+=$'\n'"$extra"; fi
  printf '%s' "$lines"
}

create_compose() {
  local env_id=$1 key_name key_id id env
  key_name="github-${REPO#*/}-deploy"
  key_id=$(api GET sshKey.all | jq -r --arg n "$key_name" '[.[] | select(.name == $n)][0].sshKeyId // empty')
  [[ -n $key_id ]] || die "no Dokploy SSH key $key_name; run 'preview onboard'"
  env=$(stack_env)

  id=$(api POST compose.create "$(jq -nc --arg n "$name" --arg e "$env_id" \
    --arg d "Staging · ${branch} · ${host}" \
    '{name: $n, environmentId: $e, composeType: "docker-compose", sourceType: "git", description: $d}')" |
    jq -r .composeId)

  api POST compose.update "$(jq -nc --arg id "$id" --arg url "git@github.com:${REPO}.git" \
    --arg key "$key_id" --arg path "./${compose_path#./}" --arg env "$env" \
    '{composeId: $id, sourceType: "git", customGitUrl: $url, customGitSSHKeyId: $key, composePath: $path,
      autoDeploy: false, isolatedDeployment: true, env: $env}')" >/dev/null

  jq -c '.routes[]' "$config" | while read -r route; do
    api POST domain.create "$(jq -nc --arg id "$id" --arg h "$host" --argjson r "$route" \
      '{composeId: $id, host: $h, serviceName: $r.service, port: $r.port, path: ($r.path // "/"),
        stripPath: ($r.stripPath // false), https: true, certificateType: "letsencrypt",
        domainType: "compose"}')" >/dev/null
  done
  echo "$id"
}

healthy() {
  local url=$1 path code
  while read -r path; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${url}${path}" || true)
    [[ $code =~ ^[234] ]] || return 1
  done < <(jq -r '(.healthcheck // ["/"])[]' "$config")
}

deploy() {
  local env_id id previous deployment="" status=""
  env_id=$(environment_id)
  [[ -n $env_id ]] || die "no Dokploy project '${project}' with a 'staging' environment; run 'preview onboard'"
  id=$(find_compose "$env_id")
  if [[ -z $id ]]; then
    id=$(create_compose "$env_id")
    echo "Created staging ${project}/${name} (${host})" >&2
  fi
  api POST compose.update "$(jq -nc --arg id "$id" --arg b "$branch" --arg path "./${compose_path#./}" \
    '{composeId: $id, customGitBranch: $b, composePath: $path}')" >/dev/null

  previous=$(latest_deployment "$id" | cut -d' ' -f1)
  api POST compose.deploy "$(jq -nc --arg id "$id" --arg t "${branch} @ ${SHA:-${GITHUB_SHA:-manual}}" \
    '{composeId: $id, title: $t}')" >/dev/null
  echo "Deploy queued for ${project}/${name}; waiting up to ${DEPLOY_TIMEOUT}s" >&2

  local deadline=$((SECONDS + DEPLOY_TIMEOUT))
  while ((SECONDS < deadline)); do
    sleep 10
    read -r deployment status <<<"$(latest_deployment "$id")" || true
    [[ -z $deployment || $deployment == "$previous" ]] && continue
    case $status in
      done) break ;;
      error) die "deployment ${deployment} failed; logs: ${DOKPLOY_URL%/} → ${project} → staging → ${name}" ;;
    esac
  done
  [[ $status == "done" ]] || die "timed out after ${DEPLOY_TIMEOUT}s waiting for the deployment"

  for _ in $(seq 1 30); do
    if healthy "https://${host}"; then
      echo "https://${host}"
      return
    fi
    sleep 5
  done
  die "deployed, but https://${host} failed its healthcheck ($(jq -c '.healthcheck // ["/"]' "$config"))"
}

# Removes the stack and its volumes. The shared database is kept: drop it by hand if wanted.
destroy() {
  local env_id id=""
  env_id=$(environment_id)
  if [[ -n $env_id ]]; then id=$(find_compose "$env_id"); fi
  if [[ -z $id ]]; then
    echo "No staging stack for ${project}" >&2
    return
  fi
  api POST compose.delete "$(jq -nc --arg id "$id" '{composeId: $id, deleteVolumes: true}')" >/dev/null
  echo "Removed staging ${project}/${name}; its database on the shared Postgres was kept" >&2
}

case "${1:-}" in
  deploy) deploy ;;
  destroy) destroy ;;
  url) echo "https://${host}" ;;
  *) echo "usage: $0 deploy|destroy|url" >&2; exit 2 ;;
esac
