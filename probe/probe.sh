#!/usr/bin/env bash
# Phase 0 probe: discover the real shape of DeepSeek's dashboard usage endpoints.
#
# The dashboard endpoints are undocumented. This dumps their raw JSON so the
# Swift decoders can be written against reality instead of guesswork.
#
# Usage:
#   ./probe.sh --token <userToken> [--api-key <sk-...>]
#
# Get the userToken from platform.deepseek.com -> DevTools -> Application ->
# Local Storage -> `userToken`. It is NOT the sk- API key, and the sk- key
# cannot authenticate the dashboard endpoints.
#
# Output lands in ./out/. Nothing is sent anywhere except DeepSeek.

set -uo pipefail

OUT="$(cd "$(dirname "$0")" && pwd)/out"
TOKEN=""
API_KEY="${DEEPSEEK_API_KEY:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --token)   TOKEN="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# Beijing-anchored date, since the dashboard's month/year params follow it.
BEIJING_NOW="$(TZ=Asia/Shanghai date '+%Y %m %d %H')"
read -r Y M D H <<< "$BEIJING_NOW"
START="$(TZ=UTC date -v-1d '+%s')"
END="$(TZ=UTC date '+%s')"

hr() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# Dump a URL to a file, reporting HTTP status and a short body preview.
# Keeps full fidelity on disk; shows just enough on screen to judge the shape.
probe() {
  local name="$1" url="$2"; shift 2
  local file="$OUT/$name.json"
  local code
  code="$(curl -sS -m 30 -o "$file" -w '%{http_code}' "$url" "$@" 2>"$OUT/$name.err")"

  printf '%-28s HTTP %-4s ' "$name" "$code"
  if [ ! -s "$file" ]; then
    printf '(empty body)\n'
  elif head -c 200 "$file" | grep -qi '<!doctype\|<html'; then
    printf '(HTML, not JSON - bot-blocked or wrong host)\n'
  else
    printf '%s bytes\n' "$(wc -c < "$file" | tr -d ' ')"
  fi
  [ -s "$OUT/$name.err" ] && sed 's/^/    ! /' "$OUT/$name.err"
  return 0
}

hr "Balance (official API - uses the sk- key, not the userToken)"
if [ -n "$API_KEY" ]; then
  probe "balance" "https://api.deepseek.com/user/balance" \
    -H "Authorization: Bearer $API_KEY" -H 'Accept: application/json'
else
  echo "skipped: no --api-key / DEEPSEEK_API_KEY"
fi

if [ -z "$TOKEN" ]; then
  hr "Dashboard endpoints"
  echo "skipped: no --token given (these are the ones we actually need)"
  echo
  echo "Without a token we learn nothing about usage shape. Re-run with --token."
  exit 0
fi

# Shared headers for every dashboard call.
dh=(-H "Authorization: Bearer $TOKEN"
    -H 'x-client-platform: web'
    -H 'Accept: application/json'
    -H 'Origin: https://platform.deepseek.com'
    -H 'Referer: https://platform.deepseek.com/usage'
    -H "User-Agent: $UA")

hr "Dashboard: account summary"
probe "summary" "https://platform.deepseek.com/api/v0/users/get_user_summary" "${dh[@]}"

hr "Dashboard: usage this month (Beijing $Y-$M)"
probe "amount_month" "https://platform.deepseek.com/api/v0/usage/amount?month=$M&year=$Y" "${dh[@]}"
probe "cost_month"   "https://platform.deepseek.com/api/v0/usage/cost?month=$M&year=$Y"   "${dh[@]}"

hr "Dashboard: today"
probe "export_today" "https://platform.deepseek.com/api/v0/usage/export" "${dh[@]}"

hr "Dashboard: by_api_key over the last 24h"
probe "bykey_amount" "https://platform.deepseek.com/api/v0/usage/by_api_key/amount?start=$START&end=$END&tz=2" "${dh[@]}"
probe "bykey_cost"   "https://platform.deepseek.com/api/v0/usage/by_api_key/cost?start=$START&end=$END&tz=2"   "${dh[@]}"

# The decisive question: is per-hour granularity available? If a one-hour
# window returns one bucket, peak/off-peak attribution can be exact. If it
# returns a whole day, we fall back to sampling the balance over time.
hr "Dashboard: HOURLY GRANULARITY TEST (1-hour window)"
probe "hour_window" "https://platform.deepseek.com/api/v0/usage/by_api_key/amount?start=$((END-3600))&end=$END&tz=2" "${dh[@]}"

hr "Result"
echo "Raw responses in $OUT/"
echo
echo "Now check: does hour_window.json contain a single hour or a whole day?"
echo "  one hour  -> exact peak/off-peak attribution is possible"
echo "  whole day -> use the balance-sampling fallback from the plan"
echo
echo "Quick look at today's data:"
[ -s "$OUT/export_today.json" ] && head -c 600 "$OUT/export_today.json"
[ -s "$OUT/amount_month.json" ] && head -c 600 "$OUT/amount_month.json"
echo
