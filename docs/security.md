# Security

Security properties and known risks of this setup. Review this file whenever a new app is
added or the architecture changes.

## Threat model in one paragraph

The VM hosts several web apps, each on its own hostname and/or on a sub-path of one main
domain. The internet can reach only Traefik (ports 80/443). A small group of known users
logs in through Authelia with username + password. The apps are assumed to be **trusted
equally**, i.e. they are your own or carefully chosen software. Most of the risks below
become serious when that assumption no longer holds. As soon as apps share a domain via
sub-paths, **R11** makes this assumption mandatory.

## What the setup protects against

| Control | Where | Checked by `verify.sh` |
|---|---|---|
| HTTPS everywhere, trusted certificates, automatic renewal | `traefik.yml` | yes, for every hostname Traefik serves (≥ 14 days left) |
| HTTP is redirected to HTTPS | `traefik.yml` | yes |
| Security headers on every response: HSTS, nosniff, frame and referrer policy | `traefik/dynamic/middlewares.yml` | yes |
| Only Traefik publishes host ports; apps are not directly reachable from the internet | compose files | yes |
| Client-sent `Remote-*` identity headers are stripped on every route | `traefik/dynamic/middlewares.yml` (`strip-auth-headers`) | yes |
| Protected routes require a login; spoofed headers don't bypass it | `authelia@file` middleware | yes |
| Access is denied unless a rule allows it; group-restricted paths enforced | `configuration.yml` | yes (example app) |
| Login portal route can't be overwritten by app labels (file provider, highest priority) | `traefik/dynamic/portal.yml` | yes (portal reachable) |
| The example app never receives cookies (it echoes headers) | `apps/whoami/docker-compose.yml` | yes |
| Logs are rotated (Docker `local` driver), so they can't fill the disk | compose files | no |
| Login check runs on the original path, before the prefix is stripped; `/appfoo` is not routed to `/app` | app labels | yes (example app) |
| Traefik dashboard/API not on the internet, bound to 127.0.0.1:8080 | `docker-compose.yml` | yes |
| Start page: static HTML with all label values escaped, strict CSP (no scripts), `noindex`, served by a read-only non-root container without Docker access; login optional (`STARTPAGE_AUTH`) | `apps/startpage/` | yes (access mode, CSP) |
| Passwords stored as argon2id hashes | `users_database.yml` | no placeholders left: yes |
| Brute-force throttling (5 failures / 2 min → 10 min ban) | `configuration.yml` (`regulation`) | no |
| Traefik has no raw Docker socket, only read access via a filtering proxy on an internal network | `docker-compose.yml` | no |
| Secrets in files with mode 600, not in compose files or env | `generate-secrets.sh` | yes |
| Authelia runs as the unprivileged owner of the repo (`PUID`/`PGID` in `proxy/.env`), not as root | `docker-compose.yml` | no |
| Images pinned to minor series, patched automatically with verify + rollback | `update.sh` | yes (post-update) |

## Known risks

Status: **open** = not mitigated, **accepted** = consciously tolerated, **mitigated** = addressed.

### R1. Lateral movement between apps via the shared network (high, open)

All apps join the `proxy` network and can reach each other directly (`http://otherapp:80`),
bypassing Traefik and Authelia. A compromised app can send `Remote-User: alice` and is
believed by every other app. **The compromise of one app is the compromise of all apps**
that rely on `Remote-*` headers.

Mitigations, if apps are not equally trusted:
- One Docker network per project, joined only by that project and Traefik (Traefik must be
  added to each network in `proxy/docker-compose.yml`, so projects no longer register
  purely through labels).
- Or have apps verify a signed JWT instead of trusting plain headers.

### R2. Every app receives the Authelia session cookie (high, accepted while all apps are trusted)

`authelia_session` is scoped to the main domain (and its subdomains), so the browser sends
it to every app. A
malicious or compromised app can read it server-side and use it to act as the user on all
protected sites. All subdomains are "same-site", so `SameSite` doesn't help.

Mitigations: host only trusted apps under this domain. Put untrusted apps on a separate
domain with its own Authelia cookie, or integrate them via OIDC so they never see the cookie.

### R3. Single-factor authentication (medium, open)

All rules use `one_factor`. A phished or reused password
grants full access. The failed-login ban also lets anyone lock out a known username for
10 minutes on purpose.

Mitigation: set `policy: two_factor` for `admins`, ideally for everything
(TOTP or passkeys/WebAuthn). Enrollment messages go to `proxy/authelia/data/notification.txt` because
no SMTP server is configured. The automatic update makes no login test, so 2FA doesn't
interfere with it. The manual login test (`TEST_USER`) only performs the first factor, so its
checks of protected pages fail once 2FA is required for them.

