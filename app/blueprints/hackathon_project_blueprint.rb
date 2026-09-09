# Renders with `current_user:` in options. Never joins form_answers: a
# member's registration answers are PII that belong to the event's own
# submission endpoints, not to a project card.
class HackathonProjectBlueprint < Blueprinter::Base
  identifier :id

  fields :hackathon_id, :track_id, :title, :tagline, :cover_url,
         :tech, :seeking, :recruiting, :submitted_at, :award,
         :stars_count, :members_count, :created_at, :updated_at

  field(:status)  { |p| p.status }
  field(:flagged) { |p| p.flagged? }
  field :flag_reason

  association :user, blueprint: UserBlueprint

  view :detail do
    fields :content, :repo_url, :demo_url, :video_url, :approved_at, :rejected_at

    # The rejection reason is for the author, not the wall.
    field :review_note, if: ->(_name, p, options) {
      policy = HackathonProjectPolicy.new(options[:current_user], p)
      policy.owner? || policy.manage_hackathon?
    }

    field :track do |p|
      p.track
    end

    field :members do |p|
      p.hackathon_project_members.includes(:user).order(:created_at).map do |m|
        JSON.parse(UserBlueprint.render(m.user)).merge("role" => m.role)
      end
    end

    field :starred_by_me do |p, options|
      u = options[:current_user]
      !!(u && p.hackathon_project_stars.exists?(user_id: u.id))
    end

    field :can_edit do |p, options|
      HackathonProjectPolicy.new(options[:current_user], p).update?
    end
    field :can_submit do |p, options|
      HackathonProjectPolicy.new(options[:current_user], p).submit?
    end
    field :can_unsubmit do |p, options|
      HackathonProjectPolicy.new(options[:current_user], p).unsubmit?
    end
    field :can_manage do |p, options|
      HackathonProjectPolicy.new(options[:current_user], p).manage_hackathon?
    end
    field :is_owner do |p, options|
      p.owner?(options[:current_user])
    end
    field :is_member do |p, options|
      p.member?(options[:current_user])
    end
  end
end
