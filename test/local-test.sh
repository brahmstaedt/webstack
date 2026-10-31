#!/usr/bin/env bash
# Runs the complete stack locally, without public DNS or Let's Encrypt, and verifies it.
#
#   test/local-test.sh run           test both installation types, each up + verify + update
#                                    test + down (exit code = test result)
#   test/local-test.sh up [MODE]     start the stack in a throwaway copy; MODE is
#                                      hosts   apps on own hosts private./public.webstack.test,
#                                              public start page (default if MODE is omitted)
#                                      single  only one domain, apps on /private and /public,
#                                              login-protected start page
#   test/local-test.sh verify        run verify.sh as an admin and as a normal user
#   test/local-test.sh update-test   test update.sh: undeployed stacks are skipped, a pulled but
#                                    unapplied image is applied, a failed check rolls back
#   test/local-test.sh down          stop everything, delete volumes and the copy
#
# How it works:
#   - copies the repo to $WORKDIR (default ~/webstack-local-test); the original is not modified
#   - configures the reserved test domain webstack.test via the .env files of the copy
#   - creates a throwaway CA and a *.webstack.test certificate, served by Traefik instead of
#     Let's Encrypt. TLS is still fully verified, against that CA.
#   - creates two test users (testadmin in group admins, testuser in group users)
#   - verify.sh sends all requests to 127.0.0.1 (RESOLVE_IP), so no DNS or /etc/hosts is needed
#
# Requirements: docker with compose plugin, openssl, curl, jq; ports 80 and 443 free.
# It uses its own compose project names (webstack-test-*), so a stopped real installation on
# the same host is left untouched. It cannot run while a real installation is running
# (same ports 80/443 and network name).

set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORKDIR:-$HOME/webstack-local-test}"
DOMAIN=webstack.test

die() { echo "error: $*" >&2; exit 1; }
log() { echo ">> $*"; }

proxy() { docker compose -f "$WORK/proxy/docker-compose.yml" "$@"; }
apps()  { docker compose -f "$WORK/apps/whoami/docker-compose.yml" "$@"; }
startpage() { docker compose -f "$WORK/apps/startpage/docker-compose.yml" "$@"; }

# Waits up to $1 seconds until the command in $2... succeeds.
wait_for() { local t="$1"; shift; for ((i = 0; i < t; i++)); do "$@" && return 0; sleep 1; done; return 1; }
page_lists() { grep -qF "$1" "$WORK/apps/startpage/html/index.html" 2>/dev/null; }
page_lacks() { ! page_lists "$1"; }

make_certs() {
  local d="$1"
  mkdir -p "$d"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -keyout "$d/ca.key" -out "$d/ca.pem" -subj "/CN=webstack local test CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$d/key.pem" -out "$d/cert.csr" -subj "/CN=*.$DOMAIN" 2>/dev/null
  openssl x509 -req -days 30 -in "$d/cert.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" \
    -CAcreateserial -out "$d/cert.pem" -extfile <(printf '%s\n' \
      "subjectAltName=DNS:*.$DOMAIN,DNS:$DOMAIN" \
      "basicConstraints=CA:FALSE" \
      "keyUsage=critical,digitalSignature,keyEncipherment" \
      "extendedKeyUsage=serverAuth") 2>/dev/null
  rm -f "$d/cert.csr" "$d/ca.srl"
  chmod 600 "$d/ca.key"
  chmod 644 "$d/key.pem"   # must be readable by Traefik inside the container; throwaway test key
}

