require "aws-sdk-s3"
require "digest"

# Uploads an image to the Cloudflare R2 bucket served at datastore.sola.day and
# returns its public URL.
#
# Why here and not Cloudflare Images: this is where essentially every image on
# the platform already lives. sails' `upload_image_v1` wrote to this bucket, so
# ~10k existing *_url values are `https://datastore.sola.day/<key>`. soon's
# first upload implementation posted to Cloudflare Images instead and returned
# whatever variant URL Cloudflare handed back — `imagedelivery.net/...` — which
# is a different host with two problems:
#
#   1. `cfImage()` in seastar-app only rewrites datastore.sola.day URLs into
#      `/cdn-cgi/image/...`, so imagedelivery.net images skip resizing entirely
#      and are served at full size.
#   2. imagedelivery.net is not reachable from mainland China (verified
#      2026-07-31: connection failure without a proxy, 200 with one), while
#      datastore.sola.day is — so every new upload would break on juluo.xyz.
#
# The key is the first 16 hex chars of the file's SHA-256, exactly as sails
# computed it, which keeps new uploads in the same namespace as the old ones.
# It also makes uploads content-addressed: re-uploading identical bytes
# overwrites the same key instead of accumulating duplicates.
#
# Config (ENV): AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_HOST (the R2 S3
# endpoint), AWS_BUCKET, S3_URL (the public custom domain). Names are kept
# identical to sails' so the values transfer verbatim.
class ObjectStore
  Error = Class.new(StandardError)

  KEY_LENGTH = 16

  # Read at call time rather than frozen into constants, so a test (or a
  # console) can point the uploader somewhere else without reloading the class.
  def self.access_key = ENV["AWS_ACCESS_KEY_ID"]
  def self.secret_key = ENV["AWS_SECRET_ACCESS_KEY"]
  def self.host       = ENV["AWS_HOST"]
  def self.bucket     = ENV["AWS_BUCKET"]
  def self.public_url = ENV["S3_URL"]

  def self.configured?
    [ access_key, secret_key, host, bucket, public_url ].all?(&:present?)
  end

  # io: an IO/UploadedFile-like object; returns the public URL (String).
  #
  # `filename` is optional and only its extension is used, appended to the
  # hashed key. Images deliberately pass nothing, so their keys stay in the
  # exact bare-hash namespace the ~10k existing values use; a document needs
  # the suffix because a browser asked to open a bare hash over a custom
  # domain has nothing but the Content-Type to go on, and no sensible name to
  # save it under.
  def self.upload(io:, content_type:, filename: nil)
    raise Error, "object storage is not configured" unless configured?

    body = io.read
    key = Digest::SHA256.hexdigest(body)[0...KEY_LENGTH] + extension_for(filename)

    # content_type is set deliberately: sails omitted it, so every pre-existing
    # object is served as application/octet-stream. Browsers render those in an
    # <img> anyway, but Cloudflare's image resizing and any future direct link
    # both behave better with the real type.
    client.put_object(bucket: bucket, key: key, body: body, content_type: content_type)

    "#{public_url.chomp('/')}/#{key}"
  rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => e
    raise Error, "upload failed: #{e.message}"
  end

  # Whitelisted rather than passed through: the key becomes part of a URL, and
  # an attacker-chosen "extension" is an attacker-chosen path.
  def self.extension_for(filename)
    ext = File.extname(filename.to_s).downcase
    ext.match?(/\A\.[a-z0-9]{1,8}\z/) ? ext : ""
  end

  def self.client
    # region "auto" is what R2 expects; the endpoint carries the account.
    @client ||= Aws::S3::Client.new(
      access_key_id: access_key,
      secret_access_key: secret_key,
      endpoint: "https://#{host}",
      region: "auto"
    )
  end
end
