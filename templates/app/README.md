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
`ldd`. Public files include fingerprinted assets served through Hamster's whitelist.

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

### Explicit input forms

Subclass `Hamster::Form` and declare literal fields, for example `field :title,
required: true, max_length: 200`, `field :count, type: :integer`, or `field
:published, type: :boolean`. Construct it with a Hash of scalar input values.
`valid?`, field-keyed `errors` and `error_codes`, preserved `values`, and explicit
`attributes` keep missing, blank, malformed, invalid and unauthorized input
separate. Invalid forms refuse `attributes`; undeclared fields fail validation.
Sensitive fields opt into `sensitive: true` and are excluded from preserved values.

Optional `model Post, operation: :create` (or `:update`) checks declared column
flags and write permissions; it never changes or inspects the physical schema.
Form validation performs no persistence. On invalid submission, construct
`Hamster::View::Form` with action, explicit csrf_token, values and errors, render
labels/inputs/error_summary, and return 422 for HTML or Turbo Stream responses.
Valid writes normally redirect with 303. POST URL-encoded forms may use the
helper's `_method` field for PATCH/DELETE; other methods cannot be overridden.

CSRF token generation/storage belongs to the application's session policy.
Before processing a mutation, call `context.valid_csrf?(expected_session_token)`
in an explicit before hook. It requires same-origin metadata and compares the
submitted form/header token without early per-byte exits. Empty tokens fail.
The rendering helper escapes tokens, labels, user values and errors; password
inputs are never repopulated. `csrf_token` and `_method` are reserved control
fields and are never returned as persistence attributes.

`generate form posts/create` creates a `PostsCreateForm` and a compiled
`forms/posts/create` template taking an explicit `form` local. Customize fields,
authorized action and CSRF policy, then run manifest/check/test/build.

### Compiled components, Turbo and assets

Views support literal text, escaped `<%= expression %>`, comments, explicit
`locals:`, literal-name `render` with explicit locals, conditional/each blocks,
and named layout slots via `content_for`/`yield`. They are compiled restricted
ERB, not arbitrary Rails ERB evaluation. Missing references/locals and dependency
cycles fail before deployment. Use `generate component card` to create a compiled
`components/card` partial. Pass component content/slots as explicit locals;
ordinary strings escape, while reviewed `Hamster::HTML` fragments retain markup.

`Hamster::Turbo.frame(id, content)` and `.stream(action, target, content)` validate
DOM identifiers and escape untrusted content. Stream actions are replace, append,
prepend, remove and update. Respond with `type: :turbo_stream`; use 422 for invalid
submissions and 303 redirects for successful ordinary HTML forms. Explicit Accept
order breaks equally specific quality ties, so Turbo's preferred stream type is
honored while absent/wildcard Accept defaults to HTML.

Put CSS, JavaScript and images/fonts in `app/assets/`. Manifest generation writes
content fingerprints under `public/assets/`, a JSON mapping, and a static native
registry. Relative ESM imports and CSS URLs are rewritten to fingerprinted URLs;
missing imports and cycles fail clearly. Use `Hamster::Assets.path("application.css")`
in compiled views. Only registered fingerprint paths are served, with correct
MIME, nosniff and immutable caching; arbitrary public files are not exposed.
The runtime root is `HAMSTER_APP_ROOT` or the working directory. Old fingerprints
may remain on disk for cached clients; deploy assets with their native binary.

Generated apps vendor pinned MIT-licensed Turbo and Stimulus distributions; see
`app/assets/vendor/VERSIONS.md`. `generate stimulus greeting` registers a controller
automatically in the generated module registry. `application.js` is the editable
entrypoint. No Node, npm, Vite or bundler is required for app setup/build/runtime.
Static relative module imports are the supported default; use an explicit custom
pipeline if you need npm package resolution or advanced bundling.

The framework's `examples/frontend` provides native/browser CRUD acceptance with
components, forms, escaping, CSRF, Turbo updates, Stimulus and no-JS fallback.

### Private attachments and local storage

Require `hamster/storage`. `generate attachments storage` creates the explicit
SQL migration for blob metadata and attachment references; review and migrate
it separately. Instantiate `Hamster::Storage::Disk` with a private existing
parent/mounted directory (0700), then `Storage::Attachments.new(database: db,
adapter: disk)`. Adapters implement `put(io, key:, max_bytes:)`, `open(key)`,
`delete(key)` and `exists?(key)`; put returns byte_size and SHA-256 checksum.
Local disk is implemented; object storage is a future optional adapter.

Upload with explicit filename/owner, then attach the returned blob ID to a
record_type/record_id/name with owner and an authorization callback. Storage
keys are independent random values; client names are display metadata only.
`open`, `download`, `detach` and `delete` require explicit authorization callbacks
receiving metadata. Bind identity to authenticated application state, never an
untrusted request owner parameter. Downloads verify size/checksum, default to
private attachment/octet-stream/nosniff, and return closeable streaming bodies.
Never place the storage directory under public/ or fingerprinted app assets.

Metadata and files are not one atomic transaction: pending metadata commits
before file writes, and ready is published only after a completed, flushed disk
write. Storage uses its own idle DB connections; attach records only after the
business record commits. Failed uploads remain pending for recovery. Deletion
locks metadata, refuses shared references, commits deleting state, removes the
file, then removes metadata. Retries are idempotent; a failed disk deletion
remains recoverable. Detaching one reference never deletes a shared blob.

Run privileged `cleanup(older_than: cutoff, limit: 100)` explicitly with a grace
period longer than the maximum upload/attachment workflow. It removes old
unreferenced ready/pending/deleting blobs and rechecks references under lock.
No async job system is required. Mount the same private persistent volume across
single-host web restarts and back up metadata and files together. Multiple hosts
need shared storage/an object adapter; local disk does not provide replication.
