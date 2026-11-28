require "kramdown"
require "nokogiri"

class ContentImageReferences
  IMAGE_FIELDS = %w[image_url image_note icon_url].freeze
  TEXT_FIELDS = %w[content notes description].freeze

  def self.urls(attrs)
    data = attrs.to_h.stringify_keys
    urls = IMAGE_FIELDS.filter_map { |field| data[field].presence }
    TEXT_FIELDS.each do |field|
      next if data[field].blank?
      html = Kramdown::Document.new(data[field].to_s).to_html
      urls.concat(Nokogiri::HTML.fragment(html).css("img[src]").map { |img| img["src"] })
    end
    # Fragments describe client-side framing and never change fetched bytes.
    # Preserve query strings: they may identify a different stored resource.
    urls.map { |url| url.to_s.split("#", 2).first }.reject(&:blank?).uniq
  end

  def self.check!(attrs, previous: nil)
    # Historical unchanged images stay editable; a newly attached image must
    # have a durable receipt from our own checked upload (no remote URL fetch).
    added = urls(attrs) - (previous ? urls(previous.attributes) : [])
    approved = ContentSafetyImage.where(url: added).pluck(:url)
    raise WechatContentSafety::RejectedImage unless (added - approved).empty?
  end
end
