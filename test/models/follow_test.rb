require "test_helper"

class FollowTest < ActiveSupport::TestCase
  test "a user cannot follow the same target twice or follow themselves" do
    user = create_user
    other = create_user
    create_follow(user: user, target: other)

    duplicate = Follow.new(user: user, target: other, status: "active")
    assert_not duplicate.valid?

    self_follow = Follow.new(user: user, target: user, status: "active")
    assert_not self_follow.valid?
  end

  test "status and target type are constrained" do
    user = create_user
    other = create_user
    follow = Follow.new(user: user, target: other, status: "blocked")
    assert_not follow.valid?

    follow.status = "active"
    follow.target = nil
    follow.target_type = "Event"
    follow.target_id = other.id
    assert_not follow.valid?
  end
end