### R4. Browser security headers (mitigated)

Every response gets HSTS (1 year), `X-Content-Type-Options: nosniff`,
`X-Frame-Options: SAMEORIGIN` and `Referrer-Policy: strict-origin-when-cross-origin` from the
`security-headers` middleware on the `websecure` entrypoint. `verify.sh` checks them. Choices:
- HSTS is set without `includeSubDomains`/`preload`, because other subdomains of the main domain
  may be served elsewhere and without HTTPS. Add them only if every subdomain is HTTPS.
- `SAMEORIGIN` instead of `DENY`, so apps on the same domain can embed each other.
- A Content-Security-Policy can't be set globally (it depends on each app). Apps should send their
  own; the start page does.

### R5. Docker API read access reaches into all containers (medium, accepted)

Traefik reads the container list through the socket proxy (`CONTAINERS=1`). That setting
allows **all read requests** under `/containers/`, not just the list: `inspect` (every
container's environment variables), `logs`, and `archive`/`export` (files inside containers,
including mounted secrets). Only Traefik can reach the socket proxy. A compromised Traefik,
which faces the internet, could therefore read the secrets and data of every container.
Write access (create, start, exec) stays blocked.

Mitigations: keep Traefik patched (the daily update does). For stronger isolation, replace the
socket proxy with one that allows only the exact endpoints Traefik needs, or switch to a
statically configured proxy that needs no Docker access (losing configuration by labels).
Giving apps their secrets as files instead of environment variables does **not** help here.

### R6. Automatic updates (medium, mitigated with residual risk)

`update.sh` pulls new patch releases within the pinned minor series daily, verifies the
system, and rolls back on failure. Residual risks:
- A compromised upstream image would be deployed automatically. The pins limit this to
  the chosen publisher and series, but don't prevent it.
- `verify.sh` checks routing, TLS and auth. It doesn't detect every functional regression
  inside an app.
- Minor/major upgrades (e.g. Traefik v3.7 → v3.8, Authelia 4.39 → 4.40) are **not**
  automatic. Someone has to watch releases and bump the tags. `tecnativa/docker-socket-proxy`
  is pinned to an exact version (no minor-series tag exists), so it gets no automatic patches.
- For apps, the tag in their compose file is the update policy. `latest` would apply breaking
  changes automatically.
- Updates stop while any core check fails (a FAIL). Problems of individual apps (their DNS or
  certificates) are only warnings and don't block updates. A failed update run only shows up as
  a failed systemd unit unless you add a notification (`OnFailure=`).

### R7. Hostnames are public (low, accepted)

Let's Encrypt certificates appear in public Certificate Transparency logs, so every hostname
(e.g. `private.example.com`) is discoverable. Apps on sub-paths of the main domain don't
show up there, but their paths are easy to guess. A wildcard certificate via DNS-01 would hide
them, but requires a DNS API token on the VM, which is a more valuable secret to protect.

### R8. Docker bypasses the host firewall (low, mitigated by verify.sh)

Ports published by Docker are reachable even if ufw/iptables rules block them. An app that
accidentally adds `ports:` is exposed to the internet. `verify.sh` fails if any container
other than Traefik publishes a port.

### R9. Single VM (inherent, accepted)

A container escape, a kernel exploit or a compromised host account affects every project.
Reduce the blast radius:
- automatic OS security updates (`unattended-upgrades`)
- SSH with keys only, no root login
- app containers run as non-root, no `privileged: true`, no extra capabilities
- backups stored off the VM

### R10. Smaller points (low)

- `trustForwardHeader: true` is safe only because Traefik is the outermost hop and does not
  trust incoming `X-Forwarded-*`. Revisit if a CDN or load balancer is ever put in front.
- `storage_encryption_key` sits on the same disk as the Authelia database, and the documented
  backup contains both. Treat the backup itself as a secret: encrypt it and keep it off the server.
- Authelia keeps sessions in memory: every restart (patch updates, reboots) logs all users out.
- `proxy/authelia/data/notification.txt` contains valid password-reset and
  2FA-enrollment tokens.
- Traefik's dashboard/API (port 8080) is published only on 127.0.0.1, but every container on
  the `proxy` network can reach it at `traefik:8080`. The API is read-only and reveals the
  routing configuration (hostnames, paths, middlewares). Set `api.insecure: false` if the
  dashboard isn't needed.
