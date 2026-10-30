# Intentionally independent of :profile/:self: adding profile fields cannot
# silently expand the discovery response or expose account credentials.
class UserSuggestionBlueprint < Blueprinter::Base
  identifier :id
  fields :name, :nickname, :image_url, :bio
  field(:city) { |user| user.data.to_h["city"] }
  field(:recommendation_reason) { |_user, options| options[:recommendation_reason] }
end
