require "test_helper"

class GroupTest < ActiveSupport::TestCase
  test "add_member creates a new membership and increments memberships_count" do
    group = Group.create!(name: "Test Group")
    user = create_user

    assert_difference "group.memberships.count", 1 do
      group.add_member(user.id, "member")
    end
    assert_equal 1, group.reload.memberships_count
    assert_equal "member", group.memberships.find_by(user: user).role
  end

  test "add_member on an existing membership updates role without a duplicate or extra count increment" do
    group = Group.create!(name: "Test Group 2")
    user = create_user
    group.add_member(user.id, "member")
    assert_equal 1, group.reload.memberships_count

    assert_no_difference "group.memberships.count" do
      group.add_member(user.id, "admin")
    end
    assert_equal 1, group.reload.memberships_count
    assert_equal "admin", group.memberships.find_by(user: user).role
  end

  test "name presence validation" do
    group = Group.new(name: "")
    assert_not group.valid?
  end
end
