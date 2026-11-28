module Ticketing
  class PaymentClosure
    def self.check(item, record_payment: true)
      new.check(item, record_payment: record_payment)
    end

    def check(item, record_payment:)
      return :closed if item.amount.to_i.zero?

      case item.payment_provider
      when "stripe" then close_stripe(item, record_payment)
      when "wechat" then close_wechat(item, record_payment)
      else :unresolved
      end
    end

    private

    def close_stripe(item, record_payment)
      return :closed if item.provider_ref.blank?

      setting = StripeSetting.find_by(id: item.stripe_setting_id)
      return :unresolved unless setting

      session = StripeGateway.retrieve_checkout_session(setting, item.provider_ref)
      if session&.status == "open" && session.payment_status != "paid"
        session = StripeGateway.expire_checkout_session(setting, item.provider_ref) ||
          StripeGateway.retrieve_checkout_session(setting, item.provider_ref)
      end
      if session&.payment_status == "paid"
        item.confirm_payment!(txhash: session.payment_intent, source: "sweeper") if record_payment
        :paid
      elsif session&.status == "expired"
        :closed
      else
        :unresolved
      end
    end

    def close_wechat(item, record_payment)
      setting = WechatPaySetting.find_by(id: item.wechat_pay_setting_id)
      return :unresolved unless setting

      trade = WechatPayGateway.query_order(setting, item.id)
      return :unresolved unless trade
      return :closed if trade["order_missing"] || trade["trade_state"] == "CLOSED"

      if trade["trade_state"] == "NOTPAY"
        return :closed if WechatPayGateway.close_order(setting, item.id)

        trade = WechatPayGateway.query_order(setting, item.id)
      end
      if trade&.fetch("trade_state", nil) == "SUCCESS"
        item.confirm_payment!(txhash: trade["transaction_id"], source: "sweeper") if record_payment
        :paid
      elsif trade&.fetch("trade_state", nil) == "CLOSED"
        :closed
      else
        :unresolved
      end
    end
  end
end
