# Compiled frontend acceptance example

This example uses reusable compiled components, explicit form validation/CSRF,
Turbo Frames/Streams, Stimulus, and fingerprinted assets. It deliberately keeps
records in a mutex-protected in-memory store so browser acceptance needs no
PostgreSQL. State is ephemeral and single-process; use Hamster records and a
shared database for a deployed application.

From the framework checkout:

```sh
ruby -Ilib examples/frontend/generate.rb ../../tmp
SPINNER_LIB=/path/to/spinner/lib ruby -Ilib -rhamster/native_smoke \
  -e 'Hamster::NativeSmoke.run(File.expand_path("tmp/frontend_demo"))'
```

This compiles a native server, binds a private ephemeral loopback port, checks
CRUD without JavaScript, escaping, invalid-form 422, CSRF rejection, and immutable
asset delivery, then stops it. To include real browser CRUD acceptance, supply
`HAMSTER_BROWSER_BINARY=/path/to/google-chrome`. The optional browser test uses
Node 24's built-in WebSocket client to control a fresh isolated Chrome profile;
Node is only a browser-test tool, not an application build/runtime dependency.
`HAMSTER_BROWSER_ARTIFACT=/path/result.html` retains the resulting DOM.

To run the demo interactively, compile `tmp/frontend_demo/test/native_server.rb`
with `-I lib -I /path/to/spinner/lib`, output a binary inside the demo, then run
it with the demo as working directory and `PORT=4000`. Visit `/posts`. Run with
one server worker process because the sample storage is process-local.
