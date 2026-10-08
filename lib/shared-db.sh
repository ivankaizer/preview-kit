#!/usr/bin/env bash
# One Postgres server per Dokploy host, shared by every project's staging stack. Each project gets
# its own database and login role on it; the superuser password never leaves the server.
#
#   shared-db.sh setup                         create and start the shared Postgres (idempotent)
#   shared-db.sh status                        print its host, image and status
#   shared-db.sh provision <name> <password>   create or update database <name> owned by role <name>
#
# Env: DOKPLOY_URL, DOKPLOY_API_KEY (bin/preview loads them)
#      SHARED_DB_PROJECT  Dokploy project holding the server, default "shared"
#      SHARED_DB_NAME     its Dokploy app name, which is also its host on dokploy-network, default "shared-postgres"
#      SHARED_DB_IMAGE    default postgres:18
set -euo pipefail
: "${DOKPLOY_URL:?run through bin/preview}" "${DOKPLOY_API_KEY:?run through bin/preview}"

db_project=${SHARED_DB_PROJECT:-shared}
db_name=${SHARED_DB_NAME:-shared-postgres}
db_image=${SHARED_DB_IMAGE:-postgres:18}
die() { echo "preview: $*" >&2; exit 1; }

api() { # api <GET|POST> <procedure> [json]
  local method=$1 proc=$2 body=${3:-} response
  local args=(-sS --retry 3 --fail-with-body -H "x-api-key: ${DOKPLOY_API_KEY}")
  if [[ $method == POST ]]; then args+=(-H "Content-Type: application/json" -d "$body"); fi
  if ! response=$(curl "${args[@]}" "${DOKPLOY_URL%/}/api/${proc}"); then
    die "Dokploy API ${proc} failed: $(jq -r '.message // .error.json.message // .' <<<"$response" 2>/dev/null | head -c 300)"
  fi
  printf '%s' "$response"
}

# Prints "<postgresId> <appName> <status>" of the shared server, or nothing. project.all only
# carries database ids, so each one is looked up.
find_server() {
  local pid
  for pid in $(api GET project.all | jq -r --arg p "$db_project" \
    '.[] | select(.name == $p) | .environments[]?.postgres[]?.postgresId'); do
    api GET "postgres.one?postgresId=$pid" | jq -r --arg n "$db_name" \
      'select(.name == $n) | "\(.postgresId) \(.appName) \(.applicationStatus)"'
  done | head -n1
}

setup() {
  local project_id env_id id app status password
  read -r id app status <<<"$(find_server)" || true
  if [[ -z ${id:-} ]]; then
    project_id=$(api GET project.all | jq -r --arg p "$db_project" '[.[] | select(.name == $p)][0].projectId // empty')
    if [[ -z $project_id ]]; then
      project_id=$(api POST project.create "$(jq -nc --arg p "$db_project" \
        '{name: $p, description: "Services shared by every project on this server"}')" | jq -r .project.projectId)
      echo "✓ Created Dokploy project $db_project" >&2
    fi
    env_id=$(api GET project.all | jq -r --arg id "$project_id" \
      '[.[] | select(.projectId == $id) | .environments[]][0].environmentId // empty')
    [[ -n $env_id ]] || die "Dokploy project $db_project has no environment"
    password=$(openssl rand -hex 24)
    api POST postgres.create "$(jq -nc --arg n "$db_name" --arg e "$env_id" --arg p "$password" --arg i "$db_image" \
      '{name: $n, appName: $n, databaseName: "postgres", databaseUser: "postgres", databasePassword: $p,
        dockerImage: $i, environmentId: $e, description: "Shared Postgres: one database per project"}')" >/dev/null
    read -r id app status <<<"$(find_server)"
    echo "✓ Created $db_name ($db_image)" >&2
  fi
  if [[ $status != "done" ]]; then
    api POST postgres.deploy "$(jq -nc --arg id "$id" '{postgresId: $id}')" >/dev/null
    for _ in $(seq 1 60); do
      read -r _ _ status <<<"$(find_server)"
      [[ $status == "done" ]] && break
      [[ $status == "error" ]] && die "$db_name failed to start; see Dokploy → $db_project → $db_name"
      sleep 5
    done
    [[ $status == "done" ]] || die "timed out waiting for $db_name to start"
    echo "✓ Started $db_name" >&2
  fi
  echo "• Shared Postgres ready at ${app}:5432 on dokploy-network" >&2
}

