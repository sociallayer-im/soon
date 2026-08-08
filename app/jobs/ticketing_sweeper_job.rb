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
    return sweep_wechat(item) if item.payment_provider == "wechat"

    if item.payment_provider == "stripe" && item.provider_ref.present?
      setting = StripeSetting.find_by(id: item.stripe_setting_id)
      session = setting && StripeGateway.retrieve_checkout_session(setting, item.provider_ref)
      # Couldn't ASK Stripe (outage, invalid key) is not the same as "not
      # paid" — expiring here could kill an order whose money already landed.
      # Leave it for the next sweep and log; a permanently unreachable order
      # surfaces through these warnings rather than through a silent expiry.
      if session.nil?
        Rails.logger.warn("[ticketing_sweeper] cannot retrieve session #{item.provider_ref} for ticket_item #{item.id} (setting #{item.stripe_setting_id}) — skipping")
        return
      end
      if session.payment_status == "paid"
        item.confirm_payment!(txhash: session.payment_intent, source: "sweeper")
        return
      end
      # Still-open session (clock skew, extended session): give it one more
      # sweep interval rather than expiring a page someone may be paying on.
      if session.status == "open"
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

  # WeChat needs one step Stripe does not: the order has to be CLOSED. A
  # Checkout Session expires on its own, but a WeChat order stays payable
  # indefinitely — expiring ours without closing theirs is how you release the
  # seat and then receive the money for it anyway.
  def sweep_wechat(item)
    setting = WechatPaySetting.find_by(id: item.wechat_pay_setting_id)
    order = setting && WechatPayGateway.query_order(setting, item.id)

    # nil means we could not ask, which is not evidence of non-payment. Leave
    # it for the next sweep; a permanently unreachable order surfaces as a
    # repeated warning rather than as a silent expiry.
    if order.nil?
      Rails.logger.warn("[ticketing_sweeper] cannot query wechat order #{item.id} (merchant #{item.wechat_pay_setting_id}) — skipping")
      return
    end

    case order["trade_state"]
    when "SUCCESS"
      item.confirm_payment!(txhash: order["transaction_id"], source: "sweeper")
    when "USERPAYING"
      # The buyer is mid-payment (WeChat is awaiting their PIN). Expiring here
      # would release a seat that is about to be paid for.
      item.update!(reserved_until: 10.minutes.from_now)
    else
      # NOTPAY / CLOSED / REVOKED / PAYERROR — close first so it cannot be
      # paid after the seat goes back, THEN expire. Order matters: the reverse
      # leaves a window where the order is free and still payable.
      WechatPayGateway.close_order(setting, item.id)
      item.timeout
    end
  end
end
