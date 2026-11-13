#!/usr/bin/env bash
# Posts a payload file (from card.jq) to the Teams webhook in $TEAMS_WEBHOOK_URL.
# Exits 0 on an HTTP 2xx, 1 otherwise. Never prints the URL: anyone who has it can post to the channel.
#
#   TEAMS_WEBHOOK_URL=... alerts/post.sh payload.json
set -uo pipefail

payload=$1

if [ -z "${TEAMS_WEBHOOK_URL:-}" ]; then
  echo "TEAMS_WEBHOOK_URL not set"
  exit 1
fi

# the URL goes in through curl's config on stdin, so it isn't on the command line either; curl's own error
# messages (which can name the host) are dropped
code=$(printf 'url = "%s"\n' "$TEAMS_WEBHOOK_URL" |
  curl -sS --config - -o /dev/null -w '%{http_code}' --max-time 30 \
    -H 'Content-Type: application/json' --data-binary @"$payload" 2>/dev/null)
code=${code:-000}

if [[ $code == 2?? ]]; then
  echo "Teams post sent: HTTP $code"
  exit 0
fi
echo "Teams post failed: HTTP $code"
exit 1
