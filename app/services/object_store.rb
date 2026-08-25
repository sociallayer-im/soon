require "aws-sdk-s3"
require "digest"

# Uploads an image and returns its public URL. Backed by Cloudflare R2
# (datastore.sola.day) on international, or Aliyun OSS (assets.juluo.xyz) on
# CN — selected by OBJECT_STORE_PROVIDER, set to "oss" only in
# ginger.cn.yml. Both are S3-compatible, so the same aws-sdk-s3 client code
# talks to either; OSS's S3-compatible API needs the OSS region id (e.g.
# "oss-cn-hangzhou") as the SDK `region:`, not "auto".
#
# Why R2 and not Cloudflare Images (international default): this is where
# essentially every image on the platform already lives. sails'
# `upload_image_v1` wrote to this bucket, so ~10k existing *_url values are
# `https://datastore.sola.day/<key>`. soon's first upload implementation
# posted to Cloudflare Images instead and returned whatever variant URL
# Cloudflare handed back — `imagedelivery.net/...` — which is a different
# host with two problems:
#
#   1. `cfImage()` in seastar-app only rewrites datastore.sola.day URLs into
#      `/cdn-cgi/image/...`, so imagedelivery.net images skip resizing entirely
#      and are served at full size.
#   2. imagedelivery.net is not reachable from mainland China (verified
#      2026-07-31: connection failure without a proxy, 200 with one) — but so,
#      it turns out, is R2 itself: on 2026-08-26 every CN upload was found
#      silently hanging (Started/Processing logged, never Completed) because
#      the S3 client had no timeout and `b96d05...r2.cloudflarestorage.com`
#      was unreachable from juluo.xyz (curl: connection timed out, no proxy).
#      Confirmed intermittent/regional, not permanent — but CN uploads now go
#      to Aliyun OSS instead of hoping R2 stays reachable.
#
# The key is the first 16 hex chars of the file's SHA-256, exactly as sails
# computed it (for the R2/international bucket only — OSS keys, being a new
# namespace, don't need to match), which keeps new uploads in the same
# namespace as the old ones. It also makes uploads content-addressed:
# re-uploading identical bytes overwrites the same key instead of
# accumulating duplicates.
#
# Config (ENV):
#   R2 (default): AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_HOST (the R2
#     S3 endpoint), AWS_BUCKET, S3_URL (the public custom domain). Names are
#     kept identical to sails' so the values transfer verbatim.
#   OSS (OBJECT_STORE_PROVIDER=oss): OSS_ACCESS_KEY_ID, OSS_ACCESS_KEY_SECRET,
#     OSS_ENDPOINT (e.g. "oss-cn-hangzhou.aliyuncs.com"), OSS_REGION (e.g.
#     "oss-cn-hangzhou"), OSS_BUCKET, OSS_PUBLIC_URL (the bound custom domain).
class ObjectStore
  Error = Class.new(StandardError)

  KEY_LENGTH = 16
  # A hung upload must not tie up a Puma/GoodJob thread forever — this host
  # runs with very few of them (RAILS_MAX_THREADS=3, GOOD_JOB_MAX_THREADS=1
  # on CN). Fail fast with a 502 instead.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  def self.oss? = ENV["OBJECT_STORE_PROVIDER"] == "oss"

  # Read at call time rather than frozen into constants, so a test (or a
  # console) can point the uploader somewhere else without reloading the class.
  def self.access_key = oss? ? ENV["OSS_ACCESS_KEY_ID"] : ENV["AWS_ACCESS_KEY_ID"]
  def self.secret_key = oss? ? ENV["OSS_ACCESS_KEY_SECRET"] : ENV["AWS_SECRET_ACCESS_KEY"]
  def self.host       = oss? ? ENV["OSS_ENDPOINT"] : ENV["AWS_HOST"]
  def self.region     = oss? ? ENV["OSS_REGION"] : "auto"
  def self.bucket     = oss? ? ENV["OSS_BUCKET"] : ENV["AWS_BUCKET"]
  def self.public_url = oss? ? ENV["OSS_PUBLIC_URL"] : ENV["S3_URL"]

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
    # OSS's S3-compatible API instead requires its real region id.
    @client ||= Aws::S3::Client.new(
      access_key_id: access_key,
      secret_access_key: secret_key,
      endpoint: "https://#{host}",
      region: region,
      http_open_timeout: OPEN_TIMEOUT,
      http_read_timeout: READ_TIMEOUT
    )
  end
end
