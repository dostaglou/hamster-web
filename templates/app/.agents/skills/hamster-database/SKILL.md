---
name: hamster-database
description: Add and inspect Hamster SQL or Ruby migrations and validate model schema contracts. Use for this application's PostgreSQL schema lifecycle, not endpoint scaffolding.
---

Read project AGENTS.md and database configuration. Identify the actual target
database before running commands; obtain explicit authorization before any
production mutation. Never print credentials into logs or reports.

- Inspect `bin/hamster db:migrate:status` and
  `bin/hamster db:migrate:history --json`. `legacy_unknown` preserves historical
  tracking without claiming a checksum was recorded. Missing or modified applied
  files require investigation; do not bypass integrity checks or rewrite history.
- Add a chronological, unique `db/migrations/VERSION_name.rb` defining one
  `Hamster::Migration` subclass with explicit `up` and `down`. Inspect current
  framework documentation for supported DSL operations. Keep existing SQL files
  intact; SQL migrations remain forward-only. Model declarations are a separate
  schema contract, never an automatic migration source.
- On a disposable development/test database, run `bin/hamster db:migrate`, verify
  schema/data behavior, run `bin/hamster db:rollback STEP=1`, then migrate again.
  Rollback refuses batches containing an irreversible migration before writing.
- Run `bin/hamster db:validate` to check declarations against the selected schema,
  plus documented project tests and native build verification when runtime
  declarations change. Do not assume `db:validate` runs migrations.
- `bin/hamster db:structure:dump` explicitly writes a derived schema snapshot and
  requires pg_dump. Do not use structure.sql as a second source of truth.

Migration Ruby executes in CRuby tooling. Do not import it into application code
or add transaction-control SQL inside a migration's framework-owned transaction.
