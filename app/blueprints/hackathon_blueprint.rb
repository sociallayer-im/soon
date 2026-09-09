# Renders with `current_user:` in options.
class HackathonBlueprint < Blueprinter::Base
  identifier :id

  fields :group_id, :event_id, :title, :tagline, :cover_url, :status,
         :start_at, :end_at, :submit_open_at, :submit_close_at,
         :projects_count, :created_at, :updated_at

  field(:submission_open) { |h| h.submission_open? }
  field(:flagged)         { |h| h.flagged? }
  field :flag_reason

  association :user, blueprint: UserBlueprint

  view :detail do
    fields :content, :projects_visibility, :can_submit_project, :tracks

    field :can_manage do |h, options|
      HackathonPolicy.new(options[:current_user], h).manage?
    end

    # can_submit is false, not an error, when the participant tier's event
    # has been deleted; `event_missing` tells the organiser why.
    field :can_submit do |h, options|
      HackathonPolicy.new(options[:current_user], h).can_submit_project?
    end
    field :event_missing do |h|
      h.can_submit_project == "participant" && h.event_id.nil?
    end

    # The one project this person is on here, if any (unique index).
    field :my_project_id do |h, options|
      u = options[:current_user]
      u && h.hackathon_project_members.where(user_id: u.id).pick(:project_id)
    end

    # The registration event, in its list shape: enough for a sign-up button.
    association :event, blueprint: EventBlueprint
  end
end