- No rate limiting on public routes; each app is responsible for its own abuse protection.
- The start page is **public by default**, so anyone can see which apps run on the server
  and where. That's useful for visitors, but it also helps attackers map the installation
  (`noindex` only keeps honest search engines away). Set `STARTPAGE_AUTH=authelia@file` to
  show it to logged-in users only, or leave the labels off apps whose existence should stay
  hidden. Listed apps keep their own access rules either way.
- App logos are files read by the generator on the host. To keep apps from publishing
  arbitrary host files through a logo label (e.g. `../../proxy/authelia/secrets/...`), only
  `.svg` files inside the app's own directory (no `..`, no symlinks out of it, ≤ 100 KB,
  containing `<svg>`) are accepted. They are embedded as `<img>` data URIs, so scripts inside
  an SVG never run. Card links may only point to `DOMAIN` or the app's own hosts, in a strict
  `https://host/path` form (no user info, no port). Apps control their own labels, so one app
  could still hide another app's card by declaring the same link, or choose the directory its
  logo is read from via the compose `working_dir` label. Both are cosmetic.
- The example app (`apps/whoami`) echoes every request header back. It never receives cookies
  (a middleware removes them), but it does reveal internal details such as container IPs.
  Remove it once you no longer need it.
- The start page generator (`watch.sh`) runs on the host as a user in group `docker`, which
  is equivalent to root on the host. It doesn't face the network. The label values it
  processes come from app authors and are escaped, and only `https://` links are accepted.

### R11. Apps on sub-paths share one browser origin (high where sub-paths are used, accepted)

Apps on sub-paths of the same domain (`https://example.com/app1/`, `/app2/`) are the **same
origin** for the browser. The browser's isolation between sites doesn't apply between them:
- JavaScript from one app can read and modify the pages of every other app, including
  CSRF tokens and displayed data, and can make authenticated requests as the user.
- `localStorage`, `sessionStorage`, IndexedDB and cookies without a `Path` are shared.
  Cookie `Path` is not a security boundary.
- A service worker registered with scope `/` by one app can intercept requests of all apps.

So **one XSS vulnerability in any app compromises the user's session in all apps.** This
is inherent to path-based hosting and can't be fixed in the proxy.

Mitigations:
- Host only trusted apps on a shared domain.
- Prefer own hostnames (the default) wherever DNS allows it. Different hosts are different origins.
- Use strict Content Security Policies in every app, and no inline scripts.
- Keep apps up to date.

### R12. Path-based access rules are fragile (medium, mitigated by tests and app checks)

Authelia rules like `^/private/admin` match the request path as Traefik passes it on.
Each app has exactly one address (own host *or* sub-path), so there is no second address
through which a rule could be bypassed. Remaining weaknesses:
- **Matching the address:** the rule must use the app's actual address: `^/private/admin` on
  `DOMAIN` for a sub-path, `^/admin` on the own host. `verify.sh` checks this for the example
  app; add similar checks for your own restricted paths.
- **Middleware order:** `authelia@file` must run before the strip middleware, otherwise
  Authelia sees the stripped path and the rule doesn't match. This happened during
  development and was caught by `verify.sh`.
- **Path boundaries:** `PathPrefix(/app)` also matches `/appfoo`. Use
  `Path(/app) || PathPrefix(/app/)`. `verify.sh` checks this for the example app.
- **Normalization:** `//`, `/./`, `..` or percent-encoding may be interpreted differently by
  Authelia and by the app's router.

Mitigation: use proxy path rules only as a first line of defense. Apps must check
`Remote-Groups` themselves for every privileged function.

### R13. App labels control all routing (medium, accepted while all apps are trusted)

Every container with Traefik labels can define routers, services and middlewares in one
shared namespace. A careless or malicious app could:
- claim the hostname or paths of another app with a more specific rule or a higher `priority`,
  and so receive its traffic, including that app's users' requests
- define a router or service with the same name as another app's. Traefik then drops both,
  taking the other app offline (and a load-balancer name collision merges servers, sending some
  of the other app's requests to it)
- attach its own middlewares to its routes, but not to other apps' routes

The login portal is protected: its route is defined in `traefik/dynamic/portal.yml` (file
provider, not reachable by labels) with the highest priority, and its service isn't a Docker
service an app could join.

Mitigations: review the labels of every app before deploying it, and use unique,
app-prefixed names. A typo is enough to cause the name collisions above.

## Reporting and response

- Run `./verify.sh` after every manual change.
- `systemctl status webstack-update.service` / `journalctl -u webstack-update` show the result
  of the last automatic update.
- To lock out a user immediately, remove them from `users_database.yml` (picked up automatically)
  and restart Authelia to end existing sessions:
  `docker compose -f proxy/docker-compose.yml restart authelia`.
