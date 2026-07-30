# Per-setting Stripe webhook receiver (design/PAYMENTS_PLAN.md §2.3).
# Events are signed by the organizer's own account, so verification uses the
# signing secret provisioned for THAT stripe_settings row. The request path:
# verify → persist (event id PK = idempotency) → enqueue → 200 fast.
# Processing happens in StripeWebhookJob; webhooks are an optimization, the
# sweeper is what's trusted.
class Api::V1::StripeWebhooksController < Api::BaseController
  skip_before_action :authenticate!
  before_action :require_stripe_enabled!

  def create
    setting = StripeSetting.find_by(id: params[:stripe_setting_id])
    return head :not_found unless setting
    # No webhook secret = this key runs sweeper-only; nothing to verify against.
    return head :bad_request if setting.webhook_secret.blank?

    event = ::Stripe::Webhook.construct_event(
      request.raw_post, request.headers["Stripe-Signature"], setting.webhook_secret
    )

    StripeEvent.create!(
      id: event.id, stripe_setting_id: setting.id,
      event_type: event.type, payload: event.as_json
    )
    StripeWebhookJob.perform_later(event.id)
    render json: { result: "ok" }
  rescue ActiveRecord::RecordNotUnique
    render json: { result: "ok", message: "duplicate delivery" }
  rescue ::Stripe::SignatureVerificationError, JSON::ParserError
    head :bad_request
  end
end
