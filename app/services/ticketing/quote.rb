module Ticketing
  # The single pricing source for both the preview endpoint (coupon_price)
  # and checkout (rsvp → build_paid_ticket_item). The two MUST agree — a
  # quote the checkout later rejects means a buyer saw a price they can't
  # pay (design/PAYMENTS_PLAN.md §3.4.5).
  #
  # Returns a Result: on success `amount`/`chain`/`coupon`/`discount_*` are
  # set; on failure `error` carries the user-facing message.
  class Quote
    Result = Struct.new(:amount, :chain, :coupon, :discount_value, :discount_data, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    # paymethod        — the PaymentMethod being charged
    # requested_chain  — buyer's chain choice (required for multi-chain methods
    #                    when require_chain)
    # coupon / coupon_code + event — either a preloaded Coupon or a code to
    #                    resolve within the event
    # ticket           — scope for applicable_ticket_ids; defaults to the
    #                    paymethod's own ticket
    # base_amount      — override the price (the preview endpoint quotes an
    #                    arbitrary amount); defaults to paymethod.price
    def self.call(paymethod:, requested_chain: nil, require_chain: false,
                  coupon: nil, coupon_code: nil, event: nil, ticket: nil, base_amount: nil)
      # Resolve the chain first: coupon amount-scaling depends on it, and for
      # multi-chain methods paymethod.chain is blank.
      if paymethod.chains.present?
        if requested_chain.present?
          return failure("chain not supported by this payment method") unless paymethod.chains.include?(requested_chain)
          chain = requested_chain
        elsif require_chain
          return failure("chain not supported by this payment method")
        end
      else
        chain = paymethod.chain
      end

      amount = (base_amount || paymethod.price).to_i
      discount_value = discount_data = nil

      if coupon.nil? && coupon_code.present?
        coupon = Coupon.find_by(selector_type: "code", event_id: event&.id, code: coupon_code)
        return failure("coupon not found") unless coupon
      end

      if coupon
        scope_ticket = ticket || (paymethod.item if paymethod.item_type == "Ticket")
        return failure("coupon not applicable to this ticket") if scope_ticket && !coupon.applicable_to?(scope_ticket)
        return failure("coupon is not available") unless coupon.available?

        amount, discount_value, discount_data = coupon.get_discounted_price(amount, paymethod, chain: chain)
      end

      # Fiat floor (PaymentMethod::MIN_PRICE): creation already holds the base
      # price to it, so landing in (0, min) here means a coupon discounted into
      # the gap — reject; exactly 0 is the valid free path. The floor is
      # per-rail, not one number: it exists to cover a fixed per-charge fee,
      # and a rail without one has no reason to refuse small amounts.
      rail = fiat_rail(paymethod, chain)
      if rail && amount.positive? && amount < PaymentMethod::MIN_PRICE.fetch(rail)
        return failure(coupon ? "coupon not applicable to this payment method" : "amount is below the minimum for this payment method")
      end

      Result.new(amount: amount, chain: chain, coupon: coupon,
                 discount_value: discount_value, discount_data: discount_data)
    end

    def self.failure(message) = Result.new(error: message)

    # Which fiat rail this quote is priced on, or nil for a crypto quote.
    # The resolved chain wins; only when there is none (the preview endpoint
    # quotes without a chain choice) does the method's own rail stand in.
    def self.fiat_rail(paymethod, chain)
      return chain if PaymentMethod::FIAT_CHAINS.include?(chain)
      return paymethod.fiat_chain if chain.nil?

      nil
    end
  end
end
