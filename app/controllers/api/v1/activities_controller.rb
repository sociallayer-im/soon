class Api::V1::ActivitiesController < Api::BaseController
  # GET /api/v1/activities
  def index
    render_collection Activity.for_receiver(current_user).includes(:initiator, :item).order(created_at: :desc, id: :desc), blueprint: ActivityBlueprint, viewer: current_user
  end

  def summary
    invitations = GroupInvite.where(status: "sending").where("expires_at IS NULL OR expires_at > ?", Time.current)
    recipient = GroupInvite.where(receiver_id: current_user.id)
    recipient = recipient.or(GroupInvite.where(receiver_address_type: "email", receiver_address: current_user.email)) if current_user.email.present?
    render json: {unread: Activity.for_receiver(current_user).unread.count,
                  tasks: SiteNotificationTasks.for(current_user).length + invitations.merge(recipient).count}
  end

  # GET /api/v1/activities/tasks — always computed with current permissions.
  def tasks
    rows = SiteNotificationTasks.for(current_user)
    limit = params[:limit].to_i.clamp(1, 100)
    limit = 50 unless params[:limit].present?
    page = [params[:page].to_i, 1].max
    pages = (rows.length.to_f / limit).ceil
    render json: {data: rows.slice((page - 1) * limit, limit) || [],
                  meta: {page: page, total: rows.length, total_pages: pages, next_page: page < pages ? page + 1 : nil}}
  end

  # POST /api/v1/activities/mark_read
  def mark_read
    if params[:all] == true
      Activity.for_receiver(current_user).unread.update_all(has_read: true)
      return render json: {result: "ok"}
    end
    activities = Activity.where(id: params[:ids])
    if activities.any? { |a| a.receiver_id != current_user.id }
      return render_error("not authorized", status: :forbidden)
    end

    activities.update_all(has_read: true)
    render json: { result: "ok" }
  end
end
