class Api::V1::CampaignReviewsController < Api::BaseController
  before_action :require_platform_admin

  def index
    status = params[:status].presence || "pending"
    return render_error("invalid review status") unless %w[pending approved rejected].include?(status)
    render_collection Campaign.where(status: "published", review_status: status).order(created_at: :desc, id: :desc), blueprint: CampaignBlueprint, current_user: current_user
  end

  def review
    decision = params[:decision].to_s
    return render_error("请选择批准或拒绝") unless %w[approved rejected].include?(decision)
    reason = params[:reason].to_s.strip
    return render_error("请填写拒绝原因") if decision == "rejected" && reason.blank?
    return render_error("审核说明最多 1000 字") if reason.length > 1000
    campaign = Campaign.find(params[:id])
    campaign.with_lock do
      return render_error("该申请已处理，请刷新列表", status: :conflict) unless campaign.status == "published" && campaign.review_status == "pending"
      if decision == "approved"
        errors = campaign.public_submission_errors
        return render_error(errors.join("，")) if errors.any?
      end
      campaign.campaign_review_logs.create!(reviewer: current_user, decision: decision, reason: reason.presence)
      campaign.update!(review_status: decision, review_reason: reason.presence, reviewed_at: Time.current, reviewed_by_id: current_user.id)
    end
    render json: CampaignBlueprint.render(campaign.reload, current_user: current_user)
  end

  private

  def require_platform_admin
    render_error("仅超级管理员可审核专题", status: :forbidden) unless current_user&.platform_admin?
  end
end