cmd_up() {
  for t in docker openssl curl jq; do command -v "$t" >/dev/null || die "$t is not installed"; done
  [[ -e "$WORK" ]] && die "$WORK exists. Run '$0 down' first."

  log "copying repo to $WORK"
  cp -a "$SRC" "$WORK"
  cd "$WORK"
  rm -rf proxy/authelia/secrets proxy/authelia/data proxy/authelia/config/users_database.yml \
         proxy/.env apps/whoami/.env apps/startpage/.env apps/startpage/html/index.html .git

  # Own compose project names, so the test's containers and volumes (`down -v`!) can never
  # touch those of a real installation on the same host (e.g. its certificate volume).
  sed -i 's/^name: /name: webstack-test-/' proxy/docker-compose.yml apps/*/docker-compose.yml
  grep -q '^name: webstack-test-proxy$' proxy/docker-compose.yml || die "could not rename the compose projects"

  local mode="${1:-hosts}" private_host="" public_host="" private_path="" public_path="" startpage_auth=""
  case "$mode" in
    hosts)  private_host="private.$DOMAIN"; public_host="public.$DOMAIN" ;;
    single) private_path=/private; public_path=/public; startpage_auth=authelia@file ;;
    *)      die "unknown mode '$mode' (hosts|single)" ;;
  esac
  log "configuring $DOMAIN, mode: $mode"
  printf 'DOMAIN=%s\n' "$DOMAIN" > proxy/.env
  printf '%s\n' "DOMAIN=$DOMAIN" "PRIVATE_HOST=$private_host" "PRIVATE_PATH=$private_path" \
                 "PUBLIC_HOST=$public_host" "PUBLIC_PATH=$public_path" > apps/whoami/.env
  printf '%s\n' "DOMAIN=$DOMAIN" "STARTPAGE_AUTH=$startpage_auth" > apps/startpage/.env

  log "creating test CA and *.$DOMAIN certificate"
  make_certs "$WORK/test/certs"
  cp test/tls.yml proxy/traefik/dynamic/zz-local-test-tls.yml
  sed -i 's|^\(\s*\)- ./traefik/dynamic:/etc/traefik/dynamic:ro|&\n\1- ../test/certs:/certs:ro|' proxy/docker-compose.yml
  grep -q '/certs:ro' proxy/docker-compose.yml || die "could not add the certificate mount"

  ./generate-secrets.sh >/dev/null

  log "creating test users"
  local image admin_pw user_pw
  image="$(grep -o 'authelia/authelia:[^ ]*' proxy/docker-compose.yml | head -n1)"
  hash() { docker run --rm "$image" authelia crypto hash generate argon2 --password "$1" | sed -n 's/^Digest: //p'; }
  admin_pw="$(openssl rand -hex 16)"
  user_pw="$(openssl rand -hex 16)"
  cat > proxy/authelia/config/users_database.yml <<EOF
users:
  testadmin:
    displayname: "Test Admin"
    password: '$(hash "$admin_pw")'
    email: testadmin@$DOMAIN
    groups: [admins]
  testuser:
    displayname: "Test User"
    password: '$(hash "$user_pw")'
    email: testuser@$DOMAIN
    groups: [users]
EOF
  grep -q "argon2id" proxy/authelia/config/users_database.yml || die "password hashing failed"
  (umask 077; printf 'ADMIN_PASSWORD=%s\nUSER_PASSWORD=%s\n' "$admin_pw" "$user_pw" > test/credentials.env)

  log "starting proxy stack"
  proxy up -d --wait --wait-timeout 180
  log "starting example app"
  apps up -d --wait --wait-timeout 120
  log "starting start page and its generator (watch.sh, in place of the systemd unit)"
  setsid nohup apps/startpage/watch.sh > test/watch.log 2>&1 < /dev/null &
  echo $! > test/watch.pid
  wait_for 30 page_lists "Example app (public)" || die "start page was not generated, see $WORK/test/watch.log"
  startpage up -d --wait --wait-timeout 60
  sleep 10   # let Traefik pick up routes

  cat <<EOF

Stack is up in $WORK (mode: $mode). Next: $0 verify

To use it in a browser on this machine:
  - add to /etc/hosts:  127.0.0.1 $DOMAIN${private_host:+ $private_host $public_host}
  - import $WORK/test/certs/ca.pem as a trusted CA in the browser (remove it afterwards)
  - start page: https://$DOMAIN/ ($([[ -n "$startpage_auth" ]] && echo "login required" || echo public))
  - open ${private_host:+https://$private_host/ }${private_path:+https://$DOMAIN$private_path/ }(login, /admin for admins only)
    and ${public_host:+https://$public_host/ }${public_path:+https://$DOMAIN$public_path/}
  - users and passwords: $WORK/test/credentials.env (testadmin / testuser)
  - Traefik dashboard: http://127.0.0.1:8080/dashboard/
EOF
}

test_env() {
  [[ -d "$WORK" ]] || die "$WORK does not exist. Run '$0 up' first."
  # DOMAIN and the optional hosts are read by verify.sh from the .env files of the copy
  export RESOLVE_IP=127.0.0.1 CA_FILE="$WORK/test/certs/ca.pem"
}

cmd_verify() {
  test_env
  # shellcheck disable=SC1091
  source "$WORK/test/credentials.env"
  local rc=0
  log "verify as testadmin (group admins)"
  TEST_USER=testadmin TEST_PASSWORD="$ADMIN_PASSWORD" "$WORK/verify.sh" || rc=1
  log "verify as testuser (no admin rights)"
  TEST_USER=testuser TEST_PASSWORD="$USER_PASSWORD" "$WORK/verify.sh" || rc=1

  log "start page follows container changes (watch.sh)"
  apps stop public >/dev/null 2>&1
  if wait_for 20 page_lacks "Example app (public)"; then echo "  PASS  stopped app disappears from the start page"
  else echo "  FAIL  stopped app disappears from the start page"; rc=1; fi
  apps start public >/dev/null 2>&1
  if wait_for 20 page_lists "Example app (public)"; then echo "  PASS  started app reappears on the start page"
  else echo "  FAIL  started app reappears on the start page"; rc=1; fi
  ((rc == 0)) && log "ALL LOCAL TESTS PASSED" || log "LOCAL TESTS FAILED"
  return $rc
}

# PASS/FAIL line for the update test; $1 = condition result (0 = pass), $2 = text
check() { if [[ "$1" == 0 ]]; then echo "  PASS  $2"; else echo "  FAIL  $2"; UPD_RC=1; fi; }

cmd_update_test() {
  test_env
  cd "$WORK"
  UPD_RC=0
  local old new code

  # An app directory that was never deployed (its compose file even fails without its .env):
  # update.sh must leave it alone instead of failing.
  mkdir -p apps/zz-undeployed
  sed 's/^name: .*/name: webstack-test-undeployed/' apps/startpage/docker-compose.yml > apps/zz-undeployed/docker-compose.yml

  docker pull -q traefik/whoami:v1.11 >/dev/null
  docker pull -q traefik/whoami:v1.12 >/dev/null
  old="$(docker image inspect -f '{{.Id}}' traefik/whoami:v1.11)"
  new="$(docker image inspect -f '{{.Id}}' traefik/whoami:v1.12)"
  running() { docker inspect -f '{{.Image}}' "$(apps ps -q public)"; }
  downgrade() { docker tag traefik/whoami:v1.11 traefik/whoami:v1.12; apps up -d --wait >/dev/null 2>&1; }

  log "update test A: an image that was pulled but never applied gets applied"
  downgrade
  docker pull -q traefik/whoami:v1.12 >/dev/null     # tag is new now, the container still runs the old image
  code=0; ./update.sh > test/update-a.log 2>&1 || code=$?   # set -e must not abort on the expected codes
  check $(( code != 0 )) "update.sh exits 0 (got $code, log: test/update-a.log)"
  check "$([[ "$(running)" == "$new" ]]; echo $?)" "the example app runs the current image afterwards"
  check "$(grep -q 'skip apps/zz-undeployed (not deployed)' test/update-a.log; echo $?)" "an undeployed app directory is skipped"

  log "update test B: a failing check after the update rolls back"
  downgrade
  mv verify.sh verify.real.sh
  cat > verify.sh <<'W'
#!/usr/bin/env bash
# TEST WRAPPER: the 2nd call (the check after the update) fails, all others run the real verify.sh
f="$(dirname "$0")/test/verify-calls"; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo $n > "$f"
if [[ $n == 2 ]]; then echo "SIMULATED FAILURE of the check after the update"; exit 1; fi
exec "$(dirname "$0")/verify.real.sh" "$@"
W
  chmod +x verify.sh; rm -f test/verify-calls
  code=0; ./update.sh > test/update-b.log 2>&1 || code=$?   # set -e must not abort on the expected codes
  mv verify.real.sh verify.sh; rm -f test/verify-calls
  check $(( code != 4 )) "update.sh exits 4 (rolled back) (got $code, log: test/update-b.log)"
  check "$([[ "$(running)" == "$old" ]]; echo $?)" "the example app runs the previous image again"

  log "update test C: the next normal run applies the update"
  code=0; ./update.sh > test/update-c.log 2>&1 || code=$?   # set -e must not abort on the expected codes
  check $(( code != 0 )) "update.sh exits 0 (got $code, log: test/update-c.log)"
  check "$([[ "$(running)" == "$new" ]]; echo $?)" "the example app runs the current image"

  rm -rf apps/zz-undeployed
  return $UPD_RC
}

