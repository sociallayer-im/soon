require "test_helper"

class Api::V1::AdminWithdrawalsControllerTest < ActionDispatch::IntegrationTest
  include FactoryHelpers

  def setup
    @admin = create_user(admin: true)
    @owner = create_user
    @group = create_group(owner: @owner)
    @withdrawal = Withdrawal.create!(group: @group, user: @owner, amount: 9_600, currency: "cny",
      status: "pending", bank_name: "Test Bank", bank_account_number: "1234", bank_account_name: "Owner Name")
  end

  test "a non-admin cannot list withdrawals" do
    get "/api/v1/admin/withdrawals", headers: auth_headers(@owner)
    assert_response :forbidden
  end

  test "an anonymous caller cannot list withdrawals" do
    get "/api/v1/admin/withdrawals"
    assert_response :unauthorized
  end

  test "an admin lists every withdrawal with group and requester detail" do
    get "/api/v1/admin/withdrawals", headers: auth_headers(@admin)
    assert_response :success
    row = json_response["data"].find { |w| w["id"] == @withdrawal.id }
    assert row
    assert_equal @group.id, row["group_id"]
    assert_equal @group.name, row["group_name"]
    assert_equal @owner.id, row["user_id"]
    assert_equal "1234", row["bank_account_number"]
  end

  test "an admin can filter by status" do
    Withdrawal.create!(group: @group, user: @owner, amount: 100, currency: "cny", status: "completed",
      bank_name: "x", bank_account_number: "1", bank_account_name: "a", processed_at: Time.current)

    get "/api/v1/admin/withdrawals", params: { status: "pending" }, headers: auth_headers(@admin)
    assert_response :success
    assert_equal [ @withdrawal.id ], json_response["data"].map { |w| w["id"] }
  end

  test "an admin settles a pending withdrawal as completed" do
    patch "/api/v1/admin/withdrawals/#{@withdrawal.id}", params: { status: "completed" }, headers: auth_headers(@admin)
    assert_response :success
    assert_equal "completed", json_response["status"]
    assert_equal @admin.id, json_response["processed_by_id"]
    assert_not_nil json_response["processed_at"]

    @withdrawal.reload
    assert_equal "completed", @withdrawal.status
    assert_equal @admin.id, @withdrawal.processed_by_id
  end

  test "an admin rejects a pending withdrawal" do
    patch "/api/v1/admin/withdrawals/#{@withdrawal.id}", params: { status: "rejected" }, headers: auth_headers(@admin)
    assert_response :success
    assert_equal "rejected", json_response["status"]
  end

  test "an admin can attach a reason note when rejecting" do
    patch "/api/v1/admin/withdrawals/#{@withdrawal.id}",
      params: { status: "rejected", note: "bank account name doesn't match the group owner" },
      headers: auth_headers(@admin)
    assert_response :success
    assert_equal "rejected", json_response["status"]

    @withdrawal.reload
    assert_equal "bank account name doesn't match the group owner", @withdrawal.note
  end

  test "a blank note is not written over an existing one" do
    @withdrawal.update!(note: "kept")
    patch "/api/v1/admin/withdrawals/#{@withdrawal.id}", params: { status: "completed", note: "" }, headers: auth_headers(@admin)
    assert_response :success
    assert_equal "kept", @withdrawal.reload.note
  end

  test "a non-admin cannot settle a withdrawal" do
    patch "/api/v1/admin/withdrawals/#{@withdrawal.id}", params: { status: "completed" }, headers: auth_headers(@owner)
    assert_response :forbidden
    assert_equal "pending", @withdrawal.reload.status
  end

  test "an already-settled withdrawal cannot be settled again" do
    @withdrawal.update!(status: "completed", processed_at: Time.current)
    patch "/api/v1/admin/withdrawals/#{@withdrawal.id}", params: { status: "rejected" }, headers: auth_headers(@admin)
    assert_response :unprocessable_entity
    assert_equal "completed", @withdrawal.reload.status
  end

  test "an invalid status value is rejected" do
    patch "/api/v1/admin/withdrawals/#{@withdrawal.id}", params: { status: "paid" }, headers: auth_headers(@admin)
    assert_response :unprocessable_entity
    assert_equal "pending", @withdrawal.reload.status
  end
  test "notification target requires current platform administration" do
    get "/api/v1/admin/withdrawals/#{@withdrawal.id}", headers: auth_headers(@admin)
    assert_response :success
    assert_equal @withdrawal.id, json_response["id"]
    get "/api/v1/admin/withdrawals/#{@withdrawal.id}", headers: auth_headers(@owner)
    assert_response :forbidden
    @admin.update!(admin: false)
    notice = Activity.for_receiver(@admin).find_by!(action: "surf/withdrawal_requested", item: @withdrawal)
    assert_nil SiteNotifications.target(notice, @admin)
  end

  test "new requests notify active administrators once without banking details and create live tasks" do
    legacy_admin = create_user(permissions: ["admin"])
    disabled = create_user(admin: true, active: false)
    withdrawal = Withdrawal.create!(group: @group, user: @owner, amount: 100, currency: "cny", status: "pending", bank_name: "SensitiveBank", bank_account_number: "PRIVATE-ACCOUNT", bank_account_name: "PrivateName")
    [@admin, legacy_admin].each do |admin|
      notices = Activity.for_receiver(admin).where(action: "surf/withdrawal_requested", item: withdrawal)
      assert_equal 1, notices.count
      assert_equal({page: "admin-withdrawals", id: withdrawal.id}, SiteNotifications.target(notices.first, admin))
      assert_not_includes notices.first.payload.to_json, "PRIVATE-ACCOUNT"
      assert_not_includes notices.first.payload.to_json, "PrivateName"
      assert_not_includes notices.first.payload.to_json, "SensitiveBank"
      assert SiteNotificationTasks.for(admin).any? { |task| task[:kind] == "withdrawal_request" && task[:resource_id] == withdrawal.id }
    end
    assert_empty Activity.for_receiver(disabled).where(item: withdrawal)
    assert_empty Activity.for_receiver(@owner).where(item: withdrawal, action: "surf/withdrawal_requested")
    assert_equal 1, Activity.for_receiver(@owner).where(item: withdrawal, action: ReviewNotifications::ACTION).count
    withdrawal.update!(note: "备注")
    assert_equal 1, Activity.for_receiver(@admin).where(item: withdrawal).count
    patch "/api/v1/admin/withdrawals/#{withdrawal.id}", params: {status: "completed"}, headers: auth_headers(@admin)
    assert_response :success
    assert_not SiteNotificationTasks.for(legacy_admin).any? { |task| task[:resource_id] == withdrawal.id }
  end

  test "rolled back requests do not emit notifications" do
    count = Activity.count
    Withdrawal.transaction do
      Withdrawal.create!(group: @group, user: @owner, amount: 100, currency: "cny", status: "pending", bank_name: "Bank", bank_account_number: "Account", bank_account_name: "Name")
      raise ActiveRecord::Rollback
    end
    assert_equal count, Activity.count
  end

  test "inactive administrators cannot view bank details or settle requests" do
    @admin.update!(active: false)
    get "/api/v1/admin/withdrawals/#{@withdrawal.id}", headers: auth_headers(@admin)
    assert_response :forbidden
    patch "/api/v1/admin/withdrawals/#{@withdrawal.id}", params: {status: "completed"}, headers: auth_headers(@admin)
    assert_response :forbidden
    assert_equal "pending", @withdrawal.reload.status
  end

end
