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

Tables default to `table :posts, enabled: true`. Set `enabled: false` to keep a
declaration while preventing queries, joins, record access and persistence.
Subclasses inherit the flag; table and column flags remain independent. Disabled
columns cannot be read or written, including through record setters. Disabled
timestamps are excluded from automatic writes. Enabled tables must exist; disabled
tables skip column validation regardless of physical presence. These flags never
change the physical schema.

`hamster db:validate --detailed` reports table existence and column check state;
`--json` emits a versioned report with `valid`, `errors`, and `tables`. Both keep
validation read-only and return a nonzero status on mismatches. Default output
remains quiet about disabled declarations.

## Installation contract and Linux verification

The clean-install gate targets Ruby 3.3.6, Bundler 2.5.23, Hamster
0.1.0.pre.3, Spinner 0.1.0.pre.4, PostgreSQL 16.6, and unmodified Spinel/Spin
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

# Candidate gems built locally (Spinner must be supplied until published):
mkdir -p tmp
gem build hamster-web.gemspec --output tmp/hamster-web.gem
bash script/ci/run_native_smoke.sh candidate tmp/hamster-web.gem /path/to/spinel-spinner-0.1.0.pre.4.gem
```

Each invocation builds an image without caches, installs the compiler from its
pinned upstream source, and tests in a separate consumer image containing no
Hamster/Spinner checkout. Only the CI harness and optional candidate gems enter
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
packages. The optional third argument installs a local Spinner gem before Hamster; both
versions, installed paths, and candidate archive/file hashes are checked before
generation and under the app bundle. Omitting it uses the published Spinner pin.
Spinner `0.1.0.pre.4` must be published separately before published-package runs
or normal RubyGems installs can use this contract.

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
For an unpublished Spinner, run
`SPINNER_CANDIDATE_GEM=/path/to/spinel-spinner-0.1.0.pre.4.gem bash script/ci/run_app_docker_smoke.sh`.
The harness stages both gems and replaces the installation step only in the
temporary test Dockerfile. Generated deployment Dockerfiles retain their normal
released-package installation workflow.

For the full build/upload, PostgreSQL provisioning, migration, and public HTTPS
sequence, see [Deploy a generated app to DigitalOcean](docs/deployment/digitalocean.md)
and its [Caddy configuration example](docs/deployment/Caddyfile.example).

### Migration lifecycle

`bin/hamster db:migrate` applies chronological `db/migrations/VERSION_name.sql`
and `.rb` files. Ruby files define one `Hamster::Migration` subclass with explicit
`up` and `down` methods. For example:

```ruby
class CreateWidgets < Hamster::Migration
  def up
    create_table :widgets, columns: {id: :bigint, name: :text}
    add_index :widgets, :name, name: :widgets_name
  end

  def down
    drop_table :widgets
  end
end
```

The tooling supports `add_column`, `remove_column`, `change_column`,
`remove_index` and `execute(sql)` for custom PostgreSQL DDL. Each migration runs
in its own transaction: do not include transaction-control SQL or operations
such as concurrent index creation that require running outside a transaction.
Ruby migrations run in CRuby tooling, never in the compiled server.

Use `db:rollback STEP=1`, `db:migrate:status`, or `db:migrate:history --json`.
Rollback preflights the selected batch and refuses SQL migrations or Ruby files
without `down`. Applied files must remain available and unchanged. Existing
tracking rows keep their versions/timestamps with unknown historical checksums;
new applications record SHA-256 checksums and apply/rollback events. All tracking
and migration changes are serialized through a PostgreSQL advisory lock.
History JSON has `format_version`, `migrations`, and ordered `events` fields.
`legacy_unknown` denotes a preserved tracking row without checksum provenance.

`db:structure:dump` explicitly writes a schema-only `pg_dump` to
`db/structure.sql`; it is a derived snapshot, never a migration input. It requires
PostgreSQL client tools. Run database commands only against an explicitly chosen
database; obtain authorization before changing production databases.

### Action callbacks and concerns

The router invokes framework-owned `dispatch`, which runs before hooks, your
existing `call`, and then after hooks. Declare hooks with literal symbols:

```ruby
module Authentication
  extend Hamster::Action::Callbacks
  before_action :authenticate

  def authenticate
    return respond(body: "Unauthorized", status: :unauthorized) unless context.same_origin?
    nil
  end
