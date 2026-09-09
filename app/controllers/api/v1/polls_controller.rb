require "csv"

class Api::V1::PollsController < Api::BaseController
  include PollGate

  before_action :require_poll_enabled!
  skip_before_action :authenticate!, only: %i[index show]
  before_action :authenticate_optional!, only: %i[index show]
  before_action :set_poll, only: %i[show update destroy vote retract close flag unflag restore export]

  # GET /api/v1/polls?group_id=&status=open|closed
  def index
    group = Group.resolve!(params[:group_id])
    return render_not_found unless group.poll_enabled?

    manager = GroupPolicy.new(current_user, group).manage?
    scope = Poll.visible_to(current_user, manager: manager).where(group_id: group.id)
    case params[:status]
    when "open"   then scope = scope.where(closed_at: nil).where("close_at IS NULL OR close_at > ?", Time.current)
    when "closed" then scope = scope.where("closed_at IS NOT NULL OR close_at <= ?", Time.current)
    end

    render_collection scope.includes(:user).order(created_at: :desc, id: :desc),
                      blueprint: PollBlueprint
  end

  def show
    return render_not_found unless PollPolicy.new(current_user, @poll).show?

    render_detail(@poll)
  end

  def create
    group = Group.resolve!(poll_params[:group_id])
    return render_not_found unless group.poll_enabled?

    poll = Poll.new(poll_params.except(:group_id, :options))
    poll.group = group
    poll.user  = current_user
    authorize poll, :create?

    Poll.transaction do
      poll.save!
      replace_options!(poll, poll_params[:options]) unless poll.number?
    end
    render_detail(poll, status: :created)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # PATCH /api/v1/polls/:id
  #
  # After the first vote: title, options, type and range are editable only
  # inside Poll::EDIT_GRACE; visibility is frozen at once, since loosening it
  # would expose choices people made under the stricter promise. content,
  # close_at and results stay editable throughout.
  def update
    authorize @poll, :update?

    attrs = poll_params.except(:group_id, :options).to_h
    locked = %w[title poll_type min_value max_value eligible_group_ids eligible_team_ids]
    changes_locked = locked.any? { |k| attrs.key?(k) && Array(attrs[k]).map(&:to_s).sort != Array(@poll[k]).map(&:to_s).sort } ||
                     poll_params.key?(:options)
    if changes_locked && !@poll.editable?
      return render_error("poll can no longer be edited after the first vote")
    end
    if attrs.key?("visibility") && attrs["visibility"] != @poll.visibility && @poll.first_voted_at.present?
      return render_error("visibility cannot change once someone has voted")
    end

    Poll.transaction do
      @poll.update!(attrs)
      replace_options!(@poll, poll_params[:options]) if poll_params.key?(:options) && !@poll.number?
      @poll.poll_options.destroy_all if @poll.number?
      @poll.refresh_counts!
    end
    render_detail(@poll.reload)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def destroy
    authorize @poll, :destroy?
    @poll.soft_delete!(by: current_user)
    render json: { result: "ok" }
  end

  def restore
    authorize @poll, :restore?
    @poll.restore!
    render json: { result: "ok" }
  end

  # POST /api/v1/polls/:id/vote
  #   single:   { option_id }
  #   multiple: { option_ids: [...] }   (the full set; the diff is applied)
  #   number:   { value }
  def vote
    authorize @poll, :vote?

    Poll.transaction do
      mine = @poll.poll_votes.where(user_id: current_user.id)
      case @poll.poll_type
      when "number"
        mine.delete_all
        @poll.poll_votes.create!(user: current_user, value: params[:value].presence&.to_i)
      when "multiple"
        wanted = Array(params[:option_ids]).map(&:to_s).uniq
        return render_error("option_ids is required") if wanted.empty?

        mine.where.not(option_id: wanted).delete_all
        (wanted - mine.pluck(:option_id)).each do |oid|
          @poll.poll_votes.create!(user: current_user, option_id: oid)
        end
      else
        mine.delete_all
        @poll.poll_votes.create!(user: current_user, option_id: params[:option_id].to_s)
      end
      @poll.update_columns(first_voted_at: Time.current) if @poll.first_voted_at.nil?
      @poll.refresh_counts!
    end
    render_detail(@poll.reload)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # DELETE /api/v1/polls/:id/vote
  def retract
    authorize @poll, :vote?
    @poll.poll_votes.where(user_id: current_user.id).delete_all
    @poll.refresh_counts!
    render_detail(@poll.reload)
  end

  def close
    authorize @poll, :close?
    @poll.update_columns(closed_at: Time.current, updated_at: Time.current)
    render json: { result: "ok" }
  end

  def flag
    authorize @poll, :flag?
    @poll.flag!(by: current_user, reason: params[:reason])
    render json: { result: "ok" }
  end

  def unflag
    authorize @poll, :flag?
    @poll.unflag!
    render json: { result: "ok" }
  end

  # GET /api/v1/polls/:id/export?by=option|voter — CSV, author/manager only.
  # by=voter is refused outright, not downgraded, when visibility hides
  # choices: a silent downgrade hands an admin an aggregate they would read
  # as a roster.
  def export
    authorize @poll, :update?
    by = params[:by].presence || "option"
    policy = PollPolicy.new(current_user, @poll)

    if by == "voter"
      return render json: { error: "Forbidden" }, status: :forbidden unless policy.can_see_choices?

      csv = CSV.generate { |out| voter_rows(out) }
    else
      csv = CSV.generate { |out| option_rows(out) }
    end
    send_data csv, type: "text/csv; charset=utf-8",
              filename: "poll-#{@poll.id}-#{by}.csv"
  end

  private

  def set_poll
    @poll = if action_name == "restore"
      Poll.with_deleted.find(params[:id])
    else
      Poll.find(params[:id])
    end
    require_group_poll!(@poll.group)
  end

  def render_detail(poll, status: :ok)
    render json: PollBlueprint.render(poll, view: :detail, current_user: current_user), status: status
  end

  # Options arrive as the full desired list: [{id?, title}]. Existing ids are
  # renamed, missing ones deleted (with their votes), new titles created.
  def replace_options!(poll, list)
    return if list.nil?

    rows = Array(list).map { |o| o.respond_to?(:to_h) ? o.to_h.stringify_keys : { "title" => o.to_s } }
    rows = rows.reject { |r| r["title"].to_s.strip.empty? }
    raise ActiveRecord::RecordInvalid, poll.tap { |p| p.errors.add(:options, "need at least two") } if rows.size < 2
    raise ActiveRecord::RecordInvalid, poll.tap { |p| p.errors.add(:options, "at most #{Poll::MAX_OPTIONS}") } if rows.size > Poll::MAX_OPTIONS

    keep_ids = rows.map { |r| r["id"] }.compact
    poll.poll_options.where.not(id: keep_ids).destroy_all
    rows.each_with_index do |r, i|
      existing = r["id"] && poll.poll_options.find_by(id: r["id"])
      if existing
        existing.update!(title: r["title"].to_s.strip, position: i)
      else
        poll.poll_options.create!(title: r["title"].to_s.strip, position: i)
      end
    end
    poll.poll_options.reset
  end

  def option_rows(out)
    if @poll.number?
      s = @poll.number_stats
      out << %w[average median participants]
      out << [ s[:average], s[:median], s[:count] ]
      return
    end
    total = @poll.votes_count
    out << %w[option votes percentage]
    @poll.poll_options.each do |o|
      pct = total.zero? ? 0 : (o.votes_count * 100.0 / total).round(1)
      out << [ o.title, o.votes_count, pct ]
    end
  end

  def voter_rows(out)
    titles = @poll.poll_options.index_by(&:id).transform_values(&:title)
    out << %w[user_id name choice voted_at]
    @poll.poll_votes.includes(:user).order(:created_at).group_by(&:user).each do |user, votes|
      choice = if @poll.number?
        votes.first.value
      else
        votes.map { |v| titles[v.option_id] }.join("; ")
      end
      out << [ user.id, user.name, choice, votes.map(&:created_at).max.iso8601 ]
    end
  end

  def poll_params
    params.require(:poll).permit(:group_id, :title, :content, :poll_type, :min_value, :max_value,
                                 :visibility, :results, :close_at,
                                 options: [ :id, :title ],
                                 eligible_group_ids: [], eligible_team_ids: [])
  end
end
