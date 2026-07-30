require "test_helper"

class Api::V1::StripeWebhooksControllerTest < ActionDispatch::IntegrationTest
  include FactoryHelpers

  SECRET = "whsec_testsecret"

  setup do
    ENV["STRIPE_ENABLED"] = "true"
    @owner = create_user
    @setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_live_k", webhook_secret: SECRET)
  end

  teardown { ENV.delete("STRIPE_ENABLED") }

  def signed_post(payload, secret: SECRET)
    body = payload.to_json
    timestamp = Time.now
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, body, secret)
    post "/api/v1/webhooks/stripe/#{@setting.id}", params: body, headers: {
      "Content-Type" => "application/json",
      "Stripe-Signature" => "t=#{timestamp.to_i},v1=#{signature}"
    }
  end

  def event_payload(id: "evt_1", type: "payment_intent.payment_failed")
    { id: id, object: "event", type: type, data: { object: { id: "pi_x" } } }
  end

  test "a correctly signed event is persisted and queued, and requires no auth" do
    assert_difference -> { StripeEvent.count }, 1 do
      signed_post(event_payload)
    end
    assert_response :success
    assert_equal "payment_intent.payment_failed", StripeEvent.find("evt_1").event_type
  end

  test "a duplicate delivery is acknowledged without a second row" do
    signed_post(event_payload(id: "evt_dup"))
    assert_no_difference -> { StripeEvent.count } do
      signed_post(event_payload(id: "evt_dup"))
    end
    assert_response :success
    assert_match "duplicate", json_response["message"]
  end

  test "a bad signature is rejected and nothing is stored" do
    assert_no_difference -> { StripeEvent.count } do
      signed_post(event_payload, secret: "whsec_wrong")
    end
    assert_response :bad_request
  end

  test "an unknown setting id 404s; a sweeper-only setting (no webhook secret) 400s" do
    post "/api/v1/webhooks/stripe/nonexistent", params: "{}",
      headers: { "Content-Type" => "application/json" }
    assert_response :not_found

    @setting.update!(webhook_secret: nil)
    signed_post(event_payload)
    assert_response :bad_request
  end
end
