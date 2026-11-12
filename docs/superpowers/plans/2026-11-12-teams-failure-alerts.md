# Teams Failure Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Post to the SIS Teams channel when a tracked CI job starts failing, gets stuck, recovers, or stops being stuck.

**Architecture:** The existing `update-status.yml` loop also writes an alerting "snapshot" (one record per observed job). A pure jq program compares the snapshot with the previous `alert-state.json` (read from `gh-pages`) and outputs the new state and a list of events. A second jq program turns the events into a Teams Adaptive Card. The workflow posts the card, then publishes `alert-state.json` next to `status.json`. It keeps the previous state if the post failed. A 15-minute schedule catches stuck jobs.

**Tech Stack:** GitHub Actions, bash, jq 1.7, gh CLI, curl. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-12-teams-failure-alerts-design.md`

## Global Constraints

- Webhook URL comes only from secret `TEAMS_WEBHOOK_URL`, and it is never echoed, never put in `set -x` output, and never passed on a command line that gets logged.
- Thresholds: queued > **600 s** (10 min), in progress > **1800 s** (30 min). Set them once as workflow `env` (`ALERT_QUEUED_LIMIT_SECONDS`, `ALERT_RUNNING_LIMIT_SECONDS`) so they are easy to change.
- Schedule: `*/15 * * * *`.
- Job key: `"<repo>|<branch>|<job name>"`.
- Failure conclusions: `failure`, `timed_out`, `startup_failure`. Ignored conclusions: `cancelled`, `skipped`, `neutral`, `action_required`, `stale`. `success` counts as passing. Jobs with `disabled: true` are ignored.
- Never block publishing `status.json` on anything alert-related.
- Dashboard page (`index.html`) and the `status.json` shape seen by it are unchanged (adding fields is fine).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Non-standard conclusions** (`timed_out`, `startup_failure`): a job that timed out on a hung server should alert like a failure. Test `timed_out_counts_as_failure` in Task 1.
2. **A stuck job that disappears** because a newer run replaced it, without our ever seeing it finish: the channel should still see it end. Test `stuck_job_replaced` in Task 2.
3. **Queued jobs with no `started_at`**, and statuses `waiting` / `pending` / `requested`: treat them as queued, measured from `created_at`. Test `waiting_status_is_queued` in Task 2.
4. **The webhook secret is missing or empty** (e.g. before the user sets it): no crash. Record the state silently so enabling it later doesn't cause a burst of posts. Test in Task 4 step "no secret".
5. **A Teams post that fails** (non-2xx or network error): the dashboard still publishes, and the alert is retried on the next run. Test in Task 4 step "post failure keeps previous state".

---

## File structure

| File | Responsibility |
|---|---|
| `alerts/compute.jq` (create) | Pure function: previous state + snapshot + now + limits → `{state, events}` |
| `alerts/card.jq` (create) | Pure function: events → Teams webhook payload (Adaptive Card) |
| `alerts/post.sh` (create) | POST a payload file to `$TEAMS_WEBHOOK_URL` and exit non-zero on failure, without printing the URL |
| `tests/alerts/run.sh` (create) | Runs every fixture case for `compute.jq` and `card.jq`, then diffs the actual output against the expected output |
| `tests/alerts/compute/<case>/{prev.json,snapshot.json,expected.json}` (create) | One directory per scenario; `prev.json` may be the literal `null` |
| `tests/alerts/card/<case>/{events.json,expected.json}` (create) | Card fixtures |
| `.github/workflows/update-status.yml` (modify) | Collect the snapshot, read the previous state, run compute, post, publish state, add the schedule and the dry-run input |
| `README.md` (modify) | "Teams alerts" section |

### Data shapes (shared by all tasks)

**Snapshot record** (`snapshot.json` is an array of these):
```json
{"key":"zl-emr|master|smoke-tests / zl-ci / smoke-test","repo":"zl-emr","branch":"master",
 "job_name":"smoke-tests / zl-ci / smoke-test","job_id":130178500472,"status":"completed",
 "conclusion":"failure","disabled":false,"created_at":"2026-11-10T22:35:47Z",
 "started_at":"2026-11-10T22:35:50Z","html_url":"https://github.com/PIH/zl-emr/actions/runs/1/job/2"}
```

**State** (`alert-state.json`):
```json
{"version":1,
 "jobs":{"<key>":{"result":"success|failure","job_id":130178500472}},
 "stuck":{"<job_id as string>":{"key":"…","repo":"…","branch":"…","job_name":"…","html_url":"…"}}}
