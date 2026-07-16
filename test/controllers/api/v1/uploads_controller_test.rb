require "test_helper"

class Api::V1::UploadsControllerTest < ActionDispatch::IntegrationTest
  def png_upload(type: "image/png")
    fixture_file_upload("pixel.png", type)
  end

  test "image upload requires authentication" do
    post "/api/v1/upload/image", params: { file: png_upload }
    assert_response :unauthorized
  end

  test "image forwards the file to Cloudflare and returns the delivery URL" do
    user = create_user
    delivered = nil
    stub = ->(io:, filename:, content_type:) {
      delivered = { filename: filename, content_type: content_type }
      "https://imagedelivery.net/hash/abc/public"
    }

    CloudflareImages.stub :upload, stub do
      post "/api/v1/upload/image", params: { file: png_upload }, headers: auth_headers(user)
    end

    assert_response :success
    assert_equal "https://imagedelivery.net/hash/abc/public", json_response["url"]
    assert_equal "pixel.png", delivered[:filename]
    assert_equal "image/png", delivered[:content_type]
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

  test "image surfaces a Cloudflare failure as 502" do
    user = create_user
    boom = ->(**) { raise CloudflareImages::Error, "Cloudflare upload failed (HTTP 500)" }
    CloudflareImages.stub :upload, boom do
      post "/api/v1/upload/image", params: { file: png_upload }, headers: auth_headers(user)
    end
    assert_response :bad_gateway
    assert_match "Cloudflare upload failed", json_response["error"]
  end
end
