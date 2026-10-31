# Hamster application conventions

Guidance version: __HAMSTER_VERSION__. Project-local skills live in
`.agents/skills/hamster-endpoint/SKILL.md` and
`.agents/skills/hamster-database/SKILL.md`. Read the relevant skill explicitly if
your agent does not discover it automatically.

- Start endpoint work with `bin/hamster generate --help` and `bin/hamster generate --schema`; prefer the supported generator to handwritten scaffolding.
- Keep one action per endpoint directory, routes in `app/routes/mappings.rb`, and shared callback modules in `app/concerns/`.
- App Ruby files load through `config/manifest.rb`; do not add local requires or runtime eval. Migration Ruby belongs exclusively in CRuby tooling.
- Run `bin/hamster manifest` after changing Ruby, views, or callback declarations; run `bin/hamster manifest:check` and `bin/hamster build` to verify native compatibility.
- Run `bin/hamster check --quick` during edits and `bin/hamster check --full` before completion. Use `--json` for stable diagnostics. Use `bin/hamster test [test/path] [--json]` for request tests. Full checks include project tests and native HTTP smoke checks.
- Use explicit migration `up`/`down`; inspect `db:migrate:status` and `db:migrate:history --json` before changing the database. Never edit applied migrations to change a schema.
- Obtain explicit authorization for production database mutations. Do not assume local environment variables identify a disposable database.
- Keep authentication and authorization explicit. Before hooks halt only with an HTTP response; after hooks are not unconditional cleanup hooks.
- Uploaded files are request-owned; use `copy_to` for durable storage. File downloads require an authorized action and explicit trusted root.
- Update guidance with `bin/hamster agents:install --dry-run` first. Customized guidance must be merged manually; it is never silently overwritten.

- Inspect static dependencies with `bin/hamster inspect action resource/action --json` and use `inspect --check` for declaration diagnostics.
- Use explicit JSON fields, form declarations and authorization callbacks for private attachments. Storage keys and job payloads must not contain request-owned IO or connection objects.
- Jobs declare a literal name/version and compile through the generated registry. Use `build:worker`/`jobs:work` for durable workers; apply queue migrations explicitly and keep jobs idempotent.
