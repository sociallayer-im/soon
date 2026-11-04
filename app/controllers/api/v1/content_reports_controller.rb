class Api::V1::ContentReportsController < Api::BaseController
  def create
    type = params[:target_type].to_s
    return render_error("举报类型无效") unless %w[Topic Event].include?(type)
    target = type.constantize.find(params[:target_id])
    visible = type == "Topic" ? TopicPolicy.new(current_user, target).show? : EventPolicy.new(current_user, target).show?
    return render_not_found unless visible
    report = ContentReport.create!(reporter: current_user, target_type: type, target_id: target.id, reason: params[:reason].to_s.strip)
    render json: { id: report.id, status: report.status }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  rescue ActiveRecord::RecordNotUnique
    render_error("你已提交过举报，请等待处理", status: :conflict)
  end
end
