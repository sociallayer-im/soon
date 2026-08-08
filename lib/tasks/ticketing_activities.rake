namespace :ticketing do
  # Reconstructs history for orders that predate ticketing_activities, so the
  # timeline is not blank for everything sold before it existed.
  #
  # Every row it writes is marked `source: "backfill"`. That marker is the
  # point: these are DERIVED from timestamps, not observed, and they inherit
  # every weakness the derivation has —
  #
  #   - `updated_at` is the last write of any kind, so an expiry or
  #     cancellation time is approximate.
  #   - A dispute lost at the provider is indistinguishable from a voluntary
  #     refund, so both are emitted as refund_succeeded.
  #   - Retries, rejected callbacks and prepay re-issues left no trace at all
  #     and cannot be recovered.
  #
  # Anything reasoning about evidence should use Ticketing::Activity.recorded,
  # which excludes these.
  #
  # Idempotent: an order that already has activity rows is skipped, so a
  # partial run can simply be repeated.
  desc "Backfill ticketing_activities for orders created before it existed"
  task backfill: :environment do
    dry_run = ENV["DRY_RUN"] == "true"
    # No .order here: find_each batches by primary key and ignores one
    # (Rails 8 warns about it). Ordering would not matter anyway — each order's
    # rows are derived independently and carry their own timestamps.
    scope = TicketItem.left_joins(:ticketing_activities)
                      .where(ticketing_activities: { id: nil })
                      .includes(:refunds)

    total = scope.count
    puts "#{total} order(s) without history#{' (dry run)' if dry_run}"
    written = 0

    scope.find_each do |item|
      rows = derive(item)
      written += rows.length
      next if dry_run

      Ticketing::Activity.transaction do
        rows.each { |row| Ticketing::Activity.create!(row.merge(subject: item, source: "backfill")) }
      end
    end

    puts "#{dry_run ? 'would write' : 'wrote'} #{written} activity row(s)"
  end

  # One order's derivable past, oldest first.
  def derive(item)
    rows = []
    money = { provider: item.payment_provider, amount: item.amount, currency: item.currency }

    rows << { action: "order_placed", created_at: item.created_at, metadata: money }
    rows << { action: "payment_confirmed", to_status: "succeeded", created_at: item.paid_at, metadata: money } if item.paid_at

    item.refunds.order(:created_at).each do |refund|
      rows << {
        action: "refund_requested", created_at: refund.created_at, actor_user_id: refund.requested_by_user_id,
        reason: refund.reason, metadata: { refund_id: refund.id, amount: refund.amount, currency: refund.currency }
      }
      case refund.status
      when "succeeded"
        rows << {
          action: "refund_succeeded", to_status: item.status, created_at: refund.updated_at,
          metadata: { refund_id: refund.id, amount: refund.amount }
        }
      when "failed"
        rows << {
          action: "refund_failed", created_at: refund.updated_at, reason: refund.error,
          metadata: { refund_id: refund.id }
        }
      end
    end

    # Approximate by construction: updated_at is the last write of any kind.
    if %w[timeout cancelled].include?(item.status)
      rows << {
        action: item.status == "timeout" ? "order_expired" : "order_cancelled",
        to_status: item.status, created_at: item.updated_at, metadata: money
      }
    end
    rows << { action: "inventory_released", created_at: item.released_at, metadata: {} } if item.released_at

    rows.sort_by { |row| row[:created_at] }
  end
end
