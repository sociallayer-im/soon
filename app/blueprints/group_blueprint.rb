class GroupBlueprint < Blueprinter::Base
  identifier :id

  # Default view stays light — it's embedded in events, invites, tracks, etc.
  fields :name, :nickname, :image_url, :logo_url, :created_at

  # Every scalar a group page or popup-city card needs, and no sub-resources.
  # Use this for LISTS. :detail on a list embeds each group's whole membership
  # roster: the homepage's 21 popup cities carry 2407 memberships between them,
  # which is a 726KB response against sails' 16KB for the same page — and the
  # consumer (sola-sdk popup_city.ts toPopupCity) reads only scalars.
  view :card do
    fields :bio, :location, :timezone, :start_date, :end_date, :active,
           :banner_image_url, :banner_link_url, :banner_text, :featured_image_url,
           :social_links, :group_tags, :event_tag_list, :requirement_tag_list, :venue_tag_list,
           :can_publish_event, :can_join_event, :can_view_event, :require_event_approval,
           # Whether this group shows discussion boards, and who may start a
           # topic. The frontend decides whether to draw the tab from the
           # first of these, so it has to travel with the group.
           :discussion_enabled, :can_post_topic,
           # Per-group opt-in for the Google Maps display (marker map, event
           # map, group-home map view) — the deployment-wide
           # NEXT_PUBLIC_ENABLE_GOOGLE_MAP flag is the other half of the gate.
           :map_enabled,
           # Same two-switch shape for polls (design/POLL_MODULE.md).
           :poll_enabled, :can_create_poll,
           # And for hackathons (design/HACKATHON_MODULE.md).
           :hackathon_enabled, :can_create_hackathon,
           # The one event whose tickets grant group membership. At most one
           # per group; nil until a manager designates one.
           :group_ticket_event_id,
           :memberships_count, :events_count, :parent_id
  end

  # Full group-page payload: the card fields plus sub-resources. Only ever
  # render this for a SINGLE group, and off Group.with_detail_associations —
  # the associations below are a per-record N+1 otherwise.
  view :detail do
    include_view :card
    association :parent, blueprint: GroupBlueprint
    association :children, blueprint: GroupBlueprint
    association :tracks, blueprint: TrackBlueprint
    # Source is active_venues (archived: false) but the key stays `venues` —
    # removed venues are soft-deleted and must not appear in any list.
    association :active_venues, blueprint: VenueBlueprint, name: :venues
    association :memberships, blueprint: MembershipBlueprint
  end

  view :extended do
    association :members, blueprint: UserBlueprint, name: :users
  end
end
