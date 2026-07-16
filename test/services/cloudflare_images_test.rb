require "test_helper"

class CloudflareImagesTest < ActiveSupport::TestCase
  test "delivery_url prefers the /public variant, falling back to the first" do
    with_public = { "result" => { "variants" => [
      "https://imagedelivery.net/hash/id/thumbnail",
      "https://imagedelivery.net/hash/id/public"
    ] } }
    assert_equal "https://imagedelivery.net/hash/id/public",
      CloudflareImages.send(:delivery_url, with_public)

    no_public = { "result" => { "variants" => ["https://imagedelivery.net/hash/id/thumbnail"] } }
    assert_equal "https://imagedelivery.net/hash/id/thumbnail",
      CloudflareImages.send(:delivery_url, no_public)
  end

  test "upload raises a clear error when not configured" do
    CloudflareImages.stub :configured?, false do
      err = assert_raises(CloudflareImages::Error) do
        CloudflareImages.upload(io: StringIO.new("x"), filename: "a.png", content_type: "image/png")
      end
      assert_match "not configured", err.message
    end
  end
end
