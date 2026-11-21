#!/usr/bin/env bash
# Find which start/end shapes the usage endpoint accepts.
#
# The endpoint returns `code 1, INVALID_PARAM` for a window it does not like.
# The rule, observed 2026-10-27: both bounds must be on a whole hour and the
# span must be a whole number of 86400-second days, with 31 days the maximum.
# Local midnight-to-midnight normally satisfies that — but not across a
# daylight-saving change, whose day is 23 or 25 hours long.
#
#   ./usage-probe.sh --token <userToken>
#
# The bucket width also answers whether hourly granularity exists at all: if a
# one-hour window comes back with bucket=3600, peak/off-peak can be attributed
# exactly. If it still says 86400, only daily totals are available.

set -uo pipefail

TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -z "$TOKEN" ] && { echo "usage: $0 --token <userToken>" >&2; exit 2; }

read -r TZOFF NOW MID MID_NEXT MID_PREV D19 AGO24 AGO6 AGO1 D7 D30 MONTH <<< "$(python3 - <<'PY'
import time, datetime
off = time.localtime().tm_gmtoff
now = int(time.time())
tz = datetime.timezone(datetime.timedelta(seconds=off))
mid = int(datetime.datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
first = int(datetime.datetime.now(tz).replace(day=1, hour=0, minute=0, second=0, microsecond=0).timestamp())
print(off, now, mid, mid + 86400, mid - 86400, mid - 19*86400, now-86400, now-21600, now-3600,
      mid - 6*86400, mid - 29*86400, first)
PY
)"

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36'
BASE='https://platform.deepseek.com/api/v0/usage/by_api_key'
HDR=(-H "Authorization: Bearer $TOKEN"
     -H 'x-client-platform: web'
     -H 'x-client-version: 1.0.0'
     -H 'x-client-bundle-id: com.deepseek.chat'
     -H 'x-client-locale: en_US'
     -H "x-client-timezone-offset: $TZOFF"
     -H 'Accept: application/json'
     -H 'Origin: https://platform.deepseek.com'
     -H 'Referer: https://platform.deepseek.com/usage'
     -H "User-Agent: $UA")

printf 'utc offset %ss\n\n' "$TZOFF"
printf '%-42s %s\n' 'window' 'result'

run() {
  local label="$1" start="$2" end="$3"
  local body
  body="$(curl -sS -m 30 "$BASE/amount?start=$start&end=$end&tz=$TZOFF" "${HDR[@]}" 2>/dev/null)"
  printf '%-42s ' "$label"
  printf '%s' "$body" | python3 -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("non-json: " + raw[:40].replace(chr(10), " "))
    raise SystemExit
code = d.get("code")
if code != 0:
    print("code " + str(code) + " | " + (d.get("msg") or "")[:40])
else:
    bd = (d.get("data") or {}).get("biz_data") or {}
    b = bd.get("bucket")
    n = len(bd.get("models") or [])
    if b:
        print("OK  bucket=" + str(b) + "s (" + str(b // 3600) + "h)  " + str(n) + " models")
    else:
        print("OK  (no bucket field)")
' 2>&1 || echo "(parse failed)"
}

echo "Baseline — the shape the captured HAR used:"
run "midnight-19d .. midnight today" "$D19" "$MID"
run "midnight today .. midnight tomorrow" "$MID" "$MID_NEXT"

echo
echo "Rolling windows:"
run "now-24h .. now" "$AGO24" "$NOW"
run "now-6h .. now"  "$AGO6"  "$NOW"
run "now-1h .. now"  "$AGO1"  "$NOW"

echo
echo "Day-aligned single days:"
run "midnight yesterday .. midnight today" "$MID_PREV" "$MID"

echo
echo "The chart's windows — the three ranges the popover asks for:"
run "7 days   (midnight-6d .. midnight tomorrow)"  "$D7"    "$MID_NEXT"
run "30 days  (midnight-29d .. midnight tomorrow)" "$D30"   "$MID_NEXT"
run "this month (1st .. midnight tomorrow)"        "$MONTH" "$MID_NEXT"

echo
echo "Reading:"
echo "  code 1 INVALID_PARAM means a bound is off a whole hour, the span is not"
echo "    a whole number of days, or the span is longer than 31 days."
echo "  A DST-crossing window of local midnights is exactly that trap: its day"
echo "    is 23 or 25 hours, so a week across it is not a whole number of days."
echo "  bucket=86400 -> daily only; peak/off-peak cannot be split within a day"
echo "  bucket=3600  -> hourly available; exact peak/off-peak attribution possible"
echo "  The chart's windows should all read OK and bucket=86400. It folds"
echo "  buckets onto local days whatever width they come back as, so a"
echo "  surprise bucket=3600 would still draw correctly — just cost more."
