class Api::V1::ReviewsController < Api::BaseController
  def index
    scope = Review.joins(:campaign).where(campaigns: { owner_id: current_user.id }).order(created_at: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    render_collection scope, blueprint: ReviewBlueprint
  end

  def decide
    review = Review.find(params[:id])
    campaign = review.campaign
    return render_error("forbidden", status: :forbidden) unless campaign.owner_id == current_user.id
    return render_error("review is not pending") unless review.status == "pending"
    return render_error("campaign is not in review") unless campaign.status == "in_review"
    return render_error("review is for a different round") unless review.round == campaign.round

    case params[:decision].to_s
    when "approved"
      decide_approved(review, campaign)
    when "changes_requested"
      return render_error("note is required") if params[:note].blank?

      ActiveRecord::Base.transaction do
        campaign.update!(status: "changes_requested")
        review.update!(status: "changes_requested", note: params[:note], decided_by: current_user)
      end
    else
      return render_error("decision must be approved or changes_requested")
    end

    render json: ReviewBlueprint.render(review.reload)
  end

  private

  def decide_approved(review, campaign)
    if campaign.published_event_ids.empty?
      ActiveRecord::Base.transaction do
        campaign.update!(status: "changes_requested")
        review.update!(
          status: "changes_requested",
          decided_by: current_user,
          note: params[:note].presence || "published intersection is empty"
        )
      end
    else
      ActiveRecord::Base.transaction do
        campaign.update!(status: "published")
        review.update!(status: "approved", note: params[:note], decided_by: current_user)
        InboxNotice.campaign_published(campaign, initiator: current_user)
      end
    end
  end
end
