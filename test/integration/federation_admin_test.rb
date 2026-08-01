require "test_helper"

# Operator surface: stats endpoint auth + counters, policy CRUD side effects
# (design/FEDERATION_TEST_PLAN.md OM-3, BL-4/BL-7 adjacent).
class FederationAdminTest < ActionDispatch::IntegrationTest
  include FederationHelpers

  setup do
    @admin = create_user(permissions: ["admin"])
    @user = create_user
  end

  test "stats requires a platform admin" do
    get "/api/v1/federation/stats", headers: auth_headers(@user)
    assert_response :forbidden
    get "/api/v1/federation/stats"
    assert_response :unauthorized
  end

  test "stats reports queue and domain counters consistent with the tables" do
    FedDelivery.create!(payload: {"type" => "Create"}, sender_type: "Group", sender_id: "x",
                        inbox_url: "https://a.example/inbox")
    FedDelivery.create!(payload: {"type" => "Create"}, sender_type: "Group", sender_id: "x",
                        inbox_url: "https://a.example/inbox", status: "failed_permanent")
    FedDomainStat.record_delivery!("a.example", success: false, error: "HTTP 500")

    get "/api/v1/federation/stats", headers: auth_headers(@admin)
    assert_response :success
    body = json_response
    assert_equal 1, body["queue"]["pending"]
    assert_equal 1, body["queue"]["failed_permanent"]
    assert body["queue"]["oldest_pending_age_seconds"].is_a?(Integer)
    domain = body["domains"].find { |d| d["domain"] == "a.example" }
    assert_equal 1, domain["failed"]
  end

  test "creating a blocked policy disables cached actors; deleting restores them" do
    remote, = create_fed_actor
    post "/api/v1/federation/policies", headers: auth_headers(@admin),
         params: {domain: remote.domain, policy: "blocked", reason: "spam"}
    assert_response :created
    assert remote.reload.blocked?

    delete "/api/v1/federation/policies/#{remote.domain}", headers: auth_headers(@admin)
    assert_response :no_content
    refute remote.reload.blocked?
  end
end
