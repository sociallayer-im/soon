require "test_helper"

class Api::V1::VenuesControllerTest < ActionDispatch::IntegrationTest
  test "index lists venues" do
    user = create_user
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner)

    get "/api/v1/venues", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |v| v["id"] }
    assert_includes ids, venue.id
  end

  test "index requires authentication" do
    get "/api/v1/venues"
    assert_response :unauthorized
  end

  test "show returns a venue" do
    user = create_user
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner, capacity: 50)

    get "/api/v1/venues/#{venue.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal venue.id, json_response["id"]
    assert_equal 50, json_response["capacity"]
  end

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/venues/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "name must be unique" do
    owner = create_user
    group = create_group(owner: owner)
    create_venue(group: group, owner: owner, name: "Duplicate Venue")

    assert_raises(ActiveRecord::RecordInvalid) do
      Venue.create!(name: "Duplicate Venue", group: group, owner: owner)
    end
  end

  test "capacity must be a positive integer when present" do
    owner = create_user
    group = create_group(owner: owner)
    venue = Venue.new(name: "Bad Capacity", group: group, owner: owner, capacity: 0)
    assert_not venue.valid?
    assert_includes venue.errors[:capacity], "must be greater than 0"

    venue.capacity = -5
    assert_not venue.valid?
  end

  test "capacity is optional" do
    owner = create_user
    group = create_group(owner: owner)
    venue = Venue.new(name: "No Capacity", group: group, owner: owner)
    assert venue.valid?
  end
end
