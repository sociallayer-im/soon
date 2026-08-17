require "test_helper"

# The rule is shared by User and Group (app/models/concerns/handle_name.rb),
# so it is tested against both — the whole point of the concern is that they
# stopped disagreeing, and a test that only covered one would not notice them
# drifting apart again.
class HandleNameTest < ActiveSupport::TestCase
  def new_user(name) = User.new(email: "h#{unique_suffix}@test.com", name: name)
  def new_group(name) = Group.new(name: name)

  test "hyphens are allowed and underscores are not, on both models" do
    assert new_user("edge-city").valid?
    assert new_group("edge-city").valid?

    assert_not new_user("edge_city").valid?
    assert_not new_group("edge_city").valid?
  end

  test "the length window is 6-20 on both models" do
    assert_not new_user("abcde").valid?
    assert_not new_group("abcde").valid?
    assert new_user("abcdef").valid?
    assert new_group("abcdef").valid?

    assert new_user("a" * 20).valid?
    assert_not new_user("a" * 21).valid?
    assert_not new_group("a" * 21).valid?
  end

  test "a handle that would shadow a frontend route is refused" do
    # /group/create is the group creation screen; a group actually called
    # "create" could never be reached at /group/create.
    assert_not new_group("create").valid?
    assert_not new_user("detail").valid?
    assert_match(/reserved/, new_group("create").tap(&:valid?).errors[:name].first)

    assert new_group("creates").valid?
  end

  # The guard that keeps live data saveable. Production holds 97 users below
  # the floor, 11 above the ceiling and 6 groups out of range — every one of
  # them would be frozen out of every future save without this.
  test "an existing out-of-range name keeps saving as long as it is not changed" do
    group = create_group
    group.update_column(:name, "sf") # as an older validation allowed

    group.reload.update!(nickname: "still here")
    assert_equal "sf", group.reload.name

    assert_raises(ActiveRecord::RecordInvalid) { group.update!(name: "nyc") }
  end

  test "a user with no name at all is untouched by the rule" do
    # `name` is nil until the register screen, and every account exists before
    # that point — validating blank here would break sign-up itself.
    assert User.new(email: "noname#{unique_suffix}@test.com").valid?
  end
end
