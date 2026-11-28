class FollowBlueprint < Blueprinter::Base
  identifier :id

  fields :target_id, :target_type, :status

  # `include=profiles` is what the web and miniprogram clients always send.
  # Followers lists read `user`; following lists read `target`. Both are the
  # public profile, never the `:self` view (that one carries email and phone).
  field :user, if: ->(_name, _follow, options) { options[:include_profiles] } do |follow|
    UserBlueprint.render_as_hash(follow.user, view: :profile)
  end

  field :target, if: ->(_name, _follow, options) { options[:include_profiles] } do |follow|
    case follow.target
    when User
      UserBlueprint.render_as_hash(follow.target, view: :profile)
    when Group
      GroupBlueprint.render_as_hash(follow.target, view: :card)
    end
  end
end
