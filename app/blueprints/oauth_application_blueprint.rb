class OauthApplicationBlueprint < Blueprinter::Base
  identifier :id

  fields :client_id, :name, :description, :logo_url, :homepage_url,
         :redirect_uris, :allowed_scopes, :status, :confidential, :created_at

  field :owner_handle do |app|
    app.group&.name || app.owner&.name
  end

  field :owner_type do |app|
    app.group_id.present? ? "group" : "user"
  end

  field :reviewed do |app|
    app.reviewed_at.present?
  end

  # The secret is never in any view. It exists in plaintext exactly twice — the
  # create response and the rotate response — and the controller adds it there
  # by hand, so there is no view that could accidentally start rendering it.

  view :admin do
    fields :trusted, :owner_id, :group_id, :reviewed_at, :updated_at
    field :active_token_count do |app|
      app.oauth_access_tokens.where(revoked_at: nil).where("expires_at > ?", Time.current).count
    end
    field :grant_count do |app|
      app.oauth_grants.count
    end
  end
end
