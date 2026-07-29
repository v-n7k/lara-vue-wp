# VPS WordPress Backbone

![Docker Compose](https://img.shields.io/badge/Docker%20Compose-v2-2496ED?logo=docker&logoColor=white)
![WordPress](https://img.shields.io/badge/WordPress-6.8-21759B?logo=wordpress&logoColor=white)
![MySQL](https://img.shields.io/badge/MySQL-8.4-4479A1?logo=mysql&logoColor=white)
![NGINX](https://img.shields.io/badge/NGINX-alpine-009639?logo=nginx&logoColor=white)

A portable Docker Compose stack for running WordPress on a VPS behind an automatically configured NGINX reverse proxy. A single `.env` file drives domains, credentials, and container naming, and `setup.sh` turns `docker-compose.yml` labels into NGINX virtual hosts — no hand-written proxy configs.

## Table of Contents

- [Quick Start](#quick-start)
- [Included Services](#included-services)
- [Prerequisites](#prerequisites)
- [Configuration (`.env`)](#configuration-env)
- [The Setup Script (`setup.sh`)](#the-setup-script-setupsh)
- [Proxying a Service](#proxying-a-service)
- [Built-in NGINX Behavior](#built-in-nginx-behavior)
- [HTTPS Behind the Proxy](#https-behind-the-proxy)
- [Database Initialization](#database-initialization)
- [Backup & Restore](#backup--restore)
- [Migration](#migration)

## Quick Start

```bash
# 1. Clone the repository onto your VPS
git clone <repo-url> vps-wordpress && cd vps-wordpress

# 2. Create your environment file and fill in domains and passwords
cp .env.example .env

# 3. Place your Cloudflare origin certificates
#    ./certs/cloudflare.crt
#    ./certs/cloudflare.key

# 4. Generate the NGINX vhosts and Basic Auth file
bash setup.sh

# 5. Start the stack
docker compose up -d
```

WordPress is then available at `https://www.<CORE_DOMAIN>` (and the bare `<CORE_DOMAIN>`), phpMyAdmin at `https://pma.<CORE_DOMAIN>`, and Portainer at `https://portainer.<CORE_DOMAIN>` — unless you override the hosts in `.env`.

## Included Services

| Service | Image | Purpose |
| :--- | :--- | :--- |
| **NGINX** | `nginx:alpine` | Reverse proxy; sole entry point, listens on port 443 (HTTPS) and routes by hostname |
| **WordPress** | `wordpress:6.8` | The content management system |
| **MySQL** | `mysql:8.4` | Relational database backing WordPress and future services |
| **phpMyAdmin** | `phpmyadmin:5.2` | Web UI for managing MySQL (Basic Auth protected) |
| **Portainer** | `portainer/portainer-ce:lts` | Docker management UI (Basic Auth protected) |

Images are pinned to stable/LTS versions. All containers are named `${PRODUCT_NAME}-<service>` (e.g. `wp-nginx`), so multiple stacks can coexist on one host.

## Prerequisites

*   A Linux VPS with Docker and Docker Compose v2 (`docker compose`) installed.
*   `jq` and `openssl` available on the host — `setup.sh` uses them to parse the compose file and hash the Basic Auth password.
*   A domain name with DNS records for your subdomains pointing to the VPS IP.
*   Cloudflare origin certificates placed in `./certs/cloudflare.crt` and `./certs/cloudflare.key`.

## Configuration (`.env`)

All domains, secrets, and naming live in `.env` (never committed). Start from `.env.example`:

| Variable | Description |
| :--- | :--- |
| `PRODUCT_NAME` | Prefix for the compose project and all container names (e.g. `wp` → `wp-nginx`) |
| `CORE_DOMAIN` | Default base domain for all services |
| `BASIC_AUTH_USER` / `BASIC_AUTH_PASSWORD` | Credentials for HTTP Basic Auth on protected services (phpMyAdmin, Portainer) |
| `WP_HOST` / `WP_DOMAIN` | WordPress FQDN parts (defaults: `www` . `CORE_DOMAIN`) |
| `PMA_HOST` / `PMA_DOMAIN` | phpMyAdmin FQDN parts (defaults: `pma` . `CORE_DOMAIN`) |
| `PORTAINER_HOST` / `PORTAINER_DOMAIN` | Portainer FQDN parts (defaults: `portainer` . `CORE_DOMAIN`) |
| `MYSQL_ROOT_PASSWORD` | MySQL root password |
| `MYSQL_USER` / `MYSQL_PASSWORD` | Application database user, granted full access to the `wordpress` database |

A service's FQDN is always `HOST.DOMAIN`. Services whose `hostname` is `www` also answer for the bare (apex) domain.

## The Setup Script (`setup.sh`)

Instead of manually writing NGINX configuration, `setup.sh` generates it from your compose file:

1.  Loads variables from `.env`.
2.  Generates `./auth/.htpasswd` with OpenSSL if `BASIC_AUTH_USER` and `BASIC_AUTH_PASSWORD` are set.
3.  Parses `docker compose config` with `jq` and writes one `server` block per proxied service to `./configs/nginx/conf.d/vhosts.conf`.
4.  If the NGINX container is already running, validates the new configuration with `nginx -t` and gracefully reloads it with zero downtime. On a failed validation the old config stays active and the script exits with status `1`, so cron jobs and CI can detect the failure.

Generated artifacts (`certs/*`, `configs/nginx/conf.d/*.conf`, `auth/.htpasswd`) are git-ignored — only `configs/nginx/nginx.conf` (the static base config) is committed.

**Making changes** (domains, passwords, adding services): edit `.env` or the labels in `docker-compose.yml`, then re-run `bash setup.sh`. New containers still need `docker compose up -d`.

## Proxying a Service

`setup.sh` inspects every service block in `docker-compose.yml`. To enable automatic proxying for a service, both `hostname` and `domainname` **must** be set:

*   **`hostname`** — the subdomain prefix (e.g. `portainer`, `pma`, `www`).
*   **`domainname`** — the base domain (e.g. `myproject.com`).

They combine into the FQDN used for NGINX's `server_name`: `FQDN = ${hostname}.${domainname}`.

### Control Labels

Optional `nginx.*` labels tune how NGINX talks to the service:

| Label | Supported Values | Default | Description |
| :--- | :--- | :--- | :--- |
| **`nginx.auth`** | `"true"` \| `"false"` | `"false"` | Enables HTTP Basic Authentication using the generated `.htpasswd` |
| **`nginx.schema`** | `"http"` \| `"https"` | `"http"` | Upstream protocol used in `proxy_pass` |
| **`nginx.port`** | `"<port_number>"` | `"80"` | Internal container port NGINX routes traffic to |

### Example

```yaml
    portainer:
        container_name: ${PRODUCT_NAME:-vps}-portainer
        image: portainer/portainer-ce:lts
        # Resolves to: portainer.vps-wp.localhost
        hostname: ${PORTAINER_HOST:-portainer}
        domainname: ${PORTAINER_DOMAIN:-${CORE_DOMAIN:-localhost}}
        labels:
            nginx.auth: "true"     # Protect with Basic Auth (.htpasswd)
            nginx.schema: "https"  # Talk to Portainer via HTTPS upstream
            nginx.port: "9443"     # Forward traffic to internal port 9443
        restart: always
```

## Built-in NGINX Behavior

*   **HTTPS only** — TLS 1.2/1.3 terminated with the Cloudflare origin certificates; nothing listens on port 80.
*   **Bare-IP scan rejection** — a catch-all `default_server` rejects TLS handshakes that don't match a configured hostname.
*   **WebSocket support** — `Upgrade`/`Connection` headers are forwarded to upstreams.
*   **Compression** — gzip enabled for CSS, JS, JSON, and SVG.
*   **Uploads up to 64 MB** — `client_max_body_size 64m`, matched by the PHP limits in `configs/php/uploads.ini` (mounted read-only into WordPress and phpMyAdmin).

## HTTPS Behind the Proxy

NGINX terminates TLS and talks plain HTTP to the WordPress container. WordPress is configured (via `WORDPRESS_CONFIG_EXTRA`) to trust the `X-Forwarded-Proto` header, so it correctly treats requests as HTTPS — no redirect loops or mixed-content issues.

## Database Initialization

On the first start with an empty `./volumes/mysql8`, MySQL runs `configs/mysql/init-dbs.sh`, which creates the `wordpress` database and grants `MYSQL_USER` full access to it. It only runs on a fresh data directory — to re-run it, remove `./volumes/mysql8` (this destroys all data).

## Backup & Restore

All persistent state lives in `./volumes/` plus your `.env` file.

**Full (cold) backup** — stop the stack and archive the whole project directory:

```bash
docker compose stop
tar -czf ../vps-wordpress-backup-$(date +%F).tar.gz .
docker compose start
```

**Database dump (hot)** — no downtime, uses the credentials already inside the container:

```bash
docker compose exec db sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" wordpress' > wordpress-$(date +%F).sql
```

**Database restore:**

```bash
docker compose exec -T db sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" wordpress' < wordpress-backup.sql
```

WordPress files (themes, plugins, uploads) live in `./volumes/wordpress` and can be copied directly.

## Migration

All state lives in this directory. To move servers: copy it (including `.env` and `./volumes/`) to the new host, point DNS at the new IP, run `bash setup.sh`, then `docker compose up -d`.
