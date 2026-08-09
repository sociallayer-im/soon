# Applies a persisted WeChat Pay callback to its order. Same contract as
# StripeWebhookJob: idempotent, order-tolerant, and every state change goes
# through TicketItem's transition table, so a late or duplicated notification
# no-ops or is recorded as an error rather than moving an order backwards.
class WechatPayWebhookJob < ApplicationJob
  queue_as :wechat_pay

  def perform(event_id)
    record = WechatPayEvent.find(event_id)
    return if record.processed_at # replayed job after a partial failure

    handle(record)
    record.update!(processed_at: Time.current)
  rescue TicketItem::InvalidTransition => e
    record.update!(processed_at: Time.current, error: e.message)
  end

  private

  def handle(record)
    resource = record.resource

    case record.event_type
    when "TRANSACTION.SUCCESS"
      confirm_payment(record, resource)
    when "REFUND.SUCCESS"
      finalize_refund(record, resource)
    when "REFUND.ABNORMAL", "REFUND.CLOSED"
      fail_refund(record, resource)
    end
  end

  def confirm_payment(record, resource)
    # trade_state is the merchant-facing verdict; the event type alone is not
    # one. A notification can arrive for a state that is not SUCCESS.
    return record.update!(error: "trade_state #{resource['trade_state']}") unless resource["trade_state"] == "SUCCESS"

    item = find_item(record, resource["out_trade_no"])
    return unless item

    unless item.status == "pending"
      # Already settled. Only worth flagging when a DIFFERENT transaction paid
      # it — that is money taken twice for one seat.
      if resource["transaction_id"].present? && item.txhash.present? && resource["transaction_id"] != item.txhash
        item.record_activity!("callback_rejected", source: "webhook",
          reason: "duplicate payment — money may have been taken twice",
          transaction_id: resource["transaction_id"], settled_via: item.txhash, event_id: record.id)
        record.update!(error: "duplicate payment: #{resource['transaction_id']} paid order #{item.id}, already settled via #{item.txhash}")
      end
      return
    end

    unless amounts_match?(resource, item)
      item.record_activity!("callback_rejected", source: "webhook",
        reason: "amount/currency mismatch",
        expected_amount: item.amount, expected_currency: item.currency,
        received: resource["amount"], event_id: record.id)
      return record.update!(error: "amount/currency mismatch for ticket_item #{item.id}")
    end

    item.confirm_payment!(txhash: resource["transaction_id"], source: "webhook")
  end

  def finalize_refund(record, resource)
    item = find_item(record, resource["out_trade_no"])
    return unless item

    # out_refund_no is the local Refund id — we generated it — so this is an
    # exact match, not a search.
    refund = item.refunds.find_by(id: resource["out_refund_no"])
    unless refund
      # A refund issued from 商户平台 rather than through our API. Record it so
      # the seat, coupon and membership still come back.
      refund = item.refunds.create!(
        amount: resource.dig("amount", "refund").to_i,
        currency: item.currency || "cny",
        full_refund: resource.dig("amount", "refund").to_i >= item.amount.to_i,
        reason: "issued from the WeChat Pay merchant console",
        requested_by_user_id: console_refunder_id(item)
      )
    end
    refund.update!(provider_ref: resource["refund_id"]) if resource["refund_id"].present?
    return if refund.status == "succeeded"

    item.apply_refund_success!(refund, source: "webhook")
  end

  # A refund that WeChat could not complete. The money did not move, so the
  # seat must NOT be released — clearing the pending row is the whole job, and
  # it also frees the one-live-full-refund index so a retry is possible.
  def fail_refund(record, resource)
    item = find_item(record, resource["out_trade_no"])
    refund = item&.refunds&.find_by(id: resource["out_refund_no"])
    return unless refund && refund.status == "pending"

    refund.update!(status: "failed", error: "WeChat reported #{record.event_type} (#{resource['refund_status']})")
    item.record_activity!("refund_failed", source: "webhook",
      reason: "WeChat reported #{record.event_type}", refund_id: refund.id, event_id: record.id)
  end

  # out_trade_no is our own order id — unlike Stripe's metadata it was never
  # attacker-supplied — but the merchant binding still matters: a validly
  # signed callback from merchant A must not settle an order whose money sits
  # with merchant B.
  def find_item(record, out_trade_no)
    return nil if out_trade_no.blank?

    item = TicketItem.find_by(id: out_trade_no, payment_provider: "wechat")
    unless item
      record.update!(error: "no wechat order for out_trade_no #{out_trade_no}")
      return nil
    end
    unless item.wechat_pay_setting_id == record.wechat_pay_setting_id
      record.update!(error: "merchant mismatch: callback for #{record.wechat_pay_setting_id} referenced order #{item.id} (#{item.wechat_pay_setting_id})")
      return nil
    end
    item
  end

  def amounts_match?(resource, item)
    amount = resource["amount"] || {}
    amount["total"].to_i >= item.amount.to_i &&
      (item.currency.blank? || amount["currency"].to_s.casecmp?(item.currency))
  end

  def console_refunder_id(item)
    WechatPaySetting.find_by(id: item.wechat_pay_setting_id)&.user_id || item.event&.owner_id || item.user_id
  end
end
