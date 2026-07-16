class EventBlueprint < Blueprinter::Base
  identifier :id

  fields :title, :content, :start_time, :end_time, :timezone, :status, :visibility,
         :meeting_url, :external_url, :category, :kind, :tags, :pinned,
         :max_participant, :participant_count, :require_approval,
         :image_url, :recurring_id, :form_id, :created_at

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
  association :venue, blueprint: VenueBlueprint
  association :owner, blueprint: UserBlueprint
  association :track, blueprint: TrackBlueprint

  view :extended do
    association :event_roles, blueprint: EventRoleBlueprint
    association :participants, blueprint: ParticipantBlueprint
    association :tickets, blueprint: TicketBlueprint
  end
end
