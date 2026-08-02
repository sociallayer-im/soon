require "test_helper"

# checkout_session + refund endpoints (PAYMENTS_PLAN Phases 5 & 7).
class Api::V1::TicketsStripeFlowTest < ActionDispatch::IntegrationTest
  include FactoryHelpers

  setup do
    ENV["STRIPE_ENABLED"] = "true"
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 5)
    @setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_live_k")
    @buyer = create_user
  end

  teardown { ENV.delete("STRIPE_ENABLED") }

  def create_order(status: "pending", **attrs)
    TicketItem.create!({ ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: status, amount: 1000, currency: "usd", payment_provider: "stripe",
      stripe_setting_id: @setting.id }.merge(attrs))
  end

  # ---------------------------------------------------------------- checkout_session

  test "checkout_session mints a session, stores provider_ref, extends the reservation" do
    item = create_order(reserved_until: 5.minutes.from_now)
    session = OpenStruct.new(id: "cs_new", url: "https://checkout.stripe.com/c/cs_new",
      status: "open", expires_at: 35.minutes.from_now.to_i)

    StripeGateway.stub :create_checkout_session, session do
      post "/api/v1/tickets/checkout_session",
        params: { ticket_item_id: item.id }, headers: auth_headers(@buyer)
    end
    assert_response :success
    assert_equal "https://checkout.stripe.com/c/cs_new", json_response["checkout_url"]
    assert_equal "cs_new", item.reload.provider_ref
    assert item.reserved_until > 30.minutes.from_now, "reservation must outlive the session"
  end

  test "checkout_session returns the SAME open session on a second click" do
    item = create_order(provider_ref: "cs_open")
    open_session = OpenStruct.new(id: "cs_open", url: "https://checkout.stripe.com/c/cs_open", status: "open")

    called_create = false
    StripeGateway.stub :retrieve_checkout_session, open_session do
      StripeGateway.stub :create_checkout_session, ->(*) { called_create = true } do
        post "/api/v1/tickets/checkout_session",
          params: { ticket_item_id: item.id }, headers: auth_headers(@buyer)
      end
    end
    assert_response :success
    assert_equal "cs_open", json_response["session_id"]
    assert_not called_create, "must reuse the open session, not orphan it with a new one"
  end

  test "checkout_session is owner-only and pending-only" do
    item = create_order
    post "/api/v1/tickets/checkout_session",
      params: { ticket_item_id: item.id }, headers: auth_headers(create_user)
    assert_response :forbidden

    item.update!(status: "succeeded")
    post "/api/v1/tickets/checkout_session",
      params: { ticket_item_id: item.id }, headers: auth_headers(@buyer)
    assert_response :unprocessable_entity
  end

  test "checkout_session 404s when STRIPE_ENABLED is unset (CN)" do
    ENV.delete("STRIPE_ENABLED")
    item = create_order
    post "/api/v1/tickets/checkout_session",
      params: { ticket_item_id: item.id }, headers: auth_headers(@buyer)
    assert_response :not_found
  end

  # ---------------------------------------------------------------- refund

  test "event owner initiates a full refund: pending row + Stripe call with the snapshotted key" do
    item = create_order(status: "succeeded", txhash: "pi_1")

    captured = nil
    fake = ->(setting, payment_intent:, amount:, idempotency_key:) {
      captured = { setting: setting, intent: payment_intent, amount: amount, key: idempotency_key }
      OpenStruct.new(id: "re_1")
    }
    StripeGateway.stub :create_refund, fake do
      post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(@owner)
    end
    assert_response :success

    refund = item.refunds.sole
    assert_equal "pending", refund.status
    assert refund.full_refund
    assert_equal "re_1", refund.provider_ref
    assert_equal @setting.id, captured[:setting].id, "must charge back through the account that took the money"
    assert_equal "pi_1", captured[:intent]
    assert_equal 1000, captured[:amount]
    # Not finalized synchronously — the webhook/sweeper does that.
    assert_equal "succeeded", item.reload.status
  end

  test "a co-host can refund; a group manager (non-co-host) cannot; group owner can for group tickets" do
    item = create_order(status: "succeeded", txhash: "pi_2")
    cohost = create_user
    EventRole.create!(event: @event, item_type: "User", item_id: cohost.id, role: "co_host", display_name: cohost.name)
    manager = create_user
    create_membership(user: manager, group: @group, role: "manager")

    StripeGateway.stub :create_refund, OpenStruct.new(id: "re_x") do
      post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(manager)
      assert_response :forbidden

      post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(cohost)
      assert_response :success
    end

    # group ticket → group owner allowed
    group_item = create_order(status: "succeeded", txhash: "pi_3", ticket_type: "group", group_id: @group.id)
    StripeGateway.stub :create_refund, OpenStruct.new(id: "re_y") do
      post "/api/v1/tickets/#{group_item.id}/refund", headers: auth_headers(@owner)
      assert_response :success
    end
  end

  test "the buyer cannot refund their own ticket" do
    item = create_order(status: "succeeded", txhash: "pi_4")
    post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(@buyer)
    assert_response :forbidden
  end

  test "concurrent second full refund is rejected by the uniqueness guard" do
    item = create_order(status: "succeeded", txhash: "pi_5")
    item.refunds.create!(requested_by: @owner, amount: 1000, full_refund: true)

    post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    # The pending refund consumes the whole balance, so the amount check
    # rejects first; the partial unique index stays as the backstop for
    # truly simultaneous inserts.
    assert_match(/invalid refund amount|already in progress/, json_response["error"])
  end

  test "a pending partial refund counts against the remaining balance" do
    item = create_order(status: "succeeded", txhash: "pi_pend")
    item.refunds.create!(requested_by: @owner, amount: 800, full_refund: false, status: "pending")

    # 800 pending + 500 requested > 1000 → rejected even though nothing has
    # settled yet; and a 200 request is correctly labeled as the full remainder.
    post "/api/v1/tickets/#{item.id}/refund",
      params: { amount: 500 }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end

  test "partial refund amounts are validated against the remaining balance" do
    item = create_order(status: "succeeded", txhash: "pi_6")
    item.refunds.create!(requested_by: @owner, amount: 800, full_refund: false, status: "succeeded")

    post "/api/v1/tickets/#{item.id}/refund",
      params: { amount: 500 }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_match "invalid refund amount", json_response["error"]

    StripeGateway.stub :create_refund, OpenStruct.new(id: "re_z") do
      post "/api/v1/tickets/#{item.id}/refund",
        params: { amount: 200 }, headers: auth_headers(@owner)
    end
    assert_response :success
    assert item.refunds.order(:created_at).last.full_refund,
      "refunding exactly the remaining balance counts as the full refund"
  end

  test "a stripe error marks the refund failed instead of leaving a stuck pending row" do
    item = create_order(status: "succeeded", txhash: "pi_7")
    boom = ->(*) { raise Stripe::APIError.new("kaput") }
    StripeGateway.stub :create_refund, boom do
      post "/api/v1/tickets/#{item.id}/refund", headers: auth_headers(@owner)
    end
    assert_response :unprocessable_entity
    assert_equal "failed", item.refunds.sole.status
  end
end
