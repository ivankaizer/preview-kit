#!/usr/bin/env bash
# Creates, updates or removes the Dokploy preview stack for one pull request.
# Normally called through `preview deploy|destroy|url` from the root of an onboarded repository.
#
# Env:
#   DOKPLOY_URL, DOKPLOY_API_KEY  required (bin/preview fills DOKPLOY_URL from the config)
#   PR_NUMBER, BRANCH, REPO       required (bin/preview derives them from gh / GitHub Actions)
#   PREVIEW_CONFIG                default .preview/config.json
#   PREVIEW_DOMAIN                overrides the config's "domain"
#   DEPLOY_TIMEOUT                seconds to wait for the build, default 1500
set -euo pipefail

config="${PREVIEW_CONFIG:-.preview/config.json}"
die() { echo "preview: $*" >&2; exit 1; }
[[ -f $config ]] || die "missing $config; run 'preview init' first"
: "${DOKPLOY_URL:?}" "${DOKPLOY_API_KEY:?}" "${PR_NUMBER:?}" "${BRANCH:?}" "${REPO:?}"

project=$(jq -r '.project // empty' "$config")
domain="${PREVIEW_DOMAIN:-$(jq -r '.domain // empty' "$config")}"
compose_path=$(jq -r '.compose // "docker-compose.preview.yml"' "$config")
[[ $project =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] || die "\"project\" must be a DNS label (a-z, 0-9, -), got '$project'"
[[ -n $domain ]] || die "set \"domain\" in $config (previews live at <branch>.<project>.<domain>)"
jq -e '(.routes | type == "array" and length > 0) and all(.routes[]; .service and .port)' "$config" >/dev/null ||
  die "\"routes\" must be a non-empty list of {service, port, path}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-1500}"
name="pr-${PR_NUMBER}"

api() { # api <GET|POST> <procedure> [json]
  local method=$1 proc=$2 body=${3:-} response
  local args=(-sS --retry 3 --fail-with-body -H "x-api-key: ${DOKPLOY_API_KEY}")
  if [[ $method == POST ]]; then args+=(-H "Content-Type: application/json" -d "$body"); fi
  if ! response=$(curl "${args[@]}" "${DOKPLOY_URL%/}/api/${proc}"); then
    die "Dokploy API ${proc} failed: $(jq -r '.message // .error.json.message // .' <<<"$response" 2>/dev/null | head -c 300)"
  fi
  printf '%s' "$response"
}

# DNS label: lowercase alphanumerics and dashes, at most 40 chars, no edge dashes.
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//' | cut -c1-40 | sed -E 's/-+$//'
}

environment_id() {
  api GET project.all | jq -r --arg p "$project" \
    '[.[] | select(.name == $p) | .environments[]? | select(.name == "previews") | .environmentId][0] // empty'
}

# Prints the compose apps of the previews environment as "<composeId> <name> <description>".
list_compose() {
  api GET "environment.one?environmentId=$1" | jq -r '.compose[]? | "\(.composeId) \(.name) \(.description // "")"'
}

# Host for this PR. Branches that slugify the same (feat/x vs feat-x) get a -pr<n> suffix
# when another open preview already owns the plain host.
preview_host() {
  local env_id=${1:-} slug other
  slug=$(slugify "$BRANCH")
  slug=${slug:-$name}
  if [[ -n $env_id ]]; then
    # Descriptions are "PR #<n> · <branch> · <host>"; the host is the last field.
    other=$(list_compose "$env_id" | awk -v me="$name" -v h=" · ${slug}.${project}.${domain}" \
      '$2 != me && length($0) >= length(h) && substr($0, length($0) - length(h) + 1) == h' | wc -l)
    if ((other > 0)); then slug="${slug:0:33}-pr${PR_NUMBER}"; fi
  fi
  echo "${slug}.${project}.${domain}"
}

find_compose() {
  list_compose "$1" | awk -v n="$name" '$2 == n { print $1; exit }'
}

current_host() { # host recorded on an existing preview, if any (last " · " field of its description)
  list_compose "$1" | awk -v n="$name" -v suffix=".${project}.${domain}" '
    $2 == n { host = $NF
              if (length(host) > length(suffix) && substr(host, length(host) - length(suffix) + 1) == suffix) print host
              exit }'
}

