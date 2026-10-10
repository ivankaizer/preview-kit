#!/usr/bin/env bash
# Builds and deploys the project's production stack: the "production" compose app in the Dokploy
# project's "production" environment. Images are built once (by CI, on a runner that shares the
# Dokploy host's Docker) and pushed to a registry on that host; the stack is a raw compose file
# rendered from "production.compose" without its `build:` sections, so Dokploy runs exactly the
# images that were built. The deployed tag is IMAGE_TAG in the stack's .env, so a rollback is a
# deploy of an older tag. Normally called through `preview prod build|deploy|url`.
#
#   prod.sh build <tag>    build the services that have `build:` and push them
#   prod.sh deploy <tag>   render the compose file, set IMAGE_TAG=<tag>, deploy and healthcheck
#   prod.sh url            print the production URLs
#
# The compose file names its images itself, e.g. `image: localhost:5000/shop/api:${IMAGE_TAG:?}`.
# Use plain ${VAR} (not ${VAR:?}) for runtime settings: CI builds without them.
#
# Env:
#   DOKPLOY_URL, DOKPLOY_API_KEY  required for deploy (bin/preview fills them)
#   PREVIEW_CONFIG                default .preview/config.json
#   DEPLOY_TIMEOUT                seconds to wait for the deployment, default 900
set -euo pipefail

config="${PREVIEW_CONFIG:-.preview/config.json}"
die() { echo "preview: $*" >&2; exit 1; }
[[ -f $config ]] || die "missing $config"
jq -e '.production | type == "object"' "$config" >/dev/null || die "no \"production\" section in $config"

project=$(jq -r '.project // empty' "$config")
compose_path=$(jq -r '.production.compose // "docker-compose.prod.yml"' "$config")
database=$(jq -r '.production.database // ""' "$config")
tls=$(jq -r '.tls // "letsencrypt"' "$config")
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-900}"
name=production
[[ -f $compose_path ]] || die "missing $compose_path"

api() { # api <GET|POST> <procedure> [json]
  local method=$1 proc=$2 body=${3:-} response
  local args=(-sS --retry 3 --fail-with-body -H "x-api-key: ${DOKPLOY_API_KEY}")
  if [[ $method == POST ]]; then args+=(-H "Content-Type: application/json" -d "$body"); fi
  if ! response=$(curl "${args[@]}" "${DOKPLOY_URL%/}/api/${proc}"); then
    die "Dokploy API ${proc} failed: $(jq -r '.message // .error.json.message // .' <<<"$response" 2>/dev/null | head -c 300)"
  fi
  printf '%s' "$response"
}

# Services that are built from source, i.e. the images this project owns.
built_services() {
  IMAGE_TAG=${1:-render} docker compose -f "$compose_path" config --format json |
    jq -r '.services | to_entries[] | select(.value.build) | .key'
}

