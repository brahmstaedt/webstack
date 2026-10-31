#!/usr/bin/env bash
# Generates apps/startpage/html/index.html from the labels of all running containers.
#
# A container is listed if it has the label webstack.startpage.name. Optional labels:
#   webstack.startpage.description   one sentence shown below the name
#   webstack.startpage.logo          SVG file in the app's compose directory, e.g. logo.svg
#   webstack.startpage.url           link target; only needed if it can't be derived. Must
#                                    point to DOMAIN or one of the app's own hosts.
#
# Without webstack.startpage.url, the link is derived from the container's Traefik router
# rule: its own host if it has one (https://<host>/), otherwise its sub-path on DOMAIN
# (https://<DOMAIN>/<path>/). Only https:// links are accepted.
#
# The page references nothing outside this server: no web fonts, scripts, stylesheets or
# external images (logos are embedded), and links only to hosts this server serves.
#
# Logos: only a relative path inside the app's own compose directory, ending in .svg, at most
# 100 KB, containing an <svg> element. It is embedded as <img src="data:...">: browsers never
# run scripts of an SVG shown as an image. Apps without (valid) logo get a default logo with
# their initial.
#
# Runs on the host (needs the docker CLI and jq). The web container never gets Docker access.
# All label values are HTML-escaped: on a single-domain installation, an injection here would
# affect every app (see docs/security.md, R11).

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/html"
LOGO_MAX_BYTES=102400

