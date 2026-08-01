module Federation
  # Drains the outbox under a rate cap. Claims rows with SKIP LOCKED so
  # overlapping sweeps (cron + after_commit kicks) never double-dispatch,
  # and re-queues rows orphaned in `delivering` by a crashed process.
  class SweeperJob < ApplicationJob
    queue_as :federation

    BATCH = ENV.fetch("FEDERATION_SWEEP_BATCH", "30").to_i
    ORPHAN_AFTER = 10.minutes

    def perform
      return unless Federation.enabled?

      # crash recovery: delivering rows older than any plausible HTTP call
      FedDelivery.where(status: "delivering")
                 .where("updated_at < ?", ORPHAN_AFTER.ago)
                 .update_all(status: "pending")

      claimed = FedDelivery.transaction do
        rows = FedDelivery.due.order(:created_at).limit(BATCH).lock("FOR UPDATE SKIP LOCKED").to_a
        FedDelivery.where(id: rows.map(&:id)).update_all(status: "delivering", updated_at: Time.current)
        rows
      end
      claimed.each { |row| DeliveryJob.perform_later(row.id) }
    end
  end
end