latest_deployment() { # prints "<id> <status>"
  api GET "deployment.allByCompose?composeId=$1" |
    jq -r 'sort_by(.createdAt) | last | if . then "\(.deploymentId) \(.status)" else "" end'
}

create_compose() {
  local env_id=$1 host=$2 key_name key_id id
  key_name="github-${REPO#*/}-deploy"
  key_id=$(api GET sshKey.all | jq -r --arg n "$key_name" '[.[] | select(.name == $n)][0].sshKeyId // empty')
  [[ -n $key_id ]] || die "no Dokploy SSH key $key_name; run 'preview onboard'"

  id=$(api POST compose.create "$(jq -nc --arg n "$name" --arg e "$env_id" \
    --arg d "PR #${PR_NUMBER} · ${BRANCH} · ${host}" \
    '{name: $n, environmentId: $e, composeType: "docker-compose", sourceType: "git", description: $d}')" |
    jq -r .composeId)

  api POST compose.update "$(jq -nc --arg id "$id" --arg url "git@github.com:${REPO}.git" \
    --arg key "$key_id" --arg path "./${compose_path#./}" --arg env "$(jq -r '.env // ""' "$config")" \
    '{composeId: $id, sourceType: "git", customGitUrl: $url, customGitSSHKeyId: $key, composePath: $path,
      autoDeploy: false, isolatedDeployment: true, env: ("COMPOSE_PARALLEL_LIMIT=1\n" + $env)}')" >/dev/null

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
  local env_id id host previous deployment="" status=""
  env_id=$(environment_id)
  [[ -n $env_id ]] || die "no Dokploy project '${project}' with a 'previews' environment; run 'preview onboard'"
  id=$(find_compose "$env_id")
  if [[ -z $id ]]; then
    host=$(preview_host "$env_id")
    id=$(create_compose "$env_id" "$host")
    echo "Created preview ${project}/${name} (${host})" >&2
  else
    host=$(current_host "$env_id")
    host=${host:-$(preview_host)}
  fi
  # Re-point at the PR branch every time, in case the head branch was renamed.
  api POST compose.update "$(jq -nc --arg id "$id" --arg b "$BRANCH" '{composeId: $id, customGitBranch: $b}')" >/dev/null

  previous=$(latest_deployment "$id" | cut -d' ' -f1)
  api POST compose.deploy "$(jq -nc --arg id "$id" --arg t "PR #${PR_NUMBER} @ ${SHA:-${GITHUB_SHA:-manual}}" \
    '{composeId: $id, title: $t}')" >/dev/null
  echo "Deploy queued for ${project}/${name}; waiting up to ${DEPLOY_TIMEOUT}s" >&2

  local deadline=$((SECONDS + DEPLOY_TIMEOUT))
  while ((SECONDS < deadline)); do
    sleep 10
    read -r deployment status <<<"$(latest_deployment "$id")" || true
    [[ -z $deployment || $deployment == "$previous" ]] && continue
    case $status in
      done) break ;;
      error) die "deployment ${deployment} failed; logs: ${DOKPLOY_URL%/} → ${project} → previews → ${name}" ;;
    esac
  done
  [[ $status == done ]] || die "timed out after ${DEPLOY_TIMEOUT}s waiting for the deployment"

  # Traefik needs a moment to pick up routes and issue the certificate.
  for _ in $(seq 1 30); do
    if healthy "https://${host}"; then
      echo "https://${host}"
      return
    fi
    sleep 5
  done
  die "deployed, but https://${host} failed its healthcheck ($(jq -c '.healthcheck // ["/"]' "$config"))"
}

destroy() {
  local env_id id
  env_id=$(environment_id)
  id=""
  if [[ -n $env_id ]]; then id=$(find_compose "$env_id"); fi
  if [[ -z $id ]]; then
    echo "No preview ${project}/${name} to remove" >&2
    return
  fi
  api POST compose.delete "$(jq -nc --arg id "$id" '{composeId: $id, deleteVolumes: true}')" >/dev/null
  echo "Removed preview ${project}/${name}" >&2
}

url() {
  local env_id host=""
  env_id=$(environment_id)
  if [[ -n $env_id ]]; then host=$(current_host "$env_id"); fi
  echo "https://${host:-$(preview_host "$env_id")}"
}

case "${1:-}" in
  deploy) deploy ;;
  destroy) destroy ;;
  url) url ;;
  *) echo "usage: $0 deploy|destroy|url" >&2; exit 2 ;;
esac
