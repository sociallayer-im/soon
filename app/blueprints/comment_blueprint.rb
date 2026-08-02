class CommentBlueprint < Blueprinter::Base
  identifier :id

  fields :title, :item_type, :item_id, :reply_parent_id, :content, :content_type,
         :comment_type, :icon_url, :created_at

  # nil for a comment that arrived over federation — its author lives on
  # another server and has no local user record.
  association :user, blueprint: UserBlueprint

  # Present only for federated comments. The frontend renders whichever of the
  # two is set; `acct` is what a reader needs to see (name@server), since a
  # remote display name on its own is indistinguishable from a local one.
  field :remote_author do |comment|
    actor = comment.fed_actor
    next nil if actor.nil?
    {acct: actor.acct, domain: actor.domain, name: actor.name,
     image_url: actor.icon_url, url: actor.uri}
  end
end