```

**Event** (`events` is an array of these):
```json
{"type":"failing|recovered|stuck|unstuck","repo":"…","branch":"…","job_name":"…","html_url":"…","detail":"…"}
```
`detail` values: `stuck` → `"queued 14 min"` / `"running 35 min"` (whole minutes, floored). `unstuck` → `"passed"`, `"failed"`, or `"replaced by a newer run"`. `failing` / `recovered` → the conclusion (e.g. `"failure"`, `"timed_out"`, `"success"`).

**compute.jq invocation:**
```bash
jq -n --argjson prev "$(cat prev.json)" --slurpfile snap snapshot.json \
   --argjson now 1762900000 --argjson queued_limit 600 --argjson running_limit 1800 \
   -f alerts/compute.jq
# → {"state": <State>, "events": [<Event>...]}
```
(`$snap[0]` is the array.) The test runner passes `now` = `1762900000` (2025-11-11T22:26:40Z) unless the case dir has a `now` file holding a different integer.

---

### Task 1: compute.jq — failing / recovered transitions and the first run

**Files:**
- Create: `alerts/compute.jq`, `tests/alerts/run.sh`, `tests/alerts/compute/*/`

**Interfaces:**
- Produces: `alerts/compute.jq` with the invocation above, and `tests/alerts/run.sh` (exit 0 = all pass; prints `PASS <case>` / `FAIL <case>` plus a diff).

- [ ] **Step 1: Write `tests/alerts/run.sh`**

For each dir in `tests/alerts/compute/*/`, run the invocation above and compare it with `expected.json` using `diff <(jq -S . expected) <(… | jq -S .)`. Do the same for `tests/alerts/card/*/` with `jq --slurpfile ev events.json -n -f alerts/card.jq` (skip when that dir is empty). Exit 1 if any case fails.

- [ ] **Step 2: Write the fixture cases.** Each is a dir with `prev.json`, `snapshot.json` and `expected.json`. Assertions are the expected `events` and the parts of `state` named:

| Case | prev | snapshot | expected |
|---|---|---|---|
| `first_run_silent` | `null` | one job `failure`, one `success` | `events: []`; `state.jobs` has both with their results and job_ids; `stuck: {}` |
| `newly_failing` | key A `success` | A `failure` (newer job_id) | one `failing` event, detail `"failure"`; `state.jobs[A].result == "failure"` |
| `still_failing_no_event` | A `failure` | A `failure` (newer job_id) | `events: []` |
| `recovered` | A `failure` | A `success` | one `recovered` event, detail `"success"` |
| `new_key_failing_alerts` | `{version:1,jobs:{},stuck:{}}` | A `failure` | one `failing` event (no prior result counts as "not failure") |
| `timed_out_counts_as_failure` | A `success` | A `timed_out` | one `failing` event, detail `"timed_out"`; result `"failure"` |
| `cancelled_ignored` | A `failure` | A `cancelled` | `events: []`; `state.jobs[A]` unchanged |
| `disabled_ignored` | A `failure` | A `success`, `disabled: true` | `events: []`; state unchanged |
| `older_job_ignored` | A `failure`, job_id 200 | A `success`, job_id 100 | `events: []`; state unchanged (guards against re-reading an older completed run) |
| `branch_is_part_of_key` | `pihmalawi-emr\|9.1.x\|build` `failure` | `pihmalawi-emr\|master\|build` `success` | `events: []`; both keys present in state |
| `two_failures_one_update` | A, B `success` | A, B `failure` | two `failing` events, in snapshot order |

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `bash tests/alerts/run.sh`
Expected: every compute case FAILs (`alerts/compute.jq` doesn't exist).

- [ ] **Step 4: Implement `alerts/compute.jq`** for completed jobs only (stuck handling is Task 2). Start from `$prev // {version:1,jobs:{},stuck:{}}`. Process snapshot records in order with `reduce`. When `$prev` is `null`, update the state but emit no events. A completed record changes state only if its conclusion is a failure or `success`, it is not disabled, and its job_id is ≥ the recorded job_id.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `bash tests/alerts/run.sh`
Expected: all compute cases `PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add alerts/compute.jq tests/alerts
git commit -m "Add alert transition logic for failing and recovered jobs"
```

### Task 2: compute.jq — stuck and no-longer-stuck

**Files:**
- Modify: `alerts/compute.jq`
- Create: more `tests/alerts/compute/*/` cases

**Interfaces:**
- Consumes: Task 1's compute.jq and runner.
- Produces: same invocation; `state.stuck` and the `stuck` / `unstuck` events.

- [ ] **Step 1: Write the fixture cases** (`now` = 1762900000 unless noted):

| Case | prev | snapshot | expected |
|---|---|---|---|
| `queued_over_limit` | empty state | job 500 `queued`, created `now-660` s | one `stuck`, detail `"queued 11 min"`; `state.stuck["500"]` set |
| `queued_under_limit` | empty | job 500 `queued`, created `now-540` | `events: []`, `stuck: {}` |
| `running_over_limit` | empty | job 500 `in_progress`, started `now-1860` | one `stuck`, detail `"running 31 min"` |
| `waiting_status_is_queued` | empty | job 500 status `waiting`, `started_at: null`, created `now-700` | one `stuck`, detail `"queued 11 min"` |
| `still_stuck_no_repeat` | `stuck["500"]` set | job 500 still `queued`, created `now-3000` | `events: []`; `stuck["500"]` kept |
| `stuck_then_passed` | `stuck["500"]`, jobs[A] `success` | job 500 `completed` `success` | one `unstuck`, detail `"passed"`; `stuck: {}` |
| `stuck_then_failed_single_line` | `stuck["500"]`, jobs[A] `success` | job 500 `completed` `failure` | **only** one `unstuck` event, detail `"failed"` (no separate `failing`); `jobs[A].result == "failure"` |
| `stuck_job_replaced` | `stuck["500"]` | no record with job_id 500; key A now job 600 `queued`, created `now-60` | one `unstuck`, detail `"replaced by a newer run"`; `stuck: {}` |
| `stuck_on_first_run_silent` | `null` | job 500 `queued`, created `now-900` | `events: []` but `stuck["500"]` recorded (so it won't burst on the next run) |
| `hidden_failure_and_new_run` | A `success`, job_id 100 | A job 200 `completed` `failure` **and** A job 300 `in_progress` started `now-60` | one `failing` event; `jobs[A]` = failure/200 |

- [ ] **Step 2: Run the tests and confirm the new cases fail**

Run: `bash tests/alerts/run.sh` → new cases FAIL, Task 1 cases still PASS.

- [ ] **Step 3: Extend `alerts/compute.jq`.** Statuses `queued`, `waiting`, `pending` and `requested` are measured from `created_at` against `$queued_limit`. `in_progress` is measured from `started_at` against `$running_limit`. Minutes = `floor(seconds / 60)`. A completed record whose job_id is in `stuck` emits `unstuck` (`passed`/`failed`) instead of `failing`/`recovered`, still updates `jobs`, and is removed from `stuck`. After the reduce, any `stuck` id that has no record in the snapshot emits `unstuck` "replaced by a newer run" and is removed. Ignored conclusions remove a stuck entry silently.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `bash tests/alerts/run.sh` → all PASS.

- [ ] **Step 5: Commit**

```bash
git add alerts/compute.jq tests/alerts
git commit -m "Detect stuck jobs and report when they finish"
```

### Task 3: card.jq — Teams Adaptive Card

**Files:**
- Create: `alerts/card.jq`, `tests/alerts/card/*/`

**Interfaces:**
- Consumes: the Event shape.
- Produces: `jq -n --slurpfile ev events.json -f alerts/card.jq` → webhook payload `{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{AdaptiveCard 1.4}}]}`. This is the same envelope as the test that posted successfully on 2026-11-12.

- [ ] **Step 1: Write the fixture cases**
  - `mixed`: events in the order recovered, failing, stuck, unstuck(failed). Expected card body: a title TextBlock, then one TextBlock per event in the order **failing, stuck, unstuck, recovered**, and a final TextBlock `[Open the CI dashboard](https://pih.github.io/ci-dashboard/)`.
  - `all_recovered`: only recovered events. Expected title `"CI: all clear"`.
  - Title when there is any failing/stuck/unstuck-failed event: `"CI: <n> problem(s)"`, where n counts `failing` + `stuck` + `unstuck` with detail `"failed"`. Otherwise `"CI: all clear"`.
  - Event line format: `"<icon> **<repo>** (<branch>): <job_name>: <label> [details](<html_url>)"`. Icons and labels: failing `🔴` `"failing (<detail>)"`. stuck `⏳` `"stuck, <detail>"`. unstuck passed `✅` `"no longer stuck (passed)"`. unstuck failed `🔴` `"failed after being stuck"`. unstuck replaced `ℹ️` `"no longer stuck (replaced by a newer run)"`. recovered `✅` `"recovered"`. Every TextBlock has `"wrap": true`.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `bash tests/alerts/run.sh` → card cases FAIL.

- [ ] **Step 3: Implement `alerts/card.jq`.**

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `bash tests/alerts/run.sh` → all PASS.

- [ ] **Step 5: Commit**

```bash
git add alerts/card.jq tests/alerts/card
git commit -m "Build the Teams card for CI alerts"
```

### Task 4: Wire alerts into update-status.yml

**Files:**
- Create: `alerts/post.sh`
- Modify: `.github/workflows/update-status.yml`

**Interfaces:**
- Consumes: compute.jq and card.jq (invocations above).
- Produces: `alert-state.json` published on `gh-pages`; `alerts/post.sh <payload-file>` (exit 0 on HTTP 2xx, exit 1 otherwise; reads the URL only from `$TEAMS_WEBHOOK_URL`).

- [ ] **Step 1: Implement `alerts/post.sh`.** Use `curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -H 'Content-Type: application/json' --data @"$1" "$TEAMS_WEBHOOK_URL"`. Don't use `set -x`. On failure, print only `Teams post failed: HTTP <code>`.

- [ ] **Step 2: Test `post.sh` locally against a throwaway listener.** Run `python3 -m http.server 8765` in the scratch dir; it answers 501 to POST. Then run `TEAMS_WEBHOOK_URL=http://localhost:8765/x bash alerts/post.sh tests/alerts/card/mixed/expected.json; echo $?`.
Expected: prints `Teams post failed: HTTP 501`, exit status 1, and the URL does not appear in the output.

- [ ] **Step 3: Modify the workflow.**
  - Triggers: add `schedule: - cron: '*/15 * * * *'` and a `workflow_dispatch` input `dry_run` (boolean, default false).
  - `env`: `ALERT_QUEUED_LIMIT_SECONDS: 600`, `ALERT_RUNNING_LIMIT_SECONDS: 1800`.
  - In the fetch loop:
    - Also read the run's `head_branch`.
    - Add `id`, `created_at` and `started_at` to the job fields kept for alerting.
    - Append one snapshot record per job (same `notify-*` filter, same `disabled` rule) to `snapshot.json`.
    - When the latest run's `status` isn't `completed`, also fetch `runs?status=completed&per_page=1`, and append that run's jobs too, older run first.
    - `status.json` is built exactly as today.
  - New step **Compute alerts**, after the fetch:
    - Read the previous state with `curl -fsS https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/gh-pages/alert-state.json`, or `git fetch` the `gh-pages` branch and `git show`. Any failure means prev = `null`.
    - Run compute.jq with `now=$(date +%s)` and write `new-state.json` and `events.json`.
    - Wrap the step so an error only warns and sets prev as the state to publish.
  - New step **Post alert**, `continue-on-error: true`:
    - If there are no events, publish `new-state.json`.
    - Else, build the payload with card.jq.
      - If `dry_run` is true, print the payload and stop the job before publishing. A dry run publishes nothing.
      - If `TEAMS_WEBHOOK_URL` is empty, log `TEAMS_WEBHOOK_URL not set; alerts not sent` and publish `new-state.json` (no secret).
      - Otherwise run `post.sh`: on success publish `new-state.json`; on failure publish the previous state (or nothing if prev was `null`).
  - **Assemble Pages site** also copies the chosen state to `_site/alert-state.json`.
  - Keep `concurrency: cancel-in-progress: true` (the spec accepts an occasional duplicate).

