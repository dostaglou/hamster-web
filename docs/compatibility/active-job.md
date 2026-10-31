# Active Job portability decision (issue #13)

Tested Active Job **8.0.2** with Active Support 8.0.2, GlobalID 1.4.0 and the
full dependency versions in `script/ci/active_job_versions.json`, CRuby 3.4.9,
and unmodified Spinel **10f112c51666e7ffd308e0ab90a69c2184870c06**.

Reproduce from the checkout:

```sh
ruby script/ci/run_active_job_spike.rb --install
ruby script/ci/run_active_job_spike.rb
```

Packages install only under `tmp/activejob-spike/gems`. The probe, actual compiler
argument array, and complete CRuby/native diagnostics are retained under that
directory. Gem specifications supply require paths, including concurrent-ruby's
nested `lib/concurrent-ruby`; Spinel's native standard-library bindings are used.

| Capability | CRuby control | Native Spinel |
| --- | --- | --- |
| `perform_now` with string argument | Pass | Blocked before execution |
| `perform_later` with upstream inline adapter | Pass | Blocked before execution |
| Serialize/deserialize then perform | Pass | Blocked before execution |
| GlobalID/model arguments | Not tested | Not tested |
| Upstream threaded/durable adapters | Not tested | Not tested |

The corrected native require-gate invocation exits 1 with:

```
spinel: cannot load such file -- concurrent/concurrent_ruby.jar (require "concurrent/concurrent_ruby.jar")
```

This is a dependency-loading blocker in concurrent-ruby, reached while inspecting
an engine-specific dependency branch; it is not evidence that Active Job's
execution code itself is incompatible. Earlier attempts including gem versions
of standard libraries stopped at `random/formatter`; adding CRuby stdlib sources
instead stopped at `openssl.so`. Those alternatives do not provide a native
execution path, and no upstream packages/compiler were patched to bypass them.

Decision: keep upstream reuse open, but implement a small native Hamster job API
for the current pinned toolchain. Making the full Active Support/concurrent-ruby
stack compile has uncertain scope beyond this ticket. Revisit this probe after
upstream require loading/runtime support advances; do not advertise Active Job
compatibility or silently load it in native production code.

The Hamster API deliberately uses one explicit JSON argument hash and a versioned
static job registry. It does not implement Active Job callbacks, GlobalID,
implicit arbitrary-object serialization, or Rails adapter compatibility.
