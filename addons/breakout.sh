#!/usr/bin/env bash
# breakout.sh — Sandbox breakout-defense probe for add-on 05.
#
# Runs the published Claude Code network-isolation bypass techniques
# (CVE-2025-66479 config-semantics bug + the SOCKS5 hostname null-byte
# injection, credit: Aonan Guan) against the sbx egress boundary and
# reports whether each one is CONTAINED.
#
# IMPORTANT: this script must run INSIDE a sandbox — it probes that
# sandbox's own egress proxy from within the VM. Run it via:
#
#   sbx exec -w "$(pwd)" demo-agent -- bash addons/breakout.sh
#
# or drop into the sandbox and run it directly. It makes only outbound
# probes and reads env vars; it changes nothing.
#
# Optional overrides:
#   BLOCKED_HOST   a host you expect to be denied (default: example.com)
#   ALLOWED_HOST   a host you expect to be allowed (default: github.com)
#   ALLOWED_SUFFIX allowlisted suffix for the smuggle test (default: github.com)

set -u

BLOCKED_HOST="${BLOCKED_HOST:-example.com}"
ALLOWED_HOST="${ALLOWED_HOST:-github.com}"
ALLOWED_SUFFIX="${ALLOWED_SUFFIX:-github.com}"

pass=0; fail=0
ok()   { printf '  \033[32m✓ CONTAINED\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗ BYPASSED \033[0m  %s\n' "$1"; fail=$((fail+1)); }
info() { printf '                %s\n' "$1"; }

hr() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# HTTP status via the proxy (curl honours HTTPS_PROXY from the sandbox env).
http_code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null; }

# Raw CONNECT to the egress proxy; prints the proxy's status line only.
# The literal token \x00 in the spec is turned into a REAL null byte inside
# Python — never via the shell, whose command substitution strips nulls.
connect_status() {
  local spec="$1"
  python3 - "$spec" <<'PY' 2>/dev/null
import os,socket,sys,re
authority=sys.argv[1].replace("\\x00","\x00")   # real NUL only where \x00 appears
proxy=os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or "http://gateway.docker.internal:3128"
host,port=re.sub(r'^https?://','',proxy).split(":")
try:
    s=socket.create_connection((host,int(port)),timeout=10)
    s.sendall((f"CONNECT {authority} HTTP/1.1\r\nHost: x\r\n\r\n").encode("latin-1"))
    print(s.recv(256).split(b"\r\n",1)[0].decode("latin-1","replace"))
    s.close()
except Exception as e:
    print(f"proxy-error: {e}")
PY
}

echo "================================================================"
echo " sbx breakout-defense probe   (sandbox: ${SANDBOX_NAME:-$(hostname)})"
echo " Techniques: CVE-2025-66479 + SOCKS5 null-byte bypass (A. Guan)"
echo "================================================================"

# ---------------------------------------------------------------------------
hr "0. Baseline — default-deny is the floor (defeats Finding 1's 'allow-all')"
code="$(http_code "https://${BLOCKED_HOST}")"
info "GET https://${BLOCKED_HOST} -> HTTP ${code}"
[ "$code" = "403" ] && ok "blocked host denied by default — no 'empty allowlist = allow everything' footgun" \
                     || bad "blocked host returned ${code}, expected 403"
code="$(http_code "https://${ALLOWED_HOST}")"
info "GET https://${ALLOWED_HOST} -> HTTP ${code}  (control: an allowlisted host still works)"

# ---------------------------------------------------------------------------
hr "1. The exploit's transport is absent — no SOCKS5 channel to attack"
if env | grep -qiE '^(all_proxy|ALL_PROXY)=' || env | grep -qi 'socks'; then
  bad "a SOCKS proxy is exposed to the agent: $(env | grep -iE 'all_proxy|socks')"
else
  ok "no ALL_PROXY / socks5h:// endpoint — Finding 2's reproducer has nothing to connect to"
  info "egress is an HTTP-CONNECT proxy: ${HTTPS_PROXY:-unset}"
fi

# ---------------------------------------------------------------------------
hr "2. Parser-differential canonicalization at the trust boundary"
for spec in "${BLOCKED_HOST}\\x00.${ALLOWED_SUFFIX}:443" "${BLOCKED_HOST}%00.${ALLOWED_SUFFIX}:443"; do
  status="$(connect_status "$spec")"
  info "CONNECT <${spec}> -> ${status}"
  case "$status" in
    *400*) ok "null-byte / percent-null authority rejected (the isValidHost() seam)";;
    *200*) bad "proxy accepted a null-byte authority — investigate";;
    *)     info "     (unexpected: ${status})";;
  esac
done

# ---------------------------------------------------------------------------
hr "3. Suffix-smuggle end-to-end — does the blocked host actually get dialed?"
smug="https://${BLOCKED_HOST}..${ALLOWED_SUFFIX}/"
code="$(http_code "$smug")"
info "GET ${smug} -> HTTP ${code}"
[ "$code" = "403" ] || [ "$code" = "000" ] \
  && ok "suffix trick never reaches ${BLOCKED_HOST} — enforcement is on the real destination" \
  || bad "suffix trick returned ${code} — verify it did not reach ${BLOCKED_HOST}"

# ---------------------------------------------------------------------------
hr "4. Cloud metadata endpoint — a top exfil target in the writeup"
code="$(http_code "http://169.254.169.254/latest/meta-data/")"
info "GET http://169.254.169.254/ -> HTTP ${code}"
[ "$code" = "403" ] || [ "$code" = "000" ] \
  && ok "IMDS unreachable from the sandbox" \
  || bad "metadata endpoint returned ${code}"

# ---------------------------------------------------------------------------
hr "5. The payoff is gone — nothing worth exfiltrating lives in the VM"
info "ANTHROPIC_API_KEY = [${ANTHROPIC_API_KEY:-}]   (proxy-injected on the wire, never in the box)"
info "GH_TOKEN          = ${GH_TOKEN:-<unset>}   (decoy placeholder, not a real token)"
[ -z "${ANTHROPIC_API_KEY:-}" ] && ok "model API key absent inside the VM" \
                                || bad "ANTHROPIC_API_KEY is populated in the VM"
case "${GH_TOKEN:-}" in
  *sbxproxymanaged*|proxy-managed|"") ok "GitHub token in the VM is a decoy — real token stays on the host";;
  gho_*|ghp_*)                        bad "a real-looking GitHub token is present in the VM";;
  *)                                  info "GH_TOKEN value not recognised — inspect manually";;
esac
[ -d "$HOME/.aws" ]        && bad "~/.aws exists in the VM"        || ok "~/.aws not mounted"
[ -d "$HOME/.config/gh" ]  && bad "~/.config/gh exists in the VM"  || ok "~/.config/gh not mounted"

echo
echo "================================================================"
printf ' Result: \033[32m%d contained\033[0m, \033[31m%d bypassed\033[0m\n' "$pass" "$fail"
echo "================================================================"
[ "$fail" -eq 0 ]
