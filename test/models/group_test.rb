require "test_helper"

class GroupTest < ActiveSupport::TestCase
  test "add_member creates a new membership and increments memberships_count" do
    group = Group.create!(name: "test-group")
    user = create_user

    assert_difference "group.memberships.count", 1 do
      group.add_member(user.id, "member")
    end
    assert_equal 1, group.reload.memberships_count
    assert_equal "member", group.memberships.find_by(user: user).role
  end

  test "add_member on an existing membership updates role without a duplicate or extra count increment" do
    group = Group.create!(name: "test-group-2")
    user = create_user
    group.add_member(user.id, "member")
    assert_equal 1, group.reload.memberships_count

    assert_no_difference "group.memberships.count" do
      group.add_member(user.id, "manager")
    end
    assert_equal 1, group.reload.memberships_count
    assert_equal "manager", group.memberships.find_by(user: user).role
  end

  test "add_member raises on an invalid role and does not increment memberships_count" do
    group = Group.create!(name: "test-group-3")
    user = create_user

    assert_raises(ActiveRecord::RecordInvalid) { group.add_member(user.id, "bogus") }
    assert_equal 0, group.reload.memberships_count
    assert_not group.memberships.exists?(user: user)
  end

  test "add_member raises on an invalid role for an existing membership without changing its role" do
    group = Group.create!(name: "test-group-4")
    user = create_user
    group.add_member(user.id, "member")

    assert_raises(ActiveRecord::RecordInvalid) { group.add_member(user.id, "bogus") }
    assert_equal "member", group.memberships.find_by(user: user).role
  end

  test "name presence validation" do
    group = Group.new(name: "")
    assert_not group.valid?
  end

  test "event_group_ids defaults to just the group itself" do
    group = create_group
    assert_equal [group.id], group.event_group_ids
  end

  test "event_group_ids includes event_union partners and de-dupes" do
    group = create_group
    partner = create_group
    group.update!(event_union: [group.id, partner.id, partner.id])
    assert_equal [group.id, partner.id].sort, group.event_group_ids.sort
  end

  test "venue_group_ids defaults to just the group itself" do
    group = create_group
    assert_equal [group.id], group.venue_group_ids
  end

  test "venue_group_ids includes venue_union partners" do
    group = create_group
    partner = create_group
    group.update!(venue_union: [partner.id])
    assert_equal [group.id, partner.id].sort, group.venue_group_ids.sort
  end
end
