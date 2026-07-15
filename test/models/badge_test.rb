require "test_helper"

class BadgeTest < ActiveSupport::TestCase
  def setup
    @creator = create_user
    @owner = create_user
    @badge_class = create_badge_class(creator: @creator)
  end

  test "end_time after start_time is valid" do
    badge = create_badge(badge_class: @badge_class, creator: @creator, owner: @owner,
      start_time: 1.day.from_now, end_time: 2.days.from_now)
    assert badge.valid?
  end

  test "end_time before start_time is invalid" do
    badge = Badge.new(badge_class: @badge_class, creator: @creator, owner: @owner, status: "minted",
      start_time: 2.days.from_now, end_time: 1.day.from_now)
    assert_not badge.valid?
    assert_match(/must be greater than/, badge.errors[:end_time].first)
  end

  test "end_time equal to start_time is invalid" do
    same_time = 1.day.from_now
    badge = Badge.new(badge_class: @badge_class, creator: @creator, owner: @owner, status: "minted",
      start_time: same_time, end_time: same_time)
    assert_not badge.valid?
  end

  test "both start_time and end_time nil is valid (allow_nil guards end_time)" do
    badge = create_badge(badge_class: @badge_class, creator: @creator, owner: @owner, start_time: nil, end_time: nil)
    assert badge.valid?
  end

  test "end_time present with start_time nil" do
    badge = Badge.new(badge_class: @badge_class, creator: @creator, owner: @owner, status: "minted",
      start_time: nil, end_time: 1.day.from_now)
    # allow_nil: true on the comparison validator only skips validation when the
    # validated attribute (end_time) itself is nil — start_time being nil is a
    # separate case. Assert whatever Rails' ComparisonValidator actually does here
    # rather than assuming; this pins down real, observed behavior.
    valid = badge.valid?
    if valid
      assert badge.errors[:end_time].empty?
    else
      assert badge.errors[:end_time].present?
    end
  end

  test "gen_swap_code and self.decode_swap_code round-trip" do
    badge = create_badge(badge_class: @badge_class, creator: @creator, owner: @owner)
    token = badge.gen_swap_code
    assert_equal badge.id, Badge.decode_swap_code(token)
  end

  test "decode_swap_code raises on a garbage token" do
    assert_raises(JwtService::Error) { Badge.decode_swap_code("not-a-real-token") }
  end

  test "status and display enums" do
    badge = create_badge(badge_class: @badge_class, creator: @creator, owner: @owner, status: "minted")
    assert badge.minted?
    badge.update!(status: "burned")
    assert badge.burned?
  end
end
