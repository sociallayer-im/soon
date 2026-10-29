class Api::V1::CampaignsController < Api::BaseController
  skip_before_action :authenticate!, only: %i[index show]
  before_action :authenticate_optional!, only: %i[index show]
  before_action :set_campaign, only: %i[show update destroy]

  def index
    scope = Campaign.where(status: "published")
    if current_user
      managed = Membership.where(user_id: current_user.id, role: %w[owner manager]).select(:group_id)
      scope = current_user.platform_admin? ? Campaign.all : Campaign.where(status: "published").or(Campaign.where(owner_id: current_user.id)).or(Campaign.where(group_id: managed))
    end
    scope = scope.where(group_id: Group.resolve!(params[:group_id]).id) if params[:group_id].present?
    if params[:city].present?
      events = Event.visible_to(current_user).where(group_id: Group.where(city: params[:city].to_s.strip).select(:id))
      scope = scope.where(id: CampaignEvent.where(event_id: events.select(:id)).select(:campaign_id))
    end
    render_collection scope.order(created_at: :desc), blueprint: CampaignBlueprint, current_user: current_user
  end

  def show
    authorize @campaign
    render json: CampaignBlueprint.render(@campaign, current_user: current_user)
  end

  def create
    @campaign = Campaign.new(campaign_params.except(:event_ids))
    @campaign.owner = current_user
    authorize @campaign
    persist_campaign!
    render json: CampaignBlueprint.render(@campaign, current_user: current_user), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def update
    authorize @campaign
    # The owning group and author are immutable.
    @campaign.assign_attributes(campaign_params.except(:event_ids, :group_id))
    persist_campaign!
    render json: CampaignBlueprint.render(@campaign.reload, current_user: current_user)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def destroy
    authorize @campaign
    @campaign.destroy!
    head :no_content
  end

  private

  def set_campaign
    @campaign = Campaign.find(params[:id])
  end

  def campaign_params
    params.require(:campaign).permit(:group_id, :title, :kicker, :introduction,
      :cover_url, :status, event_ids: [], resource_links: [], media: [:type, :url])
  end

  def persist_campaign!
    Campaign.transaction do
      # Serialize edits so two replacements cannot mix their association rows.
      Campaign.where(id: @campaign.id).lock.load if @campaign.persisted?
      ids = campaign_params.key?(:event_ids) ? campaign_params[:event_ids].uniq : @campaign.event_ids
      invalid!("at most 200 events may be included") if ids.size > 200
      invalid!("published campaigns require at least one event") if @campaign.status == "published" && ids.empty?
      events = Event.where(id: ids)
      invalid!("one or more events do not exist") unless events.count == ids.size
      # Linking a public event never grants permission to edit it. Hidden
      # events may only be selected by an editor, and cannot be published here.
      events.each do |event|
        public_event = event.status == "published" && %w[normal open_registration].include?(event.visibility)
        invalid!("published campaigns may only include public published events") if @campaign.status == "published" && !public_event
        invalid!("event is not available") unless public_event || EventPolicy.new(current_user, event).update?
      end
      @campaign.save!
      if campaign_params.key?(:event_ids)
        @campaign.campaign_events.destroy_all
        ids.each_with_index { |id, index| @campaign.campaign_events.create!(event_id: id, position: index) }
      end
    end
  end

  def invalid!(message)
    @campaign.errors.add(:base, message)
    raise ActiveRecord::RecordInvalid, @campaign
  end
end
