# GoodJob runs *inside* the Puma process (execution_mode :async) rather than as
# a separate worker: there is one container (Dockerfile CMD is a bare
# `rails server`) and the job load is a trickle of transactional email, so a
# second process would cost more than it buys.
#
# The important difference from Rails' built-in :async adapter (what this app
# used before) is durability: GoodJob writes every job to the `good_jobs`
# table, so a deploy, crash, or OOM kill re-picks up queued mail instead of
# silently dropping it. The in-process executor is only *where* work runs.
#
# The trade-off to keep in mind: a job hogs a Puma thread's worth of the
# machine, and its DB connection comes out of the same Active Record pool the
# web requests use — see config/database.yml, where the pool is sized for
# web threads + job threads + the notifier's dedicated LISTEN connection.
Rails.application.configure do
  # In test the adapter is :test (config/environments/test.rb) and jobs are
  # asserted, never executed, so the executor must not spin up.
  config.good_job.execution_mode = Rails.env.test? ? :external : :async

  config.good_job.max_threads = ENV.fetch("GOOD_JOB_MAX_THREADS", 5).to_i
  config.good_job.queues = "*"

  # LISTEN/NOTIFY picks jobs up immediately; the poll is only a backstop for a
  # missed notification, so it can be lazy.
  config.good_job.poll_interval = 30

  # Must stay comfortably under the container's SIGTERM grace period, or
  # in-flight jobs get killed mid-execution instead of finishing.
  config.good_job.shutdown_timeout = 20

  # Cron began solely for the ticketing sweeper — the reconciliation loop
  # payments trust (webhooks only make confirmation faster). Runs inside the
  # same single GoodJob thread as everything else; each sweep is a handful of
  # indexed queries when nothing is stale.
  config.good_job.enable_cron = true
  config.good_job.cron = {
    ticketing_sweeper: {
      cron: "*/5 * * * *",
      class: "TicketingSweeperJob",
      description: "Expire stale ticket reservations, confirming against Stripe first"
    },
    poll_auto_close: {
      cron: "*/5 * * * *",
      class: "PollAutoCloseJob",
      description: "Stamp closed_at on polls past their deadline and notify author + voters once"
    },
    stripe_reconciliation: {
      cron: "17 4 * * *", # daily, off-peak
      class: "StripeReconciliationJob",
      description: "Find orders refunded/disputed at Stripe but still paid locally"
    }
  }

  # Keep finished jobs around long enough to answer "did that invite actually
  # go out?", then let GoodJob prune them as later jobs complete.
  config.good_job.preserve_job_records = true
  config.good_job.cleanup_preserved_jobs_before_seconds_ago = 7.days.to_i

  # An error that escapes the job's own retry_on/discard_on is a bug, not
  # something to spin on: record it and leave the row for inspection.
  config.good_job.retry_on_unhandled_error = false
  config.good_job.on_thread_error = ->(exception) { Rails.error.report(exception, handled: false) }
end