cmd_down() {
  if [[ -d "$WORK" ]]; then
    log "stopping stack and deleting volumes"
    if [[ -f "$WORK/test/watch.pid" ]]; then
      kill -- "-$(cat "$WORK/test/watch.pid")" 2>/dev/null || kill "$(cat "$WORK/test/watch.pid")" 2>/dev/null || true
    fi
    startpage down -v --remove-orphans 2>/dev/null || true
    apps down -v --remove-orphans || true
    proxy down -v --remove-orphans || true
    # Fallback in case a container left files the current user cannot delete
    # (e.g. Authelia running as root when PUID/PGID were not set).
    if ! rm -rf "$WORK" 2>/dev/null; then
      local image
      image="$(grep -o 'image: traefik:[^ ]*' "$WORK/proxy/docker-compose.yml" | head -n1 | cut -d' ' -f2)"
      log "removing container-owned files via $image"
      docker run --rm -v "$WORK:/w" --entrypoint sh "$image" -c 'rm -rf /w/* /w/.[!.]* 2>/dev/null; true'
      rm -rf "$WORK" || die "could not delete $WORK, remove it manually: sudo rm -rf $WORK"
    fi
  fi
  log "clean"
}

case "${1:-}" in
  up)     cmd_up "${2:-hosts}" ;;
  verify) cmd_verify ;;
  update-test) cmd_update_test ;;
  down)   cmd_down ;;
  run)
    rc=0; results=()
    for mode in hosts single; do
      log "===== installation type: $mode ====="
      mrc=0
      # Separate process, so `set -e` stays active inside the setup.
      "$0" up "$mode" || mrc=$?
      ((mrc == 0)) && { "$0" verify || mrc=$?; }
      if ((mrc == 0)); then
        if [[ "$mode" == hosts ]]; then "$0" update-test || mrc=$?
        else
          log "update.sh on an up-to-date installation"
          (test_env; "$WORK/update.sh") > /dev/null 2>&1 && echo "  PASS  update.sh exits 0" || { echo "  FAIL  update.sh exits 0"; mrc=1; }
        fi
      fi
      # A cleanup problem must never hide the test result.
      "$0" down || echo "WARNING: cleanup failed, see above" >&2
      ((mrc == 0)) && results+=("$mode: PASSED") || { results+=("$mode: FAILED"); rc=1; }
    done
    for r in "${results[@]}"; do log "RESULT $r"; done
    exit $rc ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
