require "test_helper"

# Merging accounts, where teams and discussion content are concerned.
#
# Both were missing from UserMerger when they were added, and the failure was
# not subtle: from.destroy! hit their foreign keys and the whole merge raised.
class UserMergerTeamTest < ActiveSupport::TestCase
  def setup
    @from = create_user
    @into = create_user
    @group = create_group(owner: create_user, discussion_enabled: true)
    [ @from, @into ].each { |u| @group.add_member(u.id, "member") }
  end

  test "teams come across, and one both accounts share is not duplicated" do
    only_from = create_team(group: @group, users: [ @from ])
    shared    = create_team(group: @group, users: [ @from, @into ])

    UserMerger.call(from: @from, into: @into)

    assert_equal [ only_from.id, shared.id ].sort, @into.reload.teams.pluck(:id).sort
    assert_equal 1, TeamMembership.where(team: shared).count
  end

  # The ordering inside UserMerger is what makes the previous test pass:
  # Membership#after_destroy drops the leaver's team memberships in that group,
  # so deduping memberships before teams deleted the rows that were still
  # waiting to be handed over. The merge succeeded and the teams vanished.
  test "the surviving account keeps its teams even in the group both were in" do
    team = create_team(group: @group, users: [ @from ])

    UserMerger.call(from: @from, into: @into)

    assert_includes @into.reload.teams.pluck(:id), team.id
    assert_equal 1, team.reload.members_count
  end

  test "topics and replies transfer rather than being destroyed with the account" do
    category = create_category(group: @group)
    topic = create_topic(category: category, user: @from)
    reply = create_reply(topic: topic, user: @from)
    other = create_topic(category: category, user: @into)
    other.update_columns(flagged_at: Time.current, flagged_by_id: @from.id)

    UserMerger.call(from: @from, into: @into)

    assert_equal @into.id, topic.reload.user_id
    assert_equal @into.id, reply.reload.user_id
    # Audit columns follow too — the person who hid it still exists, as `into`.
    assert_equal @into.id, other.reload.flagged_by_id
  end

  test "a merge does not raise when the absorbed account has discussion rows" do
    category = create_category(group: @group)
    create_topic(category: category, user: @from)
    create_team(group: @group, users: [ @from ])

    assert_nothing_raised { UserMerger.call(from: @from, into: @into) }
    assert_not User.exists?(@from.id)
  end
end
