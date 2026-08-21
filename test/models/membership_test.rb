require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  test "valid roles pass" do
    user = create_user
    group = create_group
    %w(member manager owner).each_with_index do |role, i|
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
    dup = Membership.new(user: user, group: group, role: "manager")
    assert_not dup.valid?
    assert_includes dup.errors[:user_id], "can only join a group once"
  end

  test "unexpired? is true for a permanent (expires_at nil) membership" do
    membership = Membership.new(expires_at: nil)
    assert membership.unexpired?
  end

  test "unexpired? is true before expiry and false after" do
    future = Membership.new(expires_at: 1.day.from_now)
    past = Membership.new(expires_at: 1.day.ago)
    assert future.unexpired?
    assert_not past.unexpired?
  end

  test "unexpired? does not shadow the active column's own predicate" do
    membership = Membership.new(active: false, expires_at: nil)
    assert membership.unexpired?, "expiry check should pass regardless of the active column"
    assert_not membership.active?, "the active column's own generated predicate must still reflect the column"
  end

  test "active scope excludes expired rows but keeps permanent and future-expiring ones" do
    group = create_group
    permanent = Membership.create!(user: create_user, group: group, role: "member")
    future = Membership.create!(user: create_user, group: group, role: "member", expires_at: 1.day.from_now)
    expired = Membership.create!(user: create_user, group: group, role: "member", expires_at: 1.day.ago)

    active_ids = group.memberships.active.pluck(:id)
    assert_includes active_ids, permanent.id
    assert_includes active_ids, future.id
    assert_not_includes active_ids, expired.id
  end
end
