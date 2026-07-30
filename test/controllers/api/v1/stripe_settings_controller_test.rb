require "test_helper"

class Api::V1::StripeSettingsControllerTest < ActionDispatch::IntegrationTest
  include FactoryHelpers

  setup do
    @user = create_user
    ENV["STRIPE_ENABLED"] = "true"
  end

  teardown do
    ENV.delete("STRIPE_ENABLED")
  end

  test "the whole controller 404s when STRIPE_ENABLED is not set (CN deployments)" do
    ENV.delete("STRIPE_ENABLED")
    get "/api/v1/stripe_settings", headers: auth_headers(@user)
    assert_response :not_found
  end

  test "create validates the key against Stripe, stores the account id, and never echoes the key" do
    StripeGateway.stub :validate_key, "acct_123" do
      StripeGateway.stub :create_webhook_endpoint, [ "we_1", "whsec_abc" ] do
        post "/api/v1/stripe_settings",
          params: { stripe_setting: { name: "My key", secret_key: "sk_live_verysecret1234" } },
          headers: auth_headers(@user)
      end
    end
    assert_response :created

    assert_equal "acct_123", json_response["account_id"]
    assert_equal "live", json_response["mode"]
    assert_equal "…1234", json_response["masked_key"]
    assert_equal false, json_response["delayed_confirmation"]
    assert_not response.body.include?("verysecret"), "the secret key must never appear in a response"

    setting = StripeSetting.find(json_response["id"])
    assert_equal "whsec_abc", setting.webhook_secret
    assert_equal "we_1", setting.webhook_endpoint_id
  end

  test "a key Stripe rejects is not saved" do
    raises = ->(_key) { raise StripeGateway::InvalidKey }
    StripeGateway.stub :validate_key, raises do
      post "/api/v1/stripe_settings",
        params: { stripe_setting: { name: "Bad", secret_key: "sk_live_nope" } },
        headers: auth_headers(@user)
    end
    assert_response :unprocessable_entity
    assert_equal 0, @user.stripe_settings.count
  end

  test "failed webhook provisioning still saves the key, flagged delayed_confirmation" do
    StripeGateway.stub :validate_key, "acct_123" do
      StripeGateway.stub :create_webhook_endpoint, nil do
        post "/api/v1/stripe_settings",
          params: { stripe_setting: { name: "RK", secret_key: "rk_test_limited123" } },
          headers: auth_headers(@user)
      end
    end
    assert_response :created
    assert_equal true, json_response["delayed_confirmation"]
    assert_equal "test", json_response["mode"], "rk_test_ prefix must be detected as test mode"
  end

  test "index lists only the caller's keys" do
    other = create_user
    StripeSetting.create!(user: @user, name: "Mine", secret_key: "sk_live_a")
    StripeSetting.create!(user: other, name: "Theirs", secret_key: "sk_live_b")

    get "/api/v1/stripe_settings", headers: auth_headers(@user)
    assert_response :success
    assert_equal [ "Mine" ], json_response.map { |s| s["name"] }
  end

  test "update can rename without re-validating; another user's setting 404s" do
    setting = StripeSetting.create!(user: @user, name: "Old", secret_key: "sk_live_a")

    patch "/api/v1/stripe_settings/#{setting.id}",
      params: { stripe_setting: { name: "New" } }, headers: auth_headers(@user)
    assert_response :success
    assert_equal "New", setting.reload.name

    other = create_user
    patch "/api/v1/stripe_settings/#{setting.id}",
      params: { stripe_setting: { name: "Hijack" } }, headers: auth_headers(other)
    assert_response :not_found
  end

  test "for_event lists the EVENT OWNER's active keys to anyone who can edit the event" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    StripeSetting.create!(user: owner, name: "Owner key", secret_key: "sk_live_o")
    StripeSetting.create!(user: owner, name: "Broken", secret_key: "sk_live_b", status: "invalid")
    manager = create_user
    create_membership(user: manager, group: group, role: "manager")

    # A manager (can update the event) sees the owner's active keys — masked.
    get "/api/v1/stripe_settings/for_event", params: { event_id: event.id }, headers: auth_headers(manager)
    assert_response :success
    assert_equal [ "Owner key" ], json_response.map { |s| s["name"] }
    assert_not response.body.include?("sk_live_o")

    # An outsider with no edit rights gets nothing.
    get "/api/v1/stripe_settings/for_event", params: { event_id: event.id }, headers: auth_headers(create_user)
    assert_response :forbidden
  end

  test "key rotation is blocked while orders are in flight (rename stays allowed)" do
    setting = StripeSetting.create!(user: @user, name: "K", secret_key: "sk_live_a")
    group = create_group(owner: @user)
    event = create_event(group: group, owner: @user)
    ticket = create_ticket(event: event)
    TicketItem.create!(ticket: ticket, event: event, user: create_user, ticket_type: "event",
      status: "pending", amount: 1000, stripe_setting_id: setting.id)

    patch "/api/v1/stripe_settings/#{setting.id}",
      params: { stripe_setting: { secret_key: "sk_live_other_account" } }, headers: auth_headers(@user)
    assert_response :unprocessable_entity
    assert_match "cannot be rotated", json_response["error"]
    assert_equal "sk_live_a", setting.reload.secret_key

    patch "/api/v1/stripe_settings/#{setting.id}",
      params: { stripe_setting: { name: "Renamed" } }, headers: auth_headers(@user)
    assert_response :success
    assert_equal "Renamed", setting.reload.name
  end

  test "destroy is blocked while the key has pending or recently paid orders" do
    setting = StripeSetting.create!(user: @user, name: "K", secret_key: "sk_live_a")
    group = create_group(owner: @user)
    event = create_event(group: group, owner: @user)
    ticket = create_ticket(event: event)
    item = TicketItem.create!(ticket: ticket, event: event, user: create_user, ticket_type: "event",
      status: "pending", amount: 1000, stripe_setting_id: setting.id)

    delete "/api/v1/stripe_settings/#{setting.id}", headers: auth_headers(@user)
    assert_response :unprocessable_entity
    assert StripeSetting.exists?(setting.id)

    # Terminal order → deletable.
    item.update!(status: "cancelled")
    StripeGateway.stub :delete_webhook_endpoint, nil do
      delete "/api/v1/stripe_settings/#{setting.id}", headers: auth_headers(@user)
    end
    assert_response :no_content
    assert_not StripeSetting.exists?(setting.id)
  end
end
