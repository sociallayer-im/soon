class Api::V1::ReportsController < Api::BaseController
  def index
    return render_error("forbidden", status: :forbidden) unless current_user.platform_admin?

    scope = Report.order(created_at: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    render_collection scope, blueprint: ReportBlueprint
  end

  def create
    report = current_user.reports.new(report_params)
    report.status = "open"
    if report.save
      render json: ReportBlueprint.render(report), status: :created
    else
      render_error(report.errors.full_messages.join(", "))
    end
  end

  def resolve
    return render_error("forbidden", status: :forbidden) unless current_user.platform_admin?

    report = Report.find(params[:id])
    status = params[:status].to_s
    return render_error("status must be resolved or dismissed") unless %w[resolved dismissed].include?(status)

    report.update!(status: status, note: params[:note], resolved_by: current_user)
    render json: ReportBlueprint.render(report)
  end

  private

  def report_params
    params.require(:report).permit(:target_type, :target_id, :reason)
  end
end
