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
      item = find_item(object, by_session: object["id"])
      return unless item&.status == "pending"
      return unless object["payment_status"] == "paid"
      # Verify amount + currency against the order before flipping to paid.
      return record_mismatch(record, item) unless amounts_match?(object, item)

      item.confirm_payment!(txhash: object["payment_intent"])

    when "checkout.session.expired"
      item = find_item(object, by_session: object["id"])
      item.timeout if item&.status == "pending"

    when "charge.refunded"
      item = find_item(object, by_intent: object["payment_intent"])
      return unless item

      finalize_refunds(item, object)

    when "charge.dispute.created"
      item = find_item_by_intent(object["payment_intent"])
      item.transition!(:disputed) if item && %w[succeeded partially_refunded].include?(item.status)

    when "charge.dispute.closed"
      item = find_item_by_intent(object["payment_intent"])
      return unless item&.status == "disputed"

      if object["status"] == "won"
        item.transition!(:succeeded)
      else
        # Lost/conceded: the funds are gone — same outcome as a full refund.
        item.transition!(:refunded)
        item.release_resources!
      end
      # payment_intent.payment_failed: buyer can retry on the same session —
      # no state change, the event is recorded for the audit trail only.
    end
  end

  # Orders are resolved by metadata.ticket_item_id first (survives a lost
  # provider_ref write), then by the stored reference (§2.4).
  def find_item(object, by_session: nil, by_intent: nil)
    metadata_id = object.dig("metadata", "ticket_item_id")
    item = TicketItem.find_by(id: metadata_id) if metadata_id.present?
    item ||= TicketItem.find_by(provider_ref: by_session) if by_session.present?
    item ||= find_item_by_intent(by_intent)
    item
  end

  def find_item_by_intent(intent_id)
    return nil if intent_id.blank?
    TicketItem.find_by(txhash: intent_id, payment_provider: "stripe")
  end

  def amounts_match?(session, item)
    session["amount_total"].to_i >= item.amount.to_i &&
      (item.currency.blank? || session["currency"].to_s.casecmp?(item.currency))
  end

  def record_mismatch(record, item)
    record.update!(error: "amount/currency mismatch for ticket_item #{item.id}")
  end

  # Marks matching pending refunds succeeded and applies the side effects
  # (decision #10): a full refund releases the seat/coupon/count, cancels the
  # participant, and revokes a group-ticket auto-join; partial moves money only.
  def finalize_refunds(item, charge)
    stripe_refund_ids = Array(charge.dig("refunds", "data")).map { |r| r["id"] }
    pending = item.refunds.where(status: "pending")
    pending = pending.where(provider_ref: stripe_refund_ids) if stripe_refund_ids.any?
    return if pending.none?

    pending.each do |refund|
      refund.update!(status: "succeeded")
      if refund.full_refund
        item.transition!(:refunded)
        item.release_resources!
        item.participant&.update!(status: "cancelled", payment_status: "cancelled")
        revoke_group_ticket_membership(item)
      else
        item.transition!(:partially_refunded)
      end
    end
  end

  # Only the plain membership the purchase auto-join created — never an
  # owner/manager role the user holds for other reasons.
  def revoke_group_ticket_membership(item)
    return unless item.ticket_type == "group" && item.group

    item.group.memberships.find_by(user_id: item.user_id, role: "member")&.destroy
  end
end
