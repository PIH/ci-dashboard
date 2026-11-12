# Teams alerts for CI failures and stuck jobs

## Why

When the CI servers go down, the BAs usually find out first, partway through testing, and the medinfo team hears
about it from them. The goal is for the team to hear first.

What we actually want to know is "the CI servers are down". There is no direct signal for that yet, so for now we
alert on the next best things: tracked jobs failing (builds, deploys and smoke tests) and jobs that look stuck. The
user's main worry is noise: too many alerts, and people stop reading them. The scope is intentionally broad for a
first try, and **the user will reassess after it has run for a while**. Expect to narrow it, so keep the rules
easy to change.

## Goals

- Post to the SIS ("PIH EMR - SIS") Teams channel when any tracked job **changes from passing to failing**.
- Post when a tracked job looks **stuck**: queued for more than **10 minutes**, or running for more than
  **30 minutes** (thresholds chosen by the user).
- Post when a failing job **recovers** (passes again), so the channel shows when an outage ends.
- Group everything found in one dashboard update into **one post**. Several suites failing at once is what an outage
  looks like, and it should be one message, not five.
- Catch outages even when no builds are running, since a down server produces no build events.

## Non-goals

- Alerting on every failed run. A job that stays red sends nothing further until it recovers.
- Detecting server outages directly (pinging hosts, runner health). That may come later.
- Making the smoke tests less flaky. That's tracked separately: pihemr-smoke-tests PR #48 is on hold for a known SL flake.
- Email. It was considered and dropped, since GitHub Actions would need a mail account to send through.
- Changing what the dashboard page shows.

## Anti-goals (would make this a failure even if it works)

- Noise: repeated posts for the same ongoing problem, a post every 15 minutes while something stays stuck, or posts
  for things that aren't problems (Disabled jobs, cancelled runs).
- Alerting breaking the dashboard: a Teams outage or a bad webhook must never stop `status.json` from publishing.
- Leaking the webhook URL. Anyone who has it can post to the channel.

## Context: how the dashboard works today

