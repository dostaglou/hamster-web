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
if [[ "$mode" == candidate && -f /input/spinel-spinner.gem ]]; then
  gem install /input/spinel-spinner.gem --local --no-document
else
  gem install spinel-spinner --version "$SPINNER_VERSION" --no-document
fi
if [[ "$mode" == candidate ]]; then
  gem install /input/hamster-web.gem --no-document
else
  gem install hamster-web --version "$HAMSTER_VERSION" --no-document
fi
# Check package provenance before generation and again under the app's bundle.
candidate_paths=()
if [[ "$mode" == candidate ]]; then
  candidate_paths+=(/input/hamster-web.gem)
  if [[ -f /input/spinel-spinner.gem ]]; then candidate_paths+=(/input/spinel-spinner.gem); fi
fi
ruby /smoke/check_gems.rb "$HAMSTER_VERSION" "$SPINNER_VERSION" "${candidate_paths[@]}" | tee /artifacts/gem-paths.txt
stage=generation
hamster new SmokeApp
cd smoke_app
stage=setup
bin/hamster setup
cp Gemfile.lock spin.lock /artifacts/
bundle exec ruby /smoke/check_gems.rb "$HAMSTER_VERSION" "$SPINNER_VERSION" "${candidate_paths[@]}"
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
if [[ "$mode" == candidate ]]; then
  cat > db/migrations/002_reversible.rb <<'RUBY'
class ReversibleSmoke < Hamster::Migration
  def up
    create_table :reversible_smoke, columns: {id: :integer}
  end
  def down
    drop_table :reversible_smoke
  end
end
RUBY
  bin/hamster db:migrate
  bin/hamster db:migrate:history --json > /artifacts/migration-history.json
  bin/hamster db:rollback STEP=1
  bin/hamster db:migrate
  bin/hamster generate --help
  bin/hamster generate --schema > /artifacts/generator-schema.json
  bin/hamster agents:install --dry-run
  test -f .agents/skills/hamster-endpoint/SKILL.md
  test -f .agents/skills/hamster-database/SKILL.md
  mkdir -p app/concerns
  cp /smoke/callback_concern.rb app/concerns/audit.rb
  bin/hamster generate endpoint callbacks/check --concern SmokeApp::Audit
  cp /smoke/file_actions.rb app/routes/file_actions.rb
  ruby -e 'p="app/routes/mappings.rb"; s=File.read(p); s=s.sub("      get \"/up\",", "      post \"/upload\", to: FileFixtures::Upload, as: :upload\n      get \"/download\", to: FileFixtures::Download, as: :download\n      get \"/up\","); File.write(p,s)'
  mkdir -p /work/files /work/uploads
  python3 -c 'from pathlib import Path; Path("/work/files/download.bin").write_bytes(bytes(range(256))*8192)'
  export MAX_BODY_BYTES=4194304 HAMSTER_FILE_ROOT=/work/files UPLOAD_DIRECTORY=/work/uploads
  bin/hamster manifest
fi
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
if [[ "$mode" == candidate ]]; then
  python3 /smoke/check_callback_http.py http://127.0.0.1:4000/callbacks/check callbacks/check
  stage=file-http
  # Repeat allocations and disconnects: a single round can miss a cross-worker
  # collection of the pinned runtime's saved multipart regex subjects.
  for round in 1 2 3; do
    echo "File acceptance round $round"
    python3 /smoke/check_file_http.py http://127.0.0.1:4000
    test -z "$(find /work/uploads -type f -print -quit)"
  done
fi
echo "PASS: $mode packages generated, migrated, compiled and served native HTTP 200"
