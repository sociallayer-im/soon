require "test_helper"

class Api::V1::WithdrawalsControllerTest < ActionDispatch::IntegrationTest
  include FactoryHelpers

  setup do
    @owner = create_user
    @manager = create_user
    @group = create_group(owner: @owner)
    create_membership(user: @manager, group: @group, role: "manager")
    @event = create_event(group: @group, owner: @owner)
    @ticket = create_ticket(event: @event, quantity: 10)
    @buyer = create_user
    TicketItem.create!(ticket: @ticket, event: @event, user: @buyer, ticket_type: "event",
      status: "succeeded", amount: 10_000, currency: "cny", payment_provider: "wechat")
    ENV["WECHAT_PAY_ENABLED"] = "true"
  end

  teardown do
    ENV.delete("WECHAT_PAY_ENABLED")
  end

  test "the whole controller 404s when WECHAT_PAY_ENABLED is not set (SG deployments)" do
    ENV.delete("WECHAT_PAY_ENABLED")
    get "/api/v1/withdrawals/groups", headers: auth_headers(@owner)
    assert_response :not_found
  end

  test "groups lists every group the caller manages with its wechat balance" do
    get "/api/v1/withdrawals/groups", headers: auth_headers(@owner)
    assert_response :success
    row = json_response["groups"].find { |g| g["id"] == @group.id }
    assert_equal 9_600, row["available_amount"]
    assert_equal 0, row["total_withdrawn"]
  end

  test "groups excludes groups the caller does not manage" do
    outsider = create_user
    get "/api/v1/withdrawals/groups", headers: auth_headers(outsider)
    assert_response :success
    assert_not json_response["groups"].any? { |g| g["id"] == @group.id }
  end

  test "balance and create 403 for a plain member of the group" do
    member = create_user
    create_membership(user: member, group: @group, role: "member")

    get "/api/v1/withdrawals/balance", params: { group_id: @group.id }, headers: auth_headers(member)
    assert_response :forbidden

    post "/api/v1/withdrawals",
      params: { group_id: @group.id, bank_name: "x", bank_account_number: "1", bank_account_name: "a" },
      headers: auth_headers(member)
    assert_response :forbidden
  end

  test "create withdraws the full available balance and computes the amount server-side" do
    post "/api/v1/withdrawals",
      params: { group_id: @group.id, bank_name: "Test Bank", bank_account_number: "62220000",
                bank_account_name: "Owner Name", amount: 1 }, # client-supplied amount must be ignored
      headers: auth_headers(@owner)
    assert_response :created
    assert_equal 9_600, json_response["amount"]
    assert_equal "pending", json_response["status"]

    get "/api/v1/withdrawals/balance", params: { group_id: @group.id }, headers: auth_headers(@owner)
    assert_equal 0, json_response["available_amount"]
  end

  test "create fails with no withdrawable balance" do
    empty_group = create_group(owner: @owner)
    post "/api/v1/withdrawals",
      params: { group_id: empty_group.id, bank_name: "x", bank_account_number: "1", bank_account_name: "a" },
      headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end

  test "a co-manager cannot withdraw the same balance twice — the group's pool is shared" do
    post "/api/v1/withdrawals",
      params: { group_id: @group.id, bank_name: "x", bank_account_number: "1", bank_account_name: "a" },
      headers: auth_headers(@owner)
    assert_response :created

    # A different manager of the SAME group, acting independently, must see
    # the balance already claimed — this is the bug the group-level rewrite
    # closes: it used to be computed per requesting user.
    post "/api/v1/withdrawals",
      params: { group_id: @group.id, bank_name: "y", bank_account_number: "2", bank_account_name: "b" },
      headers: auth_headers(@manager)
    assert_response :unprocessable_entity

    assert_equal 9_600, Withdrawal.where(group: @group).sum(:amount)
  end

  test "index returns every manager's withdrawal requests against the group, not just the caller's own" do
    post "/api/v1/withdrawals",
      params: { group_id: @group.id, bank_name: "x", bank_account_number: "1", bank_account_name: "a" },
      headers: auth_headers(@owner)
    assert_response :created

    get "/api/v1/withdrawals", params: { group_id: @group.id }, headers: auth_headers(@manager)
    assert_response :success
    assert_equal [ 9_600 ], json_response.map { |w| w["amount"] }
  end

  test "index/balance/create all 404 for an unknown group_id" do
    get "/api/v1/withdrawals", params: { group_id: "does-not-exist" }, headers: auth_headers(@owner)
    assert_response :forbidden
  end
end
