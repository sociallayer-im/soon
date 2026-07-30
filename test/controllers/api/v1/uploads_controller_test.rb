require "test_helper"

class Api::V1::UploadsControllerTest < ActionDispatch::IntegrationTest
  def png_upload(type: "image/png")
    fixture_file_upload("pixel.png", type)
  end

  test "image upload requires authentication" do
    post "/api/v1/upload/image", params: { file: png_upload }
    assert_response :unauthorized
  end

  test "image stores the file and returns its datastore URL" do
    user = create_user
    delivered = nil
    stub = ->(io:, content_type:) {
      delivered = { content_type: content_type, bytes: io.read }
      "https://datastore.sola.day/0123456789abcdef"
    }

    ObjectStore.stub :upload, stub do
      post "/api/v1/upload/image", params: { file: png_upload }, headers: auth_headers(user)
    end

    assert_response :success
    assert_equal "https://datastore.sola.day/0123456789abcdef", json_response["url"]
    assert_equal "image/png", delivered[:content_type]
    assert delivered[:bytes].present?
  end

  test "image rejects a missing file" do
    user = create_user
    post "/api/v1/upload/image", params: {}, headers: auth_headers(user)
    assert_response :unprocessable_entity
    assert_match "no file", json_response["error"]
  end

  test "image rejects an unsupported content type" do
    user = create_user
    bad = fixture_file_upload("pixel.png", "application/pdf")
    post "/api/v1/upload/image", params: { file: bad }, headers: auth_headers(user)
    assert_response :unprocessable_entity
    assert_match "unsupported", json_response["error"]
  end

  test "image surfaces a storage failure as 502" do
    user = create_user
    boom = ->(**) { raise ObjectStore::Error, "upload failed: Access Denied" }
    ObjectStore.stub :upload, boom do
      post "/api/v1/upload/image", params: { file: png_upload }, headers: auth_headers(user)
    end
    assert_response :bad_gateway
    assert_match "upload failed", json_response["error"]
  end
end
