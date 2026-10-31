---
name: hamster-endpoint
description: Generate or modify endpoints, views, routes, and callback concerns in this Hamster application. Use for Hamster HTTP behavior, not database schema changes.
---

Read the project AGENTS.md. Inspect nearby actions, routes, concerns, and the
project's test instructions before editing.

1. Consult `bin/hamster generate --help` and `bin/hamster generate --schema` for
   the installed framework's supported options. Prefer `generate endpoint` for
   scaffolding; do not recreate the generator in scripts or assume other
   generator types exist.
2. Implement the endpoint's `call`. Use `respond`, `redirect_to`, `send_file`, or
   `send_data` as appropriate. Keep authentication and authorization explicit.
3. Reuse concerns under `app/concerns/`; modules that register hooks extend
   `Hamster::Action::Callbacks`. Callback names must be literal symbols and
   resolve to existing methods. Before hooks return nil or a response; after
   hooks receive the response and run only after a successful action.
4. Run `bin/hamster manifest`, `bin/hamster manifest:check`, and
   `bin/hamster build`. Run documented project tests and exercise changed HTTP
   behavior against the compiled server, including authorization failures.

Generation safely rejects customized route layouts it cannot update. Inspect
that diagnostic and make a focused manual edit when necessary. Do not add
runtime eval, reflective callback dispatch, local application requires, or
unsupported CLI commands. Run `bin/hamster check --quick` and `check --full` for the shared validation harness. Keep compiler/build tooling outside the
runtime require chain.