- [ ] **Step 4: Check the YAML and the bash.**
Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/update-status.yml'))" && bash -n alerts/post.sh && bash tests/alerts/run.sh`
Expected: no output from the YAML check or `bash -n`, and all tests PASS.

- [ ] **Step 5: Commit on a branch and push.** Make the branch `teams-failure-alerts` and push it. Do not merge.

```bash
git add alerts/post.sh .github/workflows/update-status.yml
git commit -m "Post Teams alerts for failing and stuck CI jobs"
```

- [ ] **Step 6: Dry run on GitHub.**
Run: `gh workflow run update-status.yml -R PIH/ci-dashboard --ref teams-failure-alerts -f dry_run=true`, then `gh run watch`.
Expected: the run succeeds and `gh-pages` is unchanged (check with `git ls-remote origin gh-pages`, same SHA before and after). The log shows either "no events" or a printed payload. Its snapshot covers all 17 repos (log the count of distinct repos).

### Task 5: README and go-live

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Teams alerts" section to README.md** covering:
  - what alerts (newly failing, stuck at 10/30 min, no longer stuck, recovered; one post per update)
  - where alerts go (SIS channel via the `TEAMS_WEBHOOK_URL` secret, owned by a personal Teams Workflow)
  - how to change the thresholds (the workflow `env`)
  - how to turn alerts off (delete the secret)
  - the dry-run input
  - the schedule caveats (GitHub delays cron under load; scheduled workflows pause after 60 days without repo activity)

- [ ] **Step 2: Commit and open the PR.**

```bash
git add README.md
git commit -m "Document Teams alerts"
gh pr create -R PIH/ci-dashboard --base main --head teams-failure-alerts
```

- [ ] **Step 3: Go-live checklist (needs the user).**
  - The user sets the secret: `! gh secret set TEAMS_WEBHOOK_URL -R PIH/ci-dashboard`.
  - The user merges the PR.
  - The first run on `main` sees no prior state, so it posts nothing and publishes `alert-state.json`. Verify with `curl -s https://pih.github.io/ci-dashboard/alert-state.json | jq '.jobs|length'`, which should be > 0.
