require "test_helper"

class TrackTest < ActiveSupport::TestCase
  test "name must be unique, backed by a DB-level unique index" do
    group = create_group
    Track.create!(name: "shared-name", title: "First", group: group)

    duplicate = Track.new(name: "shared-name", title: "Second", group: group)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
    assert_raises(ActiveRecord::RecordInvalid) { duplicate.save! }
  end

  test "name uniqueness is global, not scoped to group (per the migration's plain unique index)" do
    group_a = create_group
    group_b = create_group
    Track.create!(name: "cross-group-name", title: "A", group: group_a)

    duplicate_in_other_group = Track.new(name: "cross-group-name", title: "B", group: group_b)
    assert_not duplicate_in_other_group.valid?
  end

  test "bypassing the model validation still hits the DB unique index" do
    group = create_group
    Track.create!(name: "raw-insert-name", title: "First", group: group)

    assert_raises(ActiveRecord::RecordNotUnique) do
      Track.connection.execute(
        "INSERT INTO tracks (id, name, title, group_id, created_at, updated_at) " \
        "VALUES ('rawtrackidxxxx', 'raw-insert-name', 'dup', '#{group.id}', now(), now())"
      )
    end
  end
end
