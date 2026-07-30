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
  # Returns the acct_… id; raises InvalidKey when Stripe rejects it.
  def self.validate_key(secret_key)
    account = ::Stripe::Account.retrieve({}, { api_key: secret_key })
    account.id
  rescue ::Stripe::AuthenticationError, ::Stripe::PermissionError
    raise InvalidKey
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
end
