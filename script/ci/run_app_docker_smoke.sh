#!/usr/bin/env bash
# Requires Docker only on the host. Generate from a built gem inside Ruby's image.
set -Eeuo pipefail
ci_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$ci_dir/../.." && pwd)
source "$ci_dir/versions.env"
command -v docker >/dev/null || { echo "Install Docker to run this test" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Start Docker before running this test" >&2; exit 1; }
log_dir=${SMOKE_ARTIFACTS_DIR:-$repo_dir/tmp/app-docker-smoke}
mkdir -p "$log_dir"
log_dir=$(cd "$log_dir" && pwd)
work_dir=$(mktemp -d)
run_id="hamster-app-$(date +%s)-$$"
network=$run_id
postgres=$run_id-postgres
web=$run_id-web
generator=$run_id-generator
image=$run_id-runtime
migration_image=$run_id-migrations
stage="generation"
cleanup() {
  local status=$?
  trap - EXIT
  docker logs "$web" > "$log_dir/server.log" 2>&1 || true
  docker logs "$postgres" > "$log_dir/postgres.log" 2>&1 || true
  docker rm -fv "$generator" "$web" "$postgres" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm "$image" "$migration_image" >/dev/null 2>&1 || true
  rm -rf "$work_dir"
  if ((status != 0)); then echo "Generated-app Docker smoke failed during: $stage (exit $status)" >&2; fi
  echo "Generated-app Docker artifacts: $log_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# The mounted checkout is read-only and is used only to package the candidate.
docker run --rm --label io.hamster.app-smoke=true --name "$generator" \
  --user "$(id -u):$(id -g)" -e HOME=/tmp/home -e GEM_HOME=/tmp/gems -e GEM_PATH=/tmp/gems \
  -e PATH=/tmp/gems/bin:/usr/local/bin:/usr/bin:/bin \
  --mount "type=bind,source=$repo_dir,target=/framework,readonly" \
  --mount "type=bind,source=$work_dir,target=/output" "$RUBY_IMAGE" bash -euc '
    mkdir -p "$HOME" "$GEM_HOME"
    cd /framework
    gem build hamster-web.gemspec --output /output/hamster-web.gem
    gem install /output/hamster-web.gem --no-document
    cd /output
    hamster new DeployApp
  ' 2>&1 | tee "$log_dir/generation.log"
app_dir=$work_dir/deploy_app
# Exercise the payload copied into runtime, and exclusions from builder layers.
cat > "$app_dir/db/migrations/001_container.sql" <<'SQL'
CREATE TABLE container_probes (id INTEGER PRIMARY KEY, message TEXT NOT NULL);
INSERT INTO container_probes VALUES (1, 'container migration');
SQL
printf 'public asset fixture\n' > "$app_dir/public/probe.txt"
printf 'DATABASE_PASSWORD=must-not-enter-image\n' > "$app_dir/.env.production"
printf 'must-not-enter-image\n' > "$app_dir/config/master.key"
mkdir -p "$app_dir/tmp" "$app_dir/.bundle"
printf 'must-not-enter-image\n' > "$app_dir/tmp/secret"
printf 'must-not-enter-image\n' > "$app_dir/.bundle/config"
printf 'must-not-enter-image\n' > "$app_dir/bin/deploy_app-server"
cp "$app_dir/Dockerfile" "$app_dir/.dockerignore" "$log_dir/"
stage="image-build-without-database"
# No database exists yet. No database variables, build arguments, or secrets supplied.
docker build --no-cache --progress plain --label io.hamster.app-smoke=true \
  -t "$image" "$app_dir" 2>&1 | tee "$log_dir/image-build.log"
docker build --progress plain --label io.hamster.app-smoke=true \
  --target migrations -t "$migration_image" "$app_dir" 2>&1 | tee "$log_dir/migration-image-build.log"
stage="image-contract"
docker run --rm --entrypoint sh "$migration_image" -euc '
  test ! -e /app/.env.production
  test ! -e /app/config/master.key
  test ! -e /app/tmp/secret
  ! grep -r -F must-not-enter-image /app
'
docker run --rm --entrypoint sh "$image" -euc '
  test "$(id -u)" = 10001
  for tool in ruby gem bundle spin spinel cc gcc; do
    if command -v "$tool"; then echo "Unexpected runtime tool: $tool" >&2; exit 1; fi
  done
  test ! -d /app/config && test ! -d /app/app && test ! -d /app/vendor
  test -f /app/db/migrations/001_container.sql
  test "$(cat /app/public/probe.txt)" = "public asset fixture"
  ldd /app/bin/deploy_app-server > /tmp/ldd.txt
  cat /tmp/ldd.txt
  ! grep -F "not found" /tmp/ldd.txt
' | tee "$log_dir/runtime-contract.log"
docker image inspect "$image" > "$log_dir/image.json"
if docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -E '^DATABASE_'; then
  echo "Database configuration was embedded in the runtime image" >&2
  exit 1
fi
stage="database"
docker network create --label io.hamster.app-smoke=true "$network" >/dev/null
docker run -d --label io.hamster.app-smoke=true --name "$postgres" --network "$network" --network-alias postgres \
  -e POSTGRES_USER=smoke -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=postgres "$POSTGRES_IMAGE" >/dev/null
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  if docker exec "$postgres" pg_isready -U smoke -d postgres >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { echo "PostgreSQL did not become ready" >&2; exit 1; }
db_env=(-e DATABASE_HOST=postgres -e DATABASE_PORT=5432 -e DATABASE_NAME=deploy_app_production
  -e DATABASE_USERNAME=smoke -e DATABASE_PASSWORD=smoke -e DATABASE_ADMIN_USERNAME=smoke -e DATABASE_ADMIN_PASSWORD=smoke)
stage="explicit-migrations"
for command in db:create db:migrate db:migrate; do
  docker run --rm --label io.hamster.app-smoke=true --network "$network" "${db_env[@]}" \
    "$migration_image" "$command" 2>&1 | tee -a "$log_dir/migrations.log"
done
[[ "$(docker exec "$postgres" psql -U smoke -d deploy_app_production -Atc 'SELECT message FROM container_probes WHERE id = 1')" == 'container migration' ]]
[[ "$(docker exec "$postgres" psql -U smoke -d deploy_app_production -Atc "SELECT count(*) FROM schema_migrations WHERE version = '001'")" == 1 ]]
stage="runtime-health"
docker run -d --label io.hamster.app-smoke=true --name "$web" --network "$network" --network-alias web \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,mode=1777 "${db_env[@]}" "$image" >/dev/null
ready=false
for ((attempt=0; attempt<90; attempt++)); do
  state=$(docker inspect --format '{{.State.Status}} {{.State.Health.Status}}' "$web")
  [[ "$state" != exited* ]] || { echo "Native runtime exited before readiness" >&2; exit 1; }
  if [[ "$state" == 'running healthy' ]]; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { echo "Native runtime health check deadline exceeded" >&2; exit 1; }
# A separate container must reach HOST=0.0.0.0 on the advertised port.
docker run --rm --label io.hamster.app-smoke=true --network "$network" --entrypoint curl "$migration_image" \
  --fail --silent --show-error --max-time 10 http://web:4000/ > "$log_dir/response.html"
grep -F 'Welcome to deploy_app' "$log_dir/response.html"
docker exec "$web" curl --fail --silent --show-error --max-time 3 http://127.0.0.1:4000/up > "$log_dir/up.txt"
[[ "$(cat "$log_dir/up.txt")" == OK ]]
stage="liveness-during-database-outage"
docker stop --time 10 "$postgres" >/dev/null
docker exec "$web" curl --fail --silent --show-error --max-time 3 http://127.0.0.1:4000/up > "$log_dir/up-without-database.txt"
[[ "$(cat "$log_dir/up-without-database.txt")" == OK ]]
[[ "$(docker exec "$web" curl --silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}' http://127.0.0.1:4000/)" == 500 ]]
stage="sigterm"
docker stop --time 20 "$web" >/dev/null
docker inspect "$web" > "$log_dir/runtime-state.json"
[[ "$(docker inspect --format '{{.State.ExitCode}}' "$web")" == 0 ]]
echo "PASS: generated Dockerfile builds without a DB, runs non-root without Ruby/Spinel, serves HTTP, keeps /up alive without PostgreSQL, and exits cleanly on SIGTERM"
