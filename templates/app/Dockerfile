# Build with Docker only; Spinel and Ruby are installed inside the builder.
ARG RUBY_IMAGE=ruby:3.3.6-bookworm@sha256:347edd0c70ee08d87de9f01b99de2f14a64cedb5d1bfb38457dfe8cd0bf113c5
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
FROM ${RUBY_IMAGE} AS toolchain
ARG SPINEL_REVISION=10f112c51666e7ffd308e0ab90a69c2184870c06
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git libffi-dev libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir /src && cd /src && git init \
    && git remote add origin https://github.com/matz/spinel.git \
    && git fetch --depth 1 origin "$SPINEL_REVISION" && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$SPINEL_REVISION" \
    && make deps && make -j2 && make install PREFIX=/opt/spinel \
    && rm -rf /src
ENV PATH="/opt/spinel/bin:${PATH}"
RUN gem install bundler --version 2.5.23 --no-document \
    && gem install hamster-web --version __HAMSTER_VERSION__ --no-document

FROM toolchain AS builder
WORKDIR /app
COPY . .
# Setup and compilation require no database connection or credentials.
RUN bin/hamster setup && bin/hamster manifest && bin/hamster manifest:check && bin/hamster build
RUN mkdir -p /runtime/app/bin /runtime/app/db/migrations /runtime/app/public \
    && cp bin/__APP_NAME__-server /runtime/app/bin/ \
    && cp -a db/migrations/. /runtime/app/db/migrations/ \
    && cp -a public/. /runtime/app/public/ \
    && ldd bin/__APP_NAME__-server > /runtime/ldd.txt \
    && cat /runtime/ldd.txt && ! grep -F 'not found' /runtime/ldd.txt

# Optional operational image. Migrations run explicitly, never during build/boot.
FROM builder AS migrations
ENV HAMSTER_APP_ROOT=/app HAMSTER_ENV=production
ENTRYPOINT ["bin/hamster"]
CMD ["db:migrate"]

FROM ${RUNTIME_IMAGE} AS runtime
# Runtime libraries and a small HTTP health probe; no Ruby, gems or compiler.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libcrypt1 libffi8 libssl3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /runtime/app/ /app/
# Check linkage in the actual runtime image as well as in the builder.
RUN ldd /app/bin/__APP_NAME__-server > /tmp/ldd.txt \
    && cat /tmp/ldd.txt && ! grep -F 'not found' /tmp/ldd.txt && rm /tmp/ldd.txt
ENV HAMSTER_APP_ROOT=/app HAMSTER_ENV=production HOST=0.0.0.0 PORT=4000
USER 10001:10001
EXPOSE 4000
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:${PORT}/up" > /dev/null || exit 1
ENTRYPOINT ["/app/bin/__APP_NAME__-server"]
