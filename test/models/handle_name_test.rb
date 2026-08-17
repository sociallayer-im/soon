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

  test "a hyphen must sit between other characters" do
    assert new_user("edge-city").valid?
    assert new_user("edge-city-two").valid?

    assert_not new_user("-edgecity").valid?
    assert_not new_user("edgecity-").valid?
    assert_not new_user("edge--city").valid?
    assert_not new_group("-edgecity").valid?
    assert_not new_group("edgecity-").valid?
    assert_not new_group("edge--city").valid?
  end

  # users.name and groups.name are each uniquely indexed, but separately —
  # `domains` is what makes the two one namespace.
  test "a group cannot take a handle a user holds, or the other way round" do
    user = create_user(name: "sharedname")
    assert_equal "sharedname", Domain.find_by(item_type: "User", item_id: user.id)&.name

    group = Group.new(name: "sharedname")
    assert_not group.valid?
    assert_match(/taken/, group.errors[:name].first)

    other = create_group(name: "othername")
    other.name = "sharedname"
    assert_not other.valid?
  end

  test "the registry row follows a rename and frees the old handle" do
    user = create_user(name: "firstname")
    user.update!(name: "secondname")

    assert_nil Domain.find_by(name: "firstname")
    assert_equal user.id, Domain.find_by(name: "secondname").item_id
    assert_equal 1, Domain.where(item_type: "User", item_id: user.id).count

    # Which is the point: the handle it gave up is now available.
    assert Group.new(name: "firstname").valid?
  end

  test "a group and a user each get their own registry row" do
    user = create_user(name: "aaauser")
    group = create_group(name: "bbbgroup")

    assert_equal "User", Domain.find_by(name: "aaauser").item_type
    assert_equal "Group", Domain.find_by(name: "bbbgroup").item_type
  end

  # UserMerger repoints the absorbed account's registry row at the survivor,
  # so a merge can leave one item holding two.
  test "a rename collapses duplicate registry rows for the same item" do
    user = create_user(name: "keepername")
    Domain.create!(item_type: "User", item_id: user.id, name: "strayname",
                   fullname: "strayname.sola.day")
    assert_equal 2, Domain.where(item_type: "User", item_id: user.id).count

    user.update!(name: "finalname")

    assert_equal [ "finalname" ], Domain.where(item_type: "User", item_id: user.id).pluck(:name)
    # The handle the stray row was sitting on is free again.
    assert Group.new(name: "strayname").valid?
  end

  test "a user with no name at all is untouched by the rule" do
    # `name` is nil until the register screen, and every account exists before
    # that point — validating blank here would break sign-up itself.
    assert User.new(email: "noname#{unique_suffix}@test.com").valid?
  end
end
