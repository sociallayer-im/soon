require "test_helper"

class ObjectStoreTest < ActiveSupport::TestCase
  test "upload raises a clear error when not configured" do
    ObjectStore.stub :configured?, false do
      err = assert_raises(ObjectStore::Error) do
        ObjectStore.upload(io: StringIO.new("x"), content_type: "image/png")
      end
      assert_match "not configured", err.message
    end
  end

  test "the key is the first 16 hex chars of the body's SHA-256" do
    # Same derivation sails used, so new uploads keep landing in the same
    # namespace as the ~10k existing datastore.sola.day objects.
    body = "some image bytes"
    expected = Digest::SHA256.hexdigest(body)[0...16]

    put = nil
    client = Object.new
    client.define_singleton_method(:put_object) { |**args| put = args }

    with_config(client) do
      url = ObjectStore.upload(io: StringIO.new(body), content_type: "image/png")
      assert_equal "https://datastore.example/#{expected}", url
    end

    assert_equal expected, put[:key]
    assert_equal "sola", put[:bucket]
    assert_equal body, put[:body]
    # sails omitted this, leaving every old object as application/octet-stream.
    assert_equal "image/png", put[:content_type]
  end

  test "identical bytes produce the same key regardless of content type" do
    keys = []
    client = Object.new
    client.define_singleton_method(:put_object) { |**args| keys << args[:key] }

    with_config(client) do
      ObjectStore.upload(io: StringIO.new("same"), content_type: "image/png")
      ObjectStore.upload(io: StringIO.new("same"), content_type: "image/webp")
    end

    assert_equal 1, keys.uniq.size
  end

  test "a trailing slash on S3_URL does not double up in the returned URL" do
    client = Object.new
    client.define_singleton_method(:put_object) { |**| nil }

    with_config(client, public_url: "https://datastore.example/") do
      url = ObjectStore.upload(io: StringIO.new("x"), content_type: "image/png")
      assert_equal "https://datastore.example/#{Digest::SHA256.hexdigest('x')[0...16]}", url
    end
  end

  test "an S3 failure surfaces as ObjectStore::Error" do
    client = Object.new
    client.define_singleton_method(:put_object) do |**|
      raise Aws::S3::Errors::AccessDenied.new(nil, "Access Denied")
    end

    with_config(client) do
      err = assert_raises(ObjectStore::Error) do
        ObjectStore.upload(io: StringIO.new("x"), content_type: "image/png")
      end
      assert_match "upload failed", err.message
    end
  end

  private

  def with_config(client, public_url: "https://datastore.example")
    ObjectStore.stub :configured?, true do
      ObjectStore.stub :client, client do
        ObjectStore.stub :public_url, public_url do
          ObjectStore.stub :bucket, "sola" do
            yield
          end
        end
      end
    end
  end
end
