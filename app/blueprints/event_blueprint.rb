class EventBlueprint < Blueprinter::Base
  identifier :id

  fields :title, :content, :start_time, :end_time, :timezone, :status, :visibility,
         :meeting_url, :external_url, :category, :kind, :tags, :pinned,
         :max_participant, :participant_count, :require_approval, :created_at

  association :group, blueprint: GroupBlueprint
  association :place, blueprint: PlaceBlueprint
  association :venue, blueprint: VenueBlueprint

  view :extended do
    association :event_roles, blueprint: EventRoleBlueprint
    association :participants, blueprint: ParticipantBlueprint
  end
end
