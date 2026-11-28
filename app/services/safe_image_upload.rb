require "vips"
require "stringio"
require "digest"

class SafeImageUpload
  class InvalidImage < StandardError; end

  def self.upload!(file)
    # Normalize the actual bytes we will serve, rather than checking a thumbnail
    # and then serving an unchecked original/animation/SVG.
    source = file.read.b
    supported = source.start_with?("\xFF\xD8\xFF".b, "\x89PNG\r\n\x1A\n".b, "GIF87a".b, "GIF89a".b) ||
      (source.start_with?("RIFF".b) && source.byteslice(8, 4) == "WEBP")
    raise InvalidImage, "请选择 JPG、PNG、GIF 或静态 WebP 图片。" unless supported
    image = Vips::Image.new_from_buffer(source, "", access: :sequential)
    raise InvalidImage, "请选择静态图片，暂不支持动态图。" if image.get_typeof("n-pages") != 0 && image.get("n-pages") > 1
    raise InvalidImage, "图片尺寸过大，请压缩后重试。" if image.width * image.height > 40_000_000
    image = image.autorot
    image = image.thumbnail_image(1024, height: 1024, size: :down)
    bytes = image.jpegsave_buffer(Q: 85, strip: true, background: [255, 255, 255])
    raise InvalidImage, "图片内容过大，请压缩后重试。" if bytes.bytesize > 1.megabyte
    WechatContentSafety.check_image!(bytes)
    url = ObjectStore.upload(io: StringIO.new(bytes), content_type: "image/jpeg")
    ContentSafetyImage.create_or_find_by!(url: url) { |row| row.sha256 = Digest::SHA256.hexdigest(bytes) }
    url
  rescue Vips::Error
    raise InvalidImage, "图片无法读取，请重新选择 JPG、PNG 或静态 WebP 图片。"
  ensure
    file.rewind if file.respond_to?(:rewind)
  end
end
