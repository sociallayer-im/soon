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

  test "file upload requires authentication" do
    post "/api/v1/upload/file", params: { file: fixture_file_upload("cv.pdf", "application/pdf") }
    assert_response :unauthorized
  end

  test "file stores a document and returns its URL with the original name" do
    user = create_user
    delivered = nil
    stub = ->(io:, content_type:, filename: nil) {
      delivered = { content_type: content_type, filename: filename }
      "https://datastore.sola.day/0123456789abcdef.pdf"
    }

    ObjectStore.stub :upload, stub do
      post "/api/v1/upload/file",
        params: { file: fixture_file_upload("cv.pdf", "application/pdf") },
        headers: auth_headers(user)
    end

    assert_response :success
    assert_equal "https://datastore.sola.day/0123456789abcdef.pdf", json_response["url"]
    # The name travels beside the URL: the key is a content hash, so the link
    # alone says nothing about what the organizer is opening.
    assert_equal "cv.pdf", json_response["filename"]
    assert_equal "application/pdf", delivered[:content_type]
    assert_equal "cv.pdf", delivered[:filename]
  end

  test "file rejects a type the browser would execute on our own domain" do
    user = create_user
    %w[text/html image/svg+xml application/javascript].each do |type|
      post "/api/v1/upload/file",
        params: { file: fixture_file_upload("cv.pdf", type) },
        headers: auth_headers(user)
      assert_response :unprocessable_entity, "#{type} must not be storable"
      assert_match "unsupported", json_response["error"]
    end
  end

  test "extension_for only accepts a short alphanumeric suffix" do
    assert_equal ".pdf", ObjectStore.extension_for("cv.pdf")
    assert_equal ".PDF".downcase, ObjectStore.extension_for("CV.PDF")
    assert_equal "", ObjectStore.extension_for("cv")
    assert_equal "", ObjectStore.extension_for(nil)
    # Anything that could steer the key out of its namespace is dropped.
    assert_equal "", ObjectStore.extension_for("cv.../../etc/passwd")
    assert_equal "", ObjectStore.extension_for("cv.a b")
  end
end
