class Api::V1::VouchersController < Api::BaseController
  ADDRESS_REGEXP = /\A0x[a-fA-F0-9]{40}\z/
  # Voucher browsing (sender/group lists, detail) is public; actions that
  # touch a specific voucher (code reveal, revoke, use, reject) still require
  # auth via `authenticate!`, which is only skipped for index/show here.
  skip_before_action :authenticate!, only: %i[index show]
  before_action :set_voucher, only: %i[show get_code revoke use reject_badge]

  # Raised inside an issue_vouchers batch to roll the whole batch back.
  class InvalidReceiver < StandardError; end

  # GET /api/v1/vouchers/:id
  def show
    render json: VoucherBlueprint.render(@voucher, view: :with_badges)
  end

  # GET /api/v1/vouchers
  def index
    # Columns are table-qualified because the group_handle branch below joins
    # badge_classes, which has its own `counter` — unqualified, Postgres raises
    # AmbiguousColumn and the whole endpoint 500s. It only ever broke on that
    # one branch, so the sender/unfiltered paths kept working and hid it.
    vouchers = Voucher.includes(:sender, :badge_class)
                       .where("vouchers.expires_at > ? OR vouchers.expires_at IS NULL", Time.current)
                       .where("vouchers.counter != 0 OR vouchers.counter IS NULL")
    if params[:sender_handle].present?
      sender = User.find_by!(name: params[:sender_handle])
      vouchers = vouchers.where(sender_id: sender.id)
    elsif params[:group_handle].present?
      vouchers = vouchers.joins(badge_class: :group).where(groups: { name: params[:group_handle] })
    end
    render_collection vouchers.order(created_at: :desc), blueprint: VoucherBlueprint
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
    else
      # default-deny any strategy without an explicit eligibility rule (e.g. "remember")
      return render_error("voucher cannot be redeemed")
    end

    badge = nil
    badge_class = @voucher.badge_class
    @voucher.with_lock do
      # with_lock already reloads the record under lock before yielding here.
      return render_error("invalid voucher") if @voucher.invalid?
      if Badge.where(voucher_id: @voucher.id, owner_id: current_user.id).exists?
        return render_error("user has already claimed voucher")
      end

      badge = @voucher.build_badge_for(current_user)
      # Allocate the per-class index under the badge_class lock so concurrent
      # redemptions of *different* vouchers of the same class can't collide.
      badge_class.with_lock do
        badge.index = badge_class.counter
        badge.save!
        badge_class.increment!(:counter)
      end
      @voucher.decrement!(:counter)
    end

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
  end

  # POST /api/v1/vouchers/send_badge
  def send_badge
    issue_vouchers(action: "voucher/send_badge") do |address|
      receiver = User.find_by(name: address) || User.find_by(eth: address) || User.find_by(email: address)
      raise InvalidReceiver, "invalid receiver" unless receiver
      [{ strategy: "account", receiver_id: receiver.id, counter: 1 }, { receiver: receiver }]
    end
  end

  # POST /api/v1/vouchers/send_badge_by_address
  def send_badge_by_address
    issue_vouchers(action: "voucher/send_badge_by_address") do |address|
      raise InvalidReceiver, "invalid address" unless address =~ ADDRESS_REGEXP
      [{ strategy: "address", receiver_address: address, counter: 1 }, { receiver_address: address }]
    end
  end

  # POST /api/v1/vouchers/send_badge_by_email
  def send_badge_by_email
    issue_vouchers(action: "voucher/send_badge_by_email") do |address|
      raise InvalidReceiver, "invalid address or email" unless address =~ ADDRESS_REGEXP || address =~ URI::MailTo::EMAIL_REGEXP
      [{ strategy: "email", receiver_address: address, counter: 1 }, { receiver_address: address }]
    end
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
    @voucher = Voucher.find_by_id_or_legacy!(params[:id])
  end

  # Shared skeleton for the three send_badge_* actions: find + authorize the
  # badge_class once, then issue one voucher per receiver ATOMICALLY (a single
  # bad receiver rolls the whole batch back) with a consistent unweighted-value
  # guard. The block maps a receiver input to [voucher_attrs, activity_kwargs].
  def issue_vouchers(action:)
    badge_class = BadgeClass.find(params[:badge_class_id])
    authorize badge_class, :send?, policy_class: BadgeClassPolicy
    return render_error("invalid value for unweighted badge") if !badge_class.weighted && params[:value].present?

    vouchers = []
    ActiveRecord::Base.transaction do
      vouchers = Array(params[:receivers]).map do |input|
        attrs, activity = yield(input)
        voucher = build_voucher(badge_class, attrs)
        voucher.save!
        Activity.create(item: badge_class, initiator: current_user, action: action,
          payload: { voucher_id: voucher.id }, **activity)
        voucher
      end
    end
    render json: VoucherBlueprint.render(vouchers, view: :with_code), status: :created
  rescue InvalidReceiver => e
    render_error(e.message)
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