- `.github/workflows/update-status.yml` runs on `repository_dispatch` (`build-status-changed`, sent by each tracked
  repo's `notify-started` / `notify-ci-dashboard` jobs when a build starts and finishes), on pushes to `main`, and on
  `workflow_dispatch`.
- For each tracked repo it fetches the latest run of one workflow (the hard-coded `repos` list) and that run's jobs.
  It leaves out the `notify-*` jobs and marks a job `disabled` when it succeeded with "Puppet apply" skipped (the host
  has `/etc/puppet/build-disabled`). It writes `status.json`.
- It publishes `index.html` + `status.json` by force-pushing a single fresh commit to the `gh-pages` branch (#9). So
  the **previously published `status.json` is always on `gh-pages`**, and the new run can read it.
- The job uses `concurrency: pages-build, cancel-in-progress: true`, so a newer update can cancel an older one
  mid-run.
- Smoke tests are jobs named `smoke-tests / <instance> / smoke-test` inside the EMR distributions' "Build and deploy"
  runs. Smoke-test runs started manually (`smoke-tests.yml` via workflow_dispatch) aren't tracked and must not alert.
  That falls out of the design, since only the tracked workflow is read.
- Normal durations, measured 2026-11-12: the longest tracked job is ZL's smoke tests at up to ~23 min. Everything
  else tracked is well under that.

## Decided

**Destination (user):** a Teams Workflow webhook ("Post to a channel when a webhook request is received") on the SIS
channel. The user created it and a test Adaptive Card was posted successfully on 2026-11-12. The URL is stored as repo
secret **`TEAMS_WEBHOOK_URL`** in PIH/ci-dashboard and must never be printed in logs. The workflow belongs to the
user's personal account, and posts appear as from them "via Workflows". Moving it to a team or service account is a
possible later step, not part of this work.

**What alerts (user):** all tracked jobs (builds, deploys, smoke tests), plus stuck jobs at 10 min queued / 30 min
running.

**Alert on transitions, not states (agreed in discussion):**
- *Newly failing:* a job finished with `failure` and its last known completed result was not `failure` (or it has
  none yet).
- *Recovered:* a job finished with `success` and its last known completed result was `failure`.
- *Stuck:* a job is `queued` past 10 min or `in_progress` past 30 min. **Alert once per job**: identify it by its
  job id, so the same stuck job never alerts twice, and a later run of that job can alert again.
- Never alert on: `cancelled` or `skipped` conclusions, `disabled` jobs, or jobs still in progress within the
  thresholds. These neither alert nor change the job's last known result.
- A job is identified across runs by **repo + branch + job name** (e.g. `zl-emr` + `master` +
  `smoke-tests / zl-ci / smoke-test`). *Builder-check call:* almost all tracked runs are on the default branch.
  Checked since 2026-08-01: the only exceptions are `openmrs-frontend-pihemr` `release-2026-09` (workflow_dispatch)
  and `pihmalawi-emr` `9.1.x` (push). Those are real builds, so they alert like any other, the same way the dashboard
  already shows them. The branch is part of the key so that switching between a release branch and the default branch
  doesn't produce false "newly failing" or "recovered" posts.
- *No longer stuck (builder-check call):* when a job that was alerted as stuck finishes, say so in the next post: "no
  longer stuck (passed)" or, if it failed, "failed after being stuck" (one line, not a separate failure alert). A
  stuck job is the closest signal to "server down", and the channel should see that outage end too.
- *Don't lose failures to a newer run (builder-check call):* the current fetch reads only the latest run, so a
  failure can be replaced by a newer in-progress run before any dashboard update records it. Since a lost alert is
  worse than a duplicate, the alerting logic should also look at each workflow's **latest completed run** when the
  latest run isn't completed. Transitions are only evaluated per job against its last recorded result, so this adds
  no duplicates. This only changes what alerting reads, not what the dashboard shows. It roughly doubles API calls in
  the worst case, which is fine at 17 repos.

**First run / no prior state:** record the current state silently. Don't post a burst of alerts for problems that
already existed.

**One post per update:** collect all newly failing, stuck and recovered jobs from one update into a single Adaptive
Card, with failures and stuck jobs first. Each line gives repo, job name, what happened, and a link to the job
(`html_url`). The card ends with a link to the dashboard (https://pih.github.io/ci-dashboard/). If nothing changed,
post nothing.

**Timed check (agreed):** add a `schedule:` trigger every 15 minutes, so stuck jobs are found even when no build
events arrive.

**Alerting must not block publishing:** if building the card or posting to Teams fails, log a warning (without the URL)
and still publish `status.json`. Order matters, because a lost alert is worse than a duplicate: post the alert
first, then save the new alert state. If the post fails, keep the previous alert state, so the same changes are
found and posted again on the next run.

## Left to the builder

- **Where alert state lives.** "Last known completed result per job" and "stuck job ids already alerted" have to
  persist between runs. `status.json` alone isn't enough: a job that is in progress now hides its last completed
  result. A natural choice is a small `alert-state.json` published to `gh-pages` next to `status.json`, read back at
  the start of each run. Any approach that persists across runs and survives the force-push is fine.
- **Job timestamps.** Stuck detection needs to know when a job was queued. The jobs API has `created_at` and
  `started_at`; add whatever is needed to the fetch (it's fine to also add it to `status.json`).
- **Cancellation and duplicates.** With `cancel-in-progress: true`, a run can be cancelled after posting but before
  saving state, which would repeat that post on the next run. An occasional duplicate is acceptable; a lost alert
  is worse. Either keep the current concurrency and accept that, or change it if there's a simple way to avoid it.
- **Implementation language.** The workflow is bash + `jq` + `gh` today. Keep that unless the transition logic gets
  unwieldy, in which case a small script checked into the repo is fine.
- **Card layout details**, such as emoji, colours, and whether recovered jobs get their own section.
- **Scheduled-workflow caveats.** GitHub delays `schedule` triggers under load and disables them in repos with no
  activity for 60 days. Note this in the README; no workaround needed now.
- **Testing.** There's no test suite. Make the transition logic easy to run locally against sample old/new state
  files, and check it with a few fixtures (new failure, still failing, recovered, stuck, still stuck, no longer
  stuck, disabled, cancelled, first run, failure hidden behind a newer in-progress run, release-branch run, Teams
  post failed). Before turning it on, do a dry run that prints the card instead of posting it.
- **README:** a short section on what alerts, where they go, and how to change the thresholds or turn alerts off.
