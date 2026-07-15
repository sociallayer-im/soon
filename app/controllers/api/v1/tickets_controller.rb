class Api::V1::TicketsController < Api::BaseController
  skip_before_action :authenticate!, only: %i[stripe_callback set_payment_status stripe_config list_group_ticket_types check_coupon coupon_price]
  before_action :set_event, only: %i[create rsvp]
  before_action :set_ticket, only: %i[rsvp]

  STRIPE_MIN_CENTS = 400

  # POST /api/v1/events/:event_id/tickets
  def create
    authorize @event, :update?
    ticket = @event.tickets.new(ticket_params)
    if ticket.save
      render json: TicketBlueprint.render(ticket, view: :extended), status: :created
    else
      render_error(ticket.errors.full_messages.join(", "))
    end
  end

  # GET /api/v1/events/:event_id/tickets
  def index
    event = Event.find(params[:event_id])
    render_collection event.tickets, blueprint: TicketBlueprint
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/tickets/list_group_ticket_types?group_id=
  def list_group_ticket_types
    group = Group.find_by(nickname: params[:group_id]) || Group.find_by(id: params[:group_id])
    return render_not_found unless group

    render json: TicketBlueprint.render(group.tickets)
  end

  # POST /api/v1/tickets/:event_id/:ticket_id/rsvp   (event_id = params[:event_id], ticket_id = params[:ticket_id])
  def rsvp
    return render_error("event closed") if @event.status == "closed"
    return render_error("event ended") if Rails.env.production? && @event.end_time && @event.end_time + 1.hour < Time.current
    if @event.venue&.capacity.to_i > 0 && @event.participant_count.to_i >= @event.venue.capacity
      return render_error("exceed venue capacity")
    end
    return render_not_found unless @ticket

    if @ticket.quantity
      return render_error("run out of ticket") if @ticket.quantity <= 0
      @ticket.decrement!(:quantity)
    end

    participant = Participant.find_by(event: @event, user: current_user)
    if participant.nil?
      participant = @event.participants.new(user: current_user, status: "attending", payment_status: "pending", register_time: Time.current, message: params[:message])
    elsif participant.status == "cancelled"
      participant.assign_attributes(status: "attending", payment_status: "pending", register_time: Time.current, message: params[:message])
    end

    ticket_item =
      if @ticket.payment_methods.any?
        build_paid_ticket_item(participant)
      else
        TicketItem.new(ticket_type: @ticket.ticket_type, status: "succeeded", user: current_user, ticket: @ticket, event: @event, participant: participant, amount: 0, original_price: 0)
      end
    return if performed? # an inline error was already rendered by build_paid_ticket_item

    participant.save!
    @event.increment!(:participant_count)
    ticket_item.group_id = @ticket.group_id if ticket_item.ticket_type == "group"
    ticket_item.save!
    participant.update(ticket_id: ticket_item.ticket_id)

    if params[:answers].present? && @event.form_id
      submission = FormSubmission.find_or_initialize_by(form_id: @event.form_id, user_id: current_user.id)
      submission.status = "pending"
      submission.submitted_at = Time.current
      submission.save!
      FormAnswer.where(form_submission_id: submission.id).delete_all
      valid_field_ids = FormField.where(form_id: @event.form_id).pluck(:id)
      Array(params[:answers]).each do |a|
        next unless valid_field_ids.include?(a[:field_id].to_s)
        FormAnswer.create!(form_submission_id: submission.id, form_field_id: a[:field_id], value: a[:value])
      end
    end

    if ticket_item.status == "succeeded" && participant.payment_status != "succeeded"
      participant.update(payment_status: "succeeded")
      if ticket_item.ticket_type == "group" && !@event.group.memberships.exists?(user_id: current_user.id)
        @event.group.add_member(current_user.id, "member")
      end
      ticket_item.notify_group_owner
    end

    render json: { participant: ParticipantBlueprint.render_as_hash(participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  # POST /api/v1/tickets/verify_payment
  def verify_payment
    ticket_item = TicketItem.find_by(id: params[:ticket_item_id])
    return render_error("ticket_item not found") unless ticket_item
    return render_error("not authorized", status: :forbidden) unless ticket_item.user_id == current_user.id

    if ticket_item.status == "succeeded"
      return render json: { participant: ParticipantBlueprint.render_as_hash(ticket_item.participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
    end
    return render_error("ticket_item is not pending") unless ticket_item.status == "pending"

    if ticket_item.amount.to_i > 0 && ticket_item.chain != "stripe"
      return render_error("txhash is required for crypto payments") if params[:txhash].blank?
      pm = ticket_item.payment_method
      return render_error("payment_method not found") unless pm

      result = EvmPaymentVerifier.verify(
        txhash: params[:txhash], chain: ticket_item.chain,
        token_address: pm.token_address_for_chain(ticket_item.chain),
        receiver_address: pm.receiver_address, amount: ticket_item.amount,
        product_id: ticket_item.event_id, item_id: ticket_item.id
      )
      return render_error("tx verification failed: #{result.error}") unless result.success
    end

    mark_ticket_item_paid!(ticket_item, txhash: params[:txhash], sender_address: params[:sender_address])
    render json: { result: "ok", participant: ParticipantBlueprint.render_as_hash(ticket_item.reload.participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
  end

  # POST /api/v1/tickets/cancel_unpaid_item
  def cancel_unpaid_item
    ticket_item = find_ticket_item_by_order
    return render_error("ticket_item not found") unless ticket_item
    return render json: { result: "ok", message: "only for pending ticket_item" } unless ticket_item.status == "pending"
    return render_error("not allowed", status: :forbidden) unless ticket_item.user_id == current_user.id

    ticket_item.cancel
    render json: { ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
  end

  # POST /api/v1/tickets/set_payment_status  (webhook-style, shared-secret auth)
  def set_payment_status
    return render_error("invalid next token", status: :forbidden) unless ActiveSupport::SecurityUtils.secure_compare(params[:next_token].to_s, ENV.fetch("NEXT_TOKEN", ""))

    ticket_item = find_ticket_item_by_order
    return render_error("ticket_item not found") unless ticket_item
    return render json: { result: "ok", message: "skip verify succeeded ticket_item" } if ticket_item.status == "succeeded"
    return render_error("amount invalid") if params[:amount].to_i < ticket_item.amount.to_i

    if ticket_item.payment_method.present? && params[:txhash].present?
      result = EvmPaymentVerifier.verify(
        txhash: params[:txhash], chain: params[:chain],
        token_address: ticket_item.payment_method.token_address_for_chain(params[:chain]),
        receiver_address: ticket_item.payment_method.receiver_address, amount: ticket_item.amount,
        product_id: ticket_item.event_id, item_id: ticket_item.id
      )
      return render_error("tx verification failed: #{result.error}") unless result.success
    end

    mark_ticket_item_paid!(ticket_item, txhash: params[:txhash], sender_address: params[:sender_address])
    render json: { participant: ParticipantBlueprint.render_as_hash(ticket_item.reload.participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
  end

  # POST /api/v1/tickets/stripe_callback  (Stripe webhook)
  def stripe_callback
    if stripe_event_verified? && params[:type] == "charge.succeeded"
      intent_id = params.dig(:data, :object, :payment_intent)
      status = params.dig(:data, :object, :status)
      ticket_item = TicketItem.find_by(txhash: intent_id)
      if ticket_item && %w[pending unbounded succeeded cancelled timeout].include?(status)
        ticket_item.update(status: status)
        if ticket_item.participant && ticket_item.participant.payment_status != "succeeded"
          ticket_item.participant.update(payment_status: status)
        end
        ticket_item.notify_group_owner
      end
    end
    render json: { result: "ok" }
  end

  # POST /api/v1/tickets/stripe_client_secret
  def stripe_client_secret
    ticket_item = TicketItem.find(params[:ticket_item_id])
    return render_error("ticket_item is not for stripe") unless ticket_item.chain == "stripe"

    payment_intent = Stripe::PaymentIntent.create(amount: ticket_item.amount, automatic_payment_methods: { enabled: true }, currency: "usd")
    ticket_item.update(txhash: payment_intent.id)
    render json: { result: "ok", payment_intent_id: payment_intent.id, client_secret: payment_intent.client_secret }
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/tickets/stripe_config?group_id=
  def stripe_config
    render json: { stripe_public_key: ENV["STRIPE_PUBLIC_KEY"] }
  end

  # POST /api/v1/tickets/add_group_ticket_item
  def add_group_ticket_item
    group = Group.find_by(nickname: params[:group_id]) || Group.find_by(id: params[:group_id])
    return render_not_found unless group
    authorize group, :manage?, policy_class: GroupPolicy

    email = params[:email].to_s.downcase
    ticket = Ticket.find_by(content: params[:title].to_s.strip, group_id: group.id)
    return render_error("ticket type not found") unless ticket

    ticket_item = TicketItem.create_with(status: "unbounded").find_or_create_by(
      event_id: group.group_ticket_event_id, ticket_id: ticket.id,
      selector_type: "email", selector_address: email, ticket_type: "group",
      group_id: group.id, auth_type: "invite"
    )

    user = User.find_by(email: email)
    if user
      ticket_item.update(status: "succeeded", user_id: user.id)
      group.add_member(user.id, "member")
    end
    render json: { result: "ok" }
  end

  # POST /api/v1/tickets/set_coupon
  def set_coupon
    event = Event.find(params[:event_id])
    authorize event, :update?

    event.coupons_attributes = coupon_params if event.respond_to?(:coupons_attributes=)
    if event.respond_to?(:coupons_attributes=) && !event.save
      return render_error(event.errors.full_messages.join(", "))
    end
    render json: { result: "ok" }
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/tickets/check_coupon?event_id=&code=
  def check_coupon
    coupon = Coupon.find_by(event_id: params[:event_id], code: params[:code])
    render json: { coupon: coupon ? CouponBlueprint.render_as_hash(coupon, view: :with_code) : nil }
  end

  # GET /api/v1/tickets/get_coupon?id=
  def get_coupon
    coupon = Coupon.find(params[:id])
    authorize coupon.event, :update?
    render json: { coupon_id: coupon.id, code: coupon.code }
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/tickets/coupon_price?code=&payment_method_id=&amount=
  def coupon_price
    coupon = Coupon.find_by(selector_type: "code", code: params[:code])
    return render_error("coupon not found") unless coupon

    paymethod = PaymentMethod.find_by(id: params[:payment_method_id])
    amount, = coupon.get_discounted_price(params[:amount], paymethod)
    render json: { coupon_id: coupon.id, amount: amount }
  end

  # GET /api/v1/tickets/list?profile_handle=&event_id=
  def list
    user = User.find_by(handle: params[:profile_handle])
    return render_error("user not found") unless user
    return render_error("not authorized", status: :forbidden) unless user.id == current_user.id || event_manager?(params[:event_id])

    items = TicketItem.where(user_id: user.id, event_id: params[:event_id])
    items = items.where(status: params[:status]) if params[:status].present?
    render json: TicketItemBlueprint.render(items)
  end

  # GET /api/v1/tickets/coupons?event_id=
  def coupons
    event = Event.find(params[:event_id])
    authorize event, :update?
    render json: CouponBlueprint.render(event.coupons)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/tickets/coupon?id=
  def coupon
    coupon = Coupon.find(params[:id])
    authorize coupon.event, :update?
    render json: CouponBlueprint.render(coupon)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/tickets/coupon_usage?coupon_id=
  def coupon_usage
    coupon = Coupon.find(params[:coupon_id])
    authorize coupon.event, :update?
    render json: TicketItemBlueprint.render(TicketItem.includes(:user).where(coupon_id: coupon.id), view: :with_profile)
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  private

  def set_event
    @event = Event.find(params[:event_id])
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  def set_ticket
    @ticket = @event ? Ticket.find_by(id: params[:ticket_id], event_id: @event.id) : nil
  end

  def event_manager?(event_id)
    event = Event.find_by(id: event_id)
    event && (event.owner_id == current_user.id || current_user.memberships.exists?(group: event.group, role: %w[admin owner]))
  end

  def find_ticket_item_by_order
    TicketItem.find_by(chain: params[:chain], event_id: params[:product_id], id: params[:item_id])
  end

  def mark_ticket_item_paid!(ticket_item, txhash:, sender_address:)
    ticket_item.update!(status: "succeeded", txhash: txhash, sender_address: sender_address)

    if ticket_item.ticket_type == "group" && !ticket_item.group.memberships.exists?(user_id: ticket_item.user_id)
      ticket_item.group.add_member(ticket_item.user_id, "member")
    end

    if ticket_item.participant && ticket_item.participant.payment_status != "succeeded"
      ticket_item.participant.update(payment_status: "succeeded")
    end

    ticket_item.notify_group_owner
  end

  def build_paid_ticket_item(participant)
    paymethod = PaymentMethod.find_by(id: params[:payment_method_id], item_type: "Ticket", item_id: @ticket.id)
    unless paymethod
      render json: { result: "error", message: "payment_method not found" }
      return nil
    end

    amount = paymethod.price
    coupon_id = nil
    discount_value = nil
    discount_data = nil

    if params[:coupon].present?
      coupon = Coupon.find_by(selector_type: "code", event_id: @event.id, code: params[:coupon])
      unless coupon
        render json: { result: "error", message: "coupon not found" }
        return nil
      end
      if coupon.expires_at < Time.current || coupon.max_allowed_usages <= coupon.order_usage_count
        render json: { result: "error", message: "coupon is not available" }
        return nil
      end
      amount, discount_value, discount_data = coupon.get_discounted_price(amount, paymethod)
      if discount_value
        coupon.increment!(:order_usage_count)
        coupon_id = coupon.id
      end
    end

    selected_chain =
      if paymethod.chains.present?
        requested = params[:chain].to_s
        unless paymethod.chains.include?(requested)
          render json: { result: "error", message: "chain not supported by this payment method" }
          return nil
        end
        requested
      else
        paymethod.chain
      end

    amount = 0 if selected_chain == "stripe" && amount < STRIPE_MIN_CENTS
    status = amount.zero? ? "succeeded" : "pending"

    TicketItem.new(
      status: status, ticket_type: @ticket.ticket_type, user: current_user, ticket: @ticket, event: @event,
      chain: selected_chain, protocol: paymethod.protocol, participant: participant, amount: amount,
      original_price: paymethod.price, payment_method_id: paymethod.id,
      discount_value: discount_value, discount_data: discount_data, coupon_id: coupon_id
    )
  end

  def stripe_event_verified?
    true # TODO: verify Stripe-Signature header once a webhook signing secret is configured
  end

  def ticket_params
    params.require(:ticket).permit(:title, :content, :check_badge_class_id, :quantity, :end_time,
      :need_approval, :status, :ticket_type, :group_id, :start_date, :end_date,
      days_allowed: [], tracks_allowed: [],
      payment_methods_attributes: [:id, :chain, :kind, :token_name, :token_address, :receiver_address, :price, :protocol, :_destroy, chains: []])
  end

  def coupon_params
    params.require(:coupons).map do |c|
      c.permit(:id, :selector_type, :label, :code, :receiver_address, :discount_type, :discount,
        :expires_at, :max_allowed_usages, :order_usage_count, :_destroy,
        applicable_ticket_ids: [], ticket_item_ids: [])
    end
  end
end
