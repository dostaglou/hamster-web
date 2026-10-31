# Deploy a generated Hamster app to DigitalOcean

Use one Ubuntu droplet for the native app, PostgreSQL, and the Caddy HTTPS
reverse proxy. The examples use Hamster 0.1.0.pre.3 and an image upload deployment. The runtime executable runs as UID 10001; the migration
image retains Ruby and the CLI for explicit database operations.

Replace `203.0.113.10` with your droplet IP and `hamster.example.com` with your
domain. Commands marked for the server assume root access; otherwise use an
administrative account with `sudo`. Credential files are created on the server
at runtime. Keep them outside source control and Docker image layers.

## Generate an app for validation

On the build machine, select Ruby 3.3 or newer. Use `ruby`, `gem`, and `hamster`
from the same Ruby installation: different rbenv Rubies have separate installed
gems. The `_0.1.0.pre.3_` executable argument selects a gem version within that
Ruby installation.

```bash
gem install hamster-web --version 0.1.0.pre.3 --no-document
hamster _0.1.0.pre.3_ new DummyHamsterApp
cd dummy_hamster_app
ls Dockerfile .dockerignore app/application.rb app/routes/up/index/action.rb

cat > db/migrations/001_create_smoke_checks.sql <<'SQL'
CREATE TABLE smoke_checks (id INTEGER PRIMARY KEY, message TEXT NOT NULL);
INSERT INTO smoke_checks VALUES (1, 'Hamster deployment works');
SQL

printf '\n.env*\n*.tar.gz\n' >> .gitignore
```

Use an empty destination or a new app name; generation does not overwrite an
existing app. The migration above is a fixture for this dummy application.
The remaining examples assume the `dummy_hamster_app` directory and this schema.
For an existing application, substitute its image tags, database name, and
verification query. Docker is the only compilation prerequisite on the host;
Ruby, Spin, and Spinel are installed inside the generated builder.

This is a single-server deployment: Docker runs the native app and PostgreSQL,
with persistent database storage. The server needs Docker, not host Ruby or
Spinel. Upload the **runtime image and migration image**, not a macOS executable.

## Prepare a server and choose its architecture

