#!/usr/bin/env bash
# Runs the alert fixtures: each case dir holds inputs and expected.json.
#   tests/alerts/compute/<case>/{prev.json,snapshot.json,expected.json[,now]}
#   tests/alerts/card/<case>/{events.json,expected.json}
set -uo pipefail
cd "$(dirname "$0")/../.."

DEFAULT_NOW=1762900000
fails=0

check() {  # check <case-name> <expected-file> <command...>
  local name=$1 expected=$2; shift 2
  local actual
  if actual=$("$@" 2>&1) && diff <(jq -S . "$expected") <(echo "$actual" | jq -S .) > /tmp/alerts-diff.$$ 2>&1; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    [ -s /tmp/alerts-diff.$$ ] && sed 's/^/    /' /tmp/alerts-diff.$$ || echo "$actual" | sed 's/^/    /'
    fails=$((fails + 1))
  fi
  rm -f /tmp/alerts-diff.$$
}

for dir in tests/alerts/compute/*/; do
  [ -d "$dir" ] || continue
  now=$DEFAULT_NOW
  [ -f "$dir/now" ] && now=$(cat "$dir/now")
  check "compute/$(basename "$dir")" "$dir/expected.json" \
    jq -n --argjson prev "$(cat "$dir/prev.json")" --slurpfile snap "$dir/snapshot.json" \
      --argjson now "$now" --argjson queued_limit 600 --argjson running_limit 1800 \
      -f alerts/compute.jq
done

for dir in tests/alerts/card/*/; do
  [ -d "$dir" ] || continue
  check "card/$(basename "$dir")" "$dir/expected.json" \
    jq -n --slurpfile ev "$dir/events.json" -f alerts/card.jq
done

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
