class ParticipantBlueprint < Blueprinter::Base
  identifier :id

  # registered_at = when they RSVP'd; checked_in_at = when a manager scanned
  # them at the door. Distinct — see AddCheckedInAtToParticipants.
  fields :status, :payment_status, :registered_at, :checked_in_at, :created_at

  # nil for an RSVP that arrived over federation — the attendee lives on
  # another server and has no local user record. Consumers must treat this as
  # nullable; `remote_author` carries the identity in that case.
  association :user, blueprint: UserBlueprint

  # Present only for federated participants, and shaped exactly like
  # CommentBlueprint's field of the same name so one renderer handles both.
  # `acct` is what a reader needs to see (name@server) — a remote display name
  # on its own is indistinguishable from a local one.
  field :remote_author do |participant|
    actor = participant.fed_actor
    next nil if actor.nil?
    {acct: actor.acct, domain: actor.domain, name: actor.name,
     image_url: actor.icon_url, url: actor.uri}
  end
end
