# CI Dashboard

A live status dashboard for PIH's GitHub Actions builds — modules, EMR distributions, and
ETL pipelines — grouped by category, showing Passing/Failing/Running at a glance.

**[View the dashboard →](https://pih.github.io/ci-dashboard/)**

Status updates are pushed to this page directly from each tracked repo's build workflow the
moment a build starts or finishes, rather than relying on polling.

## Teams alerts

Each dashboard update also checks for changes worth telling the team about, and posts them as one card to the
SIS ("PIH EMR - SIS") Teams channel:

- 🔴 a tracked job (build, deploy or smoke test) **starts failing**: only on the change from passing to failing,
  not again while it stays red
- ⏳ a job looks **stuck**: queued for more than 10 minutes, or running for more than 30 (once per job)
- ✅ a failing job **recovers**, or a stuck job **finishes**

Cancelled and skipped jobs, and jobs shown as Disabled, never alert. Besides build events, the workflow runs every 15
minutes so stuck jobs are noticed even when no builds are running (e.g. a CI server is down).

**Where they go:** the webhook URL of a Teams Workflow ("Post to a channel when a webhook request is received") on
the channel, stored as the repo secret `TEAMS_WEBHOOK_URL`. The Teams Workflow belongs to the person who created
it, so it stops working if their account does. To point alerts somewhere else, create a new Workflow and replace
the secret: `gh secret set TEAMS_WEBHOOK_URL -R PIH/ci-dashboard`.

**Turning alerts off:** delete the secret. The dashboard keeps updating, and alerts simply aren't sent.

**Changing the thresholds:** `ALERT_QUEUED_LIMIT_SECONDS` and `ALERT_RUNNING_LIMIT_SECONDS` in
`.github/workflows/update-status.yml`.

**Trying a change safely:** run the workflow by hand with **dry run** checked
(`gh workflow run update-status.yml -R PIH/ci-dashboard --ref <branch> -f dry_run=true`). It prints the card it
would post, and publishes nothing.

**How it works:** the last state is kept in `alert-state.json` next to `status.json` on the `gh-pages` branch.
`alerts/compute.jq` compares it with the jobs seen now, `alerts/card.jq` builds the card, and `alerts/post.sh` posts
it. If a post fails, the old state is kept, so the same alert is retried on the next run. Run the tests with
`bash tests/alerts/run.sh`.

GitHub can delay scheduled runs when it is busy, and pauses them in a repo with no activity for 60 days. If the
15-minute checks stop, re-enable the workflow on the Actions tab.

**Removing alerts entirely:** everything was added in one PR, [#10](https://github.com/PIH/ci-dashboard/pull/10).
Its description has step-by-step instructions to back it out and return the dashboard to how it was before.
