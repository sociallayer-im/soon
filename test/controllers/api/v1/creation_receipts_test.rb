require "test_helper"
class Api::V1::CreationReceiptsTest < ActionDispatch::IntegrationTest
  include ContentSafetyTestGateway
  test "retries return original resource and changed payloads are rejected" do
    user=create_user
    payload={group:{name:"receipt-#{unique_suffix}"},idempotency_key:"create_receipt_example"}
    assert_difference "Group.count",1 do
      post "/api/v1/groups",params:payload,headers:auth_headers(user),as: :json
      assert_response :created
    end
    first=response.parsed_body
    assert_no_difference "Group.count" do
      post "/api/v1/groups",params:payload,headers:auth_headers(user),as: :json
      assert_response :created
      assert_equal first,response.parsed_body
    end
    assert_equal 1,CreationReceipt.where(user:user).count
    post "/api/v1/groups",params:payload.deep_merge(group:{nickname:"changed"}),headers:auth_headers(user),as: :json
    assert_response :conflict
    other=create_user
    post "/api/v1/groups",params:payload.deep_merge(group:{name:"other-#{unique_suffix}"}),headers:auth_headers(other),as: :json
    assert_response :created
  end

  test "explicit public browsing excludes inactive groups and remains independent of membership" do
    viewer=create_user
    owner=create_user
    live=create_group(owner:owner)
    frozen=create_group(owner:owner,active:false)
    shown=create_event(group:live,owner:owner,status:"published")
    create_event(group:frozen,owner:owner,status:"published")
    create_event(group:live,owner:owner,status:"draft")
    get "/api/v1/events",params:{browse_all:true},headers:auth_headers(viewer)
    assert_response :success
    assert_equal [shown.id],json_response["data"].map { |event| event["id"] }
  end

  test "failed validation does not consume the key or save a receipt" do
    user=create_user
    post "/api/v1/groups",params:{group:{name:"!"},idempotency_key:"create_receipt_retry"},headers:auth_headers(user),as: :json
    assert_response :unprocessable_entity
    assert_equal 0,CreationReceipt.where(user:user).count
    post "/api/v1/groups",params:{group:{name:"retry-#{unique_suffix}"},idempotency_key:"create_receipt_retry"},headers:auth_headers(user),as: :json
    assert_response :created
  end

  test "event retry preserves a single event and its tickets" do
    user=create_user; group=create_group(owner:user)
    payload={event:{group_id:group.id,title:"Idempotent",start_time:1.day.from_now.iso8601,end_time:2.days.from_now.iso8601,status:"published"},tickets:[{title:"Default",quantity:12,status:"normal",ticket_type:"event"}],idempotency_key:"create_receipt_event"}
    post "/api/v1/events",params:payload,headers:auth_headers(user),as: :json
    assert_response :created
    id=response.parsed_body["id"]
    assert_no_difference ["Event.count","Ticket.count"] do
      post "/api/v1/events",params:payload,headers:auth_headers(user),as: :json
      assert_response :created
      assert_equal id,response.parsed_body["id"]
    end
  end
end
