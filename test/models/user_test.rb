require "test_helper"

class UserTest < ActiveSupport::TestCase
  # The 6-character floor applies to picking a name, not to holding one:
  # live accounts registered under the old 3-character minimum must keep
  # saving unrelated changes forever.
  test "a new name must be at least 6 characters" do
    user = User.new(email: "short@test.com", name: "abc")
    assert_not user.valid?
    assert_match(/6-20/, user.errors[:name].first)

    user.name = "abcdef"
    assert user.valid?
  end

  test "a grandfathered short name keeps saving as long as it is not changed" do
    legacy = User.new(email: "legacy@test.com")
    legacy.save!
    legacy.update_column(:name, "bob") # as the old validation allowed

    legacy.reload.update!(nickname: "still here")

    assert_raises(ActiveRecord::RecordInvalid) { legacy.update!(name: "cat") }
  end
end
