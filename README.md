# webstack

Run multiple Dockerized web apps on a single VM.

Traefik in front of all project containers: routing, Let's Encrypt TLS, and optional login
via Authelia (username + password, optional 2FA, users managed in a YAML file).

Each app is reachable under **either** its own hostname (a subdomain or any other domain; the
default) **or** a sub-path of the main domain, for installations with only one domain. This
is configured per installation and app in the app's `.env`.

```
                 :80/:443
Internet ──────► Traefik ──(forwardAuth)──► Authelia      https://example.com/auth/
                    │
                    ├──► https://private.example.com/     (login required)
                    │    or https://example.com/private/
                    └──► https://public.example.com/      (no login)
                         or https://example.com/public/

Start page:        https://example.com/ lists all apps (public by default, with logout link)
Traefik dashboard: http://127.0.0.1:8080/dashboard/ on the VM only (SSH tunnel)
```

```
proxy/                    the front stack (run once per VM)
  .env.example            DOMAIN (copy to .env)
  docker-compose.yml      traefik, authelia, docker socket proxy
  traefik/traefik.yml     entrypoints, Let's Encrypt, providers
  traefik/dynamic/        login portal route, shared middlewares (authelia@file, headers)
  authelia/config/        configuration.yml, users_database.yml
apps/whoami/              example app (template for your own; optional)
  .env.example            DOMAIN + one address per service: own host or sub-path
apps/startpage/           start page at https://<DOMAIN>/ listing all apps (optional)
  generate.sh, watch.sh   build the page from container labels (on the host)
generate-secrets.sh       creates Authelia's secrets and the PUID/PGID entries
verify.sh                 checks a running installation end to end
update.sh                 auto-update: pull, verify, roll back on failure
ops/systemd/              daily update timer, start page generator
test/local-test.sh        full local test without public DNS or Let's Encrypt
docs/app-interface.md     what an app must implement to fit in
docs/security.md          security properties and known risks
```

**Read [docs/security.md](docs/security.md) before hosting apps you don't fully trust.**
This matters especially when apps run on sub-paths of one domain, because they then share one browser origin.

## Requirements

- A Linux VM with GNU tools (developed and tested on Ubuntu). macOS and BSD are not supported,
  not even for running `verify.sh` against a server.
- Docker Engine with the Compose v2 plugin (tested with Compose 2.40; needs `up --wait`,
  `--wait-timeout` and `pull --ignore-buildable`).
- `curl`, `openssl`, `jq`.
- IPv4. IPv6 is not configured: don't publish AAAA records for the domains, otherwise clients
  and Let's Encrypt may try to connect over IPv6 and fail.
- Ports 80 and 443 reachable from the internet.

## Trying it locally first

You can run and test the whole stack on any Linux machine with Docker, without a domain, DNS
records or Let's Encrypt:

```sh
test/local-test.sh run      # tests both installation types; the exit code is the result
```

`run` tests two installation types, each started, verified and torn down:
- `hosts`: apps on own hostnames (the default) and a public start page. This type also
  tests `update.sh`: undeployed apps are skipped, a pulled but unapplied image is applied, and
  a failed check after an update is rolled back.
- `single`: only the main domain, apps on sub-paths, and a login-protected start page.

Or step by step: `up hosts` (or `up single`), then `verify` (repeat as you like),
`update-test`, and finally `down`.

The script works on a throwaway copy of the repo (default `~/webstack-local-test`), so
your configuration is never modified. In the copy it:
- uses the reserved test domain `webstack.test`
- creates a throwaway CA and a certificate for `webstack.test` and `*.webstack.test` that
  Traefik serves instead of Let's Encrypt
- creates the test users `testadmin` (group `admins`) and `testuser`
- runs `verify.sh` as both users, with every request sent to `127.0.0.1`

TLS is still fully verified, against the test CA. Run it as a normal user in the `docker`
group, with ports 80/443 free. It can't run while a real installation is running on the same
host. A stopped one is left untouched.

