# App interface: what a web project must implement

This is the contract between a project and the shared proxy (Traefik + Authelia).
An app that follows it can be deployed alongside the others without changes to the proxy.

Each app is reachable under **either** its **own host** (the default) **or** a **sub-path** of
the main domain (`https://<DOMAIN>/<app>/`, for installations with only one domain), never
both. The installation decides per app. An app only has to support sub-paths if it is to be
deployed on one; state in its README whether it does.

## 1. Packaging

- Ship as one or more Docker containers with your own `docker-compose.yml` and `.env.example`
  (copy `apps/whoami/`).
- Join the external Docker network `proxy`. Other containers (database, cache, ...) should
  stay on a private network of your project and not join `proxy`.
- **Publish no host ports.** The app must be reachable only through Traefik, because the
  identity headers below are trustworthy only under that condition. `verify.sh` checks this.
- Reference images by a tag that only receives compatible updates (e.g. `myapp:1.4`, not
  `latest`). The daily `update.sh` pulls newer builds of that tag and restarts the app. Put a
  `.no-auto-update` file in the project directory to opt out.
- Optional: a Docker `HEALTHCHECK`. Traefik stops routing to a container that reports unhealthy.

## 2. Addresses and routing

Each app has exactly one address: an own **host** or a **path** on the main domain, set per
installation in the app's `.env`:

```yaml
# apps/myapp/docker-compose.yml (labels of the app's service)
- traefik.enable=true
- traefik.http.routers.myapp.rule=${MYAPP_HOST:+Host(`${MYAPP_HOST}`)}${MYAPP_PATH:+Host(`${DOMAIN}`) && (Path(`${MYAPP_PATH}`) || PathPrefix(`${MYAPP_PATH}/`))}
- traefik.http.routers.myapp.entrypoints=websecure
- traefik.http.routers.myapp.middlewares=authelia@file${MYAPP_PATH:+,myapp-strip}   # without login: drop authelia@file
- traefik.http.middlewares.myapp-strip.stripprefix.prefixes=${MYAPP_PATH:-/unused}
- traefik.http.services.myapp.loadbalancer.server.port=8080
```

```sh
# apps/myapp/.env
DOMAIN=example.com
MYAPP_HOST=myapp.example.com   # own host (subdomain or any other domain) ...
MYAPP_PATH=                    # ... OR e.g. /myapp for single-domain installations
```

Set exactly one. If both are set or both are empty, the rule is invalid: Traefik logs an
error and the app is unreachable. The strip middleware is only attached with a path, so an
app on its own host never has its paths rewritten.

Rules:
- Use `Path(/myapp) || PathPrefix(/myapp/)`, **not** just `PathPrefix(/myapp)`. The latter also
  matches `/myappfoo`, which would be stripped to `/foo` and slip past path-based rules.
- **`authelia@file` must come before the strip middleware.** Authelia must see the original
  path, otherwise its path rules (e.g. `^/myapp/admin`) don't match. Getting this wrong was a
  real admin bypass found by `verify.sh` during development.