For a fresh setup, create an Ubuntu 24.04 DigitalOcean droplet and attach your
SSH key. Add a DigitalOcean Cloud Firewall allowing SSH/TCP 22 from your current
IP. Keep PostgreSQL 5432 and app port 4000 closed to the Internet. Use an SSH
tunnel for initial verification, then complete the public HTTPS section to
route Internet requests to the app.
[Server creation](https://docs.digitalocean.com/products/droplets/how-to/create/),
[Cloud Firewall setup](https://docs.digitalocean.com/products/networking/firewalls/how-to/configure-rules/).

On your build machine, replace the example IP:

```bash
DEPLOY_HOST=root@203.0.113.10
ssh "$DEPLOY_HOST" uname -m
```

| Server output | Build platform |
| --- | --- |
| `x86_64` | `linux/amd64` |
| `aarch64` | `linux/arm64` |

Choose the corresponding value below. Build the images for the droplet
architecture. Docker Desktop on Apple Silicon can build AMD64 images using
emulation, although compiler builds can take substantially longer.
[Docker platform guidance](https://docs.docker.com/build/building/multi-platform/).

On the server, install Docker Engine using the official **Ubuntu apt repository**
instructions, then verify the service. These server commands assume a fresh
server accessed as root; an existing non-root administrative account can use
`sudo` instead.
[Docker installation instructions](https://docs.docker.com/engine/install/ubuntu/#install-using-the-apt-repository).

```bash
# On the DigitalOcean droplet, after installing Docker:
systemctl enable --now docker
docker run --rm hello-world
apt-get update
apt-get install -y openssl
install -d -m 700 /opt/dummy-hamster
```

## Build images for the server and upload them

On your build machine, from the generated dummy app:

```bash
cd /path/to/dummy_hamster_app
DEPLOY_PLATFORM=linux/amd64  # Change to linux/arm64 for an ARM server.

docker buildx build --platform "$DEPLOY_PLATFORM" --target runtime --load \
  -t dummy-hamster:release-001 .
docker buildx build --platform "$DEPLOY_PLATFORM" --target migrations --load \
  -t dummy-hamster:migrations-release-001 .

docker image inspect --format '{{.Os}}/{{.Architecture}}' dummy-hamster:release-001

set -o pipefail
docker image save dummy-hamster:release-001 dummy-hamster:migrations-release-001 \
  | gzip > ../dummy-hamster-release-001.tar.gz
scp ../dummy-hamster-release-001.tar.gz "$DEPLOY_HOST:/opt/dummy-hamster/"
```

On the server:

```bash
cd /opt/dummy-hamster
docker image load --input dummy-hamster-release-001.tar.gz
docker image inspect --format '{{.Os}}/{{.Architecture}}' dummy-hamster:release-001
```

The archive is written outside the app directory to keep it out of subsequent
Docker build contexts. This transfers both images and their tags without
requiring a registry. Docker can load the compressed archive directly. The migration image is larger because
it contains build/operational tools.
[Image save](https://docs.docker.com/reference/cli/docker/image/save/),
[image load](https://docs.docker.com/reference/cli/docker/image/load/).

## Provision persistent PostgreSQL on the server

Run this bootstrap once on the fresh server. It generates new server passwords;
do not reuse the local test password or rerun it against an existing database.
PostgreSQL initialization variables only initialize an empty data directory;
they do not change passwords in an existing volume.
[PostgreSQL image behavior](https://hub.docker.com/_/postgres).

```bash
(
set -euo pipefail
cd /opt/dummy-hamster
umask 077
PG_ADMIN_PASSWORD=$(openssl rand -hex 32)
APP_DB_PASSWORD=$(openssl rand -hex 32)

printf 'POSTGRES_PASSWORD=%s\n' "$PG_ADMIN_PASSWORD" > postgres.env
cat > app.env <<ENV
DATABASE_HOST=postgres
DATABASE_PORT=5432
DATABASE_NAME=dummy_hamster_app_production
DATABASE_USERNAME=hamster
DATABASE_PASSWORD=$APP_DB_PASSWORD
ENV
chmod 600 postgres.env app.env

docker network create dummy-hamster
docker volume create dummy-hamster-pgdata
docker run -d --restart unless-stopped --name dummy-hamster-db \
  --network dummy-hamster --network-alias postgres \
  --env-file postgres.env \
  -v dummy-hamster-pgdata:/var/lib/postgresql/data \
  postgres:16-bookworm

for attempt in {1..60}; do
  if docker exec dummy-hamster-db pg_isready -U postgres -d postgres; then break; fi
  sleep 1
done
docker exec dummy-hamster-db pg_isready -U postgres -d postgres

# Separate application role; it owns its database but is not a superuser.
# APP_DB_PASSWORD contains generated hex only, suitable for this SQL literal.
docker exec -i dummy-hamster-db psql -U postgres -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE hamster LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$APP_DB_PASSWORD';
CREATE DATABASE dummy_hamster_app_production OWNER hamster;
SQL
unset PG_ADMIN_PASSWORD APP_DB_PASSWORD
)
```

The maintained `16-bookworm` tag keeps this example on PostgreSQL major version
16. No database port is published. The current Hamster driver does not support
database TLS, so this example keeps database traffic on the same server's Docker
network; do not adapt it by exposing PostgreSQL over the public Internet.

## Migrate, start, and verify

On the server:

```bash
cd /opt/dummy-hamster

docker run --rm --network dummy-hamster --env-file app.env \
  dummy-hamster:migrations-release-001 db:migrate
```

After migration reports success, start the native app:

```bash
docker run -d --restart unless-stopped --name dummy-hamster-app \
  --network dummy-hamster --env-file app.env \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
  --stop-timeout 20 -p 127.0.0.1:4000:4000 \
  dummy-hamster:release-001

curl --fail --retry 10 --retry-delay 1 --retry-connrefused http://127.0.0.1:4000/up
curl --fail http://127.0.0.1:4000/
docker logs --tail 100 dummy-hamster-app
docker inspect --format '{{.State.Health.Status}}' dummy-hamster-app
docker exec dummy-hamster-db psql -U postgres -d dummy_hamster_app_production \
  -c 'SELECT * FROM smoke_checks; SELECT version FROM schema_migrations;'
```

Wait for Docker health to become `healthy` after its first probe. Migrations
must finish successfully before starting the app. They are not run by image
build or server boot. The database was provisioned separately, so no `db:create`
command or administrative password is needed in `app.env`.

To access it from your build machine, open another local terminal:

```bash
DEPLOY_HOST=root@203.0.113.10
ssh -N -L 4400:127.0.0.1:4000 "$DEPLOY_HOST"
```

Keep that tunnel open. In another terminal, run
`curl --fail http://127.0.0.1:4400/up` or open `http://127.0.0.1:4400/` in your
browser. There is no need to open port 4000 in the DigitalOcean firewall.

## Configure public HTTPS

Point a domain such as `hamster.example.com` at the server's IP, and allow inbound
TCP 80/443 in the DigitalOcean firewall. Keep 4000 and 5432 private. If you publish an
AAAA record, it must point to the server's working IPv6 address as well.

Install Caddy on the host using its official Ubuntu package instructions. On a
fresh server dedicated to this app, put the following in `/etc/caddy/Caddyfile`,
replacing the example domain and IP. A copy is provided in
[Caddyfile.example](Caddyfile.example):
[Install Caddy](https://caddyserver.com/docs/install#debian-ubuntu-raspbian).

```caddyfile
hamster.example.com {
    reverse_proxy 127.0.0.1:4000
}

http://203.0.113.10 {
    redir https://hamster.example.com{uri} permanent
}
```

Then, on the server:

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl reload caddy
curl --fail https://hamster.example.com/up
```

Caddy proxies to the loopback-bound app and manages HTTPS certificates for the
configured public domain when DNS and inbound connectivity are correct.
[Reverse proxy configuration](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy),
[automatic HTTPS requirements](https://caddyserver.com/docs/automatic-https).
Docker-published ports can bypass UFW rules; the loopback binding and DigitalOcean
firewall are deliberate here.
[Docker firewall behavior](https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw).

## Subsequent deployments

Use new immutable image tags (`release-002`, etc.), repeat the matching-platform
build/save/upload/load steps, and apply that release's migrations explicitly.
Before migrations on data you want to keep, take a backup, for example on the
server:

```bash
cd /opt/dummy-hamster
umask 077
set -o pipefail
docker exec dummy-hamster-db pg_dump -U postgres dummy_hamster_app_production \
  | gzip > "backup-$(date +%Y%m%d-%H%M%S).sql.gz"
```

Copy backups off the server as well. The named volume survives container
replacement but is not a backup. For a simple deployment with brief downtime,
stop the old app with `docker stop -t 20 dummy-hamster-app`, retain its image/tag,
remove the stopped app container, run migrations, and start the new image using
the same network, environment file, volume-backed database, and port binding.
Do not remove the PostgreSQL volume. Image rollback only works with compatible
schema changes; a database restore is a separate operation. The archive upload
can later be replaced by pushing/pulling the same tags through a private image
registry.
