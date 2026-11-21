#!/usr/bin/env bash
# Work out how platform.deepseek.com actually wants the userToken.
#
# The captured HAR was a sanitized export, so it carried no Authorization or
# Cookie header — meaning the auth scheme is inferred from third-party
# projects, not observed. A 40003 response means the token reached DeepSeek and
# was rejected, which is either a bad/expired token or the wrong scheme. This
# tries each plausible scheme against a cheap endpoint and prints the server's
# own code and message for each.
#
#   ./auth-probe.sh --token <userToken>
#
# Nothing is printed except the token's last 4 characters.

set -uo pipefail

TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$TOKEN" ]; then
  echo "usage: $0 --token <userToken>" >&2
  exit 2
fi

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36'
URL='https://platform.deepseek.com/api/v0/users/get_user_summary'
COMMON=(-H 'Accept: application/json'
        -H 'x-client-platform: web'
        -H 'x-client-version: 1.0.0'
        -H 'x-client-bundle-id: com.deepseek.chat'
        -H 'x-client-locale: en_US'
        -H 'x-client-timezone-offset: 7200'
        -H 'Origin: https://platform.deepseek.com'
        -H 'Referer: https://platform.deepseek.com/usage'
        -H "User-Agent: $UA")

printf 'token: ...%s (%s chars)\n\n' "${TOKEN: -4}" "${#TOKEN}"

try() {
  local label="$1"; shift
  local body code msg
  body="$(curl -sS -m 25 "$URL" "${COMMON[@]}" "$@" 2>/dev/null)"
  code="$(printf '%s' "$body" | python3 -c \
    'import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get("code"), "|", (d.get("msg") or "")[:90])
except Exception:
    print("non-json |", sys.stdin.read()[:90] if False else "")' 2>/dev/null)"
  [ -z "$code" ] && code="(empty)"
  printf '  %-34s -> %s\n' "$label" "$code"
  return 0
}

# A cheap, side-effect-free endpoint. Success is code 0.
echo "Auth schemes:"
try "Authorization: Bearer"  -H "Authorization: Bearer $TOKEN"
try "Authorization: raw"     -H "Authorization: $TOKEN"
try "Cookie: userToken="     -H "Cookie: userToken=$TOKEN"
try "Cookie: token="         -H "Cookie: token=$TOKEN"
try "X-Token"                -H "X-Token: $TOKEN"
try "X-User-Token"           -H "X-User-Token: $TOKEN"
try "no auth (control)"      -H 'X-Control: 1'

# Look for an expiry inside the token. Session tokens usually carry one, and
# "expired" produces exactly the same 40003 as "wrong value" — so it is worth
# distinguishing before re-copying anything. Only the decoded timestamp is
# printed, never the token.
echo
echo "Token contents:"
python3 - "$TOKEN" <<'PY'
import sys, base64, json, re, datetime

t = sys.argv[1].strip()
found = False

def scan(raw, label):
    global found
    try:
        text = raw.decode('utf-8', 'ignore')
    except Exception:
        return
    for m in re.finditer(r'\b(1[6-9]\d{8}|20\d{8})\b', text):
        ts = int(m.group(1))
        when = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
        age = datetime.datetime.now(datetime.timezone.utc) - when
        state = 'EXPIRED' if age.total_seconds() > 0 else 'still valid for'
        delta = age if age.total_seconds() > 0 else -age
        print(f"  {label}: timestamp {when:%Y-%m-%d %H:%M UTC} — {state} {delta}".rstrip())
        found = True
    if '"exp"' in text or "'exp'" in text:
        print(f"  {label}: contains an 'exp' claim")
        found = True

# JWT-style: decode the middle segment.
parts = t.split('.')
if len(parts) == 3:
    print("  shape: looks like a JWT (3 dot-separated segments)")
    for seg, name in ((parts[1], 'payload'),):
        try:
            scan(base64.urlsafe_b64decode(seg + '=' * (-len(seg) % 4)), name)
        except Exception:
            pass
else:
    print(f"  shape: opaque, {len(parts)} segment(s), no dots — not a JWT")

# Opaque base64 blob: try to decode the whole thing.
if len(parts) == 1:
    for enc, name in ((base64.b64decode, 'base64'), (base64.urlsafe_b64decode, 'base64url')):
        try:
            scan(enc(t + '=' * (-len(t) % 4)), name)
        except Exception:
            continue

if not found:
    print("  no expiry found (opaque token — expiry cannot be checked locally)")
PY

echo
echo "Reading:"
echo "  code 0        -> that scheme works"
echo "  40002         -> no token reached the server at all"
echo "  40003         -> token reached DeepSeek and was rejected: expired or wrong value"
echo "  same for all  -> the scheme is not the problem; the token value is"
echo "  differs       -> the scheme that returns 0 is the one to use"
echo
echo "If every scheme returns 40003, the value itself is wrong. In DevTools,"
echo "the localStorage entry may be a JSON object rather than a bare string —"
echo "copy the string inside it, not the surrounding braces."
