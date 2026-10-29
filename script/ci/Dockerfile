ARG RUBY_IMAGE=ruby:3.3.6-bookworm
FROM ${RUBY_IMAGE} AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl file git libffi-dev libssl-dev pkg-config postgresql-client \
    && rm -rf /var/lib/apt/lists/*

FROM base AS compiler
ARG SPINEL_REVISION
RUN test -n "$SPINEL_REVISION" && mkdir /src && cd /src \
    && git init && git remote add origin https://github.com/matz/spinel.git \
    && git fetch --depth 1 origin "$SPINEL_REVISION" && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$SPINEL_REVISION" \
    && make deps && make -j2 && make install PREFIX=/opt/spinel

FROM base
COPY --from=compiler /opt/spinel /opt/spinel
COPY versions.env native_smoke.sh /smoke/
# Reset inherited Ruby/Bundler configuration before invoking the consumer.
ENTRYPOINT ["env", "-i", "PATH=/opt/spinel/bin:/usr/local/bin:/usr/bin:/bin", "LANG=C.UTF-8", "bash", "/smoke/native_smoke.sh"]
