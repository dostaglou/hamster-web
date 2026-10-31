# Spinner pre.4 consumer verification

Hamster delegates socket transport to `spinel-spinner = 0.1.0.pre.4` and retains
its file bodies, validation, authorization hooks, and upload cleanup. No transport
class is reopened and no generated compatibility require remains.

## Pinned runtime disconnect crash

The first clean Linux candidate consumer reproduced the prior segmentation fault
during an aborted file download. A retained executable/core reproduced it again.
The collector thread's backtrace reaches `sp_gc_mark` from
`sp_re_mark_globals`, during allocation in the file-response worker. The saved
regex subject points into a freed mutable String payload. The pinned runtime's
cross-worker `sp_re_push_match_roots` helper roots heap strings but skips mutable
payload markers, while the collector's own globals marker dereferences them.

Multipart boundary/disposition captures now match `dup` copies of the two header
subjects. This makes the saved subjects independently owned heap strings. It adds
bounded header copies and changes no parsing rules, body limits, upload ownership,
or file-serving API. The compiler revision and installed runtime are unchanged.
A discarded experiment removing implicit regex backreferences still crashed;
copying the multipart match subjects passed five complete file acceptance rounds,
including 50 aborted downloads and continued health/cleanup checks.

The native consumer gate now runs file acceptance three times, with an empty
upload spool required after every round. Version, isolated gem resolution, local
archive hashes, and installed file hashes are checked before generation and again
under Bundler. The generated-app Docker harness checks the candidate archives in
its generator and test toolchain image, while the normal generated Dockerfile
keeps its released-package installation step.

The full Ruby suite, including disposable PostgreSQL lifecycle/concurrency and
packaging/project skill checks, passed 36 tests / 307 assertions without skips.
The final clean Linux consumer passed all three file rounds (30 aborted downloads)
with both final candidate archives and verified installed provenance. The generated
Docker image also passed build-without-database, migrations, runtime exclusions,
non-root health checks, database outage liveness, and clean SIGTERM shutdown.
Local native/Docker logs and crash backtraces are retained under ignored
`tmp/binary-transport-verification/`; candidate gems are under `pkg/`.

```sh
bash script/ci/run_native_smoke.sh candidate pkg/hamster-web-0.1.0.pre.3.gem ../spinner/pkg/spinel-spinner-0.1.0.pre.4.gem
SPINNER_CANDIDATE_GEM=../spinner/pkg/spinel-spinner-0.1.0.pre.4.gem bash script/ci/run_app_docker_smoke.sh
```

These commands use disposable applications/databases and isolated gem homes.
RubyGems publication and git pushes are separate steps and were not performed.
