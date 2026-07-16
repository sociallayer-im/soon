require "test_helper"

class Api::V1::PlacesControllerTest < ActionDispatch::IntegrationTest
  test "index lists places" do
    user = create_user
    place = create_place

    get "/api/v1/places", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |p| p["id"] }
    assert_includes ids, place.id
  end

  test "index requires authentication" do
    get "/api/v1/places"
    assert_response :unauthorized
  end

  test "show returns a place" do
    user = create_user
    place = create_place(address: "123 Main St")

    get "/api/v1/places/#{place.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal place.id, json_response["id"]
    assert_equal "123 Main St", json_response["address"]
  end

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/places/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "name must be unique" do
    create_place(name: "Duplicate Place")
    assert_raises(ActiveRecord::RecordInvalid) do
      Place.create!(name: "Duplicate Place")
    end
  end

  test "latitude is bounded to +/-90 and longitude to +/-180" do
    place = Place.new(name: "Bad Coords", latitude: 200, longitude: -200)
    assert_not place.valid?
    assert_includes place.errors[:latitude], "must be less than or equal to 90"
    assert_includes place.errors[:longitude], "must be greater than or equal to -180"
  end

  test "latitude and longitude are optional" do
    place = Place.new(name: "No Coords")
    assert place.valid?
  end
end
