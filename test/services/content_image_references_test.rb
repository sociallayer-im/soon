require "test_helper"

class ContentImageReferencesTest < ActiveSupport::TestCase
  test "extracts inline reference and HTML images without checking regular links" do
    urls = ContentImageReferences.urls({"image_url" => "https://store/cover", "content" => "![inline](https://store/one)\n\n![ref][pic]\n\n[pic]: https://store/two\n\n[link](https://example.com)\n\n<img src='https://store/three'>"})
    assert_equal %w[https://store/cover https://store/one https://store/two https://store/three], urls
  end

  test "framed approved images retain their safety receipt" do
    url = "https://store/framed"
    ContentSafetyImage.create!(url: url, sha256: "framed-hash")
    ContentImageReferences.check!({"image_url" => "#{url}#surf-frame-v1=1169,1153,1.37326,0.51336,0"})
    assert_raises(WechatContentSafety::RejectedImage) do
      ContentImageReferences.check!({"image_url" => "#{url}?different=1#surf-frame-v1=1,1,1,0,0"})
    end
    assert_raises(WechatContentSafety::RejectedImage) do
      ContentImageReferences.check!({"image_url" => "https://untrusted/image#surf-frame-v1=1,1,1,0,0"})
    end
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
