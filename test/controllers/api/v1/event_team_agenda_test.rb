require "test_helper"
class Api::V1::EventTeamAgendaTest < ActionDispatch::IntegrationTest
  setup do
    @owner=create_user
    @guest=create_user
    @group=create_group(owner:@owner)
    @event=create_event(group:@group,owner:@owner,status:"published",visibility:"normal",start_time:1.day.from_now,end_time:1.day.from_now+2.hours,notes:"嘉宾集合说明")
  end

  test "owner automatically has registered status and an upcoming appointment without RSVP" do
    assert_no_difference "Participant.count" do
      get "/api/v1/events",params:{attendee_id:@owner.id,collection:"upcoming"},headers:auth_headers(@owner)
    end
    assert_response :success
    row=json_response["data"].find { |e| e["id"]==@event.id }
    assert row
    assert_equal true,row["is_attending"]
    assert_equal true,row["is_event_team"]
  end

  test "linked guests are included once and removing the role removes implicit registration" do
    role=EventRole.create!(event:@event,item_type:"User",item_id:@guest.id,role:"speaker",display_name:"嘉宾")
    get "/api/v1/events",params:{attendee_id:@guest.id,collection:"upcoming"},headers:auth_headers(@guest)
    assert_response :success
    assert_equal [@event.id],json_response["data"].map { |e| e["id"] }
    get "/api/v1/events/#{@event.id}",headers:auth_headers(@guest)
    assert_response :success
    assert_equal true,json_response["is_attending"]
    assert_equal true,json_response["is_event_team"]
    assert_equal "嘉宾集合说明",json_response["notes"]
    assert_nil json_response["current_participant"]
    role.destroy!
    get "/api/v1/events/#{@event.id}",headers:auth_headers(@guest)
    assert_equal false,json_response["is_attending"]
    get "/api/v1/events",params:{attendee_id:@guest.id},headers:auth_headers(@guest)
    assert_empty json_response["data"]
  end

  test "all linked guest roles count but plain names and group membership do not" do
    %w[co_host speaker judge custom_host].each do |kind|
      role=EventRole.create!(event:@event,item_type:"User",item_id:@guest.id,role:kind,display_name:"嘉宾")
      get "/api/v1/events/#{@event.id}",headers:auth_headers(@guest)
      assert_equal true,json_response["is_event_team"],kind
      role.destroy!
    end
    EventRole.create!(event:@event,item_type:"User",role:"speaker",display_name:@guest.nickname || @guest.name)
    create_membership(user:@guest,group:@group)
    get "/api/v1/events/#{@event.id}",headers:auth_headers(@guest)
    assert_equal false,json_response["is_event_team"]
  end

  test "unlisted guest events are visible in own calendar but not to other viewers" do
    @event.update!(visibility:"unlisted")
    EventRole.create!(event:@event,item_type:"User",item_id:@guest.id,role:"judge",display_name:"评委")
    get "/api/v1/events",params:{attendee_id:@guest.id},headers:auth_headers(@guest)
    assert_equal [@event.id],json_response["data"].map { |e| e["id"] }
    get "/api/v1/events",params:{attendee_id:@guest.id},headers:auth_headers(create_user)
    assert_empty json_response["data"]
    @event.update!(status:"cancelled")
    get "/api/v1/events",params:{attendee_id:@guest.id},headers:auth_headers(@guest)
    assert_empty json_response["data"]
  end
end
