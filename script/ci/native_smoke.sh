#!/usr/bin/env bash
# Runs inside the consumer image, which contains no Hamster/Spinner checkout.
set -Eeuo pipefail
# shellcheck source=versions.env
source /smoke/versions.env
mode=${1:-published}
[[ "$mode" == candidate || "$mode" == published ]] || { echo "Expected candidate or published" >&2; exit 2; }
mkdir -p /artifacts /work
stage=initialization
server_pid=
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for ((attempt=0; attempt<15; attempt++)); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if ((status != 0)); then
    echo "Smoke failed during: $stage (exit $status)" >&2
    tail -n 100 /artifacts/server.log 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
exec > >(tee /artifacts/smoke.log) 2>&1
export HOME=/work/home GEM_HOME=/work/gems GEM_PATH=/work/gems
export BUNDLE_USER_HOME=/work/bundle BUNDLE_DISABLE_SHARED_GEMS=true
export PATH="$GEM_HOME/bin:$PATH"
mkdir -p "$HOME" "$GEM_HOME"
cd /work
stage=toolchain
ruby --version | tee /artifacts/ruby-version.txt
grep -F "ruby $RUBY_VERSION " /artifacts/ruby-version.txt
spinel --version | tee /artifacts/spinel-version.txt
grep -F "${SPINEL_REVISION:0:8}" /artifacts/spinel-version.txt
spin --version | tee /artifacts/spin-version.txt
grep -F "${SPINEL_REVISION:0:8}" /artifacts/spin-version.txt
stage=installation
gem install bundler --version "$BUNDLER_VERSION" --no-document
gem install spinel-spinner --version "$SPINNER_VERSION" --no-document
if [[ "$mode" == candidate ]]; then
  gem install /input/hamster-web.gem --no-document
else
  gem install hamster-web --version "$HAMSTER_VERSION" --no-document
fi
# Check package provenance before generation and again under the app's bundle.
cat > /work/check_gems.rb <<'RUBY'
require "rubygems"
expected = {"hamster-web" => ARGV.fetch(0), "spinel-spinner" => ARGV.fetch(1)}
expected.each do |name, version|
  spec = Gem::Specification.find_by_name(name, "= #{version}")
  path = File.realpath(spec.full_gem_path)
  abort "#{name} resolved outside isolated gems: #{path}" unless path.start_with?(File.realpath(ENV.fetch("GEM_HOME")) + "/")
  puts "#{name} #{spec.version}: #{path}"
end
RUBY
ruby /work/check_gems.rb "$HAMSTER_VERSION" "$SPINNER_VERSION" | tee /artifacts/gem-paths.txt
stage=generation
hamster new SmokeApp
cd smoke_app
stage=setup
bin/hamster setup
cp Gemfile.lock spin.lock /artifacts/
bundle exec ruby /work/check_gems.rb "$HAMSTER_VERSION" "$SPINNER_VERSION"
grep -Fx "$PG_REVISION" vendor/packages/pg-0.2.0/.spin-sha
export DATABASE_HOST=postgres DATABASE_PORT=5432 DATABASE_NAME=smoke_app_test
export DATABASE_USERNAME=smoke DATABASE_PASSWORD=smoke DATABASE_ADMIN_USERNAME=smoke DATABASE_ADMIN_PASSWORD=smoke
export HAMSTER_ENV=test
export PGHOST="$DATABASE_HOST" PGPORT="$DATABASE_PORT" PGUSER="$DATABASE_USERNAME" PGPASSWORD="$DATABASE_PASSWORD"
stage=database-creation
bin/hamster db:create
stage=migration
mkdir -p db/migrations
cat > db/migrations/001_smoke.sql <<'SQL'
CREATE TABLE smoke_probes (id INTEGER PRIMARY KEY, message TEXT NOT NULL);
INSERT INTO smoke_probes (id, message) VALUES (1, 'native smoke migration');
SQL
bin/hamster db:migrate
# A second execution would fail on CREATE TABLE if tracking did not work.
bin/hamster db:migrate
[[ "$(psql -X -d "$DATABASE_NAME" -Atc "SELECT message FROM smoke_probes WHERE id = 1")" == 'native smoke migration' ]]
[[ "$(psql -X -d "$DATABASE_NAME" -Atc "SELECT count(*) FROM schema_migrations WHERE version = '001'")" == 1 ]]
stage=compilation
bin/hamster manifest:check
bin/hamster build
test -x bin/smoke_app-server
file bin/smoke_app-server | tee /artifacts/binary.txt
grep -F 'ELF' /artifacts/binary.txt
stage=startup
HOST=127.0.0.1 PORT=4000 bin/hamster serve > /artifacts/server.log 2>&1 &
server_pid=$!
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  kill -0 "$server_pid" 2>/dev/null || { echo "Native server exited before readiness" >&2; exit 1; }
  code=$(curl --silent --output /artifacts/response.html --write-out '%{http_code}' --connect-timeout 1 --max-time 2 http://127.0.0.1:4000/ || true)
  if [[ "$code" == 200 ]]; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { echo "HTTP readiness deadline exceeded" >&2; exit 1; }
stage=http-assertions
grep -F 'Welcome to smoke_app' /artifacts/response.html
grep -F 'Your Hamster application is running.' /artifacts/response.html
echo "PASS: $mode packages generated, migrated, compiled and served native HTTP 200"
