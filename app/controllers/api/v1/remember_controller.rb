# "Remember": a shared commemorative badge minted to a small group of people
# who were physically together. One user creates a remember voucher and shows
# a QR code; others scan and join (recorded as remember/join activities); once
# enough people joined, the creator mints — every joiner receives an identical
# badge from the remember badge class.
class Api::V1::RememberController < Api::BaseController
  # How many joiners (creator included) a mint needs.
  REQUIRED_JOINERS = 2

  skip_before_action :authenticate!, only: %i[meta show related_groups]

  # GET /api/v1/remember/meta — client config: which badge class remember
  # badges mint from, and the joiner threshold. (sails hardcoded the id; here
  # it's whichever badge class is marked badge_type "remember".)
  def meta
    badge_class = BadgeClass.find_by(badge_type: "remember")
    types = badge_class ? [{ path: "remember", badge_class_id: badge_class.id, count: REQUIRED_JOINERS }] : []
    render json: { types: types }
  end

  # POST /api/v1/remember — mints nothing yet: creates the shared voucher and
  # auto-joins the creator.
  def create
    badge_class = BadgeClass.find_by(id: params[:badge_class_id], badge_type: "remember")
    return render_error("remember badge class not found") unless badge_class
    if !badge_class.weighted && params[:value].present?
      return render_error("invalid value for unweighted badge")
    end

    voucher = Voucher.new(
      sender: current_user, badge_class: badge_class, strategy: "remember",
      counter: 1, message: params[:message],
      expires_at: params[:expires_at].presence || 90.days.from_now
    )
    data = { value: params[:value], start_time: params[:start_time], end_time: params[:end_time] }.compact
    voucher.data = data if data.any?

    ActiveRecord::Base.transaction do
      voucher.save!
      join_activity!(voucher, current_user)
    end
    render json: payload(voucher), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # GET /api/v1/remember/:voucher_id — public poll target: who has joined,
  # and whether the mint already happened (counter 0).
  def show
    render json: payload(remember_voucher!)
  end

  # POST /api/v1/remember/:voucher_id/join — idempotent.
  def join
    voucher = remember_voucher!
    return render_error("remember is no longer active") if voucher.invalid?
    join_activity!(voucher, current_user)
    render json: payload(voucher)
  end

  # POST /api/v1/remember/:voucher_id/cancel — leave before the mint.
  def cancel
    joins(remember_voucher!).where(initiator_id: current_user.id).destroy_all
    render json: { result: "ok" }
  end

  # POST /api/v1/remember/:voucher_id/mint — creator only; one badge per
  # joiner. Same index/counter locking discipline as VouchersController#use.
  def mint
    voucher = remember_voucher!
    return render_error("only the creator can mint", status: :forbidden) unless voucher.sender_id == current_user.id

    badges = []
    badge_class = voucher.badge_class
    voucher.with_lock do
      return render_error("remember voucher already used") if voucher.counter.zero?
      members = joins(voucher).order(:created_at).to_a
      return render_error("not enough members joined") if members.size < REQUIRED_JOINERS

      members.each do |activity|
        badge = voucher.build_badge_for(activity.initiator)
        # Allocate the per-class index under the badge_class lock (see
        # VouchersController#use for why).
        badge_class.with_lock do
          badge.index = badge_class.counter
          badge.save!
          badge_class.increment!(:counter)
        end
        Activity.create!(item: badge, initiator: current_user, action: "remember/mint")
        badges << badge
      end
      voucher.update!(counter: 0) # fully consumed — a remember mints exactly once
    end

    render json: {
      voucher: JSON.parse(VoucherBlueprint.render(voucher)),
      badge_class: JSON.parse(BadgeClassBlueprint.render(badge_class)),
      badges: JSON.parse(BadgeBlueprint.render(badges))
    }
  end

  # GET /api/v1/remember/related_groups?user_ids=a,b,c
  # Popup-city groups (dated + located) each user attended events in — the
  # remember page decorates joined members with these.
  def related_groups
    ids = params[:user_ids].to_s.split(",").first(50)
    group_data = {}
    User.where(id: ids).includes(participated_events: :group).each do |user|
      groups = user.participated_events.map(&:group).uniq
                   .select { |g| g.start_date.present? && g.location.present? }
      group_data[user.id] = { name: user.name, groups: JSON.parse(GroupBlueprint.render(groups)) }
    end
    render json: { group_data: group_data }
  end

  private

  def remember_voucher!
    Voucher.find_by!(id: params[:voucher_id], strategy: "remember")
  end

  def joins(voucher)
    Activity.where(item_type: "Voucher", item_id: voucher.id, action: "remember/join")
  end

  def join_activity!(voucher, user)
    Activity.find_or_create_by!(item_type: "Voucher", item_id: voucher.id,
      initiator_id: user.id, action: "remember/join")
  end

  # The shared read shape for create/show/join: the voucher, its badge class,
  # and the join roster (each activity carries its initiator).
  def payload(voucher)
    {
      voucher: JSON.parse(VoucherBlueprint.render(voucher)),
      badge_class: JSON.parse(BadgeClassBlueprint.render(voucher.badge_class)),
      activities: JSON.parse(ActivityBlueprint.render(joins(voucher).includes(:initiator).order(:created_at)))
    }
  end
end
