#!/usr/bin/env bash
# Verifies that a running installation actually works end to end.
#
# Usage (from the repo root on the server; the HTTP checks also work from another Linux machine):
#   ./verify.sh
#   TEST_USER=alice TEST_PASSWORD='...' ./verify.sh     # also tests a real login (needs jq)
#
# Results: PASS, FAIL, WARN, SKIP. The exit code is 1 if any check FAILed, else 0.
#   FAIL  the proxy, login, TLS of the main domain, security headers, start page, or the
#         security behaviour of the example app (if deployed) is broken
#   WARN  another app's hostname has a DNS or certificate problem. That's the app's problem and
#         must not block security updates of the proxy (update.sh only stops on FAIL).
#
# Configuration is read from proxy/.env, apps/whoami/.env and apps/startpage/.env if present;
# environment variables take precedence (needed when running from another machine):
#   DOMAIN                     main domain (login portal at https://DOMAIN/auth/)
#   PRIVATE_HOST|PRIVATE_PATH  address of the example app's protected service (one of the two)
#   PUBLIC_HOST|PUBLIC_PATH    address of the example app's public service (one of the two)
#                              The example app is only tested if it is configured/deployed.
#   STARTPAGE_AUTH             start page access (empty = public, authelia@file = login)
#   CERT_MIN_DAYS              minimum remaining certificate validity (default 14)
#
# Testing without public DNS (see test/local-test.sh):
#   RESOLVE_IP=127.0.0.1   send all requests to this IP instead of resolving the hostnames
#   CA_FILE=path/ca.pem    trust only this CA (e.g. a local test CA) instead of the system CAs
#
# Requires Linux with GNU tools, curl, openssl, getent; jq for the login checks and for
# checking every hostname Traefik serves. Server-side checks run only where this checkout's
# Traefik container exists. TLS is always verified: an untrusted certificate is a failure.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

# Reads KEY=value from an env file like Docker Compose does (export prefix, quotes, inline
# comments, CRLF), without executing it.
envval() {
  [[ -f "$1" ]] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$2=//p" "$1" | tail -n1 |
    sed -E 's/\r$//; s/[[:space:]]+#.*$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/[[:space:]]+$//'
}

DOMAIN="${DOMAIN:-$(envval proxy/.env DOMAIN)}"
DOMAIN="${DOMAIN:-example.com}"
EXAMPLE_CONFIGURED=0
for v in PRIVATE_HOST PRIVATE_PATH PUBLIC_HOST PUBLIC_PATH; do
  if [[ -v $v ]]; then EXAMPLE_CONFIGURED=1; else printf -v "$v" '%s' "$(envval apps/whoami/.env "$v")"; fi
done
[[ -f apps/whoami/.env ]] && EXAMPLE_CONFIGURED=1
CERT_MIN_DAYS="${CERT_MIN_DAYS:-14}"
AUTH_URL="https://$DOMAIN/auth"
START_URL="https://$DOMAIN/"

PASS=0; FAIL=0; WARN=0; SKIP=0
green() { printf '\e[32m%s\e[0m' "$*"; }
red()   { printf '\e[31m%s\e[0m' "$*"; }
yellow(){ printf '\e[33m%s\e[0m' "$*"; }
ok()   { PASS=$((PASS+1)); echo "  $(green PASS)  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  $(red FAIL)  $1${2:+  -- $2}"; }
warn() { WARN=$((WARN+1)); echo "  $(yellow WARN)  $1${2:+  -- $2}"; }
skip() { SKIP=$((SKIP+1)); echo "  $(yellow SKIP)  $1${2:+  -- $2}"; }
info() { echo "        info: $*"; }
section() { echo; echo "== $1"; }

# Server-side checks only where this checkout's proxy is running (not on a laptop that merely
# has Docker installed).
LOCAL=0
if command -v docker >/dev/null 2>&1 &&
   [[ -n "$(docker compose -f proxy/docker-compose.yml ps -q traefik 2>/dev/null)" ]]; then
  LOCAL=1
fi

# --- example app: deployed? addresses?
EXAMPLE=0
if ((LOCAL)) && [[ -f apps/whoami/docker-compose.yml ]]; then
  [[ -n "$(docker compose -f apps/whoami/docker-compose.yml ps -a -q 2>/dev/null)" ]] && EXAMPLE=1
elif ((EXAMPLE_CONFIGURED)); then
  EXAMPLE=1
