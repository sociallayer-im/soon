# Renders with `current_user:` in options. The :detail view is the only one
# that carries per-voter data, and every field of it that could reveal who
# chose what goes through PollPolicy's three visibility checks.
class PollBlueprint < Blueprinter::Base
  identifier :id

  fields :group_id, :title, :poll_type, :min_value, :max_value, :visibility, :results,
         :close_at, :closed_at, :votes_count, :created_at, :updated_at,
         :eligible_group_ids, :eligible_team_ids

  field(:closed)  { |poll| poll.closed? }
  field(:flagged) { |poll| poll.flagged? }
  field :flag_reason

  association :user, blueprint: UserBlueprint

  view :detail do
    field :content

    field :editable do |poll|
      poll.editable?
    end

    field :can_vote do |poll, options|
      PollPolicy.new(options[:current_user], poll).vote?
    end

    # Who may vote, as names: a group is a ref, a team is a ref — neither a
    # roster. Lets the page say "members of X and the volunteers" instead of
    # "you cannot vote" with no reason.
    association :eligible_groups, blueprint: GroupBlueprint
    association :eligible_teams, blueprint: TeamRefBlueprint

    field :can_edit do |poll, options|
      PollPolicy.new(options[:current_user], poll).update?
    end

    field :can_manage do |poll, options|
      PollPolicy.new(options[:current_user], poll).manages_group?
    end

    field :can_see_results do |poll, options|
      PollPolicy.new(options[:current_user], poll).can_see_results?
    end

    # Always visible to the voter themself, whatever the visibility setting.
    field :my_vote do |poll, options|
      poll.vote_of(options[:current_user])
    end

    # votes_count is null, not 0, when this reader may not see results — the
    # client must not draw an empty bar for a number it was never given.
    field :options do |poll, options|
      see = PollPolicy.new(options[:current_user], poll).can_see_results?
      poll.poll_options.map do |o|
        { id: o.id, title: o.title, position: o.position,
          votes_count: see ? o.votes_count : nil }
      end
    end

    field :stats do |poll, options|
      next nil unless poll.number?
      next nil unless PollPolicy.new(options[:current_user], poll).can_see_results?

      poll.number_stats
    end

    # Present only when the reader may see participants; each entry carries
    # `choice` only when they may also see choices.
    field :voters do |poll, options|
      policy = PollPolicy.new(options[:current_user], poll)
      next nil unless policy.can_see_participants?

      choices = policy.can_see_choices?
      rows = poll.poll_votes.includes(:user).order(:created_at).group_by(&:user)
      rows.map do |user, votes|
        entry = JSON.parse(UserBlueprint.render(user))
        entry["voted_at"] = votes.map(&:created_at).max
        if choices
          entry["choice"] = case poll.poll_type
          when "multiple" then votes.map(&:option_id)
          when "number"   then votes.first.value
          else                 votes.first.option_id
          end
        end
        entry
      end
    end
  end
end
