# __APP_NAME__

Run `bin/hamster setup` to install gems and vendor the locked Spin PostgreSQL driver.
Spin and Spinel must already be installed. Configure DATABASE_USERNAME,
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
gem before running setup.

Run a deployed binary from the application root or set HAMSTER_APP_ROOT.
Include db/migrations alongside the binary. PostgreSQL TLS is not supported
by the current driver integration.

Each endpoint has an action.rb and optional view.html.erb in app/routes/.
Declare endpoints centrally in app/routes/mappings.rb. Run
`bin/hamster manifest` after changing Ruby sources or templates and commit
the generated manifest and view registry with your source changes.
