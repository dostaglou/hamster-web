# Hamster Web

Hamster is a Spinel web framework under development. The `hamster-web` gem will
provide the `hamster` CLI and the `hamster/web` application runtime. Spinner is
its HTTP server dependency.

The starter generates and compiles with PostgreSQL support, explicit routes,
actions, compiled views, and SQL migrations. Database creation and migration
commands, the console, and schema-aware records/queries are available.
Telemetry extraction and asset delivery remain under development.

Install the public framework preview from RubyGems:

```sh
gem install bundler --version 2.5.23
gem install hamster-web --version 0.1.0.pre.3
hamster new MyApp
cd my_app
bin/hamster setup
# Configure PostgreSQL credentials; these defaults use your local OS role.
export DATABASE_USERNAME="$USER"
export DATABASE_ADMIN_USERNAME="$USER"
export DATABASE_PASSWORD=""
export DATABASE_ADMIN_PASSWORD=""
bin/hamster db:create
bin/hamster db:migrate
bin/hamster build
bin/hamster serve
```

Run framework tests with `ruby -Ilib -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'`.

## Records and queries

Load `hamster/data` (also loaded by the PostgreSQL adapter) and declare models
with `Hamster::Table`, `table`, and literal `column` definitions. Columns must
explicitly opt into writes with `write: :create`, `:update`, or `:both`.
Creation returns a result with `success?`, `record`, and `errors`; `create!`
returns the record or raises a typed error. Timestamps are maintained only
when the model declares created_at or updated_at columns.

`database.with_connection` binds the connection for record writes. Queries
such as `Post.where(title: "Hello").order(:id).load` return typed rows. Explicit
callers can also pass `connection:` to query terminal methods or scope writes
with `Hamster::Record.with_connection(connection)`.

Run `hamster manifest` after adding columns or query fields: it generates the
static getters and setters used by Spinel. Rebuild after model changes.

## Console and schema checks

Run `hamster console` (or `hamster c`) in an application. The IRB session exposes
`app`, `application`, and `database`; record operations use a connection scoped
to that session. Exit releases the connection and shuts down the application.
Database environment settings apply as they do to the server.

Run `hamster db:validate` to compare declared tables and columns against the
configured PostgreSQL database. It reports missing tables/columns, incompatible
types, and unexpected nullability with a nonzero exit status. It never migrates
or modifies the schema. Configuration is loaded through config/commands.rb,
a CRuby-only adapter generated with new applications.

## Installation contract and Linux verification

The clean-install gate targets Ruby 3.3.6, Bundler 2.5.23, Hamster
0.1.0.pre.3, Spinner 0.1.0.pre.1, PostgreSQL 16.6, and unmodified Spinel/Spin
revision `10f112c51666e7ffd308e0ab90a69c2184870c06`. The exact CI inputs live
in `script/ci/versions.env`; Linux compatibility is verified by the native
smoke workflow. This pin does not include the experimental benchmark runtime.

The server gem is named `spinel-spinner`; Ruby application code uses
`require "spinner"` and the `Spinner` namespace. Hamster installs it as a
separate, exact-version dependency. The RubyGems package named `spinner` is
unrelated. Neither framework gem bundles a compiler or a precompiled server.

Spinel and its `spin` project tool must be installed before app setup. On
Debian Bookworm, install `build-essential`, `ca-certificates`, `curl`, `git`,
`pkg-config`, `libffi-dev`, and `libssl-dev`. PostgreSQL must be available;
`postgresql-client` provides the smoke test's `psql` checks. Build the pinned
upstream toolchain into a dedicated installation prefix:

```sh
git clone https://github.com/matz/spinel.git
cd spinel
git checkout --detach 10f112c51666e7ffd308e0ab90a69c2184870c06
make deps
make -j2
make install PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
spinel --version
spin --version
```

Then run the app generation commands above from an empty directory. Setup
fetches the PostgreSQL driver revision in the generated `spin.lock` from
`https://github.com/rubys/spinel-pg`. RubyGems and GitHub network access are
required. Configure `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`,
`DATABASE_USERNAME`, and `DATABASE_PASSWORD` for your PostgreSQL server.
`DATABASE_ADMIN_NAME` defaults to `postgres`; administrative credentials default
to the application credentials and need permission to create the database.
The generated README describes the defaults and build/serve commands.

To build a local framework preview instead of installing the public package:

```sh
gem build hamster-web.gemspec
gem install --local hamster-web-0.1.0.pre.3.gem
```

Run the clean Linux gate locally with Docker running (no local PostgreSQL or
Spinel installation needed):

```sh
# Public packages, installed directly from RubyGems:
bash script/ci/run_native_smoke.sh published

# Candidate gem built from this checkout, plus published Spinner:
mkdir -p tmp
gem build hamster-web.gemspec --output tmp/hamster-web.gem
bash script/ci/run_native_smoke.sh candidate tmp/hamster-web.gem
```

Each invocation builds an image without caches, installs the compiler from its
pinned upstream source, and tests in a separate consumer image containing no
Hamster/Spinner checkout. Only the CI harness and optional candidate gem enter
that environment. Gems, Bundler settings, and the generated app use fresh
isolated directories. Package resolution must stay within that gem installation.
The test creates a disposable database, applies a real migration twice, checks
its effects and tracking, compiles the app, and asserts HTTP 200 and welcome
content from the native executable. Containers, their processes, networks, and
the tagged test image are removed on exit. Docker retains image build layers;
no restored layers are used by the gate.

Logs, lockfiles, resolved package paths, and HTTP output are retained under
`tmp/native-smoke-<mode>/` (override with `SMOKE_ARTIFACTS_DIR`). GitHub Actions
uploads those diagnostics even on failure. Pull requests and main test the
candidate package; weekly and manually triggered runs also test published
packages. Public pins are advanced deliberately when releases are available.

## Generated deployment images

New applications include a multi-stage `Dockerfile`, `.dockerignore`, and a
`GET /up` liveness endpoint. Build with `docker build -t my_app .`; no host Ruby,
Spinel, or database is needed. The default image runs the native executable as
UID 10001 on port 4000, with shared libraries, migrations and public assets only.
Ruby and the compiler are confined to build/operational stages.

Build `--target migrations` separately and run that image's `db:migrate`
command with database settings supplied at runtime before deploying the native
image. Migrations never run during image build or server startup. `/up` bypasses
database checkout after the application's initial database/migration verification,
so it reports process liveness rather than database readiness. The generated
README includes deployment commands, environment settings and shutdown semantics.

Run `bash script/ci/run_app_docker_smoke.sh` to verify the generated image using
Docker alone. It packages and installs the current framework inside a temporary
container, generates an app, builds before creating any database, checks secret
exclusions and runtime linkage, applies a real migration, verifies HTTP and Docker
health checks as a non-root user without Ruby/Spinel, stops PostgreSQL to test
liveness, and verifies clean SIGTERM shutdown. Diagnostics are retained in
`tmp/app-docker-smoke/`. This runs as a separate job in the native smoke workflow.
