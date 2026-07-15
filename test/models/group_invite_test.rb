require "test_helper"

class GroupInviteTest < ActiveSupport::TestCase
  test "role vocabulary matches Membership's exactly (an invite's role is passed straight through on accept)" do
    group = create_group
    valid = GroupInvite.new(group: group, role: "admin", status: "sending", receiver_address_type: "email", receiver_address: "x@test.com")
    assert valid.valid?, "expected role 'admin' to be valid: #{valid.errors.full_messages}"
  end

  test "'manager' is no longer accepted — it was never a valid Membership role and silently broke acceptance" do
    group = create_group
    invite = GroupInvite.new(group: group, role: "manager", status: "sending", receiver_address_type: "email", receiver_address: "x@test.com")
    assert_not invite.valid?
    assert_includes invite.errors[:role], "is not included in the list"
  end
end
