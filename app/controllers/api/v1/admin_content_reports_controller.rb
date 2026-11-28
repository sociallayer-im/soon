class Api::V1::AdminContentReportsController < Api::BaseController
  before_action :require_admin

  def index
    status = params[:status].presence || "pending"
    return render_error("无效状态") unless %w[pending reviewed].include?(status)
    page = [params[:page].to_i, 1].max
    reports = ContentReport.where(status: status).order(created_at: :desc, id: :desc).limit(21).offset((page - 1) * 20).to_a
    more = reports.length > 20
    render json: {data: reports.first(20).map { |r| report_json(r) }, meta: {next_page: more ? page + 1 : nil}}
  end

  def review
    decision = params[:decision].to_s
    note = params[:note].to_s.strip
    return render_error("请选择处理方式") unless %w[dismiss hide].include?(decision)
    return render_error("请填写处理说明") if note.blank? || note.length > 1000
    report = ContentReport.find(params[:id])
    report.with_lock do
      return render_error("该举报已处理", status: :conflict) unless report.status == "pending"
      if decision == "hide"
        target = report.target_type.constantize.find_by(id: report.target_id)
        return render_error("内容已不存在，请选择忽略") unless target
        target.with_lock do
          return render_error("内容已下架，请选择不予处理", status: :conflict) if target.is_a?(Topic) ? target.flagged? : target.moderated_at.present?
          if target.is_a?(Topic)
            target.flag!(by: current_user, reason: note)
          else
            target.update!(moderated_at: Time.current, moderation_reason: note, moderated_by_id: current_user.id)
            SiteNotifications.emit(receiver: target.owner, item: target, action: "event_taken_down",
              title: "活动已下架", body: "「#{target.title}」已下架，仅你可以查看。处理说明：#{note}",
              key: "event_taken_down:#{report.id}")
          end
        end
      end
      report.update!(status: "reviewed", decision: decision, review_note: note, reviewer: current_user, reviewed_at: Time.current)
    end
    render json: report_json(report)
  end

  def restore
    report = ContentReport.find(params[:id])
    return render_error("只有已下架内容可以恢复") unless report.status == "reviewed" && report.decision == "hide"
    note = params[:note].to_s.strip
    return render_error("请填写恢复说明") if note.blank? || note.length > 1000
    report.with_lock do
      return render_error("内容已恢复", status: :conflict) if report.restored_at.present?
      target = report.target_type.constantize.find_by(id: report.target_id)
      return render_error("内容已不存在") unless target
      target.with_lock do
        flagged_at = target.is_a?(Topic) ? target.flagged_at : target.moderated_at
        flagged_by = target.is_a?(Topic) ? target.flagged_by_id : target.moderated_by_id
        return render_error("内容状态已变化，请刷新后处理", status: :conflict) unless flagged_at && flagged_by == report.reviewer_id && flagged_at <= report.reviewed_at && flagged_at >= report.created_at
        if target.is_a?(Topic)
          target.unflag!
        else
          target.update!(moderated_at: nil, moderation_reason: nil, moderated_by_id: nil)
        end
      end
      report.update!(restored_at: Time.current, restored_by_id: current_user.id, restore_note: note)
    end
    render json: report_json(report)
  end

  private
  def require_admin
    render_error("仅平台管理员可处理举报", status: :forbidden) unless current_user&.platform_admin?
  end
  def report_json(report)
    target = report.target_type.constantize.find_by(id: report.target_id)
    {id: report.id, target_type: report.target_type, target_id: report.target_id, title: target&.title || "内容已删除", reason: report.reason, status: report.status, decision: report.decision, review_note: report.review_note, restored_at: report.restored_at, created_at: report.created_at}
  end
end
