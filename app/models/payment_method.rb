class PaymentMethod < ApplicationRecord
  SUPPORTED_CHAINS = %w[ethereum optimism arbitrum polygon base stripe wechat].freeze

  # The rails whose `price` is an integer of a fiat minor unit (cents, 分)
  # rather than a token amount scaled by the token's decimals. Every place
  # that has to tell "is this money or is this a token" keys off this set —
  # most importantly Coupon's fixed-amount scaling, which multiplies by 10000
  # for token amounts and would otherwise turn a ¥1 coupon into ¥10,000.
  FIAT_CHAINS = %w[stripe wechat].freeze

  CURRENCIES = %w[usd cny].freeze

  # Each fiat rail settles in exactly one currency: Stripe here is the SG
  # deployment (USD); WeChat Pay, when it lands, is domestic CNY only.
  #
  # The currency is nonetheless a stored column rather than something derived
  # on read, because ticket_items and refunds have to remember what was
  # actually charged — an order taken in USD stays a USD order even if the
  # rail's default later changes — and because relaxing this map (Stripe
  # presentment in CNY, say) then costs a data change instead of a migration.
  RAIL_CURRENCY = { "stripe" => "usd", "wechat" => "cny" }.freeze

  # Product floor for card payments (cents). Stripe's own hard minimum is 50¢;
  # $4 is deliberate — smaller charges are mostly eaten by the $0.30 + 2.9% fee.
  # The same constant gates ticket creation (here) and the after-coupon amount
  # at checkout (TicketsController) — see design/PAYMENTS_PLAN.md decision #8/#9.
  STRIPE_MIN_CENTS = 400

  # Per-rail floor, in that rail's minor unit. It is a map rather than one
  # constant because the reason for the $4 card floor is Stripe's fixed $0.30
  # per charge — a rail without a fixed fee has no such reason, and copying
  # 400 across would silently ban every small ticket on it.
  # WeChat Pay charges ≈0.6% and no fixed fee, and accepts amounts down to 1分,
  # so it gets the real floor rather than an inherited $4 that would ban every
  # ticket under ¥4 for a reason that does not apply to it
  # (design/WECHAT_INTEGRATION.md §2.5).
  MIN_PRICE = { "stripe" => STRIPE_MIN_CENTS, "wechat" => 1 }.freeze

  belongs_to :item, polymorphic: true, optional: true
  # Which of the event owner's Stripe keys this method charges to (nil for
  # crypto methods and for stripe methods created before stripe_settings).
  belongs_to :stripe_setting, optional: true
  # Which merchant collects this method's WeChat payments. Not organizer-chosen
  # — there is one platform merchant — but stored per method so an order's
  # snapshot is a fact about the order, not a lookup of current config.
  belongs_to :wechat_pay_setting, optional: true

  before_validation :assign_currency
  before_validation :assign_wechat_pay_setting

  validates :item_type, inclusion: { in: %w(Ticket User) }
  validates :chain, inclusion: { in: SUPPORTED_CHAINS }, allow_blank: true
  validate :chains_must_be_supported
  validates :currency, inclusion: { in: CURRENCIES }, allow_blank: true
  validate :currency_matches_rail
  # Guarded so pre-existing rows saved for unrelated reasons don't suddenly
  # fail validation — only new methods and price changes are held to the floor.
  validate :price_meets_rail_minimum, if: -> { new_record? || will_save_change_to_price? }
  # A card method with no key cannot be charged at all — the buyer would only
  # find out at checkout, which PAYMENTS_PLAN decision #5 rules out. Applies
  # to every save, including edits of keyless sails-era rows: those were
  # never chargeable (Stripe was non-functional before this work), so the
  # organizer picking a key is the repair, not a regression.
  validate :stripe_method_has_a_key
  validate :wechat_method_has_a_setting

  enum :kind, { crypto: "crypto", fiat: "fiat", credit: "credit" }

  def token_address_for_chain(chain_name)
    chain_token_addresses&.dig(chain_name.to_s) || token_address
  end

  def effective_chains
    chains.present? ? chains : [chain].compact
  end

  # The fiat rail this method charges on, or nil for a crypto method. Single
  # value by construction: a fiat chain is always its own payment method
  # (a card price in cents can't share a row with a token price), so the
  # multi-chain `chains` array only ever holds crypto entries.
  def fiat_chain
    (effective_chains & FIAT_CHAINS).first
  end

  def fiat? = fiat_chain.present?

  private

  # Fills the rail's only currency so callers never have to send it, while
  # still allowing an explicit value that #currency_matches_rail then checks.
  # Also repairs rows created before the column was used.
  def assign_currency
    rail = fiat_chain
    self.currency = RAIL_CURRENCY[rail] if rail && currency.blank?
  end

  # Unlike Stripe, nothing asks the organizer which merchant collects: CN has
  # exactly one. Resolving it here (rather than in the controller) means every
  # creation path gets it, including the group-ticket and recurring ones.
  def assign_wechat_pay_setting
    return unless fiat_chain == "wechat"
    return if wechat_pay_setting_id.present?

    self.wechat_pay_setting_id = WechatPaySetting.platform_default&.id
  end

  def chains_must_be_supported
    invalid = Array(chains) - SUPPORTED_CHAINS
    errors.add(:chains, "contains unsupported chains: #{invalid.join(', ')}") if invalid.any?
  end

  def currency_matches_rail
    rail = fiat_chain
    if rail.nil?
      # A crypto price is denominated in its token, whose name lives in
      # token_name; a fiat currency here would describe the amount wrongly and
      # would make Coupon's scaling look settled when it isn't.
      errors.add(:currency, "does not apply to crypto payment methods") if currency.present?
      return
    end

    expected = RAIL_CURRENCY[rail]
    return if currency == expected

    errors.add(:currency, "must be #{expected.upcase} for #{rail} payments")
  end

  def stripe_method_has_a_key
    return unless effective_chains.include?("stripe")
    return if stripe_setting_id.present?

    errors.add(:stripe_setting_id, "is required for card payments — pick which Stripe key collects the money")
  end

  # Same reasoning as the Stripe key check: an uncollectable method must fail
  # for the organizer at creation, not for a buyer at checkout. Reached only
  # when no merchant is installed at all — assign_wechat_pay_setting fills it
  # otherwise.
  def wechat_method_has_a_setting
    return unless effective_chains.include?("wechat")
    return if wechat_pay_setting_id.present?

    errors.add(:wechat_pay_setting_id,
      "is required for WeChat payments — no WeChat Pay merchant is configured on this deployment")
  end

  def price_meets_rail_minimum
    rail = fiat_chain
    return unless rail
    minimum = MIN_PRICE.fetch(rail)
    return if price.to_i >= minimum

    errors.add(:price, minimum_error_message(rail, minimum))
  end

  def minimum_error_message(rail, minimum)
    if rail == "stripe"
      "must be at least $#{minimum / 100} (#{minimum} cents) for card payments — use a crypto payment method for smaller amounts"
    else
      "must be at least #{minimum} (minor units) for #{rail} payments"
    end
  end
end
