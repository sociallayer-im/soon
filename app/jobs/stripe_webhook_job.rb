# Applies a persisted Stripe webhook event to its order. Idempotent and
# order-tolerant: every transition goes through TicketItem's state machine,
# so a late/duplicate event that would move an order backwards raises or
# no-ops instead of corrupting it (e.g. a success arriving after the sweeper
# expired the order is recorded as an error for reconciliation, not applied).
class StripeWebhookJob < ApplicationJob
  queue_as :stripe

  def perform(event_id)
    record = StripeEvent.find(event_id)
    return if record.processed_at # replayed job after a partial failure

    handle(record)
    record.update!(processed_at: Time.current)
  rescue TicketItem::InvalidTransition => e
    record.update!(processed_at: Time.current, error: e.message)
  end

  private

  def handle(record)
    object = record.payload.dig("data", "object") || {}

    case record.event_type
    when "checkout.session.completed"
      item = find_item(record, object, by_session: object["id"])
      return unless object["payment_status"] == "paid"
      # A paid session whose order is missing or already settled with a
      # DIFFERENT payment is an orphan charge — money taken, no ticket to
      # give. Never transition; flag for manual refund.
      if item.nil?
        # (find_item may already have recorded a setting-mismatch error.)
        record.update!(error: "orphan payment: no matching pending order for session #{object['id']}") if record.error.blank?
        return
      end
      unless item.status == "pending"
        if object["payment_intent"].present? && object["payment_intent"] != item.txhash
          record.update!(error: "orphan payment: session #{object['id']} paid but order #{item.id} already settled via #{item.txhash}")
        end
        return
      end
      # Verify amount + currency against the order before flipping to paid.
      return record_mismatch(record, item) unless amounts_match?(object, item)

      item.confirm_payment!(txhash: object["payment_intent"], source: "webhook")

    when "checkout.session.expired"
      item = find_item(record, object, by_session: object["id"])
      item.timeout(source: "webhook") if item&.status == "pending"

    when "charge.refunded"
      item = find_item(record, object, by_intent: object["payment_intent"])
      return unless item

      finalize_refunds(item, object)

    when "charge.dispute.created"
      item = find_item(record, object, by_intent: object["payment_intent"])
      item.transition!(:disputed, source: "webhook") if item && %w[succeeded partially_refunded].include?(item.status)

    when "charge.dispute.closed"
      item = find_item(record, object, by_intent: object["payment_intent"])
      return unless item&.status == "disputed"

      if object["status"] == "won"
        item.transition!(:succeeded, source: "webhook")
      else
        # Lost/conceded: the funds are gone — same outcome as a full refund,
        # which means the seat goes back too, not just the inventory. It never
        # did: release_resources! decremented the count while the participant
        # stayed "attending", so the attendee list and the counter disagreed.
        holder = item.participant
        item.transition!(:refunded, source: "webhook", reason: "dispute lost")
        item.release_resources!
        item.settle_participant!(holder)
      end
      # payment_intent.payment_failed: buyer can retry on the same session —
      # no state change, the event is recorded for the audit trail only.
    end
  end

  # Orders are resolved by metadata.ticket_item_id first (survives a lost
  # provider_ref write), then by the stored reference (§2.4) — and are ONLY
  # accepted when snapshotted to the SAME stripe_setting whose endpoint
  # received the event. Without that binding, a signed webhook from account A
  # (metadata is attacker-controlled at session creation) could confirm,
  # expire, or "refund" an order whose money lives in account B. Mismatches
  # are recorded for audit and never transition anything.
  def find_item(record, object, by_session: nil, by_intent: nil)
    metadata_id = object.dig("metadata", "ticket_item_id")
    item = TicketItem.find_by(id: metadata_id) if metadata_id.present?
    item ||= TicketItem.find_by(provider_ref: by_session) if by_session.present?
    item ||= TicketItem.find_by(txhash: by_intent, payment_provider: "stripe") if by_intent.present?
    return nil unless item

    unless item.stripe_setting_id == record.stripe_setting_id
      record.update!(error: "setting mismatch: event for setting #{record.stripe_setting_id} referenced order #{item.id} (setting #{item.stripe_setting_id})")
      return nil
    end
    item
  end

  def amounts_match?(session, item)
    session["amount_total"].to_i >= item.amount.to_i &&
      (item.currency.blank? || session["currency"].to_s.casecmp?(item.currency))
  end

  def record_mismatch(record, item)
    record.update!(error: "amount/currency mismatch for ticket_item #{item.id}")
  end

  # Finalizes local pending refunds matched by provider_ref — and refunds
  # with NO local row at all, i.e. issued directly from the Stripe Dashboard,
  # for which a row is created on the fly (attributed to the key's owner).
  # Side effects live in TicketItem#apply_refund_success!.
  def finalize_refunds(item, charge)
    total = item.amount.to_i
    Array(charge.dig("refunds", "data")).each do |stripe_refund|
      refund = item.refunds.find_by(provider_ref: stripe_refund["id"])
      refund ||= item.refunds.where(status: "pending", provider_ref: nil).first&.tap do |r|
        r.update!(provider_ref: stripe_refund["id"]) # our API call lost the response
      end
      refund ||= item.refunds.create!(
        provider_ref: stripe_refund["id"],
        amount: stripe_refund["amount"] || total,
        currency: item.currency || "usd",
        full_refund: charge["amount_refunded"].to_i >= total,
        reason: "issued from Stripe dashboard",
        requested_by_user_id: dashboard_refunder_id(item)
      )
      next if refund.status == "succeeded"

      item.apply_refund_success!(refund, source: "webhook")
    end
  end

  # A dashboard refund was made by whoever holds the Stripe account — the
  # key's owner; fall back to the event owner for legacy rows.
  def dashboard_refunder_id(item)
    StripeSetting.find_by(id: item.stripe_setting_id)&.user_id || item.event&.owner_id || item.user_id
  end
end