build() {
  local tag=$1 services=() service
  while read -r service; do services+=("$service"); done < <(built_services "$tag")
  ((${#services[@]})) || die "no service in $compose_path has a build section"
  IMAGE_TAG=$tag docker compose -f "$compose_path" build --pull "${services[@]}"
  IMAGE_TAG=$tag docker compose -f "$compose_path" push "${services[@]}"
  echo "Built and pushed ${project} ${tag}: ${services[*]}" >&2
}

# The compose file as Dokploy will run it: anchors resolved, variables left for Dokploy's .env,
# no build sections. JSON is valid YAML.
render() {
  docker compose -f "$compose_path" config --no-interpolate --format json |
    jq 'del(.name) | del(.services[].build) | del(.networks.default)'
}

environment_id() {
  api GET project.all | jq -r --arg p "$project" \
    '[.[] | select(.name == $p) | .environments[]? | select(.name == "production") | .environmentId][0] // empty'
}

find_compose() {
  api GET "environment.one?environmentId=$1" | jq -r --arg n "$name" '[.compose[]? | select(.name == $n)][0].composeId // empty'
}

latest_deployment() { # prints "<id> <status>"
  api GET "deployment.allByCompose?composeId=$1" |
    jq -r 'sort_by(.createdAt) | last | if . then "\(.deploymentId) \(.status)" else "" end'
}

# With "database": "dedicated", the stack gets its own Postgres ("<project>-postgres") in the
# production environment. Prints DATABASE_URL when it creates the server, nothing otherwise.
ensure_database() {
  local env_id=$1 db_name pid password app status
  [[ $database == dedicated ]] || { [[ -z $database ]] || die "\"production.database\" must be \"dedicated\" or absent"; return; }
  db_name="$(tr '-' '_' <<<"$project")"
  pid=$(api GET "environment.one?environmentId=$env_id" |
    jq -r --arg n "${project}-postgres" '[.postgres[]? | select(.name == $n)][0].postgresId // empty')
  [[ -z $pid ]] || return 0
  password=$(openssl rand -hex 24)
  api POST postgres.create "$(jq -nc --arg n "${project}-postgres" --arg e "$env_id" --arg d "$db_name" --arg p "$password" \
    '{name: $n, appName: $n, databaseName: $d, databaseUser: $d, databasePassword: $p, dockerImage: "postgres:18",
      environmentId: $e, description: "Production database"}')" >/dev/null
  pid=$(api GET "environment.one?environmentId=$env_id" |
    jq -r --arg n "${project}-postgres" '[.postgres[]? | select(.name == $n)][0].postgresId // empty')
  [[ -n $pid ]] || die "could not create ${project}-postgres"
  api POST postgres.deploy "$(jq -nc --arg id "$pid" '{postgresId: $id}')" >/dev/null
  for _ in $(seq 1 60); do
    read -r app status <<<"$(api GET "postgres.one?postgresId=$pid" | jq -r '"\(.appName) \(.applicationStatus)"')"
    [[ $status == "done" ]] && break
    [[ $status == "error" ]] && die "${project}-postgres failed to start"
    sleep 5
  done
  [[ $status == "done" ]] || die "timed out waiting for ${project}-postgres"
  echo "✓ Created ${project}-postgres (${app})" >&2
  printf 'DATABASE_URL=postgres://%s:%s@%s:5432/%s' "$db_name" "$password" "$app" "$db_name"
}

# The stack's .env on creation: the database, "production.generate" secrets (made once, e.g.
# {"SESSION_KEY": "base64:32"}) and "production.env". Later deploys only change IMAGE_TAG.
initial_env() {
  local db_url=$1 lines="COMPOSE_PARALLEL_LIMIT=1" key spec
  [[ -z $db_url ]] || lines+=$'\n'"$db_url"
  while IFS=$'\t' read -r key spec; do
    [[ -n $key ]] || continue
    case $spec in
      base64:*) lines+=$'\n'"${key}=$(openssl rand -base64 "${spec#base64:}")" ;;
      hex:*) lines+=$'\n'"${key}=$(openssl rand -hex "${spec#hex:}")" ;;
      *) die "production.generate.${key}: use base64:<bytes> or hex:<bytes>, got '$spec'" ;;
    esac
  done < <(jq -r '(.production.generate // {}) | to_entries[] | "\(.key)\t\(.value)"' "$config")
  local extra
  extra=$(jq -r '.production.env // ""' "$config")
  [[ -z $extra ]] || lines+=$'\n'"$extra"
  printf '%s' "$lines"
}

ensure_domains() {
  local id=$1 existing route
  existing=$(api GET "compose.one?composeId=$id" | jq -c '[.domains[]? | "\(.host)\(.path // "/")"]')
  jq -c '.production.domains[]' "$config" | while read -r route; do
    jq -e --argjson e "$existing" '("\(.host)\(.path // "/")") as $k | $e | index($k)' <<<"$route" >/dev/null && continue
    api POST domain.create "$(jq -nc --arg id "$id" --argjson r "$route" --arg tls "$tls" \
      '{composeId: $id, host: $r.host, serviceName: $r.service, port: $r.port, path: ($r.path // "/"),
        stripPath: ($r.stripPath // false), https: ($tls != "edge"),
        certificateType: (if $tls == "edge" then "none" else "letsencrypt" end),
        domainType: "compose"}')" >/dev/null
    echo "✓ Added domain $(jq -r '"\(.host)\(.path // "/")"' <<<"$route")" >&2
  done
}

healthy() {
  local url code
  while read -r url; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)
    [[ $code =~ ^[234] ]] || return 1
  done < <(jq -r '(.production.healthcheck // [])[]' "$config")
}

deploy() {
  local tag=$1 env_id id db_url="" env previous deployment="" status=""
  : "${DOKPLOY_URL:?}" "${DOKPLOY_API_KEY:?}"
  env_id=$(environment_id)
  [[ -n $env_id ]] || die "no Dokploy project '${project}' with a 'production' environment"
  id=$(find_compose "$env_id")
  if [[ -z $id ]]; then
    db_url=$(ensure_database "$env_id")
    id=$(api POST compose.create "$(jq -nc --arg n "$name" --arg e "$env_id" \
      '{name: $n, environmentId: $e, composeType: "docker-compose", description: "Production"}')" | jq -r .composeId)
    api POST compose.update "$(jq -nc --arg id "$id" --arg env "$(initial_env "$db_url")" \
      '{composeId: $id, sourceType: "raw", isolatedDeployment: true, autoDeploy: false, env: $env}')" >/dev/null
    echo "Created ${project}/${name}" >&2
  fi

  env=$(api GET "compose.one?composeId=$id" | jq -r '.env // ""' | grep -v '^IMAGE_TAG=' || true)
  api POST compose.update "$(jq -nc --arg id "$id" --arg file "$(render)" --arg env "${env}"$'\n'"IMAGE_TAG=${tag}" \
    '{composeId: $id, sourceType: "raw", composeFile: $file, env: $env}')" >/dev/null
  ensure_domains "$id"

  previous=$(latest_deployment "$id" | cut -d' ' -f1)
  api POST compose.deploy "$(jq -nc --arg id "$id" --arg t "$tag" '{composeId: $id, title: $t}')" >/dev/null
  echo "Deploy of ${project} ${tag} queued; waiting up to ${DEPLOY_TIMEOUT}s" >&2

  local deadline=$((SECONDS + DEPLOY_TIMEOUT))
  while ((SECONDS < deadline)); do
    sleep 10
    read -r deployment status <<<"$(latest_deployment "$id")" || true
    [[ -z $deployment || $deployment == "$previous" ]] && continue
    case $status in
      done) break ;;
      error) die "deployment ${deployment} failed; logs: ${DOKPLOY_URL%/} → ${project} → production → ${name}" ;;
    esac
  done
  [[ $status == "done" ]] || die "timed out after ${DEPLOY_TIMEOUT}s waiting for the deployment"

  for _ in $(seq 1 30); do
    if healthy; then
      urls
      return
    fi
    sleep 5
  done
  die "deployed, but the healthcheck failed: $(jq -c '.production.healthcheck // []' "$config")"
}

urls() { jq -r '[.production.domains[].host] | unique[] | "https://\(.)"' "$config"; }

case "${1:-}" in
  build) build "${2:?usage: $0 build <tag>}" ;;
  deploy) deploy "${2:?usage: $0 deploy <tag>}" ;;
  url) urls ;;
  *) echo "usage: $0 build <tag>|deploy <tag>|url" >&2; exit 2 ;;
esac
