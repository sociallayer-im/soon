class EventBlueprint < Blueprinter::Base
  identifier :id

  # Default view stays light — it's used for LISTS (index, pending_approval)
  # and echoed back on create/update. `content` is excluded: some events carry
  # markdown with embedded base64 images running into multiple MB, and no list
  # or card UI renders it — the detail page always re-fetches via :extended.
  fields :title, :start_time, :end_time, :timezone, :status, :visibility,
         :meeting_url, :external_url, :category, :kind, :tags, :pinned,
         :max_participant, :participant_count, :require_approval, :requirement_tags,
         :image_url, :recurring_id, :form_id, :notes, :created_at

  # Viewer flags — only emitted when the request was authenticated and the
  # controller passed the viewer's sets (see EventsController#personalization_options).
  field :is_attending, if: ->(_n, _o, options) { options.key?(:attending_ids) } do |event, options|
    options[:attending_ids].include?(event.id)
  end
  field :is_starred, if: ->(_n, _o, options) { options.key?(:starred_ids) } do |event, options|
    options[:starred_ids].include?(event.id)
  end
  field :is_owner, if: ->(_n, _o, options) { options.key?(:viewer_id) } do |event, options|
    event.owner_id == options[:viewer_id]
  end

  association :group, blueprint: GroupBlueprint
  association :place, blueprint: PlaceBlueprint
  association :venue, blueprint: VenueRefBlueprint
  association :owner, blueprint: UserBlueprint
  association :track, blueprint: TrackRefBlueprint

  view :extended do
    field :content
    association :event_roles, blueprint: EventRoleBlueprint
    # Withdrawn (soft-deleted) participants are not attendees — reject in Ruby
    # so a preloaded association isn't re-queried.
    association :participants, blueprint: ParticipantBlueprint do |event|
      event.participants.reject(&:cancelled?)
    end
    association :tickets, blueprint: TicketBlueprint, view: :extended
  end
end
