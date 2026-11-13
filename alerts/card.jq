# Turns the events from compute.jq into a Teams webhook payload (an Adaptive Card).
#
#   jq -n --slurpfile ev events.json -f alerts/card.jq
#
# Problems are listed first (failing, stuck, no longer stuck), then recoveries.

def order: {failing: 0, stuck: 1, unstuck: 2, recovered: 3}[.type];

def is_problem: .type == "failing" or .type == "stuck" or (.type == "unstuck" and .detail == "failed");

def icon_and_label:
  if .type == "failing" then ["🔴", "failing (\(.detail))"]
  elif .type == "stuck" then ["⏳", "stuck, \(.detail)"]
  elif .type == "unstuck" and .detail == "failed" then ["🔴", "failed after being stuck"]
  elif .type == "unstuck" and .detail == "passed" then ["✅", "no longer stuck (passed)"]
  elif .type == "unstuck" then ["ℹ️", "no longer stuck (\(.detail))"]
  else ["✅", "recovered"] end;

def line: icon_and_label as [$icon, $label]
  | "\($icon) **\(.repo)** (\(.branch)): \(.job_name): \($label) [details](\(.html_url))";

def text_block: {type: "TextBlock", text: ., wrap: true};

def is_good: .type == "recovered" or (.type == "unstuck" and .detail == "passed");

def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

# The title counts what this post reports, e.g. "CI: 3 problems, 1 recovered". It never says "all clear": other jobs
# reported earlier may still be failing.
$ev[0] as $events
| ($events | map(select(is_problem)) | length) as $problems
| ($events | map(select(is_good)) | length) as $good
| (($events | length) - $problems - $good) as $other
| ([ (if $problems > 0 then plural($problems; "problem") else empty end),
     (if $good > 0 then "\($good) recovered" else empty end),
     (if $other > 0 then plural($other; "update") else empty end) ]
   | "CI: " + join(", ")) as $title
| {
    type: "message",
    attachments: [{
      contentType: "application/vnd.microsoft.card.adaptive",
      content: {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        type: "AdaptiveCard",
        version: "1.4",
        body: (
          [{type: "TextBlock", size: "Medium", weight: "Bolder", text: $title, wrap: true}]
          + ($events | sort_by(order) | map(line | text_block))
          + ["[Open the CI dashboard](https://pih.github.io/ci-dashboard/)" | text_block]
        )
      }
    }]
  }