The local test can't check DNS and the Let's Encrypt certificate issuance. The first
`./verify.sh` on the real server covers those.

## Setup

On the VM, as a normal user in the `docker` group. That user owns the installation, and
Authelia runs as that user:

1. **Get the code:**
   ```sh
   sudo mkdir /srv/webstack && sudo chown "$USER": /srv/webstack
   git clone https://github.com/brahmstaedt/webstack.git /srv/webstack && cd /srv/webstack
   ```

2. **Configuration:**
   ```sh
   cp proxy/.env.example proxy/.env               # set DOMAIN
   cp apps/whoami/.env.example apps/whoami/.env   # same DOMAIN; one address per service
   ```
   Optionally set a contact e-mail for Let's Encrypt in `proxy/traefik/traefik.yml` (`acme.email`).

3. **DNS.** Point `DOMAIN` and every app hostname you configured at the VM's IPv4 address (a
   wildcard `*.DOMAIN` record is easiest). With sub-paths only, `DOMAIN` alone is enough.
   If port 80 can't be opened, switch to `dnsChallenge` in `traefik.yml`.

4. **Secrets:**
   ```sh
   ./generate-secrets.sh
   ```
   This creates Authelia's secrets and appends `PUID`/`PGID` (the owner of the repository) to
   `proxy/.env`.

5. **Users:**
   ```sh
   cp proxy/authelia/config/users_database.yml.example proxy/authelia/config/users_database.yml
   docker run --rm -it authelia/authelia:4.39 authelia crypto hash generate argon2   # prompts for the password
   ```
   Paste each `Digest:` value as that user's `password`. Changes are picked up automatically.

6. **Start:**
   ```sh
   (cd proxy && docker compose up -d)
   (cd apps/whoami && docker compose up -d)    # optional example app
   ```
   Traefik obtains a certificate for every hostname in a router rule automatically, including
   apps on other domains, and renews it well before it expires. That needs DNS pointing to the
   VM and port 80 reachable. The first certificates take a few seconds to a minute
   (`docker compose -f proxy/docker-compose.yml logs -f traefik`).
   Tip: while experimenting, enable the staging `caServer` in `traefik.yml` to avoid
   Let's Encrypt rate limits. Remove it (and delete the `proxy_letsencrypt` volume) for real certificates.

7. **Start page** (optional, see below).

8. **Verify** (see below), then open `https://<DOMAIN>/`.

The example app only exists to show and test the setup. Remove it whenever you like with
`(cd apps/whoami && docker compose down)`. `verify.sh` then skips its checks.

**Traefik dashboard:** only reachable on the VM itself. From your machine:
`ssh -L 8080:127.0.0.1:8080 <vm>`, then open `http://localhost:8080/dashboard/`.

## Verifying an installation

`verify.sh` tests the live system. Run it on the VM from the repo root, where it reads `DOMAIN`
and the example app's addresses from the `.env` files. From another Linux machine, only the
HTTP and TLS checks run; pass the values as environment variables.

```sh
./verify.sh
TEST_USER=alice TEST_PASSWORD='secret' ./verify.sh            # includes a real login
DOMAIN=example.com PRIVATE_HOST=private.example.com PUBLIC_HOST=public.example.com ./verify.sh   # from another machine
```

Each check ends as PASS, FAIL, WARN or SKIP:

