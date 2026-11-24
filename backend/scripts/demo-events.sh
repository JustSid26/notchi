#!/bin/bash
# Live-demo helper: fires a burst of realistic LIVE events at the backend, including
# retried (duplicate) deliveries, then prints what the heap and the Bloom filter did.
#
#   ./scripts/demo-events.sh            # 40 events, ~30% retried
#   ./scripts/demo-events.sh 200 0.5    # 200 events, ~50% retried
set -euo pipefail
BASE="${NOTCHI_BACKEND:-http://127.0.0.1:7340}"
N="${1:-40}"
DUP="${2:-0.3}"

curl -sf "$BASE/api/health" >/dev/null || { echo "Backend not running on $BASE (start it with: java -jar target/notchi-backend.jar --demo)"; exit 1; }

jobs=(build deploy tests lint docs migrate)
states=(running running running attention failed done)
sent=()
for ((i = 1; i <= N; i++)); do
  if (( ${#sent[@]} > 0 )) && awk -v r="$RANDOM" -v p="$DUP" 'BEGIN { exit !(r / 32767 < p) }'; then
    body="${sent[$((RANDOM % ${#sent[@]}))]}"          # a retry: same event id as before
  else
    job="${jobs[$((RANDOM % ${#jobs[@]}))]}"
    state="${states[$((RANDOM % ${#states[@]}))]}"
    progress=$(awk -v r="$RANDOM" 'BEGIN { printf "%.2f", r / 32767 }')
    body="{\"eventId\":\"evt-$i\",\"id\":\"$job\",\"title\":\"$job\",\"state\":\"$state\",\"progress\":$progress,\"ttl\":120}"
    sent+=("$body")
  fi
  verdict=$(curl -s -X POST "$BASE/api/live/events" -H 'Content-Type: application/json' -d "$body" \
            | sed -E 's/.*"verdict":"([^"]+)".*/\1/')
  printf '%3d  %-26s %s\n' "$i" "$verdict" "$(echo "$body" | sed -E 's/.*"eventId":"([^"]+)".*"id":"([^"]+)".*"state":"([^"]+)".*/\1 \2 \3/')"
done

echo
echo "LIVE queue (most urgent first):"
curl -s "$BASE/api/live?limit=10" | sed -E 's/\},\{/}\n{/g' | sed -E 's/.*"id":"([^"]+)".*"state":"([^"]+)".*/  \2  \1/' | grep -v algorithm || true
echo
echo "Duplicate screening:"
curl -s "$BASE/api/stats" | tr ',' '\n' | grep -E '"(received|duplicatesDropped|exactLookupsSkipped|falsePositives|bits|hashes|fillRatio|expectedFalsePositiveRate)"' | sed 's/^/  /'
