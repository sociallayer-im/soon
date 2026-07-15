class Api::V1::VouchersController < Api::BaseController
  ADDRESS_REGEXP = /\A0x[a-fA-F0-9]{40}\z/
  before_action :set_voucher, only: %i[show get_code revoke use reject_badge]

  # GET /api/v1/vouchers/:id
  def show
    render json: VoucherBlueprint.render(@voucher, view: :with_badges)
  end

  # GET /api/v1/vouchers
  def index
    vouchers = Voucher.includes(:sender, :badge_class)
                       .where("expires_at > ? OR expires_at IS NULL", Time.current)
                       .where("counter != 0 OR counter IS NULL")
    if params[:sender_handle].present?
      sender = User.find_by!(handle: params[:sender_handle])
      vouchers = vouchers.where(sender_id: sender.id)
    elsif params[:group_handle].present?
      vouchers = vouchers.joins(badge_class: :group).where(groups: { handle: params[:group_handle] })
    end
    render_collection vouchers.order(created_at: :desc), blueprint: VoucherBlueprint
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/vouchers/:id/code
  def get_code
    authorize @voucher, :read?
    render json: { voucher_id: @voucher.id, code: @voucher.code }
  end

  # POST /api/v1/vouchers/:id/revoke
  def revoke
    authorize @voucher, :update?
    @voucher.update(counter: 0)
    render json: VoucherBlueprint.render(@voucher, view: :with_badges)
  end

  # POST /api/v1/vouchers/:id/use
  def use
    return render_error("invalid voucher") if @voucher.invalid?

    case @voucher.strategy
    when "code"
      return render_error("voucher code is empty or incorrect") unless @voucher.code.to_s == params[:code].to_s
    when "event", "account"
      return render_error("voucher is not for this user") unless @voucher.receiver_id == current_user.id
    when "address"
      return render_error("voucher is not for this user") unless @voucher.receiver_address == current_user.eth
    when "email"
      return render_error("voucher is not for this user") unless @voucher.receiver_address == current_user.email
    end

    if Badge.where(voucher_id: @voucher.id, owner_id: current_user.id).exists?
      return render_error("user has already claimed voucher")
    end

    badge_class = @voucher.badge_class
    badge = Badge.new(
      index: badge_class.counter,
      content: @voucher.badge_content || @voucher.message || badge_class.content,
      metadata: badge_class.metadata,
      status: "minted",
      badge_class_id: badge_class.id,
      creator_id: @voucher.sender_id,
      owner_id: current_user.id,
      voucher_id: @voucher.id
    )
    badge.title = @voucher.badge_title || badge_class.title
    badge.image_url = @voucher.badge_image || badge_class.image_url
    if @voucher.data.present?
      badge.value = @voucher.data["value"] if @voucher.data["value"]
      badge.start_time = @voucher.data["start_time"] if @voucher.data["start_time"]
      badge.end_time = @voucher.data["end_time"] if @voucher.data["end_time"]
    end
    badge.save!

    badge_class.increment!(:counter)
    @voucher.decrement!(:counter)

    if @voucher.strategy == "event"
      Participant.find_by(voucher_id: @voucher.id)&.update(badge_id: badge.id)
    end

    if badge_class.permissions.include?("group_member_pass") && badge_class.group
      Membership.find_or_create_by(user: current_user, group: badge_class.group) do |m|
        m.role = "member"
        m.active = true
      end
    end

    Activity.create(item: badge, initiator: current_user, action: "voucher/use", payload: { index: params[:index] })
    render json: BadgeBlueprint.render(badge)
  end

  # POST /api/v1/vouchers
  #
  # Mints a code-strategy voucher, redeemable up to `counter` times.
  def create
    badge_class = BadgeClass.find(params[:badge_class_id])
    authorize badge_class, :send?, policy_class: BadgeClassPolicy
    return render_error("invalid value for unweighted badge") if !badge_class.weighted && params[:value].present?

    voucher = build_voucher(badge_class,
      strategy: "code",
      code: SecureRandom.alphanumeric(8).upcase,
      counter: params[:counter].presence || 65_535)

    if voucher.save
      Activity.create(item: badge_class, initiator: current_user, action: "voucher/create")
      render json: VoucherBlueprint.render(voucher, view: :with_code), status: :created
    else
      render_error(voucher.errors.full_messages.join(", "))
    end
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/vouchers/send_badge
  def send_badge
    badge_class = BadgeClass.find(params[:badge_class_id])
    authorize badge_class, :send?, policy_class: BadgeClassPolicy
    return render_error("invalid value for unweighted badge") if !badge_class.weighted && params[:value].present?

    vouchers = Array(params[:receivers]).map do |address|
      receiver = User.find_by(handle: address) || User.find_by(eth: address) || User.find_by(email: address)
      return render_error("invalid receiver") unless receiver

      voucher = build_voucher(badge_class, strategy: "account", receiver_address_type: "id", receiver_id: receiver.id, counter: 1)
      voucher.save!
      Activity.create(item: badge_class, initiator: current_user, action: "voucher/send_badge", receiver: receiver, payload: { voucher_id: voucher.id })
      voucher
    end
    render json: VoucherBlueprint.render(vouchers, view: :with_code), status: :created
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/vouchers/send_badge_by_address
  def send_badge_by_address
    badge_class = BadgeClass.find(params[:badge_class_id])
    authorize badge_class, :send?, policy_class: BadgeClassPolicy

    vouchers = Array(params[:receivers]).map do |address|
      return render_error("invalid address") unless address =~ ADDRESS_REGEXP

      voucher = build_voucher(badge_class, strategy: "address", receiver_address_type: "address", receiver_address: address, counter: 1)
      voucher.save!
      Activity.create(item: badge_class, initiator: current_user, action: "voucher/send_badge_by_address", receiver_address: address, payload: { voucher_id: voucher.id })
      voucher
    end
    render json: VoucherBlueprint.render(vouchers, view: :with_code), status: :created
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/vouchers/send_badge_by_email
  def send_badge_by_email
    badge_class = BadgeClass.find(params[:badge_class_id])
    authorize badge_class, :send?, policy_class: BadgeClassPolicy

    vouchers = Array(params[:receivers]).map do |address|
      return render_error("invalid address or email") unless address =~ ADDRESS_REGEXP || address =~ URI::MailTo::EMAIL_REGEXP

      voucher = build_voucher(badge_class, strategy: "email", receiver_address_type: "email", receiver_address: address, counter: 1)
      voucher.save!
      Activity.create(item: badge_class, initiator: current_user, action: "voucher/send_badge_by_email", receiver_address: address, payload: { voucher_id: voucher.id })
      voucher
    end
    render json: VoucherBlueprint.render(vouchers, view: :with_code), status: :created
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # POST /api/v1/vouchers/:id/reject_badge
  def reject_badge
    unless @voucher.strategy == "account" && @voucher.receiver_id == current_user.id
      return render_error("voucher is not for this user")
    end

    @voucher.update(counter: 0)
    render json: VoucherBlueprint.render(@voucher, view: :with_badges)
  end

  private

  def set_voucher
    @voucher = Voucher.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def build_voucher(badge_class, attrs)
    data = {}
    data[:value] = params[:value] if params[:value].present?
    data[:start_time] = params[:start_time] if params[:start_time].present?
    data[:end_time] = params[:end_time] if params[:end_time].present?

    Voucher.new(attrs.merge(
      sender: current_user,
      badge_class: badge_class,
      badge_title: params[:badge_title],
      badge_content: params[:badge_content],
      badge_image: params[:badge_image],
      message: params[:message],
      expires_at: params[:expires_at].presence || 90.days.from_now,
      data: data.presence
    ))
  end
end
