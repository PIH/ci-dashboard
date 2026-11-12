# Works out which CI alerts to send, from the previous alert state and a snapshot of the jobs seen now.
#
#   jq -n --argjson prev <state or null> --slurpfile snap snapshot.json \
#      --argjson now <epoch seconds> --argjson queued_limit <s> --argjson running_limit <s> -f alerts/compute.jq
#
# Output: {state: <new state>, events: [<event>...]}. See
# docs/superpowers/plans/2026-11-12-teams-failure-alerts.md for the shapes. With no previous state (first run) the
# state is recorded but no events are emitted, so turning alerts on doesn't post every existing problem.

def failure_conclusions: ["failure", "timed_out", "startup_failure"];

# the result a completed job counts as: "failure", "success", or null (ignored, e.g. cancelled or skipped)
def result_of($rec):
  if $rec.disabled then null
  elif ($rec.conclusion as $c | failure_conclusions | index($c)) then "failure"
  elif $rec.conclusion == "success" then "success"
  else null end;

def event($type; $rec; $detail):
  {type: $type, repo: $rec.repo, branch: $rec.branch, job_name: $rec.job_name, html_url: $rec.html_url,
   detail: $detail};

($prev == null) as $first_run
| ($prev // {version: 1, jobs: {}, stuck: {}}) as $start
| reduce ($snap[0][] | select(.status == "completed")) as $rec ({state: $start, events: []};
    result_of($rec) as $result
    | .state.jobs[$rec.key] as $known
    | if $result == null or ($known != null and $rec.job_id < $known.job_id) then .
      else
        ($known.result // null) as $before
        | .state.jobs[$rec.key] = {result: $result, job_id: $rec.job_id}
        | if $result == "failure" and $before != "failure" then .events += [event("failing"; $rec; $rec.conclusion)]
          elif $result == "success" and $before == "failure" then .events += [event("recovered"; $rec; $rec.conclusion)]
          else . end
      end)
| if $first_run then .events = [] else . end