- Router, middleware and service names must be unique across **all** projects on the VM.
- The paths `/auth` (login portal) and any path used by another app are taken.
- TLS is automatic (Let's Encrypt) for the main domain and every own host. Their DNS records
  must point to the VM.
- Without login, an own host on a **different** domain (e.g. `myapp.org` next to
  `example.com`) needs nothing extra. **With** login it needs three additions: a second session
  cookie entry in Authelia (`session.cookies`) with its own `authelia_url`, a portal route for
  that host (like `traefik/dynamic/portal.yml`), and an `access_control` rule for the host
  (the default policy is `deny`). Subdomains of `DOMAIN` need nothing extra.
- Labels give an app full control over Traefik routing: it could claim hostnames or paths of
  other apps (see docs/security.md, R13). The login portal is defined in
  `traefik/dynamic/portal.yml` and can't be overwritten by labels.

## 3. Sub-path support (only for apps deployed on a sub-path)

Behind `https://<DOMAIN>/myapp/`, the prefix is stripped. The app receives:

| Browser requests | App receives | Plus header |
|---|---|---|
| `https://example.com/myapp/` | `/` | `X-Forwarded-Prefix: /myapp` |
| `https://example.com/myapp/items/1` | `/items/1` | `X-Forwarded-Prefix: /myapp` |
| `https://myapp.example.com/items/1` (own host) | `/items/1` | none |

The app serves everything relative to `/`, and must **prepend `X-Forwarded-Prefix`** to every
URL it sends to the browser:
- links, form actions, asset URLs (`/static/...`), redirects (`Location` headers)
- cookie `Path`
- URLs embedded in JavaScript (API base URL, websocket URL)

Frameworks handle this in two ways:
- **Per request from `X-Forwarded-Prefix`.** Works for the path and the own host at the same
  time. Examples: Flask with `ProxyFix(x_prefix=1)`, Spring with
  `server.forward-headers-strategy=framework`.
- **A fixed base path** (e.g. Django `FORCE_SCRIPT_NAME`, FastAPI/Uvicorn `--root-path`, many
  SPA build settings). Only correct if the app is reached **exclusively** via its sub-path, so
  leave its own host empty.

Check your framework's documentation. Where neither exists, read the header in a small
middleware.

Single-page apps must use relative asset paths or a `<base href>` derived from the prefix.
An app that hard-codes absolute paths like `/static/app.js` **breaks** on a sub-path.

## 4. Headers the app receives

Always set by Traefik:

| Header | Meaning |
|---|---|
| `X-Forwarded-Proto: https` | the original request was HTTPS |
| `X-Forwarded-Host` | the original hostname |
| `X-Forwarded-Prefix` | the stripped path prefix (sub-path addresses only) |
| `X-Forwarded-For`, `X-Real-Ip` | the client IP |

Use these when the app builds absolute URLs or redirects, sets `Secure` cookies, or logs
client IPs. Otherwise it will generate `http://` links or log Traefik's IP. Only trust them
from the `proxy` network.

Set only on routes with the `authelia@file` middleware, for the logged-in user:

| Header | Example | Notes |
|---|---|---|
| `Remote-User` | `alice` | stable username, use as the user ID |
| `Remote-Groups` | `admins,users` | comma-separated, may be empty |
| `Remote-Email` | `alice@example.com` | |
| `Remote-Name` | `Alice Smith` | display name |

Traefik removes client-supplied copies of these headers on **every** route. So on a
public route they are guaranteed to be absent, and on a protected route they always
come from Authelia.

## 5. Authentication

Choose per app:

- **Protected** (`authelia@file`): every request is authenticated before it reaches the app.
  The app has no login page and no password storage. It reads `Remote-User` on each request
  and creates or looks up the local user record on first sight ("just-in-time provisioning").
- **Public**: no `authelia@file`. The app is open, or it has its own login.

Authorization:
- Coarse rules (who may use the app at all, 2FA required) go in Authelia's `access_control`.
- Path rules (e.g. `/myapp/admin` for group `admins`) must match the app's address in this
  installation: `^/myapp/admin` on `DOMAIN` for a sub-path, `^/admin` on the own host
  (see the example rules in `configuration.yml`, which cover both variants).
- **Also check `Remote-Groups` inside the app** for privileged functions. Path-based proxy
  rules can be fragile: double slashes, `/./` or URL encoding may be normalized differently by
  Authelia and by the app's router.

Behaviour the app should handle on protected routes:

- **Logout:** link to `https://<DOMAIN>/auth/logout`. Users then land on the start page
  (`https://<DOMAIN>/`). To send them elsewhere, add `?rd=<URL-encoded https URL>`. The target
  must be on `DOMAIN` or one of its subdomains. Clearing the app's own session isn't enough,
  because the user would be logged straight back in.
- **Session expiry:** a browser page load is redirected to the login portal. A `fetch`/XHR
  request may get an error status (typically `401`) instead of a redirect, so the frontend
  should treat that as "reload the page".
- **No user database needed,** but do not assume a user exists in the app only because it
  existed earlier: users can be removed from `users_database.yml` at any time.

## 6. Start page entry (optional)

Add two labels to the app's service to list it on the start page at `https://<DOMAIN>/`.
The start page is public by default (configurable per installation), so don't put anything
confidential in the name or description:

```yaml
- webstack.startpage.name=Wiki                              # shown as the title
- webstack.startpage.description=Team knowledge base        # one short sentence (optional)
- webstack.startpage.logo=logo.svg                          # optional, see below
```

**Logo:** an SVG file in the app's own compose directory (the directory containing its
`docker-compose.yml`), referenced by a relative path. Requirements: ends in `.svg`, at most
100 KB, contains an `<svg>` element, no `..` in the path, and no symlink pointing outside the
directory. Use a square `viewBox`; it is shown at 56×56 px on a light-blue tile in light mode
and a dark-blue tile in dark mode, so it should be legible on both. The logo is embedded into
the page as an image (`data:` URI): scripts, external fonts and external images inside the SVG
never run or load. Without a logo, or if the file doesn't meet the requirements, the card shows
a default logo with the app's initial. The generator prints the reason when it ignores a logo.

The link is derived from the router rule: the app's own host if set, otherwise its sub-path
on `DOMAIN`. Only if that can't work (e.g. an unusual rule), set
`webstack.startpage.url=https://...` explicitly. Only `https://` links to `DOMAIN` or one of the
app's own hosts are accepted. The start page never references anything outside this server.
All values are shown as plain text (HTML-escaped). If an app has several services, label
only the one users should open. The page updates within seconds when the app starts or stops.

## 7. Cookies and browser isolation

- **On one domain, all apps share one browser origin.** Cookies without a `Path`,
  `localStorage`, `sessionStorage`, IndexedDB and service workers are shared, and JavaScript
  from one app can read and change the pages of every other app. An XSS hole in one app
  therefore affects all of them (see docs/security.md, R11).
- Set your own cookies with `Path=<X-Forwarded-Prefix>/` (or `/` on an own host), and mark
  them `Secure; HttpOnly; SameSite=Lax`. Use cookie names prefixed with the app name. `Path`
  only avoids collisions; it is **not** a security boundary.
- Namespace `localStorage` keys with the app name. Don't register service workers with
  scope `/`.
- Authelia's session cookie `authelia_session` is sent to every app. Don't use that name.
- Apps on different hosts are different origins: cross-app API calls need CORS.

## Checklist

- [ ] `docker-compose.yml` joins network `proxy`, publishes no ports; `.env.example` provided
- [ ] router rule from the template: own host or sub-path, configurable in `.env`
- [ ] strip middleware for the path; `authelia@file` listed **before** it
- [ ] unique router/middleware/service names; path (if any) not used by another app or `/auth`
- [ ] if deployed on a sub-path: all URLs, redirects and cookie paths use `X-Forwarded-Prefix`
- [ ] README states whether the app supports sub-paths
- [ ] protected: user read from `Remote-User`, privileged functions also check `Remote-Groups`, logout links to `https://<DOMAIN>/auth/logout`
- [ ] Authelia path rules (if any) match the app's address (host or path)
- [ ] DNS record for the own host (if any)
- [ ] image tag chosen for safe auto-updates (or `.no-auto-update`)
- [ ] optional: `webstack.startpage.name` / `.description` / `.logo` labels
- [ ] `./verify.sh` still passes