status() {
  local id app status
  read -r id app status <<<"$(find_server)" || true
  [[ -n ${id:-} ]] || die "no shared Postgres yet; run 'preview db setup'"
  echo "host=${app} port=5432 status=${status} image=$(api GET "postgres.one?postgresId=$id" | jq -r .dockerImage)"
}

# Creates (or re-passwords) role <name> and database <name> owned by it, through a one-off Dokploy
# "server" schedule that runs psql inside the shared Postgres container. The schedule is deleted
# afterwards so the password doesn't linger in Dokploy.
provision() {
  local name=$1 password=$2 id app status schedule_id deployment="" result="" logs
  [[ $name =~ ^[a-z][a-z0-9_]{0,62}$ ]] || die "database name must match [a-z][a-z0-9_]*, got '$name'"
  [[ $password =~ ^[A-Za-z0-9]+$ ]] || die "password must be alphanumeric"
  read -r id app status <<<"$(find_server)" || true
  [[ -n ${id:-} && $status == "done" ]] || die "shared Postgres is not running; run 'preview db setup'"

  local script
  script=$(cat <<EOF
set -eu
c=\$(docker ps -q -f "name=^${app}\\." | head -n1)
[ -n "\$c" ] || { echo "PROVISION FAILED: no running ${app} container"; exit 1; }
docker exec -i "\$c" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<'SQL'
DO \$\$ BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = '${name}') THEN
    ALTER ROLE ${name} WITH LOGIN PASSWORD '${password}';
  ELSE
    CREATE ROLE ${name} WITH LOGIN PASSWORD '${password}';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE ${name} OWNER ${name}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${name}')\gexec
REVOKE ALL ON DATABASE ${name} FROM PUBLIC;
SQL
echo "PROVISIONED ${name}"
EOF
)
  schedule_id=$(api POST schedule.create "$(jq -nc --arg n "provision-${name}" --arg s "$script" \
    '{name: $n, cronExpression: "0 0 1 1 *", scheduleType: "dokploy-server", shellType: "bash",
      command: "provision", script: $s, enabled: false}')" | jq -r '.scheduleId // empty')
  if [[ -z $schedule_id ]]; then
    schedule_id=$(api GET "schedule.list?id=&scheduleType=dokploy-server" |
      jq -r --arg n "provision-${name}" '[.[] | select(.name == $n)] | last | .scheduleId // empty')
  fi
  [[ -n $schedule_id ]] || die "could not create the provisioning job"
  # shellcheck disable=SC2064
  trap "api POST schedule.delete '{\"scheduleId\":\"$schedule_id\"}' >/dev/null || true" RETURN

  api POST schedule.runManually "$(jq -nc --arg id "$schedule_id" '{scheduleId: $id}')" >/dev/null
  for _ in $(seq 1 30); do
    sleep 2
    read -r deployment result <<<"$(api GET "deployment.allByType?id=$schedule_id&type=schedule" |
      jq -r 'sort_by(.createdAt) | last | if . then "\(.deploymentId) \(.status)" else "" end')" || true
    [[ $result == "done" || $result == "error" ]] && break
  done
  [[ -n $deployment ]] || die "provisioning job for ${name} never started"
  logs=$(api GET "deployment.readLogs?deploymentId=$deployment&tail=50" 2>/dev/null || true)
  if [[ $result != "done" ]] || ! grep -q "PROVISIONED ${name}" <<<"$logs"; then
    die "provisioning ${name} failed (${result:-timeout}): $(grep -o 'PROVISION FAILED[^"]*\|ERROR:[^"]*' <<<"$logs" | head -n3)"
  fi
  echo "✓ Database ${name} ready on ${app}" >&2
}

case "${1:-}" in
  setup) setup ;;
  status) status ;;
  host) read -r _ app _ <<<"$(find_server)"; echo "${app:-}" ;;
  provision) provision "${2:?name}" "${3:?password}" ;;
  *) echo "usage: $0 setup|status|host|provision <name> <password>" >&2; exit 2 ;;
esac