end
```

Put shared modules in `app/concerns/` and include them in action classes.
Before hooks return `nil` to continue or an HTTP response to halt. After hooks
accept the response, return `nil` to retain it, or return a replacement response.
They run in registration order, with inherited hooks first, only after a successful
`call`; they do not run on halts or exceptions. Use `ensure` for unconditional
cleanup. Repeated inclusion of a concern does not duplicate its hooks.

Run `bin/hamster manifest` after changing callbacks. The manifest generates direct
method calls for both CRuby and Spinel; dynamic callback names are unsupported.
Code loaded outside a generated manifest does not have generated callback chains.
Do not override `dispatch` or the generated `run_before_actions`/
`run_after_actions` methods. Generator flags follow this runtime API.

### Uploads and downloads

`context.form` parses URL-encoded forms as before. For multipart forms, it returns
arrays of UTF-8 text values per key; `context.uploads` returns arrays of
`Hamster::UploadedFile` per key. Parsing is lazy and shared between these APIs.
Uploads expose `filename`, untrusted `content_type`, `size`, and binary `io`.
`copy_to(destination)` explicitly creates a new durable file without overwriting
an existing path. Client filenames never determine temporary storage paths.
Request-owned temporary files are deleted when the response closes, including
HEAD and interrupted transfers. Copy files before handing work to another process.

Actions can call `send_file("report.bin", root: trusted_directory)` or
`send_data(io_or_string, filename: "report.bin")`. IO bodies are read in 64 KiB
chunks and closed after the response. Downloads default to attachment disposition,
`application/octet-stream`, and `nosniff`; use explicit validated MIME types for
trusted content. Download paths must be within the canonical trusted root and
cannot contain symlinks beneath it. Authorization belongs in the action or its
before hooks. A HEAD request falls back to its GET route and never enumerates the
response body. Range requests are not implemented.

Generated servers expose `MAX_BODY_BYTES` (1 MiB), `BODY_MEMORY_BYTES` (64 KiB),
`SPOOL_DIRECTORY`, and `SPOOL_BUDGET_BYTES` (128 MiB across Spinner workers).
Multipart limits are `UPLOAD_MAX_PARTS` (128), `UPLOAD_MAX_HEADER_BYTES` (16 KiB per
part), `UPLOAD_MAX_FIELD_BYTES` (64 KiB per field), and `UPLOAD_MAX_FILE_BYTES`
(defaults to the request limit). `UPLOAD_DIRECTORY` selects the private upload
spool directory. Increase request and file limits explicitly for larger uploads.
Upload copies use additional disk space, bounded per request by the body limit;
provision temporary disk for concurrent requests in addition to Spinner's spool
budget. Parser limits are checked even when called outside Spinner. Malformed
multipart bodies return 400; exceeded limits return 413.

Binary response transport requires Spinner `0.1.0.pre.4`. Spinner handles binary
socket writes for buffered responses, streams, and WebSockets with the pinned
compiler. Existing apps should update their exact Spinner Gemfile pin and remove
the old compatibility require, then rebuild their native executable. Hamster owns
file bodies, path validation, authorization hooks, and upload cleanup. Multipart
header captures use owned string copies to avoid the pinned runtime's saved-regex
GC bug across workers; header and file limits remain unchanged. The native gate
repeats file acceptance and disconnect checks three times.

### Project-local agent guidance and endpoint generation

New apps include versioned `AGENTS.md` plus discoverable `hamster-endpoint` and
`hamster-database` skills under `.agents/skills/`. No global agent configuration
is required. Agents that do not automatically discover these files can read them
explicitly from AGENTS.md.

Run `bin/hamster generate --help` or `bin/hamster generate --schema` for the
installed generator contract. For example:

```sh
bin/hamster generate endpoint posts/show --method GET --path /posts/:id --name post --view
bin/hamster manifest:check
bin/hamster build
```

Use repeatable `--concern Module` and `--before method` options for existing
concerns and callback methods. Generation validates in staging and refuses file,
route, or name conflicts. Automatic route edits require the conventional generated
Mappings class with literal routes and explicit names; customized layouts receive
a diagnostic without partial output. No authentication stubs are generated.

Existing apps can run `bin/hamster agents:install --dry-run`, then
`bin/hamster agents:install`. Managed-file hashes live in
`.agents/hamster-guidance.json`. Missing files are installed, unchanged managed
files are upgraded, and customized files are preserved with a manual-merge
notice and nonzero exit status. Review old guidance against the current templates
when a conflict is reported. The full component-generator and unified check/test
CLI roadmaps remain separate; use documented project tests and existing native
build checks.

### Composable generators

Use `bin/hamster generate --schema` for the installed contract. Standalone
`action posts/show`, `view posts/show`, and `route posts/show --path /posts/:id`
compose the same files as `endpoint posts/show --view`. Use `--no-view` for a
body-only action. `route --to App::Routes::Posts::Show::Action` targets an existing
statically declared action. Automatic route edits require conventional literal
Mappings declarations; customized routing receives a diagnostic.

`generate table posts title:text` creates an explicit `Posts` declaration for
physical table `posts`; it never creates or migrates the database. `generate
migration create_posts` creates an intentionally unimplemented reversible Ruby
migration; fill in both methods before running it. `--timestamp YYYYMMDDhhmmss`
selects an explicit unique version.

All generators accept `--dry-run` and `--json`. JSON lists the exact changed
relative files, including refreshed manifests. Proposals are parsed and checked
in staging before writes; collisions, symlinks, and unresolved callbacks fail
without changing the app. Dry runs leave the app untouched.

### Shared checks and optional hooks

`bin/hamster check --quick` checks Ruby syntax, manifest freshness, literal route
references/conflicts and action view references without rewriting files or
connecting to a database. `--json` returns versioned diagnostic codes, relative
paths and line numbers. `check --full` adds project `test/**/*_test.rb` tests and
compiles `test/native_server.rb`, starts it on a private ephemeral loopback port,
and checks `/up`. It also runs `test/native_http.rb` when present. The default
native test entrypoint uses no database; database tests must explicitly select
an isolated disposable test database. CI runs full checks in the native consumer.

Run `bin/hamster hooks:install` explicitly from an app Git root to configure
`.githooks/pre-commit`; add `--pre-push` for full checks before pushing. Customized
hooks are preserved. Cloning or generating an app never changes Git config.
Hooks can be bypassed with Git's normal `--no-verify` option; CI is authoritative.

### JSON actions and explicit negotiation

Use `respond(json: {id: 1}, status: :created)` for UTF-8 JSON; `json: nil`
produces `null`. Supply exactly one of `view:`, `body:`, or `json:`. Only JSON
scalars, arrays, and hashes with string/symbol keys are supported. Select record
fields explicitly; arbitrary objects, duplicate normalized keys, cycles, invalid
UTF-8 and nonfinite numbers are rejected.

`context.json` lazily parses and caches `application/json` or `application/*+json`
bodies with a default 1 MiB limit (server-owned env key `hamster.json_max_bytes`
can lower it). Invalid bodies return 400, wrong media types 415, and oversized
bodies 413. JSON and form parsing are mutually exclusive per request. Spinner's
transport limit still applies independently.

Branch on `context.wants_json?` or `context.format` (`:html`, `:json`,
`:turbo_stream`, `:none`) when an endpoint offers variants. Negotiation honors
Accept quality/specificity and defaults to HTML for absent Accept or ties;
respond with 406 explicitly for `:none`. Negotiated responses include `Vary:
Accept, Turbo-Frame`, including the HTML branch. Existing HTML/Turbo rendering
continues through `respond(view: ...)` and `type: :turbo_stream`.

### Request tests and disposable databases

`bin/hamster test [test/path] [--json]` runs CRuby request tests. New endpoints
include tests that assert their actual generated response. `check --full` runs
the same tests plus compiled HTTP checks. Extend `test/native_http.rb` for your
application's native assertions; `test/native_server.rb` is an explicit test
entrypoint and defaults to no database.

`Hamster::Testing::Client` accepts headers, JSON, form, raw and multipart bodies;
responses expose status, headers, body, parsed `json`, and `content_type`. Bodies
and request inputs close even on HEAD or iteration failures. Tests inherit
`Hamster::Testing::Test` for status, content-type, HTML and JSON assertions.

For real database tests, require `hamster/test_database`, make the vendored pg
driver available, and call `Hamster::Testing::TestDatabase.with_database` with
your migration path. Explicitly set `HAMSTER_ENV=test`, `HAMSTER_TEST_DATABASE=1`
and `TEST_DATABASE_USERNAME` (plus optional TEST_DATABASE_HOST/PORT/PASSWORD).
Unset DATABASE_NAME and DATABASE_URL. Each invocation creates a unique database,
migrates it, and drops only that owned database in ensure. Non-loopback hosts
require `HAMSTER_TEST_ALLOW_REMOTE=1`; use a dedicated test PostgreSQL service.
`TestDatabase.rollback(database) { |connection| ... }` isolates fixture changes
within a transaction that always rolls back. Never share that connection with
another thread. No production endpoint is inferred from application settings.

### Development rebuild loop

Run `bin/hamster dev` after setup. It hashes source/view/config/asset/test files,
debounces changes, runs fast CRuby syntax checks, regenerates deterministic
manifests through the build command, compiles Spinel, checks freshness, and starts
the new executable. The server stops as soon as an edit is observed. Failed
builds leave it stopped, show compiler diagnostics, and recover on the next edit.
Changes during compilation trigger another build before any server starts.

One build runs at a time; polling uses a bounded interval. Build timings are
printed after every successful rebuild. Ctrl-C/TERM drains the entire child
server process group with a deadline, then forces cleanup if necessary. Full
request/native tests remain explicit (`check --full`); dev reports the checks it
actually ran. AOT compilation still occurs on edits; no incremental compiler or
runtime code reloading is promised. Compare reported timings after small action,
view and route edits on your machine before tuning the loop.

### Static application inspection

`bin/hamster inspect --json` emits a deterministic versioned graph of routes,
actions, views, tables/columns, queries, concerns, methods/callbacks and tests.
Nodes have stable declaration-based IDs and relative source paths/lines; edges
carry `declared`, `inferred`, or `unknown` certainty. `inspect routes --json` and
`inspect action posts/create --json` filter the graph. `--check` returns nonzero
for unresolved callbacks/routes, missing views or declared disabled dependencies;
these checks also participate in `check --quick`.

Inspection parses declarations and manifests without executing application Ruby,
loading credentials, or connecting to a database. It reports dynamic/unresolved
references instead of claiming complete Ruby analysis. Test-to-action links use
generator path conventions and are explicitly inferred. No live DB inspection
is performed. Graph facts update automatically after renames and new components.
