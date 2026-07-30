# All Stripe API access goes through here with a per-call client — never the
# process-global Stripe.api_key, which would race across accounts under
# Puma's threads. Each method takes the StripeSetting whose account it acts
# on (design/PAYMENTS_PLAN.md §2.1).
class StripeGateway
  WEBHOOK_EVENTS = %w[
    checkout.session.completed
    checkout.session.expired
    payment_intent.payment_failed
    charge.refunded
    charge.dispute.created
    charge.dispute.closed
  ].freeze

  class InvalidKey < StandardError; end

  # Validates a candidate key by asking Stripe who it belongs to.
  # Returns the acct_… id (nil when the key authenticated but may not read the
  # account); raises InvalidKey, carrying Stripe's own message, when the key
  # is rejected.
  #
  # NB: the id argument must be nil (not {}), which routes to the singleton
  # /v1/account — the key's own account. A non-nil id is checked as a string
  # by stripe-ruby and {} raises TypeError; passing the key AS the id only
  # works for sk_ prefixes and would break restricted (rk_) keys.
  def self.validate_key(secret_key)
    account = ::Stripe::Account.retrieve(nil, { api_key: secret_key })
    account.id
  rescue ::Stripe::PermissionError => e
    # The key IS valid — Stripe authenticated it and then refused this
    # endpoint. Typical for a Restricted key without account-read scope,
    # which is exactly the key type we recommend, so accept it and carry on
    # without an account id rather than locking the user out.
    Rails.logger.info("[stripe] key accepted without account read: #{e.message}")
    nil
  rescue ::Stripe::AuthenticationError => e
    raise InvalidKey, e.message
  rescue ::Stripe::StripeError => e
    # Connection/API trouble is not the key's fault — say so, don't blame it.
    raise InvalidKey, "could not reach Stripe to verify the key: #{e.message}"
  end

  # Creates the webhook endpoint on the key's account, pointed at our
  # per-setting URL. Returns [endpoint_id, signing_secret] — the secret is
  # only ever disclosed at creation time. Returns nil on failure (e.g. a
  # restricted key without webhook scope): the setting then runs in
  # sweeper-only mode with delayed confirmation (PAYMENTS_PLAN §6.2).
  def self.create_webhook_endpoint(setting)
    endpoint = ::Stripe::WebhookEndpoint.create(
      { url: webhook_url(setting), enabled_events: WEBHOOK_EVENTS },
      { api_key: setting.secret_key }
    )
    [ endpoint.id, endpoint.secret ]
  rescue ::Stripe::StripeError
    nil
  end

  # Best-effort cleanup when a key is removed/rotated.
  def self.delete_webhook_endpoint(setting)
    return if setting.webhook_endpoint_id.blank?

    ::Stripe::WebhookEndpoint.delete(setting.webhook_endpoint_id, {}, { api_key: setting.secret_key })
  rescue ::Stripe::StripeError
    nil
  end

  # API_URL is the backend's own public origin (api.sola.day) — WEB_URL is
  # the frontend and would 404 a webhook.
  def self.webhook_url(setting)
    "#{ENV.fetch('API_URL', 'http://localhost:3000')}/api/v1/webhooks/stripe/#{setting.id}"
  end

  # ---- checkout ----

  # Session lifetime. Stripe requires expires_at ≥ 30 minutes out; the extra
  # slack keeps our sweeper strictly behind the session's own expiry.
  SESSION_TTL = 35.minutes

  # No idempotency key here by design: the controller reuses an existing open
  # session first, so duplicate creation is already rare, and an orphaned
  # session simply expires — while a key would conflict on legitimate
  # recreate-after-expiry (same key, different expires_at).
  def self.create_checkout_session(setting, ticket_item)
    event = ticket_item.event
    web = ENV.fetch("WEB_URL", "http://localhost:4001")
    return_url = "#{web}/event/detail/#{ticket_item.event_id}"

    ::Stripe::Checkout::Session.create(
      {
        mode: "payment",
        # Cards settle synchronously: session "complete" implies paid, which
        # the webhook handler and sweeper rely on. Async rails (bank debits
        # etc.) would introduce a complete-but-unpaid limbo state plus
        # async_payment_succeeded events this integration does not handle.
        payment_method_types: [ "card" ],
        line_items: [ {
          quantity: 1,
          price_data: {
            currency: ticket_item.currency.presence || setting.currency,
            unit_amount: ticket_item.amount,
            product_data: { name: [ event&.title, ticket_item.ticket&.title ].compact.join(" — ") }
          }
        } ],
        # ticket_item_id on both objects: the order stays resolvable even if
        # our provider_ref write is lost (PAYMENTS_PLAN §2.4).
        metadata: { ticket_item_id: ticket_item.id },
        payment_intent_data: { metadata: { ticket_item_id: ticket_item.id } },
        expires_at: SESSION_TTL.from_now.to_i,
        success_url: "#{return_url}?payment=success&ticket_item=#{ticket_item.id}",
        cancel_url: "#{return_url}?payment=cancelled&ticket_item=#{ticket_item.id}"
      },
      { api_key: setting.secret_key }
    )
  end

  def self.retrieve_checkout_session(setting, session_id)
    ::Stripe::Checkout::Session.retrieve(session_id, { api_key: setting.secret_key })
  rescue ::Stripe::StripeError
    nil
  end

  # For reconciliation: the intent plus its charge (refund/dispute state).
  def self.retrieve_payment_intent(setting, intent_id)
    ::Stripe::PaymentIntent.retrieve(
      { id: intent_id, expand: [ "latest_charge" ] },
      { api_key: setting.secret_key }
    )
  rescue ::Stripe::StripeError
    nil
  end

  # ---- refunds ----

  def self.create_refund(setting, payment_intent:, amount:, idempotency_key:)
    ::Stripe::Refund.create(
      { payment_intent: payment_intent, amount: amount },
      { api_key: setting.secret_key, idempotency_key: idempotency_key }
    )
  end
end
