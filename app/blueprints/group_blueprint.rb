class GroupBlueprint < Blueprinter::Base
  identifier :id

  # Default view stays light — it's embedded in events, invites, tracks, etc.
  fields :name, :nickname, :image_url, :logo_url, :created_at

  # Full group-page payload: everything the frontend group/popup-city pages
  # render, plus sub-resources (memberships, tracks, venues, parent/children).
  view :detail do
    fields :bio, :location, :timezone, :start_date, :end_date, :active,
           :banner_image_url, :banner_link_url, :banner_text,
           :social_links, :group_tags, :event_tag_list, :requirement_tag_list, :venue_tag_list,
           :can_publish_event, :can_join_event, :can_view_event,
           :memberships_count, :events_count, :parent_id
    association :parent, blueprint: GroupBlueprint
    association :children, blueprint: GroupBlueprint
    association :tracks, blueprint: TrackBlueprint
    association :venues, blueprint: VenueBlueprint
    association :memberships, blueprint: MembershipBlueprint
  end

  view :extended do
    association :members, blueprint: UserBlueprint, name: :users
  end
end
