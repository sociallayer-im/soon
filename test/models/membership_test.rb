require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  test "valid roles pass" do
    user = create_user
    group = create_group
    %w(member admin owner).each_with_index do |role, i|
      u = create_user
      m = Membership.new(user: u, group: group, role: role)
      assert m.valid?, "expected role #{role} to be valid: #{m.errors.full_messages}"
    end
  end

  test "an arbitrary role string is invalid" do
    user = create_user
    group = create_group
    membership = Membership.new(user: user, group: group, role: "superadmin")
    assert_not membership.valid?
    assert_includes membership.errors[:role], "is not included in the list"
  end

  test "a user can only join a group once" do
    user = create_user
    group = create_group
    Membership.create!(user: user, group: group, role: "member")
    dup = Membership.new(user: user, group: group, role: "admin")
    assert_not dup.valid?
    assert_includes dup.errors[:user_id], "can only join a group once"
  end
end
