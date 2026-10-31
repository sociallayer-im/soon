require "test_helper"

class Api::V1::MiniprogramReviewContractsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_gate=ENV["DISCUSSION_ENABLED"]
    ENV["DISCUSSION_ENABLED"]="true"
    @owner=create_user
    @viewer=create_user
    @group=create_group(owner:@owner,city:"上海")
    @event=create_event(group:@group,owner:@owner,status:"published",start_time:1.day.from_now,end_time:2.days.from_now)
  end

  teardown { ENV["DISCUSSION_ENABLED"]=@previous_gate }

  test "detail capabilities recognize group managers and email-linked editors but not judges" do
    create_membership(user:@viewer,group:@group,role:"manager")
    get "/api/v1/events/#{@event.id}",params:{include_participants:false},headers:auth_headers(@viewer)
    assert_response :success
    assert_equal true,json_response["can_edit"]
    assert_equal true,json_response["can_manage_participants"]
    assert_equal true,json_response["can_check_in"]
    assert_not json_response.key?("participants")
    @viewer.memberships.destroy_all
    role=EventRole.create!(event:@event,role:"speaker",item_type:"User",display_name:"邮箱嘉宾",email:@viewer.email)
    get "/api/v1/events/#{@event.id}",headers:auth_headers(@viewer)
    assert_equal true,json_response["can_edit"]
    role.update!(role:"judge")
    get "/api/v1/events/#{@event.id}",headers:auth_headers(@viewer)
    assert_equal false,json_response["can_edit"]
  end

  test "closed future events report registration unavailable with a specific reason" do
    @event.update!(status:"closed")
    get "/api/v1/events/#{@event.id}"
    assert_response :success
    assert_equal false,json_response["can_register"]
    assert_equal "报名已截止",json_response["registration_unavailable_reason"]
  end

  test "unified personal agenda paginates hosted and attending events once" do
    create_participant(event:@event,user:@owner,status:"attending")
    guest_event=create_event(group:@group,owner:@viewer,status:"published")
    create_participant(event:guest_event,user:@owner,status:"attending")
    ids=[]
    2.times do |i|
      get "/api/v1/events",params:{user_id:@owner.id,limit:1,page:i+1},headers:auth_headers(@owner)
      assert_response :success
      ids.concat(json_response["data"].map { |row| row["id"] })
      assert_equal 2,json_response["meta"]["total"]
    end
    assert_equal [@event.id,guest_event.id].sort,ids.sort
  end

  test "team registration list exposes admission without inventing RSVP rows" do
    EventRole.create!(event:@event,role:"speaker",item_type:"User",item_id:@viewer.id,display_name:"嘉宾")
    assert_no_difference "Participant.count" do
      get "/api/v1/registrations",params:{team:true,limit:1},headers:auth_headers(@viewer)
    end
    assert_response :success
    assert_equal [@event.id],json_response["data"].map { |row| row["id"] }
    assert_equal true,json_response["data"].first["is_event_team"]
    assert_nil json_response["meta"]["next_page"]
  end

  test "ranked account picker follows first and paginates without duplicates or private profiles" do
    followed=create_user
    hidden=create_user(data:{visibility:"private"})
    Follow.create!(user:@viewer,target:followed,status:"active")
    Follow.create!(user:@viewer,target:hidden,status:"active")
    create_event(group:@group,owner:followed,status:"published")
    get "/api/v1/users/role_candidates",params:{limit:1},headers:auth_headers(@viewer)
    assert_response :success
    assert_equal followed.id,json_response["data"].first["id"]
    assert_equal 2,json_response["meta"]["next_page"]
    get "/api/v1/users/role_candidates",params:{limit:1,page:2},headers:auth_headers(@viewer)
    assert_equal [@owner.id],json_response["data"].map { |row| row["id"] }
    assert_nil json_response["meta"]["next_page"]
  end

  test "profile posts use category and group visibility and expose pagination" do
      category=create_category(group:@group,visibility:"public")
      visible=create_topic(category:category,user:@owner)
      private_category=create_category(group:@group,visibility:"manager")
      create_topic(category:private_category,user:@owner)
      disabled=create_group(owner:@owner,discussion_enabled:false)
      create_topic(category:create_category(group:disabled,visibility:"public"),user:@owner)
      get "/api/v1/users/#{@owner.id}/topics",params:{page:1,limit:1}
      assert_response :success
      assert_equal [visible.id],json_response["data"].map { |row| row["id"] }
      assert_equal 1,json_response["meta"]["total"]
  end

  test "membership lists opt into pagination while old clients keep array contract" do
    create_membership(user:@viewer,group:@group)
    get "/api/v1/users/#{@viewer.id}/groups",params:{page:1,limit:1}
    assert_response :success
    assert_equal 1,json_response["data"].length
    assert_equal 1,json_response["meta"]["total"]
    get "/api/v1/users/#{@viewer.id}/groups"
    assert_kind_of Array,json_response
  end

  test "availability replacement rolls back earlier slots and deletion if a later slot fails" do
    venue=create_venue(group:@group,owner:@owner)
    original=venue.availabilities.create!(day_of_week:"monday",intervals:[["08:00","10:00"]],role_required:"all")
    post "/api/v1/venues/#{venue.id}/availability",params:{availabilities:[{day_of_week:"tuesday",intervals:[]},{day_of_week:"invalid",intervals:[]}]},headers:auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_equal [original.id],venue.availabilities.reload.pluck(:id)
  end
  test "role candidates include eligible community members only for roster-authorized viewers" do
    member=create_user
    outsider=create_user
    create_membership(user:member,group:@group)
    create_membership(user:@viewer,group:@group)
    get "/api/v1/users/role_candidates",params:{group_id:@group.id},headers:auth_headers(@viewer)
    assert_response :success
    ids=json_response["data"].map { |row| row["id"] }
    assert_includes ids,member.id
    assert_equal ids.uniq,ids
    get "/api/v1/users/role_candidates",params:{group_id:@group.id},headers:auth_headers(outsider)
    assert_response :success
    assert_not_includes json_response["data"].map { |row| row["id"] },member.id
  end

  test "linked-event summary retains visibility authorization without loading full bodies" do
    @event.update!(content:"正文" * 2000)
    get "/api/v1/events/#{@event.id}",params:{summary:true,include_participants:false}
    assert_response :success
    assert_equal @event.title,json_response["title"]
    assert_not json_response.key?("content")
    assert_not json_response.key?("participants")
    @event.update!(status:"draft")
    get "/api/v1/events/#{@event.id}",params:{summary:true}
    assert_response :forbidden
  end

  test "mine orders do not require a public handle and never reveal another buyers order" do
    @viewer.update!(name:nil)
    ticket=create_ticket(event:@event)
    own=TicketItem.create!(event:@event,ticket:ticket,user:@viewer,ticket_type:"event",status:"pending",amount:10,currency:"cny")
    other=TicketItem.create!(event:@event,ticket:ticket,user:@owner,ticket_type:"event",status:"pending",amount:10,currency:"cny")
    get "/api/v1/tickets/list",params:{event_id:@event.id,mine:true,status:"pending",profile_handle:@owner.name},headers:auth_headers(@viewer)
    assert_response :success
    assert_equal [own.id],json_response.map { |row| row["id"] }
    assert_not_includes json_response.map { |row| row["id"] },other.id
    get "/api/v1/tickets/list",params:{event_id:@event.id,mine:true}
    assert_response :unauthorized
  end

end
