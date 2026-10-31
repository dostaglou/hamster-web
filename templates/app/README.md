# __APP_NAME__

Run `bin/hamster setup` to install gems and vendor the locked Spin PostgreSQL driver.
Spin and Spinel must already be installed. The preview installation contract is
Ruby 3.3.6, Bundler 2.5.23, Hamster __HAMSTER_VERSION__, spinel-spinner
0.1.0.pre.4, and Spinel/Spin revision
`10f112c51666e7ffd308e0ab90a69c2184870c06`. See the framework README at
https://github.com/dostaglou/hamster-web for compiler installation prerequisites.
Spinner's gem name is `spinel-spinner`; application code uses `require "spinner"`.
Both gems are available from https://rubygems.org. Configure DATABASE_USERNAME,
DATABASE_PASSWORD, and optionally DATABASE_HOST and DATABASE_PORT for your local
PostgreSQL server. DATABASE_NAME defaults to __APP_NAME___development.

Setup and build apply three string-copy compatibility fixes to the pinned
pg client for Spinel. The fixes are repeatable after spin vendor and reject
an unknown driver revision; avoid editing vendored driver sources manually.

Run `bin/hamster db:create`, `bin/hamster db:migrate`, `bin/hamster build`,
then `bin/hamster serve`. Build does not require a database connection.
An empty migration directory is valid; db:migrate initializes migration tracking.
The server listens on http://127.0.0.1:4000 by default; configure HOST and PORT
to override it. During framework development, install the local hamster-web
gem before running setup. Otherwise the pinned framework is installed from RubyGems.

Run a deployed binary from the application root or set HAMSTER_APP_ROOT.
Include db/migrations alongside the binary. PostgreSQL TLS is not supported
by the current driver integration.

Use `bin/hamster console` (alias `c`) for an IRB session with app, application,
and database variables and a connection scope for record writes and queries.
Use `bin/hamster db:validate` to check model table/column declarations against
PostgreSQL without applying migrations. These commands use config/commands.rb,
which is deliberately excluded from the compiled server's boot chain.

Each endpoint has an action.rb and optional view.html.erb in app/routes/.
Declare endpoints centrally in app/routes/mappings.rb. Run
`bin/hamster manifest` after changing Ruby sources or templates and commit
the generated manifest and view registry with your source changes.

## Docker deployment

The generated Dockerfile builds the Spinel compiler and `spin` at the pinned
revision, installs the framework from RubyGems, runs setup and manifest checks,
and compiles your application. Docker is the only build prerequisite on the
host. Commit `Gemfile.lock` and `spin.lock` to keep dependency resolution stable.
No database or database credentials are needed to build either target.

```sh
docker build -t __APP_NAME__:latest .
docker build --target migrations -t __APP_NAME__:migrations .
```

The default image uses Debian Bookworm slim and UID/GID 10001. It contains the
native executable, shared runtime libraries, SQL migrations and `public/`;
Ruby, gems, Spinel, application source and build tools stay in the builder.
Both builder and runtime verify the executable's shared library linkage with
`ldd`. Public files are retained for application-managed assets; the image does
not add an asset-serving route.

Provide database settings at container runtime, for example in an uncommitted
`.env.production` file. Set `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`,
`DATABASE_USERNAME`, and `DATABASE_PASSWORD`. The production database name
defaults to `__APP_NAME___production`. The database must already exist; use
`db:create` with separate administrative credentials only when provisioning it.
The Docker context excludes `.env` files, private keys, local gems, compiled
host binaries, and local Bundler settings. Keep credentials out of Ruby source
and Docker build arguments as well.

Apply migrations explicitly as a deployment step, then start the native image:

```sh
docker run --rm --env-file .env.production __APP_NAME__:migrations
docker run -d --name __APP_NAME__ --env-file .env.production -p 4000:4000 __APP_NAME__:latest
```

The `migrations` target includes Ruby and build dependencies for the existing
Hamster CLI; it is a separate operational image. Its default command is
`db:migrate`, and an explicit argument can select another command. Neither
image build nor native server startup applies migrations. Startup verifies the
configured database and rejects missing migration tracking or pending migrations.

The runtime sets `HAMSTER_APP_ROOT=/app`, `HAMSTER_ENV=production`,
`HOST=0.0.0.0` and `PORT=4000`. Override `PORT` and the port mapping together if
needed. The executable runs directly as PID 1 and receives SIGTERM. Allow its
graceful shutdown time when stopping it, for example `docker stop -t 20 __APP_NAME__`.
Only temporary storage needs to be writable; the CI smoke test runs with a
read-only root filesystem and a writable `/tmp`.

`GET /up` returns HTTP 200 with `OK` after successful startup. This is liveness:
it checks HTTP dispatch without checking out a database connection. A later
database outage does not make `/up` fail. It is not a readiness check or a
promise that application requests can reach PostgreSQL. The route is declared
in `app/routes/mappings.rb`, and `app/application.rb` bypasses the normal
database checkout for that path. The Docker health check calls `/up` using the
configured `PORT`.

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