| Area | What is verified | Result if broken |
|---|---|---|
| Server | proxy containers running, Authelia healthy, `authelia validate-config`, secrets mode 600, no placeholder hashes, only Traefik publishes host ports, dashboard on 127.0.0.1 only | FAIL |
| Main domain | DNS, trusted certificate valid for 14+ more days, `http://` → `https://`, security headers (HSTS, `nosniff`, `X-Frame-Options`, `Referrer-Policy`), unknown paths 404 | FAIL |
| Login portal | health, login page, logout page | FAIL |
| Start page (if deployed) | public or login-protected as configured, links to the example app, logout link, no external resources, restrictive CSP, `noindex` | FAIL |
| Example app (if deployed) | routing and prefix handling, path boundaries, spoofed `Remote-User` headers stripped, no cookies passed to the app, anonymous users sent to the login portal | FAIL |
| Login flow (with `TEST_USER`) | login works, the backend receives the right `Remote-User`, `/admin` allowed for `admins` and denied for others, logout returns to the start page and ends the session | FAIL |
| Other apps' hostnames | DNS and certificates of every other hostname Traefik serves (needs `jq`) | WARN |

The exit code is 1 if any check FAILed. Warnings don't affect it: one app with a broken DNS
record or certificate must not block security updates for everything else. Read them anyway.
TLS is never skipped: a staging or self-signed certificate counts as a failure. Repeated wrong
`TEST_PASSWORD` values trigger Authelia's temporary ban (5 tries / 2 min → 10 min).

## Start page

`https://<DOMAIN>/` shows a list of all apps with a logout link. It is **public** by
default. To show it only to logged-in users, set `STARTPAGE_AUTH=authelia@file` in
`apps/startpage/.env` and run `docker compose up -d` in `apps/startpage/`. Without the start
page, `https://<DOMAIN>/` returns 404.

Each app appears as a card: two per row on large screens, one per row on phones, in dark blue
and white, following the visitor's light/dark preference. Apps declare their card with labels
(see [docs/app-interface.md](docs/app-interface.md)):

```yaml
- webstack.startpage.name=Wiki
- webstack.startpage.description=Team knowledge base
- webstack.startpage.logo=logo.svg        # optional SVG in the app's directory; default: initial letter
```

The page references nothing outside this server. It has no web fonts and no scripts, and logos
are embedded. Its Content-Security-Policy also blocks any external loading in the browser.

The link is derived from the app's router rule. The page is static HTML that a script on the
host generates from the labels of the running containers. The web container
(`nginx-unprivileged`, read-only) has no Docker access. A systemd unit regenerates the page
within seconds whenever a container starts or stops.

```sh
cp apps/startpage/.env.example apps/startpage/.env      # same DOMAIN; STARTPAGE_AUTH optional
apps/startpage/generate.sh                               # first page
(cd apps/startpage && docker compose up -d)
# keep it current: the instance name is the user that owns the repo (in group docker)
sudo cp ops/systemd/webstack-startpage@.service /etc/systemd/system/   # adjust the path inside if needed
sudo systemctl enable --now webstack-startpage@$USER.service
```

## Adding a project

The full contract an app must fulfil (addresses, headers, auth behaviour, cookies,
checklist) is in [docs/app-interface.md](docs/app-interface.md). In short, copy `apps/whoami/`:

- join the external `proxy` network and publish **no** ports
- the router rule serves the app on its own host **or** a sub-path, as set in the app's `.env`
- on a sub-path the prefix is stripped. Only apps that support running under a prefix
  (`X-Forwarded-Prefix`) can be deployed that way
- if login is required, put `authelia@file` **before** the strip middleware
- `loadbalancer.server.port` = the port the app listens on inside the container
- router, middleware and service names must be unique on the whole host

Your backend reads the logged-in user from the request headers `Remote-User`,
`Remote-Groups`, `Remote-Email` and `Remote-Name`. They are safe to trust **only**
because the app is reachable solely through Traefik, which strips client-sent copies
on every route.

Per-app rules (e.g. only group `admins`, or `two_factor`) go in `access_control` in
`proxy/authelia/config/configuration.yml`. Rules are evaluated top-down and the first match wins.

## Automatic updates

`update.sh` keeps the images up to date. It doesn't decide about versions itself: it pulls the
newest image for exactly the tag in each compose file. So **the tag is the update policy**:

