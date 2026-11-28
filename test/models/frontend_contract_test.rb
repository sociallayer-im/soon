require "test_helper"

class FrontendContractTest < ActiveSupport::TestCase
  test "profile exposes saved cover without exposing arbitrary data" do
    user = create_user(data: {cover_image_url: "https://assets.juluo.xyz/cover", private_value: "hidden"})
    result = UserBlueprint.render_as_hash(user, view: :profile)
    assert_equal "https://assets.juluo.xyz/cover", result[:cover_image_url]
    assert_not result.key?(:data)
  end

  test "list preserves attachment markdown beyond excerpt boundary" do
    owner = create_user
    group = create_group(owner: owner)
    topic = create_topic(category: create_category(group: group), user: owner,
      content: "a" * 700 + "\n![Surf 帖子附件](https://assets.juluo.xyz/photo)")
    result = TopicBlueprint.render_as_hash(topic)
    assert_includes result[:image_urls], "https://assets.juluo.xyz/photo"
    assert_operator result[:content].length, :<, topic.content.length
    assert_equal topic.content, TopicBlueprint.render_as_hash(topic, view: :detail)[:content]
  end

  test "event list includes named roles" do
    owner = create_user
    event = create_event(group: create_group(owner: owner), owner: owner)
    event.event_roles.create!(role: "speaker", item_type: "User", item_id: owner.id, display_name: "嘉宾")
    result = EventBlueprint.render_as_hash(event)
    assert_equal "嘉宾", result[:event_roles].first[:display_name]
    assert_not result[:event_roles].first.key?(:email)
    event.event_roles.first.update!(email: "invite@example.com")
    assert_equal "invite@example.com", EventBlueprint.render_as_hash(event.reload, view: :extended, manage_participants: true)[:event_roles].first[:email]
  end

  test "discussion and stars notify once and never notify self" do
    owner = create_user
    writer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    category = create_category(group: group)
    topic = create_topic(category: category, user: writer, event: event)
    assert_equal 1, Activity.where(receiver: owner, item: topic, action: "surf/event_discussion").count
    reply = create_reply(topic: topic, user: owner)
    assert_equal 1, Activity.where(receiver: writer, item: topic, action: "surf/reply").count
    assert_equal 0, Activity.where(receiver: owner, item: topic, action: "surf/reply").count
    2.times do
      star = Comment.create!(user: owner, item: topic, comment_type: "star")
      star.destroy!
    end
    assert_equal 1, Activity.where(receiver: writer, item: topic, action: "surf/topic_star").count
    Comment.create!(user: writer, item: topic, comment_type: "star")
    assert_equal 0, Activity.where(receiver: writer, initiator: writer, item: topic, action: "surf/topic_star").count
  end
end
