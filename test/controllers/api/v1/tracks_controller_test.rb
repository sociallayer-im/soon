require "test_helper"

class Api::V1::TracksControllerTest < ActionDispatch::IntegrationTest
  test "index lists tracks" do
    user = create_user
    owner = create_user
    group = create_group(owner: owner)
    track = create_track(group: group)

    get "/api/v1/tracks", headers: auth_headers(user)
    assert_response :success
    ids = json_response["data"].map { |t| t["id"] }
    assert_includes ids, track.id
  end

  test "index is public but create requires authentication" do
    get "/api/v1/tracks"
    assert_response :success

    post "/api/v1/tracks", params: { track: { title: "X" } }
    assert_response :unauthorized
  end

  test "show returns a track with its group" do
    user = create_user
    owner = create_user
    group = create_group(owner: owner)
    track = create_track(group: group)

    get "/api/v1/tracks/#{track.id}", headers: auth_headers(user)
    assert_response :success
    assert_equal track.id, json_response["id"]
    assert_equal group.id, json_response["group"]["id"]
  end

  test "show 404s for an unknown id" do
    user = create_user
    get "/api/v1/tracks/does-not-exist", headers: auth_headers(user)
    assert_response :not_found
  end

  test "name must be unique at the model level" do
    owner = create_user
    group = create_group(owner: owner)
    create_track(group: group, name: "Duplicate Track")

    assert_raises(ActiveRecord::RecordInvalid) do
      Track.create!(name: "Duplicate Track", title: "Other Title", group: group)
    end
  end

  # This session added a DB-level unique index (db/migrate/20260316000000) backing
  # Track#name's uniqueness validation. Confirm the constraint is enforced even if the
  # model-level validation were somehow bypassed (e.g. two racing inserts).
  test "name uniqueness is enforced at the database level, not just in the model" do
    owner = create_user
    group = create_group(owner: owner)
    create_track(group: group, name: "DB Enforced Track")

    duplicate = Track.new(name: "DB Enforced Track", title: "Other Title", group: group)
    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate.save!(validate: false)
    end
  end
end