| Tag in the compose file | What the daily update does |
|---|---|
| `myapp:1.4.2` (exact version) | nothing, never updates automatically |
| `myapp:1.4` (minor series, **recommended**) | applies 1.4.x patch releases. The proxy uses this: `traefik:v3.7`, `authelia:4.39`, `nginx-unprivileged:1.30-alpine` |
| `myapp:1` (major series) | applies all 1.x versions, including new features |
| `myapp:latest` | applies everything, including breaking changes (not recommended) |
| `.no-auto-update` file in the app directory | skips the app entirely |

Use a minor-series tag only if the app's publisher maintains one.

Each run:
1. runs `verify.sh` and changes nothing if the system is already broken (a FAIL; warnings don't count)
2. pulls newer images for the tags of the proxy and every **deployed** app (apps you never
   started or removed with `docker compose down` are skipped)
3. recreates every container whose running image differs from its tag's image, including
   images that were pulled earlier but never applied
4. runs `verify.sh` again and, if it fails, re-tags the previously running images and restarts them

Old images are deleted only after a successful verification. The automatic run does no login
test, so no password has to be stored on the server.

Install as a daily systemd timer (repo in `/srv/webstack`, otherwise adjust
the paths in the `.service` file):

```sh
sudo cp ops/systemd/webstack-update.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now webstack-update.timer
sudo systemctl start webstack-update.service   # first run by hand
journalctl -u webstack-update -e               # result
```

A failed run leaves the unit in the `failed` state (`systemctl --failed`).
Exit codes: 2 pre-check failed (nothing changed), 3 pull failed, 4 update rolled back,
5 rollback also failed. To be notified, add an `OnFailure=` unit that sends mail or a chat message.

Not covered by `update.sh`:
- **Minor and major versions:** watch the Traefik and Authelia release notes, bump the tag, and
  run `./update.sh` by hand. It verifies the result, but it can't roll back a *tag change*: if
  verification fails, revert the tag and run `docker compose up -d` again.
- **The OS:** install `unattended-upgrades` for the host itself.

## Operations

- **Logs:** `docker compose -f proxy/docker-compose.yml logs traefik authelia`. All containers
  use Docker's `local` log driver, which rotates logs, so they can't fill the disk.
- **Password reset / 2FA enrollment** (no SMTP configured): the message is written to a file:
  `cat proxy/authelia/data/notification.txt`
- **Restarting Authelia logs everyone out.** That includes patch updates and reboots, because
  sessions are kept in memory.

### Backup

```sh
cd /srv/webstack
docker compose -f proxy/docker-compose.yml stop authelia    # consistent copy of its database
tar -czf ~/webstack-backup.tgz proxy/.env apps/*/.env \
    proxy/authelia/config/users_database.yml proxy/authelia/data proxy/authelia/secrets
docker compose -f proxy/docker-compose.yml start authelia
# certificates and Let's Encrypt account (optional; saves re-issuing and rate limits)
docker run --rm -v proxy_letsencrypt:/v:ro --entrypoint tar traefik:v3.7 -czf - -C /v . > ~/webstack-certs.tgz
```

Add your apps' own data (their volumes or directories). The backup contains Authelia's secrets
and password hashes: store it encrypted and off the server.

### Restore

On a new server with the requirements above:

```sh
sudo mkdir /srv/webstack && sudo chown "$USER": /srv/webstack
git clone https://github.com/brahmstaedt/webstack.git /srv/webstack && cd /srv/webstack
tar -xzf ~/webstack-backup.tgz
# if this user's uid/gid differ from the old server: fix PUID/PGID in proxy/.env (id -u / id -g)
(cd proxy && docker compose create)            # creates the containers and the certificate volume
docker run --rm -i -v proxy_letsencrypt:/v --entrypoint tar traefik:v3.7 -xzf - -C /v < ~/webstack-certs.tgz
(cd proxy && docker compose up -d)
# then your apps, the start page and the systemd units as in Setup; finally ./verify.sh
```
