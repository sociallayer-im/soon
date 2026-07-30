# The reconciliation loop payments actually trust — webhooks only make it
# faster (design/PAYMENTS_PLAN.md §3.7). Every 5 minutes (GoodJob cron):
# each pending order past reserved_until is checked against Stripe FIRST (a
# payment may have landed while a webhook was lost), then confirmed or
# expired; inventory release stays exactly-once via released_at.
class TicketingSweeperJob < ApplicationJob
  queue_as :stripe

  def perform
    TicketItem.where(status: "pending").where("reserved_until < ?", Time.current).find_each do |item|
      sweep(item)
    rescue => e
      Rails.error.report(e, handled: true, context: { ticket_item_id: item.id })
    end
  end

  private

  def sweep(item)
    if item.payment_provider == "stripe" && item.provider_ref.present?
      setting = StripeSetting.find_by(id: item.stripe_setting_id)
      session = setting && StripeGateway.retrieve_checkout_session(setting, item.provider_ref)
      if session&.payment_status == "paid"
        item.confirm_payment!(txhash: session.payment_intent)
        return
      end
      # Still-open session (clock skew, extended session): give it one more
      # sweep interval rather than expiring a page someone may be paying on.
      if session&.status == "open"
        item.update!(reserved_until: 10.minutes.from_now)
        return
      end
    end

    # Free-with-reservation edge cases and crypto orders share the same
    # expiry; a crypto payment that lands later still verifies through
    # verify_payment, which requires status pending — the buyer simply
    # re-registers. Legacy pending rows with no reserved_until are skipped
    # by the query and left alone.
    item.timeout
  end
end
