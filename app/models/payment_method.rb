class PaymentMethod < ApplicationRecord
  SUPPORTED_CHAINS = %w[ethereum optimism arbitrum polygon base stripe].freeze

  # Product floor for card payments (cents). Stripe's own hard minimum is 50¢;
  # $4 is deliberate — smaller charges are mostly eaten by the $0.30 + 2.9% fee.
  # The same constant gates ticket creation (here) and the after-coupon amount
  # at checkout (TicketsController) — see design/PAYMENTS_PLAN.md decision #8/#9.
  STRIPE_MIN_CENTS = 400

  belongs_to :item, polymorphic: true, optional: true
  # Which of the event owner's Stripe keys this method charges to (nil for
  # crypto methods and for stripe methods created before stripe_settings).
  belongs_to :stripe_setting, optional: true

  validates :item_type, inclusion: { in: %w(Ticket User) }
  validates :chain, inclusion: { in: SUPPORTED_CHAINS }, allow_blank: true
  validate :chains_must_be_supported
  # Guarded so pre-existing rows saved for unrelated reasons don't suddenly
  # fail validation — only new methods and price changes are held to the floor.
  validate :stripe_price_meets_minimum, if: -> { new_record? || will_save_change_to_price? }

  enum :kind, { crypto: "crypto", fiat: "fiat", credit: "credit" }

  def token_address_for_chain(chain_name)
    chain_token_addresses&.dig(chain_name.to_s) || token_address
  end

  def effective_chains
    chains.present? ? chains : [chain].compact
  end

  private

  def chains_must_be_supported
    invalid = Array(chains) - SUPPORTED_CHAINS
    errors.add(:chains, "contains unsupported chains: #{invalid.join(', ')}") if invalid.any?
  end

  def stripe_price_meets_minimum
    return unless effective_chains.include?("stripe")
    return if price.to_i >= STRIPE_MIN_CENTS

    errors.add(:price, "must be at least $#{STRIPE_MIN_CENTS / 100} (#{STRIPE_MIN_CENTS} cents) for card payments — use a crypto payment method for smaller amounts")
  end
end
