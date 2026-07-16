# Uploads an image to Cloudflare Images and returns its public delivery URL.
#
# The client sends the file to us; we forward it to Cloudflare's Images v1 API
# (multipart, Bearer-token auth) and hand back the delivery URL. Cloudflare's
# response already contains fully-formed variant URLs (imagedelivery.net/…),
# so we don't build any URL ourselves.
#
# Config (ENV): CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_IMAGES_TOKEN.
class CloudflareImages
  Error = Class.new(StandardError)

  ACCOUNT_ID = ENV["CLOUDFLARE_ACCOUNT_ID"].freeze
  API_TOKEN  = ENV["CLOUDFLARE_IMAGES_TOKEN"].freeze
  TIMEOUT    = 15 # seconds

  def self.configured?
    ACCOUNT_ID.present? && API_TOKEN.present?
  end

  def self.endpoint
    "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT_ID}/images/v1"
  end

  # io: an IO/UploadedFile-like object; returns the delivery URL (String).
  def self.upload(io:, filename:, content_type:)
    raise Error, "Cloudflare Images is not configured" unless configured?

    response = HTTPX
      .with(timeout: { operation_timeout: TIMEOUT }, headers: { "authorization" => "Bearer #{API_TOKEN}" })
      .post(endpoint, form: { file: { body: io, filename: filename, content_type: content_type } })

    if response.is_a?(HTTPX::ErrorResponse)
      raise Error, "Cloudflare upload failed: #{response.error.message}"
    end

    body = parse(response)
    unless response.status == 200 && body["success"]
      raise Error, body.dig("errors", 0, "message").presence || "Cloudflare upload failed (HTTP #{response.status})"
    end

    delivery_url(body) || raise(Error, "Cloudflare returned no delivery URL")
  end

  def self.parse(response)
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    {}
  end
  private_class_method :parse

  # Prefer the "/public" variant; fall back to the first variant Cloudflare returns.
  def self.delivery_url(body)
    variants = body.dig("result", "variants") || []
    variants.find { |u| u.to_s.end_with?("/public") } || variants.first
  end
  private_class_method :delivery_url
end
