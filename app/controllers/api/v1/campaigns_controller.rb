class Api::V1::CampaignsController < Api::BaseController
  skip_before_action :authenticate!, only: %i[index show]
  before_action :authenticate_optional!, only: %i[index show]
  before_action :set_campaign, only: %i[show update submit destroy]

  def index
    editor = false
    scope = if params[:owner_id].present?
      owner = User.resolve!(params[:owner_id])
      editor = current_user&.id == owner.id
      (editor ? owner.campaigns : Campaign.where(owner_id: owner.id, status: "published")).order(created_at: :desc)
    else
      Campaign.where(status: "published").order(created_at: :desc)
    end
    scope = scope.where(group_id: params[:group_id]) if params[:group_id].present?
    render_collection scope, blueprint: CampaignBlueprint, editor: editor
  end

  def show
    return render_not_found unless @campaign.status == "published" || editor?

    render json: CampaignBlueprint.render(@campaign, editor: editor?)
  end

  def create
    campaign = current_user.campaigns.new(campaign_params.merge(status: "draft", round: 1))
    if campaign.save
      render json: CampaignBlueprint.render(campaign, editor: true), status: :created
    else
      render_error(campaign.errors.full_messages.join(", "))
    end
  end

  def update
    return render_error("forbidden", status: :forbidden) unless editor?

    @campaign.assign_attributes(campaign_params)
    ActiveRecord::Base.transaction do
      if @campaign.status == "in_review"
        @campaign.round += 1
        @campaign.reviews.where(status: "pending").update_all(status: "superseded", updated_at: Time.current)
        @campaign.save!
        create_creator_review!(@campaign)
      else
        @campaign.save!
      end
    end
    render json: CampaignBlueprint.render(@campaign, editor: true)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # Removes the series and its review tasks. Linked events stay; event_ids is
  # only an array on the campaign.
  def destroy
    return render_error("forbidden", status: :forbidden) unless editor?

    ActiveRecord::Base.transaction do
      Activity.where(item: @campaign).delete_all
      @campaign.destroy!
    end
    head :no_content
  end

  def submit
    return render_error("forbidden", status: :forbidden) unless editor?
    return render_error("campaign cannot be submitted") unless @campaign.status.in?(%w[draft changes_requested])

    ActiveRecord::Base.transaction do
      @campaign.update!(status: "in_review")
      create_creator_review!(@campaign)
    end
    render json: CampaignBlueprint.render(@campaign, editor: true)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  private

  def set_campaign
    @campaign = Campaign.find(params[:id])
  end

  def editor?
    current_user.present? && @campaign.owner_id == current_user.id
  end

  def campaign_params
    params.require(:campaign).permit(:group_id, :title, :kicker, :introduction, :featured_image_url, event_ids: [], resource_links: [])
  end

  def create_creator_review!(campaign)
    campaign.reviews.create!(
      round: campaign.round,
      scope: "creator",
      status: "pending",
      snapshot: {
        "title" => campaign.title,
        "introduction" => campaign.introduction,
        "event_ids" => campaign.event_ids,
        "group_id" => campaign.group_id
      }
    )
  end
end
