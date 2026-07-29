require "test_helper"

class GroupInviteTest < ActiveSupport::TestCase
  test "role vocabulary matches Membership's exactly (an invite's role is passed straight through on accept)" do
    group = create_group
    %w(member manager owner).each do |role|
      invite = GroupInvite.new(group: group, role: role, status: "sending", receiver_address_type: "email", receiver_address: "x@test.com")
      assert invite.valid?, "expected role '#{role}' to be valid: #{invite.errors.full_messages}"
    end
  end

  test "'admin' is not accepted — the group-membership tier is 'manager', and 'admin' would silently break acceptance" do
    group = create_group
    invite = GroupInvite.new(group: group, role: "admin", status: "sending", receiver_address_type: "email", receiver_address: "x@test.com")
    assert_not invite.valid?
    assert_includes invite.errors[:role], "is not included in the list"
  end
end