# Reads KEY=value from an env file like Docker Compose does (export prefix, quotes, inline
# comments, CRLF), without executing it.
envval() {
  [[ -f "$1" ]] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$2=//p" "$1" | tail -n1 |
    sed -E 's/\r$//; s/[[:space:]]+#.*$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/[[:space:]]+$//'
}
DOMAIN="${DOMAIN:-$(envval "$root/proxy/.env" DOMAIN)}"
[[ -n "$DOMAIN" ]] || { echo "error: DOMAIN not set (proxy/.env)" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq is not installed" >&2; exit 1; }

mapfile -t ids < <(docker ps -q --filter label=webstack.startpage.name)
if ((${#ids[@]})); then json="$(docker inspect "${ids[@]}")"; else json='[]'; fi

# One JSON object per app: name, description, url, logo (label), dir (compose directory).
apps="$(jq -c --arg d "$DOMAIN" '
  def link:
    .Config.Labels as $l
    | ([$l | to_entries[] | select(.key | test("^traefik\\.http\\.routers\\.[^.]+\\.rule$")) | .value][0] // "") as $rule
    | [$rule | scan("Host\\(`([^`]+)`\\)") | .[0]] as $hosts
    | [$rule | scan("Path\\(`([^`]+)`\\)") | .[0]] as $paths
    | ($l["webstack.startpage.url"] // "") as $override
    | if $override != "" then
        # only hosts served by this server: DOMAIN or the own hosts of this app
        # strict form: https://<host>[/path], no user info (@), no port
        ((($override | capture("^https://(?<h>[A-Za-z0-9.-]+)(/[^\\s\"<>@]*)?$") | .h)) // "") as $oh
        | if ([$d] + $hosts | index($oh)) != null then $override else "" end
      else
        [$hosts[] | select(. != $d or ($paths | length) == 0)] as $own
        | if ($own | length) > 0 then "https://\($own[0])/"
          elif ($paths | length) > 0 then "https://\($d)\($paths[0])/"
          else "" end
      end;
  [ .[]
    | .Config.Labels as $l
    | { name: $l["webstack.startpage.name"],
        description: ($l["webstack.startpage.description"] // ""),
        logo: ($l["webstack.startpage.logo"] // ""),
        dir: ($l["com.docker.compose.project.working_dir"] // ""),
        url: link }
    | select(.url | test("^https://[^\\s\"<>]+$")) ]
  | unique_by(.url)
  | sort_by(.name | ascii_downcase)
  | .[]
' <<<"$json")"

# Prints a data: URI for a valid logo, or nothing.
logo_uri() {
  local dir="$1" rel="$2" file real realdir
  [[ -n "$dir" && -n "$rel" ]] || return 0
  if [[ "$rel" == /* || "$rel" == *..* || "$rel" != *.svg ]]; then
    echo "  logo ignored: '$rel' must be a relative .svg path inside the app directory" >&2; return 0
  fi
  file="$dir/$rel"
  real="$(realpath -e "$file" 2>/dev/null)" || { echo "  logo ignored: $file not found" >&2; return 0; }
  realdir="$(realpath -e "$dir")"
  [[ "$real" == "$realdir"/* && -f "$real" ]] || { echo "  logo ignored: $file is outside $dir" >&2; return 0; }
  (( $(stat -c %s "$real") <= LOGO_MAX_BYTES )) || { echo "  logo ignored: $file is larger than $LOGO_MAX_BYTES bytes" >&2; return 0; }
  grep -qi '<svg' "$real" || { echo "  logo ignored: $file contains no <svg> element" >&2; return 0; }
  printf 'data:image/svg+xml;base64,%s' "$(base64 -w0 "$real")"
}

cards=""
count=0
while IFS= read -r app; do
  [[ -n "$app" ]] || continue
  uri="$(logo_uri "$(jq -r .dir <<<"$app")" "$(jq -r .logo <<<"$app")")"
  cards+="$(jq -r --arg logo "$uri" '
    (.url | sub("^https://"; "") | sub("/$"; "")) as $shown
    | (.name | explode | .[0:1] | implode | ascii_upcase) as $initial
    | "      <li><a class=\"card\" href=\"\(.url | @html)\">"
      + (if $logo != ""
         then "<img class=\"logo\" src=\"\($logo | @html)\" alt=\"\" width=\"52\" height=\"52\">"
         else "<svg class=\"logo default\" viewBox=\"0 0 52 52\" aria-hidden=\"true\"><text x=\"26\" y=\"34\" text-anchor=\"middle\">\($initial | @html)</text></svg>"
         end)
      + "<span class=\"text\"><span class=\"name\">\(.name | @html)</span>"
      + (if .description != "" then "<span class=\"desc\">\(.description | @html)</span>" else "" end)
      + "<span class=\"url\">\($shown | @html)</span></span></a></li>"
  ' <<<"$app")"$'\n'
  count=$((count + 1))
done <<<"$apps"

[[ -n "$cards" ]] || cards='      <li class="empty">No apps are listed yet. Apps appear here once they declare a webstack.startpage.name label.</li>'
domain_html="$(jq -rn --arg d "$DOMAIN" '$d | @html')"
domain_wbr="${domain_html//./.<wbr>}"   # long domains may wrap only after a dot
h1_class=""; ((${#DOMAIN} > 20)) && h1_class=' class="long"'   # smaller headline for long domains
# After logout, return to the start page.
logout_html="$(jq -rn --arg d "$DOMAIN" '"https://\($d)/auth/logout?rd=" + ("https://\($d)/" | @uri) | @html')"
generated="$(date -u '+%Y-%m-%d %H:%M UTC')"

mkdir -p "$out"
tmp="$(mktemp "$out/.index.XXXXXX")"
cat > "$tmp" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex">
  <meta name="color-scheme" content="light dark">
  <title>Apps on $domain_html</title>
  <style>
    /* Contrast (WCAG): text >= 7:1, card and tile edges >= 3:1, in light and dark mode. */
    :root {
      --navy: #0d2b5e;
      --page: #ffffff;
      --band: var(--navy);
      --on-band: #ffffff;
      --card: #ffffff;
      --edge: #7f8fae;
      --edge-strong: var(--navy);
      --text: var(--navy);
      --muted: #3d5073;
      --tile: #e9eff8;
      --focus: #3f80f2;          /* >= 3:1 on white and on the navy band */
      color-scheme: light dark;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --page: #081a3c;
        --band: var(--page);         /* one calm surface: no band in dark mode */
        --card: #12305f;
        --edge: #6c84b4;
        --edge-strong: #ffffff;
        --text: #ffffff;
        --muted: #c9d5ec;
        --focus: #9cc0ff;
      }
    }
    * { box-sizing: border-box; }
    html { background: var(--page); }
    body {
      margin: 0;
      color: var(--text);
      font-family: "Avenir Next", Avenir, "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif;
      font-size: 1rem;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
    }
    .inner { max-width: 60rem; margin-inline: auto; }
    .band { background: var(--band); color: var(--on-band); padding: 3.5rem 1.5rem 6rem; }
    .top { display: flex; justify-content: space-between; align-items: flex-start; gap: 1.5rem; }
    h1 {
      margin: 0;
      font-family: "Avenir Next", Avenir, "Segoe UI Variable Display", "Segoe UI", system-ui, sans-serif;
      font-size: clamp(2rem, 6vw, 3.5rem);
      font-weight: 700;
      line-height: 1.05;
      letter-spacing: -0.025em;
      overflow-wrap: break-word;
    }
    h1.long { font-size: clamp(1.75rem, 5vw, 2.625rem); }
    .lede { margin: .625rem 0 0; font-size: 1.125rem; }
    .logout {
      flex: none;
      color: var(--on-band);
      text-decoration: none;
      padding: .4375rem 1rem;
      border: 1px solid rgba(255, 255, 255, .75);
      border-radius: 999px;
    }
    .logout:hover { background: rgba(255, 255, 255, .12); border-color: #ffffff; }
    main { padding: 0 1.5rem 4rem; }
    .cards {
      list-style: none;
      margin-top: -3.5rem;
      margin-bottom: 0;
      padding: 0;
      display: grid;
      grid-template-columns: 1fr;
      gap: 1rem;
    }
    @media (min-width: 52rem) { .cards { grid-template-columns: 1fr 1fr; gap: 1.25rem; } }
    .card {
      display: flex;
      gap: 1.25rem;
      align-items: flex-start;
      height: 100%;
      padding: 1.5rem;
      background: var(--card);
      border: 1px solid var(--edge);
      border-radius: .75rem;
      color: inherit;
      text-decoration: none;
    }
    .card:hover { border-color: var(--edge-strong); box-shadow: inset 0 0 0 1px var(--edge-strong); }
    .card:focus-visible, .logout:focus-visible { outline: 3px solid var(--focus); outline-offset: 3px; }
    .logo { flex: none; width: 52px; height: 52px; border-radius: 12px; background: var(--tile); }
    img.logo { padding: 7px; object-fit: contain; }
    .default text { fill: var(--navy); font: 600 22px "Avenir Next", Avenir, "Segoe UI", system-ui, sans-serif; }
    .text { display: flex; flex-direction: column; min-width: 0; }
    .name { font-size: 1.1875rem; font-weight: 600; line-height: 1.3; }
    .desc { margin-top: .25rem; color: var(--muted); max-width: 34em; }
    .url { margin-top: .625rem; font-size: .875rem; color: var(--muted); overflow-wrap: anywhere; }
    .empty { grid-column: 1 / -1; padding: 1.5rem; background: var(--card); border: 1px dashed var(--edge); border-radius: .75rem; color: var(--muted); }
    footer { margin-top: 3rem; font-size: .875rem; color: var(--muted); }
    @media (prefers-color-scheme: dark) {
      .band { padding-bottom: 1.5rem; }
      .cards { margin-top: 0; }
      .logout { border-color: var(--edge); }
      .logout:hover { border-color: #ffffff; }
    }
    @media (prefers-reduced-motion: no-preference) {
      .card, .logout { transition: border-color .15s ease, box-shadow .15s ease, background-color .15s ease; }
    }
    @media (max-width: 30rem) {
      .top { flex-direction: column-reverse; gap: 1rem; }
      .logout { align-self: flex-end; padding: .3125rem .875rem; }
      .band { padding: 1.5rem 1.25rem 5rem; }
      main { padding: 0 1rem 3rem; }
      .card { padding: 1.25rem; gap: 1rem; }
    }
    @media (max-width: 30rem) and (prefers-color-scheme: dark) {
      .band { padding-bottom: 1.25rem; }
    }
  </style>
</head>
<body>
  <header class="band">
    <div class="inner top">
      <div>
        <h1$h1_class>$domain_wbr</h1>
        <p class="lede">Apps on this server</p>
      </div>
      <a class="logout" href="$logout_html">Log out</a>
    </div>
  </header>
  <main>
    <ul class="cards inner">
$cards    </ul>
    <footer class="inner">Updated $generated</footer>
  </main>
</body>
</html>
EOF
chmod 644 "$tmp"
mv -f "$tmp" "$out/index.html"   # atomic: nginx never serves a half-written file
echo "start page: $count app(s) -> $out/index.html"
