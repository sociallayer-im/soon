class Api::V1::UploadsController < Api::BaseController
  MAX_BYTES = 10.megabytes
  ALLOWED_TYPES = %w[image/png image/jpeg image/gif image/webp image/svg+xml].freeze

  # Documents an application form may ask for. Deliberately an allow-list and
  # deliberately narrow: the bucket is served from datastore.sola.day, a domain
  # that also serves our own assets, so anything the browser will execute in
  # that origin (text/html, image/svg+xml as a top-level document, .js) is a
  # stored-XSS vector against the platform rather than a file upload.
  # Deliberately the same ceiling as an image rather than the larger one a
  # document seems to want. 10 MB is the only size proven to survive the whole
  # chain — Traefik, Thruster, Puma — because #image has been running at it;
  # neither proxy has a body limit configured, but "not configured" is not the
  # same as verified, and the failure mode is a non-JSON error from a proxy
  # rather than the clean 422 this controller would return. Raise it after
  # measuring an actual upload through the deployed stack, not before.
  MAX_FILE_BYTES = MAX_BYTES
  ALLOWED_FILE_TYPES = (ALLOWED_TYPES - %w[image/svg+xml] + %w[
    application/pdf
    text/plain
    text/csv
    application/zip
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.ms-powerpoint
    application/vnd.openxmlformats-officedocument.presentationml.presentation
  ]).freeze

  # POST /api/v1/upload/image
  #
  # Authenticated image upload. The file is stored in the datastore.sola.day
  # bucket and its public URL is returned for the caller to store on a model's
  # *_url field — see ObjectStore for why that host and not Cloudflare Images.
  def image
    file = params[:file]
    return render_error("no file provided") unless file.respond_to?(:read) && file.respond_to?(:content_type)
    return render_error("file too large (max #{MAX_BYTES / 1.megabyte}MB)") if file.size > MAX_BYTES
    return render_error("unsupported file type") unless ALLOWED_TYPES.include?(file.content_type)

    url = ObjectStore.upload(io: file.to_io, content_type: file.content_type)
    render json: { url: url }
  rescue ObjectStore::Error => e
    render_error(e.message, status: :bad_gateway)
  end

  # POST /api/v1/upload/file
  #
  # The same store, for the non-image attachments an application form can ask
  # for (a CV, a slide deck). Separate from #image because the two differ in
  # every parameter that matters: allowed types, size ceiling, and whether the
  # key keeps a file extension.
  def file
    upload = params[:file]
    return render_error("no file provided") unless upload.respond_to?(:read) && upload.respond_to?(:content_type)
    return render_error("file too large (max #{MAX_FILE_BYTES / 1.megabyte}MB)") if upload.size > MAX_FILE_BYTES
    return render_error("unsupported file type") unless ALLOWED_FILE_TYPES.include?(upload.content_type)

    url = ObjectStore.upload(
      io: upload.to_io,
      content_type: upload.content_type,
      filename: upload.original_filename
    )
    # The original name travels alongside the URL rather than inside it: the
    # key is a content hash, so the link alone cannot tell the organizer
    # whether they are about to open a CV or a floor plan.
    render json: { url: url, filename: upload.original_filename, size: upload.size }
  rescue ObjectStore::Error => e
    render_error(e.message, status: :bad_gateway)
  end
end