fi
PUBLIC_URLS=(); PRIVATE_URLS=(); ADMIN_URLS=()
EXAMPLE_HOSTS=()
example_address() {   # $1 service label, $2 host, $3 path -> sets ADDR="<url> <prefix or ->"
  ADDR=""
  if [[ -n "$2" && -n "$3" ]]; then
    bad "example app ($1): set either a host or a path, not both" "apps/whoami/.env"
  elif [[ -n "$2" ]]; then ADDR="https://$2/ -"; EXAMPLE_HOSTS+=("$2")
  elif [[ -n "$3" ]]; then ADDR="https://$DOMAIN$3/ $3"
  else bad "example app ($1): no address configured" "set a host or a path in apps/whoami/.env"
  fi
}
if ((EXAMPLE)); then
  example_address private "$PRIVATE_HOST" "$PRIVATE_PATH"
  if [[ -n "$ADDR" ]]; then
    PRIVATE_URLS=("$ADDR")
    if [[ -n "$PRIVATE_HOST" ]]; then ADMIN_URLS=("https://$PRIVATE_HOST/admin"); else ADMIN_URLS=("https://$DOMAIN$PRIVATE_PATH/admin"); fi
  fi
  example_address public "$PUBLIC_HOST" "$PUBLIC_PATH"
  [[ -n "$ADDR" ]] && PUBLIC_URLS=("$ADDR")
  ((${#PRIVATE_URLS[@]} && ${#PUBLIC_URLS[@]})) || EXAMPLE=0
fi

# --- hostnames: main domain + example (FAIL), all others Traefik serves (WARN)
CORE_HOSTS=("$DOMAIN" "${EXAMPLE_HOSTS[@]}")
OTHER_HOSTS=()
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
if ((LOCAL && HAVE_JQ)) && api="$(curl -fsS --max-time 5 http://127.0.0.1:8080/api/http/routers 2>/dev/null)"; then
  while read -r h; do
    [[ -n "$h" ]] && ! printf '%s\n' "${CORE_HOSTS[@]}" | grep -qxF "$h" && OTHER_HOSTS+=("$h")
  done < <(jq -r '.[] | select((.entryPoints // []) | index("websecure")) | .rule' <<<"$api" 2>/dev/null |
           grep -oE 'Host\(`[^`]+`\)' | sed -E 's/^Host\(`(.*)`\)$/\1/' | sort -u)
fi
mapfile -t OTHER_HOSTS < <(printf '%s\n' "${OTHER_HOSTS[@]}" | awk 'NF && !seen[$0]++')
ALL_HOSTS=("${CORE_HOSTS[@]}" "${OTHER_HOSTS[@]}")

CURL=(curl -sS --max-time 15 --proto '=http,https')
RESOLVE_IP="${RESOLVE_IP:-}"
CA_FILE="${CA_FILE:-}"
if [[ -n "$RESOLVE_IP" ]]; then
  for h in "${ALL_HOSTS[@]}"; do CURL+=(--resolve "$h:80:$RESOLVE_IP" --resolve "$h:443:$RESOLVE_IP"); done
fi
if [[ -n "$CA_FILE" ]]; then
  [[ -r "$CA_FILE" ]] || { echo "CA_FILE not readable: $CA_FILE" >&2; exit 1; }
  CURL+=(--cacert "$CA_FILE")
fi
# Prints "<http_code> <redirect_url>"
status() { "${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "$@" 2>/dev/null || echo "000 "; }
host_of() { local u="${1#*://}"; echo "${u%%/*}"; }

# Expected start page mode: from STARTPAGE_AUTH (env or apps/startpage/.env), unknown otherwise.
START_EXPECT=unknown
if [[ -v STARTPAGE_AUTH || -f apps/startpage/.env ]]; then
  STARTPAGE_AUTH="${STARTPAGE_AUTH-$(envval apps/startpage/.env STARTPAGE_AUTH)}"
  if [[ -n "$STARTPAGE_AUTH" ]]; then START_EXPECT=protected; else START_EXPECT=public; fi
fi

echo "Domain: $DOMAIN   portal: $AUTH_URL/"
if ((EXAMPLE)); then echo "Example app: private = ${PRIVATE_URLS[0]%% *}   public = ${PUBLIC_URLS[0]%% *}"
else echo "Example app: not deployed (its checks are skipped)"; fi
((${#OTHER_HOSTS[@]})) && echo "Other hostnames served by Traefik (DNS + TLS, warnings only): ${OTHER_HOSTS[*]}"

# ---------------------------------------------------------------------------
section "Server (Docker on this host)"
if ((!LOCAL)); then
  skip "server checks" "this checkout's proxy is not running here (fine when checking from another machine)"
else
  PROXY=(docker compose -f proxy/docker-compose.yml)
  running="$("${PROXY[@]}" ps --status running --services 2>/dev/null)"
  for svc in socket-proxy traefik authelia; do
    grep -qx "$svc" <<<"$running" && ok "proxy/$svc is running" || bad "proxy/$svc is running"
  done
  for app in whoami startpage; do
    f="apps/$app/docker-compose.yml"
    [[ -f "$f" && -n "$(docker compose -f "$f" ps -a -q 2>/dev/null)" ]] || continue
    stopped="$(comm -23 <(docker compose -f "$f" config --services 2>/dev/null | sort) \
                         <(docker compose -f "$f" ps --status running --services 2>/dev/null | sort))"
    [[ -z "$stopped" ]] && ok "$app is running" || bad "$app is running" "not running: $(echo $stopped)"
  done

  cid="$("${PROXY[@]}" ps -q authelia 2>/dev/null)"
  health="$( [[ -n "$cid" ]] && docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
  case "$health" in
    healthy) ok "authelia container is healthy" ;;
    none)    skip "authelia container health" "image has no healthcheck" ;;
    *)       bad "authelia container is healthy" "status: ${health:-not found}" ;;
  esac
  if out="$("${PROXY[@]}" exec -T authelia authelia validate-config --config /config/configuration.yml 2>&1)"; then
    ok "authelia configuration is valid"
  else
    bad "authelia configuration is valid" "$(tail -n 3 <<<"$out" | tr '\n' ' ')"
  fi
  if [[ ! -f proxy/authelia/config/users_database.yml ]]; then
    bad "users_database.yml exists"
  elif grep -q REPLACE_ME proxy/authelia/config/users_database.yml; then
    bad "users_database.yml has real password hashes" "still contains REPLACE_ME"
  else
    ok "users_database.yml has real password hashes"
  fi
  for s in jwt_secret session_secret storage_encryption_key; do
    f="proxy/authelia/secrets/$s"
    if [[ ! -s "$f" ]]; then bad "secret $s exists"
    elif [[ "$(stat -c %a "$f")" != 600 ]]; then bad "secret $s is mode 600" "is $(stat -c %a "$f")"
    else ok "secret $s exists (mode 600)"; fi
  done
  [[ "$(envval proxy/.env PUID)" == 0 ]] && warn "Authelia runs as root (PUID=0 in proxy/.env)" "let a normal user own the repository"

  for f in apps/*/.env; do
    [[ -f "$f" ]] || continue
    d="$(envval "$f" DOMAIN)"
    [[ -z "$d" || "$d" == "$DOMAIN" ]] || warn "DOMAIN in $f matches proxy/.env" "$d != $DOMAIN"
  done

  # Only Traefik may publish ports on the host; everything else must be reachable only via the proxy.
  tid="$("${PROXY[@]}" ps -q traefik 2>/dev/null)"
  traefik_name="$(docker inspect -f '{{.Name}}' "$tid" 2>/dev/null | tr -d /)"
  exposed="$(docker ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' -v t="$traefik_name" '$2 ~ /->/ && $1 != t {print $1}')"
  if [[ -z "$exposed" ]]; then ok "no container except traefik publishes host ports"
  else bad "no container except traefik publishes host ports" "exposed: $(echo $exposed)"; fi

  bindings="$(docker port "$tid" 8080/tcp 2>/dev/null)"
  if [[ -n "$bindings" ]] && ! grep -qv '^127\.0\.0\.1:' <<<"$bindings"; then
    ok "dashboard port 8080 is bound to 127.0.0.1 only"
  else
    bad "dashboard port 8080 is bound to 127.0.0.1 only" "bindings: $(echo $bindings)"
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/api/overview)"
  [[ "$code" == 200 ]] && ok "dashboard API answers on 127.0.0.1:8080" || bad "dashboard API answers on 127.0.0.1:8080" "got $code"
  ((HAVE_JQ)) || skip "hostnames of other apps" "jq is not installed, so only the main domain and the example app are checked"
fi

# ---------------------------------------------------------------------------
# $1 = host, $2 = ok|warn (which result a failure gives)
check_host() {
  local h="$1" sev="$2" err ip
  local fail=bad; [[ "$sev" == warn ]] && fail=warn
  if [[ -z "$RESOLVE_IP" ]]; then
    ip="$(getent ahosts "$h" 2>/dev/null | awk 'NR==1{print $1}')"
    if [[ -n "$ip" ]]; then ok "$h resolves ($ip)"; else $fail "$h resolves"; return; fi
  fi
  if err="$("${CURL[@]}" -o /dev/null "https://$h/" 2>&1)"; then
    ok "$h presents a trusted certificate"
  else
    $fail "$h presents a trusted certificate" "$err"
  fi
  if openssl s_client -connect "${RESOLVE_IP:-$h}:443" -servername "$h" </dev/null 2>/dev/null \
       | openssl x509 -noout -checkend $((CERT_MIN_DAYS*86400)) >/dev/null 2>&1; then
    ok "$h certificate valid for at least $CERT_MIN_DAYS more days"
  else
    $fail "$h certificate valid for at least $CERT_MIN_DAYS more days"
  fi
}

section "DNS and TLS"
[[ -n "$RESOLVE_IP" ]] && skip "DNS resolution" "RESOLVE_IP=$RESOLVE_IP is set, hostnames are not resolved"
for h in "${CORE_HOSTS[@]}"; do check_host "$h" ok; done
for h in "${OTHER_HOSTS[@]}"; do check_host "$h" warn; done

# ---------------------------------------------------------------------------
section "Redirects and security headers"
for url in "$AUTH_URL/" "${PUBLIC_URLS[@]%% *}" "${PRIVATE_URLS[@]%% *}"; do
  http="http://${url#https://}"
  read -r code loc <<<"$(status "$http")"
  if [[ "$code" =~ ^30[178]$ && "$loc" == "$url"* ]]; then ok "$http redirects to https ($code)"
  else bad "$http redirects to https" "got $code ${loc:-no Location}"; fi
done
hdrs="$("${CURL[@]}" -o /dev/null -D - "$AUTH_URL/" 2>/dev/null | tr -d '\r')"
for h in 'strict-transport-security: max-age=' 'x-content-type-options: nosniff' 'x-frame-options: SAMEORIGIN' 'referrer-policy: '; do
  grep -qi "^$h" <<<"$hdrs" && ok "responses have ${h%%:*}" || bad "responses have ${h%%:*}" "($AUTH_URL/)"
done
read -r code _ <<<"$(status "https://$DOMAIN/doesnotexist")"
[[ "$code" == 404 ]] && ok "unknown paths on $DOMAIN return 404" || bad "unknown paths on $DOMAIN return 404" "got $code"

# ---------------------------------------------------------------------------
section "Login portal"
read -r code _ <<<"$(status "$AUTH_URL/api/health")"
[[ "$code" == 200 ]] && ok "$AUTH_URL/api/health returns 200" || bad "$AUTH_URL/api/health returns 200" "got $code"
read -r code _ <<<"$(status "$AUTH_URL/")"
[[ "$code" == 200 ]] && ok "$AUTH_URL/ login page returns 200" || bad "$AUTH_URL/ login page returns 200" "got $code"
read -r code _ <<<"$(status "$AUTH_URL/logout")"
[[ "$code" == 200 ]] && ok "$AUTH_URL/logout page exists" || bad "$AUTH_URL/logout page exists" "got $code"

# ---------------------------------------------------------------------------
# Checks the content of the start page. $1 = who is looking, further args = extra curl options.
startpage_content() {
  local who="$1" hdrs page entry; shift
  hdrs="$(mktemp)"
  page="$("${CURL[@]}" "$@" -D "$hdrs" "$START_URL" 2>/dev/null)"
  grep -q '<title>Apps on' <<<"$page" && ok "start page is shown ($who)" || bad "start page is shown ($who)"
  for entry in "${PRIVATE_URLS[@]}" "${PUBLIC_URLS[@]}"; do
    grep -qF "href=\"${entry%% *}\"" <<<"$page" && ok "start page links to ${entry%% *}" || bad "start page links to ${entry%% *}"
  done
  grep -qF "href=\"$AUTH_URL/logout?rd=" <<<"$page" && ok "start page has a logout link (returning to the start page)" \
                                                   || bad "start page has a logout link (returning to the start page)"
  if grep -qiE '<script|<link|@import|url\(' <<<"$page" || grep -oiE '\ssrc="[^"]*"' <<<"$page" | grep -qviE 'src="data:'; then
    bad "start page loads no external resources" "found script/link/@import/url() or a non-data: src"
  else
    ok "start page loads no external resources"
  fi
  grep -qi "^content-security-policy: default-src 'none'" "$hdrs" && ok "start page sends a restrictive Content-Security-Policy" \
                                                               || bad "start page sends a restrictive Content-Security-Policy"
  grep -qi '^x-robots-tag: noindex' "$hdrs" && ok "start page asks search engines not to index it" \
                                            || bad "start page asks search engines not to index it"
  rm -f "$hdrs"
}

section "Start page"
read -r code loc <<<"$(status -H 'Accept: text/html' "$START_URL")"
STARTPAGE=none
if [[ "$code" == 404 ]]; then
  [[ "$START_EXPECT" == unknown ]] && skip "start page" "not deployed ($START_URL returns 404)" \
                                   || bad "start page is deployed" "$START_URL returns 404"
elif [[ "$code" =~ ^30[23]$ && "$loc" == "$AUTH_URL/"* ]]; then
  STARTPAGE=protected
  ok "$START_URL redirects anonymous users to the login portal (protected start page)"
elif [[ "$code" == 200 ]]; then
  STARTPAGE=public
  ok "$START_URL is reachable without login (public start page)"
  startpage_content "anonymous"
else
  bad "$START_URL answers" "got $code ${loc:-}"
fi
if [[ "$STARTPAGE" != none && "$START_EXPECT" != unknown ]]; then
  [[ "$STARTPAGE" == "$START_EXPECT" ]] && ok "start page access mode is '$START_EXPECT' as configured (STARTPAGE_AUTH)" \
                                        || bad "start page access mode is '$START_EXPECT' as configured (STARTPAGE_AUTH)" "is $STARTPAGE"
fi

# ---------------------------------------------------------------------------
# Checks that a whoami response came through the expected route.
# $1 body, $2 url, $3 expected X-Forwarded-Prefix ("-" = none), $4 label
check_routed() {
  local body="$1" url="$2" prefix="$3" label="$4" host
  host="$(host_of "$url")"
  if ! grep -qi "^Host: $host" <<<"$body"; then
    bad "$label: $url reaches the app" "no whoami response"; return
  fi
  ok "$label: $url reaches the app"
  if ! grep -q '^GET / HTTP' <<<"$body"; then
    bad "$label: app receives path / (prefix stripped)" "$(grep -m1 '^GET ' <<<"$body")"
  elif [[ "$prefix" == - ]]; then
    if grep -qi '^X-Forwarded-Prefix:' <<<"$body"; then
      bad "$label: no X-Forwarded-Prefix on own host" "$(grep -i '^X-Forwarded-Prefix:' <<<"$body" | tr -d '\r')"
    else
      ok "$label: app receives path / without X-Forwarded-Prefix"
    fi
  elif grep -qiE "^X-Forwarded-Prefix: ${prefix}[[:space:]]*$" <<<"$body"; then
    ok "$label: app receives path / and X-Forwarded-Prefix: $prefix"
  else
    bad "$label: app receives X-Forwarded-Prefix: $prefix" "$(grep -i '^X-Forwarded-Prefix:' <<<"$body" | tr -d '\r')"
  fi
  if grep -qi '^Cookie:' <<<"$body"; then
    bad "$label: cookies are not passed to the example app" "it would reflect the session cookie"
  else
    ok "$label: cookies are not passed to the example app"
  fi
}

section "Example app"
if ((!EXAMPLE)); then
  skip "example app checks" "apps/whoami is not deployed"
else
  read -r url prefix <<<"${PUBLIC_URLS[0]}"
  body="$("${CURL[@]}" -H 'Remote-User: mallory' -H 'Remote-Groups: admins' -H 'Remote_User: mallory' \
           -H 'Cookie: authelia_session=probe' "$url" 2>/dev/null)"
  check_routed "$body" "$url" "$prefix" "public"
  if grep -qiE '^Remote[-_](User|Groups):' <<<"$body"; then
    bad "spoofed Remote-User/Remote-Groups headers are stripped" "backend received them"
  else
    ok "spoofed Remote-User/Remote-Groups headers are stripped (incl. Remote_User spelling)"
  fi
  if [[ "$prefix" != - ]]; then
    read -r code _ <<<"$(status "https://$DOMAIN${prefix}foo")"
    [[ "$code" == 404 ]] && ok "path boundary: ${prefix}foo is not routed to $prefix (404)" \
                         || bad "path boundary: ${prefix}foo is not routed to $prefix" "got $code"
  fi

  url="${PRIVATE_URLS[0]%% *}"
  for u in "$url" "${ADMIN_URLS[@]}"; do
    read -r code loc <<<"$(status -H 'Accept: text/html' "$u")"
    if [[ "$code" =~ ^30[23]$ && "$loc" == "$AUTH_URL/"* ]]; then ok "$u redirects anonymous users to the login portal"
    elif [[ "$code" == 401 ]]; then ok "$u rejects anonymous users (401)"
    else bad "$u requires login" "got $code ${loc:-}"; fi
  done
  read -r code _ <<<"$(status -H 'Remote-User: alice' -H 'Remote-Groups: admins' "$url")"
  [[ "$code" != 200 ]] && ok "spoofed Remote-User does not bypass login ($code)" || bad "spoofed Remote-User does not bypass login" "got 200"
fi

# ---------------------------------------------------------------------------
section "Login flow"
if [[ -z "${TEST_USER:-}" || -z "${TEST_PASSWORD:-}" ]]; then
  skip "real login" "set TEST_USER and TEST_PASSWORD to enable"
elif ((!HAVE_JQ)); then
  skip "real login" "jq not installed"
else
  jar="$(mktemp)"; trap 'rm -f "$jar"' EXIT
  # The password goes through stdin, not the command line (visible in ps).
  resp="$(jq -nc --arg u "$TEST_USER" --arg p "$TEST_PASSWORD" '{username:$u,password:$p,keepMeLoggedIn:false}' |
          "${CURL[@]}" -c "$jar" -b "$jar" -H 'Content-Type: application/json' --data-binary @- \
            "$AUTH_URL/api/firstfactor" 2>/dev/null)"
  if [[ "$(jq -r '.status // empty' <<<"$resp" 2>/dev/null)" == OK ]]; then
    ok "login as $TEST_USER succeeds"
    if ((EXAMPLE)); then
      read -r url prefix <<<"${PRIVATE_URLS[0]}"
      body="$("${CURL[@]}" -b "$jar" -H 'Remote-User: mallory' "$url" 2>/dev/null)"
      check_routed "$body" "$url" "$prefix" "private (logged in)"
      if grep -qiE "^Remote-User: ${TEST_USER}[[:space:]]*$" <<<"$body"; then ok "backend receives Remote-User: $TEST_USER"
      else bad "backend receives Remote-User: $TEST_USER" "got: $(grep -i '^Remote-User' <<<"$body" | tr -d '\r' | tr '\n' ' ')"; fi
      groups="$(grep -i '^Remote-Groups:' <<<"$body" | cut -d: -f2- | tr -d ' \r')"
      info "Remote-Groups = ${groups:-<none>}"
      for u in "${ADMIN_URLS[@]}"; do
        read -r code _ <<<"$(status -b "$jar" "$u")"
        if [[ ",$groups," == *,admins,* ]]; then
          [[ "$code" == 200 ]] && ok "admin can open $u" || bad "admin can open $u" "got $code"
        else
          [[ "$code" == 403 ]] && ok "non-admin is denied $u (403)" || bad "non-admin is denied $u" "got $code"
        fi
      done
    fi
    [[ "$STARTPAGE" == protected ]] && startpage_content "after login" -b "$jar"

    # Log out the way the portal does, with the start page as target.
    resp="$("${CURL[@]}" -b "$jar" -c "$jar" -H 'Content-Type: application/json' \
              -d "{\"targetURL\":\"$START_URL\"}" "$AUTH_URL/api/logout" 2>/dev/null)"
    [[ "$(jq -r '.data.safeTargetURL // empty' <<<"$resp" 2>/dev/null)" == true ]] \
      && ok "logout accepts $START_URL as redirect target" || bad "logout accepts $START_URL as redirect target" "response: ${resp:-<none>}"
    if ((EXAMPLE)); then
      read -r code _ <<<"$(status -b "$jar" -H 'Accept: text/html' "${PRIVATE_URLS[0]%% *}")"
      [[ "$code" != 200 ]] && ok "after logout, the protected app requires login again ($code)" || bad "after logout, the protected app requires login again" "got 200"
    fi
  else
    bad "login as $TEST_USER succeeds" "response: ${resp:-<none>} (note: repeated failures trigger a temporary ban)"
  fi
fi

# ---------------------------------------------------------------------------
echo
summary="$(green "$PASS passed"), $( ((FAIL)) && red "$FAIL failed" || echo "0 failed"), $( ((WARN)) && yellow "$WARN warnings" || echo "0 warnings"), $SKIP skipped"
echo "Result: $summary"
((FAIL == 0))
