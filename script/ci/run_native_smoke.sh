#!/usr/bin/env bash
# Only this directory and an optional .gem artifact enter the consumer image.
set -Eeuo pipefail
ci_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$ci_dir/versions.env"
mode=${1:-published}
if [[ "$mode" != candidate && "$mode" != published ]]; then
  echo "Usage: $0 published | candidate path/to/hamster-web.gem" >&2
  exit 2
fi
gem_file=
if [[ "$mode" == candidate ]]; then
  [[ $# == 2 && -f "$2" ]] || { echo "Candidate mode requires a built .gem artifact" >&2; exit 2; }
  gem_file=$(cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")
fi
command -v docker >/dev/null || { echo "Install Docker to run the Linux smoke test" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Start the Docker daemon before running the smoke test" >&2; exit 1; }
log_dir=${SMOKE_ARTIFACTS_DIR:-$ci_dir/../../tmp/native-smoke-$mode}
mkdir -p "$log_dir"
log_dir=$(cd -- "$log_dir" && pwd)
run_id="hamster-smoke-$(date +%s)-$$"
network=$run_id
postgres=$run_id-postgres
consumer=$run_id-consumer
image=$run_id
cleanup() {
  local status=$?
  trap - EXIT
  docker logs "$postgres" > "$log_dir/postgres.log" 2>&1 || true
  docker rm -fv "$consumer" "$postgres" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm "$image" >/dev/null 2>&1 || true
  echo "Smoke artifacts: $log_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Disable build caches as well as gem caches for the clean-install gate.
docker build --no-cache --progress plain --label io.hamster.native-smoke=true --build-arg "RUBY_IMAGE=$RUBY_IMAGE" \
  --build-arg "SPINEL_REVISION=$SPINEL_REVISION" -t "$image" "$ci_dir" 2>&1 | tee "$log_dir/image-build.log"
docker network create --label io.hamster.native-smoke=true "$network" >/dev/null
docker run -d --label io.hamster.native-smoke=true --name "$postgres" --network "$network" --network-alias postgres \
  -e POSTGRES_USER=smoke -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=postgres \
  "$POSTGRES_IMAGE" >/dev/null
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  if docker exec "$postgres" pg_isready -U smoke -d postgres >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { echo "PostgreSQL readiness deadline exceeded" >&2; exit 1; }
consumer_args=(--label io.hamster.native-smoke=true --name "$consumer" --network "$network"
  --mount "type=bind,source=$log_dir,target=/artifacts")
if [[ "$mode" == candidate ]]; then
  consumer_args+=(--mount "type=bind,source=$gem_file,target=/input/hamster-web.gem,readonly")
fi
docker run "${consumer_args[@]}" "$image" "$mode"
