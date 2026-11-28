class Api::V1::ContentReportsController < Api::BaseController
  def create
    type = params[:target_type].to_s
    return render_error("举报类型无效") unless %w[Topic Event].include?(type)
    target = type.constantize.find(params[:target_id])
    visible = type == "Topic" ? TopicPolicy.new(current_user, target).show? : EventPolicy.new(current_user, target).show?
    return render_not_found unless visible
    report = ContentReport.transaction do
      record = ContentReport.create!(reporter: current_user, target_type: type, target_id: target.id, reason: params[:reason].to_s.strip)
      if type == "Event"
        SiteNotifications.emit(receiver: target.owner, item: target, action: "event_reported",
          title: "活动收到举报", body: "「#{target.title}」收到举报，等待平台处理。",
          key: "event_reported:#{record.id}")
      end
      record
    end
    render json: { id: report.id, status: report.status }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  rescue ActiveRecord::RecordNotUnique
    render_error("你已提交过举报，请等待处理", status: :conflict)
  end
end
