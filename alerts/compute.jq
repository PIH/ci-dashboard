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

def queued_statuses: ["queued", "waiting", "pending", "requested"];

def seconds_since($ts): $now - ($ts | fromdateiso8601);

# for a job that hasn't finished: "queued 11 min" / "running 31 min" if it is past its limit, else null
def stuck_detail($rec):
  if ($rec.status as $s | queued_statuses | index($s)) then
    seconds_since($rec.created_at) as $s
    | if $s > $queued_limit then "queued \($s / 60 | floor) min" else null end
  elif $rec.status == "in_progress" and $rec.started_at != null then
    seconds_since($rec.started_at) as $s
    | if $s > $running_limit then "running \($s / 60 | floor) min" else null end
  else null end;

# a finished job: update its last known result, and report it as failing / recovered, or, if it had been reported
# stuck, as no longer stuck (one line either way)
def completed($rec):
  result_of($rec) as $result
  | ($rec.job_id | tostring) as $id
  | (.state.stuck[$id] != null) as $was_stuck
  | .state.stuck |= del(.[$id])
  | .state.jobs[$rec.key] as $known
  | if $result == null or ($known != null and $rec.job_id < $known.job_id) then .
    else
      ($known.result // null) as $before
      | .state.jobs[$rec.key] = {result: $result, job_id: $rec.job_id}
      | if $was_stuck then .events += [event("unstuck"; $rec; if $result == "failure" then "failed" else "passed" end)]
        elif $result == "failure" and $before != "failure" then .events += [event("failing"; $rec; $rec.conclusion)]
        elif $result == "success" and $before == "failure" then .events += [event("recovered"; $rec; $rec.conclusion)]
        else . end
    end;

# an unfinished job: report it once when it goes past its limit
def unfinished($rec):
  ($rec.job_id | tostring) as $id
  | stuck_detail($rec) as $detail
  | if $detail == null or .state.stuck[$id] != null or $rec.disabled then .
    else
      .state.stuck[$id] = {key: $rec.key, repo: $rec.repo, branch: $rec.branch, job_name: $rec.job_name,
                           html_url: $rec.html_url}
      | .events += [event("stuck"; $rec; $detail)]
    end;

($prev == null) as $first_run
| ($prev // {version: 1, jobs: {}, stuck: {}}) as $start
| ($snap[0] | map(.job_id | tostring)) as $seen
| reduce $snap[0][] as $rec ({state: $start, events: []};
    if $rec.status == "completed" then completed($rec) else unfinished($rec) end)
# stuck jobs that are no longer in the snapshot were replaced by a newer run before we saw them finish
| reduce (.state.stuck | to_entries[] | select(.key as $id | $seen | index($id) | not)) as $gone (.;
    .state.stuck |= del(.[$gone.key])
    | .events += [$gone.value | {type: "unstuck", repo, branch, job_name, html_url,
                                 detail: "replaced by a newer run"}])
| if $first_run then .events = [] else . end
