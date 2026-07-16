class Api::V1::UploadsController < Api::BaseController
  MAX_BYTES = 10.megabytes
  ALLOWED_TYPES = %w[image/png image/jpeg image/gif image/webp image/svg+xml].freeze

  # POST /api/v1/upload/image
  #
  # Authenticated image upload. The file is forwarded to Cloudflare Images and
  # the delivery URL is returned for the caller to store on a model's *_url field.
  def image
    file = params[:file]
    return render_error("no file provided") unless file.respond_to?(:read) && file.respond_to?(:content_type)
    return render_error("file too large (max #{MAX_BYTES / 1.megabyte}MB)") if file.size > MAX_BYTES
    return render_error("unsupported file type") unless ALLOWED_TYPES.include?(file.content_type)

    url = CloudflareImages.upload(
      io: file.to_io,
      filename: file.original_filename,
      content_type: file.content_type
    )
    render json: { url: url }
  rescue CloudflareImages::Error => e
    render_error(e.message, status: :bad_gateway)
  end
end
