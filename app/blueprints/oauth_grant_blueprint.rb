class OauthGrantBlueprint < Blueprinter::Base
  identifier :id

  fields :scopes, :created_at, :updated_at

  field :client_id do |grant|
    grant.oauth_application.client_id
  end

  field :app_name do |grant|
    grant.oauth_application.name
  end

  field :app_logo_url do |grant|
    grant.oauth_application.logo_url
  end

  field :owner_handle do |grant|
    grant.oauth_application.group&.name || grant.oauth_application.owner&.name
  end

  # So the management screen can show what the app can do RIGHT NOW, which is
  # not the same as what was consented to: an app that has been disabled, or
  # whose tokens have all expired, is harmless until it is used again.
  field :scope_details do |grant|
    OauthClaims.describe(grant.scopes)
  end
end
