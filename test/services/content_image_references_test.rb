require "test_helper"

class ContentImageReferencesTest < ActiveSupport::TestCase
  test "extracts inline reference and HTML images without checking regular links" do
    urls = ContentImageReferences.urls({"image_url" => "https://store/cover", "content" => "![inline](https://store/one)\n\n![ref][pic]\n\n[pic]: https://store/two\n\n[link](https://example.com)\n\n<img src='https://store/three'>"})
    assert_equal %w[https://store/cover https://store/one https://store/two https://store/three], urls
  end

  test "unchecked remote URL cannot bypass upload safety" do
    assert_raises(WechatContentSafety::RejectedImage) { ContentImageReferences.check!({"content" => "![x](https://untrusted/image.jpg)"}) }
  end

  test "only approved or unchanged historical images are allowed" do
    url = "https://store/checked"
    ContentSafetyImage.create!(url: url, sha256: "checked-hash")
    ContentImageReferences.check!({"image_url" => url})
    previous = Struct.new(:attributes).new({"image_url" => "https://store/historical"})
    ContentImageReferences.check!({"image_url" => "https://store/historical", "content" => "new text"}, previous: previous)
    assert_raises(WechatContentSafety::RejectedImage) { ContentImageReferences.check!({"image_url" => "https://store/replaced"}, previous: previous) }
  end
end
