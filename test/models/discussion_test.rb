require "test_helper"

# Model-level rules for the discussion boards: counters, state, and the two
# validations that stop a topic drifting away from its board.
class DiscussionTest < ActiveSupport::TestCase
  def setup
    @owner = create_user
    @author = create_user
    @group = create_group(owner: @owner, discussion_enabled: true)
    @category = create_category(group: @group)
  end

  test "topic takes its group from its category" do
    topic = Topic.create!(title: "T", category: @category, user: @author)
    assert_equal @group.id, topic.group_id
  end

  test "a topic cannot point at another group's category" do
    other = create_group(owner: @owner)
    foreign = create_category(group: other)
    topic = Topic.new(title: "T", category: foreign, group: @group, user: @author)

    assert_not topic.valid?
    assert_includes topic.errors[:category], "belongs to another group"
  end

  test "replies_count and last reply count only live replies" do
    topic = create_topic(category: @category, user: @author)
    first = create_reply(topic: topic, user: @author)
    second = create_reply(topic: topic, user: @author)

    assert_equal 2, topic.reload.replies_count
    assert_equal second.id, topic.last_reply_id

    # Flagging is not deleting, but the count and the "last reply" pointer both
    # describe what a reader can see — so a hidden reply must leave both.
    second.flag!(by: @owner, reason: "spam")
    assert_equal 1, topic.reload.replies_count
    assert_equal first.id, topic.last_reply_id

    first.soft_delete!(by: @author)
    topic.refresh_last_reply!
    assert_equal 0, topic.reload.replies_count
    assert_nil topic.last_reply_id
  end

  test "category topics_count follows creation, flagging and deletion" do
    assert_equal 0, @category.reload.topics_count

    topic = create_topic(category: @category, user: @author)
    assert_equal 1, @category.reload.topics_count

    topic.flag!(by: @owner)
    assert_equal 0, @category.reload.topics_count

    topic.unflag!
    assert_equal 1, @category.reload.topics_count

    topic.soft_delete!(by: @author)
    @category.refresh_topics_count!
    assert_equal 0, @category.reload.topics_count
  end

  test "soft delete hides a topic from everyone and restore brings it back" do
    topic = create_topic(category: @category, user: @author)
    topic.soft_delete!(by: @author)

    assert_nil Topic.find_by(id: topic.id)
    assert Topic.with_deleted.exists?(id: topic.id)
    assert_equal @author.id, Topic.with_deleted.find(topic.id).deleted_by_id

    Topic.with_deleted.find(topic.id).restore!
    assert Topic.exists?(id: topic.id)
  end

  test "a reply pointing into another topic is silently unlinked" do
    topic = create_topic(category: @category, user: @author)
    other = create_topic(category: @category, user: @author)
    elsewhere = create_reply(topic: other, user: @author)

    reply = Reply.create!(topic: topic, user: @author, content: "x",
                          reply_to_id: elsewhere.id)

    # Refused rather than accepted, but without failing the write: the quote is
    # not what the person came to say.
    assert_nil reply.reply_to_id
  end

  test "a reply quoting one in the same topic keeps the pointer" do
    topic = create_topic(category: @category, user: @author)
    target = create_reply(topic: topic, user: @author)

    reply = Reply.create!(topic: topic, user: @author, content: "x",
                          reply_to_id: target.id)
    assert_equal target.id, reply.reply_to_id
  end

  test "a closed topic takes no more replies" do
    topic = create_topic(category: @category, user: @author, closed_at: Time.current)
    reply = Reply.new(topic: topic, user: @author, content: "x")

    assert_not reply.valid?
    assert_includes reply.errors[:topic], "is closed"
  end

  test "a reply older than the bump window does not resurface its topic" do
    topic = create_topic(category: @category, user: @author)
    topic.update_columns(created_at: 2.months.ago, last_active_mark: 1)

    create_reply(topic: topic, user: @author)

    # Anti-necroposting: the reply is recorded, the position in the list is not.
    assert_equal 1, topic.reload.last_active_mark
    assert_equal 1, topic.replies_count
  end

  test "tag and length limits" do
    topic = Topic.new(title: "T", category: @category, user: @author,
                      tags: Array.new(11) { |i| "t#{i}" })
    assert_not topic.valid?
    assert_includes topic.errors[:tags].join, "more than 10"

    long = Topic.new(title: "x" * 201, category: @category, user: @author)
    assert_not long.valid?
    assert_includes long.errors[:title].join, "too long"
  end

  test "category visibility resolves per viewer" do
    member = create_user
    create_membership(user: member, group: @group)
    stranger = create_user
    invitee = create_user

    public_board  = create_category(group: @group, visibility: "public")
    member_board  = create_category(group: @group, visibility: "member")
    manager_board = create_category(group: @group, visibility: "manager")
    create_membership(user: invitee, group: @group)
    team_board = create_category(group: @group, visibility: "team")
    team = create_team(group: @group, users: [ invitee ])
    CategoryTeam.create!(category: team_board, team: team)

    assert_equal [ public_board.id ].sort,
                 Category.visible_to(nil, group: @group).where.not(id: @category.id).pluck(:id).sort
    assert_equal [ public_board.id ].sort,
                 Category.visible_to(stranger, group: @group).where.not(id: @category.id).pluck(:id).sort
    assert_equal [ public_board.id, member_board.id ].sort,
                 Category.visible_to(member, group: @group).where.not(id: @category.id).pluck(:id).sort
    # A manager sees every board in the group, team-restricted ones included —
    # otherwise they could not moderate them, and a board whose team is later
    # deleted would become unreachable by anyone. See Category.visible_to.
    assert_equal [ public_board.id, member_board.id, manager_board.id, team_board.id ].sort,
                 Category.visible_to(@owner, group: @group).where.not(id: @category.id).pluck(:id).sort
    assert_equal [ public_board.id, member_board.id, team_board.id ].sort,
                 Category.visible_to(invitee, group: @group).where.not(id: @category.id).pluck(:id).sort
  end

  # The mirror of GroupPolicy's 2026-07-29 narrowing: managing a parent group
  # confers nothing over a child's content. Granting read here would have left
  # a parent manager able to read a board they are refused moderation on.
  test "a parent group's manager does NOT see a child group's manager board" do
    parent = create_group(owner: @owner)
    child = create_group(discussion_enabled: true, parent_id: parent.id)
    board = create_category(group: child, visibility: "manager")

    assert_not_includes Category.visible_to(@owner, group: child).pluck(:id), board.id

    # A manager of the child group itself does see it.
    child_manager = create_user
    create_membership(user: child_manager, group: child, role: "manager")
    assert_includes Category.visible_to(child_manager, group: child).pluck(:id), board.id
  end
end
