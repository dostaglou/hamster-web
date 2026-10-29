# __APP_NAME__

Run `bin/hamster setup` to install gems and vendor the locked Spin PostgreSQL driver.
Spin and Spinel must already be installed. The preview installation contract is
Ruby 3.3.6, Bundler 2.5.23, Hamster __HAMSTER_VERSION__, spinel-spinner
0.1.0.pre.1, and Spinel/Spin revision
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
