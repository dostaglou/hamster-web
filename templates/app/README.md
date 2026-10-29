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
