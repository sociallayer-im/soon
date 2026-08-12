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
    # Confirmed-attendees-only image (group QR code). The controller decides
    # who qualifies (EventsController#reveal_image_note?); absent from the
    # payload entirely for everyone else, so a signed-out fetch can't leak it.
    field :image_note, if: ->(_n, _o, options) { options[:reveal_image_note] }
    association :event_roles, blueprint: EventRoleBlueprint
    # Withdrawn (soft-deleted) participants are not attendees — reject in Ruby
    # so a preloaded association isn't re-queried.
    #
    # This array is the part of the response that grows without bound — one
    # embedded user per RSVP — and the detail page shows it behind a tab most
    # visitors never open. `include_participants: false` leaves it out; the
    # list then comes from GET /events/:id/participants when it's actually
    # wanted. Opt-out rather than opt-in so already-deployed clients, which
    # index into this array, keep working.
    association :participants, blueprint: ParticipantBlueprint,
                if: ->(_n, _o, options) { options[:include_participants] != false } do |event|
      event.participants.reject(&:cancelled?)
    end
    # The viewer's own RSVP. Without it, dropping the array above would also
    # drop the answer to "have I joined, did my payment go through, was I
    # checked in" — which is what the page's primary button is made of.
    association :current_participant, blueprint: ParticipantBlueprint,
                if: ->(_n, _o, options) { options.key?(:current_participant) } do |_event, options|
      options[:current_participant]
    end
    association :tickets, blueprint: TicketBlueprint, view: :extended
  end
end
