# Daily reverse reconciliation (design/PAYMENTS_PLAN.md §3.7): finds orders
# that are paid locally but refunded/disputed at Stripe — the webhook
# normally catches these, but a key running sweeper-only, a lost delivery,
# or a refund issued straight from the Stripe Dashboard all slip past it.
# Discrepancies are applied through the same finalizer the webhook uses,
# and a per-setting summary line goes to the log as the daily report.
class StripeReconciliationJob < ApplicationJob
  queue_as :stripe

  LOOKBACK = 45.days

  def perform
    scope = TicketItem.where(payment_provider: "stripe", status: %w[succeeded partially_refunded disputed])
                      .where("paid_at > ?", LOOKBACK.ago)
                      .where.not(txhash: nil)
                      .where.not(stripe_setting_id: nil)

    scope.group_by(&:stripe_setting_id).each do |setting_id, items|
      setting = StripeSetting.find_by(id: setting_id)
      next unless setting

      checked = 0
      fixed = 0
      items.each do |item|
        checked += 1
        fixed += 1 if reconcile(setting, item)
      rescue => e
        Rails.error.report(e, handled: true, context: { ticket_item_id: item.id })
      end
      Rails.logger.info(
        "[stripe_reconciliation] setting=#{setting.id} account=#{setting.account_id} " \
        "checked=#{checked} discrepancies_fixed=#{fixed} " \
        "local_paid_sum=#{items.sum { |i| i.amount.to_i }}"
      )
    end
  end

  private

  # Returns true when a discrepancy was found and applied.
  def reconcile(setting, item)
    intent = StripeGateway.retrieve_payment_intent(setting, item.txhash)
    return false unless intent # unreachable key/intent — leave for the log

    charge = intent.latest_charge
    return false unless charge

    if charge.respond_to?(:dispute) && charge.dispute.present? && item.status != "disputed"
      item.transition!(:disputed, source: "reconciliation")
      return true
    end

    refunded = charge.amount_refunded.to_i
    return false unless refunded.positive?

    if refunded >= item.amount.to_i && item.status != "refunded"
      apply_missing_refund(setting, item, charge, full: true)
      true
    elsif refunded < item.amount.to_i && item.status == "succeeded"
      apply_missing_refund(setting, item, charge, full: false)
      true
    else
      false
    end
  end

  def apply_missing_refund(setting, item, charge, full:)
    refund = item.refunds.where(status: "pending").first
    refund ||= item.refunds.create!(
      amount: full ? item.amount.to_i : charge.amount_refunded.to_i,
      currency: item.currency || "usd",
      full_refund: full,
      reason: "found by reconciliation",
      requested_by_user_id: setting.user_id
    )
    item.apply_refund_success!(refund, source: "reconciliation")
  end
end
