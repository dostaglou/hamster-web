# Hamster Web

Hamster is a Spinel web framework under development. The `hamster-web` gem will
provide the `hamster` CLI and the `hamster/web` application runtime. Spinner is
its HTTP server dependency.

The starter generates and compiles with PostgreSQL support, explicit routes,
actions, compiled views, and SQL migrations. Database creation and migration
commands, the console, and schema-aware records/queries are available.
Telemetry extraction and asset delivery remain under development.

Build and install the local framework preview:

```sh
gem build hamster-web.gemspec
gem install --local hamster-web-0.1.0.pre.2.gem
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

Run framework tests with `ruby -Ilib -e 'Dir["test/*_test.rb"].sort.each { |file| require_relative file }'`.

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
