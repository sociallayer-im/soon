require "test_helper"
require "vips"

class SafeImageUploadTest < ActiveSupport::TestCase
  def image
    StringIO.new(Vips::Image.black(20, 20).pngsave_buffer)
  end

  test "checks exact normalized bytes before public upload and records receipt" do
    checked = nil
    stored = nil
    WechatContentSafety.stub(:check_image!, ->(bytes) { checked = bytes }) do
      ObjectStore.stub(:upload, ->(io:, content_type:) { stored = io.read; assert_equal "image/jpeg", content_type; "https://datastore.sola.day/test-safe" }) do
        assert_difference "ContentSafetyImage.count", 1 do
          assert_equal "https://datastore.sola.day/test-safe", SafeImageUpload.upload!(image)
        end
      end
    end
    assert_equal checked, stored
    assert_equal Digest::SHA256.hexdigest(stored), ContentSafetyImage.last.sha256
  end

  test "unsafe or unavailable images never reach public storage" do
    [WechatContentSafety::Rejected, WechatContentSafety::Unavailable].each do |error|
      WechatContentSafety.stub(:check_image!, ->(*) { raise error }) do
        ObjectStore.stub(:upload, ->(**) { flunk "unchecked image uploaded" }) do
          assert_no_difference "ContentSafetyImage.count" do
            assert_raises(error) { SafeImageUpload.upload!(image) }
          end
        end
      end
    end
  end

  test "SVG cannot be disguised as a raster upload" do
    assert_raises(SafeImageUpload::InvalidImage) do
      SafeImageUpload.upload!(StringIO.new('<svg xmlns="http://www.w3.org/2000/svg"><image href="http://localhost/private"/></svg>'))
    end
  end

  test "invalid bytes fail before checking or storing" do
    assert_raises(SafeImageUpload::InvalidImage) { SafeImageUpload.upload!(StringIO.new("not an image")) }
  end
end
