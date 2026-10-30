# Never release a ticket while its remote checkout can still take money.
class PendingPaymentClosure
  def self.call(item)
    attempted = item.provider_ref.present? || item.ticketing_activities.where(action: "prepay_requested").exists?
    return unless attempted && item.amount.to_i.positive?
    case item.payment_provider
    when "wechat"
      setting = WechatPaySetting.find_by(id: item.wechat_pay_setting_id)
      order = setting && WechatPayGateway.query_order(setting, item.id)
      raise TicketItem::InvalidTransition, "暂时无法确认支付状态，请稍后重试" unless order
      if %w[SUCCESS USERPAYING].include?(order["trade_state"])
        raise TicketItem::InvalidTransition, "订单已支付或正在支付，请先刷新支付结果"
      end
      unless order["trade_state"] == "CLOSED" || WechatPayGateway.close_order(setting, item.id)
        raise TicketItem::InvalidTransition, "支付订单暂时无法关闭，请稍后重试"
      end
    when "stripe"
      setting = StripeSetting.find_by(id: item.stripe_setting_id)
      session = setting && StripeGateway.retrieve_checkout_session(setting, item.provider_ref)
      raise TicketItem::InvalidTransition, "暂时无法确认支付状态，请稍后重试" unless session
      if session.payment_status == "paid" || session.status == "complete"
        raise TicketItem::InvalidTransition, "订单已支付，请先刷新支付结果"
      end
      StripeGateway.expire_checkout_session(setting, item.provider_ref) if session.status == "open"
    end
  end
end
