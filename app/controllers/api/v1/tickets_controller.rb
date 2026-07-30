class Api::V1::TicketsController < Api::BaseController
  skip_before_action :authenticate!, only: %i[stripe_callback set_payment_status stripe_config list_group_ticket_types check_coupon coupon_price]
  before_action :set_event, only: %i[create update destroy rsvp]
  before_action :set_ticket, only: %i[update destroy rsvp]

  STRIPE_MIN_CENTS = PaymentMethod::STRIPE_MIN_CENTS

  # How long an unpaid order holds its inventory before the sweeper expires
  # it. Uniform across rails (PAYMENTS_PLAN §6.5): sized to Stripe's 30-min
  # Checkout Session floor plus slack.
  RESERVATION_TTL = 35.minutes

  # Raised when a coupon is exhausted between quoting and checkout; rolls back rsvp.
  class CouponUnavailable < StandardError; end

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

  # PATCH /api/v1/events/:event_id/tickets/:ticket_id
  def update
    authorize @event, :update?
    return render_not_found unless @ticket

    if @ticket.update(ticket_params)
      render json: TicketBlueprint.render(@ticket, view: :extended)
    else
      render_error(@ticket.errors.full_messages.join(", "))
    end
  end

  # DELETE /api/v1/events/:event_id/tickets/:ticket_id
  # Sold tickets must stay (ticket_items reference them) — retire with status
  # "inactive" instead; unsold tickets are destroyed outright.
  def destroy
    authorize @event, :update?
    return render_not_found unless @ticket

    if @ticket.ticket_items.exists?
      @ticket.update!(status: "inactive")
    else
      @ticket.destroy
    end
    head :no_content
  end

  # GET /api/v1/events/:event_id/tickets
  def index
    event = Event.find(params[:event_id])
    render_collection event.tickets, blueprint: TicketBlueprint, view: :extended
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
    return render_error("ticket is not on sale") unless @ticket.status == "normal"
    return render_error("ticket sale has ended") if @ticket.end_time && @ticket.end_time < Time.current
    if @ticket.check_badge_class_id.present? && !holds_required_badge?(@ticket)
      return render_error("this ticket requires a badge you do not hold", status: :forbidden)
    end
    return render_error("run out of ticket") unless @ticket.reserve!

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
        TicketItem.new(ticket_type: @ticket.ticket_type, status: "succeeded", user: current_user, ticket: @ticket, event: @event, participant: participant, amount: 0, original_price: 0, payment_provider: "free", paid_at: Time.current)
      end
    if performed? # an inline error was already rendered by build_paid_ticket_item
      @ticket.release!
      return
    end
    ticket_item.group_id = @ticket.group_id if ticket_item.ticket_type == "group"

    # Everything that must succeed-or-fail together lives in one transaction:
    # a rollback undoes the participant, the count bump, and the coupon usage.
    # The ticket reservation is committed separately (reserve!), so it is the
    # only thing we must hand back on failure.
    ActiveRecord::Base.transaction do
      participant.save!
      @event.increment!(:participant_count)
      ticket_item.save!
      participant.update!(ticket_id: ticket_item.ticket_id)
      consume_coupon!(ticket_item)
      save_form_submission! if params[:answers].present? && @event.form_id
      ticket_item.confirm_payment! if ticket_item.status == "succeeded"
    end

    render json: { participant: ParticipantBlueprint.render_as_hash(participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
  rescue CouponUnavailable
    @ticket.release!
    render_error("coupon is not available")
  rescue ActiveRecord::RecordInvalid => e
    @ticket.release!
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

    if ticket_item.amount.to_i > 0
      return unless payment_proof_ok?(ticket_item, chain: ticket_item.chain, txhash: params[:txhash])
    end

    ticket_item.confirm_payment!(txhash: params[:txhash], sender_address: params[:sender_address])
    render json: { result: "ok", participant: ParticipantBlueprint.render_as_hash(ticket_item.participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
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
    token = ENV["NEXT_TOKEN"].to_s
    # An unset NEXT_TOKEN must not authorize anyone — secure_compare("", "") is
    # true, so guard the blank case explicitly rather than relying on the compare.
    if token.blank? || !ActiveSupport::SecurityUtils.secure_compare(params[:next_token].to_s, token)
      return render_error("invalid next token", status: :forbidden)
    end

    ticket_item = find_ticket_item_by_order
    return render_error("ticket_item not found") unless ticket_item
    return render json: { result: "ok", message: "skip verify succeeded ticket_item" } if ticket_item.status == "succeeded"
    return render_error("amount invalid") if params[:amount].to_i < ticket_item.amount.to_i

    if ticket_item.amount.to_i > 0 && ticket_item.chain != "stripe"
      return unless payment_proof_ok?(ticket_item, chain: params[:chain].presence || ticket_item.chain, txhash: params[:txhash])
    end

    ticket_item.confirm_payment!(txhash: params[:txhash], sender_address: params[:sender_address])
    render json: { participant: ParticipantBlueprint.render_as_hash(ticket_item.participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
  end

  # POST /api/v1/tickets/stripe_callback  (Stripe webhook)
  def stripe_callback
    return render json: { result: "ignored" } unless stripe_event_verified?

    intent_id = params.dig(:data, :object, :payment_intent)
    ticket_item = intent_id.present? && TicketItem.find_by(txhash: intent_id)
    # Only pending items transition, so a late webhook can't resurrect a
    # cancelled/timed-out item (which would oversell against released quantity).
    if ticket_item && ticket_item.status == "pending"
      case params[:type]
      when "charge.succeeded"
        # Funnel through confirm_payment! so the group auto-join / participant
        # flip / notify side effects match every other payment path.
        ticket_item.confirm_payment! if params.dig(:data, :object, :status) == "succeeded"
      when "charge.failed", "charge.expired", "payment_intent.canceled"
        ticket_item.cancel # releases the reserved quantity and coupon usage
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
  #
  # Manager grants a group ticket to an email address. A matching account gets
  # the TicketItem + membership immediately; an unknown email gets a
  # GroupInvite (ticket_id set) that auto-accepts — see
  # GroupInvite#auto_accept_ticket_invites_for — the moment that email is
  # verified via signup/bind/trusted_signin.
  def add_group_ticket_item
    group = Group.find_by(nickname: params[:group_id]) || Group.find_by(id: params[:group_id])
    return render_not_found unless group
    authorize group, :manage?, policy_class: GroupPolicy

    email = params[:email].to_s.downcase
    ticket = Ticket.find_by(content: params[:title].to_s.strip, group_id: group.id)
    return render_error("ticket type not found") unless ticket

    user = User.find_by(email: email)
    if user
      ticket_item = TicketItem.create_with(status: "succeeded", user_id: user.id).find_or_create_by(
        event_id: group.group_ticket_event_id, ticket_id: ticket.id,
        selector_type: "email", selector_address: email, ticket_type: "group",
        group_id: group.id, auth_type: "invite"
      )
      ticket_item.update(status: "succeeded", user_id: user.id) unless ticket_item.status == "succeeded"
      group.add_member(user.id, "member")
    else
      GroupInvite.find_or_create_by!(
        group: group, ticket_id: ticket.id,
        receiver_address_type: "email", receiver_address: email, status: "sending"
      ) { |invite| invite.role = "member" }
    end
    render json: { result: "ok" }
  end

  # POST /api/v1/tickets/set_coupon
  def set_coupon
    event = Event.find(params[:event_id])
    authorize event, :update?

    # _destroy is translated to a soft delete (removed: true): ticket_items
    # keep a valid coupon_id for their audit trail, and Coupon#available?
    # stops the code redeeming. A hard destroy would sever that history.
    attrs = coupon_params.map do |c|
      if c[:_destroy].present? && c[:id].present?
        { id: c[:id], removed: true }
      else
        c.except(:_destroy)
      end
    end
    event.coupons_attributes = attrs
    return render_error(event.errors.full_messages.join(", ")) unless event.save

    render json: { result: "ok" }
  rescue ActiveRecord::RecordNotFound
    render_not_found
  end

  # GET /api/v1/tickets/check_coupon?event_id=&code=
  def check_coupon
    coupon = Coupon.find_by(event_id: params[:event_id], code: params[:code])
    coupon = nil if coupon&.removed # a soft-deleted code looks like no code at all
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
  #
  # The quote must agree with what rsvp will actually accept, or the buyer
  # sees one price and checkout rejects it — both paths run Ticketing::Quote.
  def coupon_price
    coupon = Coupon.find_by(selector_type: "code", code: params[:code])
    return render_error("coupon not found") if coupon.nil? || coupon.removed

    paymethod = PaymentMethod.find_by(id: params[:payment_method_id])
    if paymethod
      quote = Ticketing::Quote.call(paymethod: paymethod, coupon: coupon, base_amount: params[:amount])
      return render_error(quote.error) unless quote.ok?
      amount = quote.amount
    else
      # Legacy chainless preview: no payment context at all, discount as-is.
      amount, = coupon.get_discounted_price(params[:amount], nil)
    end
    render json: { coupon_id: coupon.id, amount: amount }
  end

  # GET /api/v1/tickets/list?profile_handle=&event_id=
  def list
    if params[:profile_handle].present?
      user = User.find_by(name: params[:profile_handle])
      return render_error("user not found") unless user
      return render_error("not authorized", status: :forbidden) unless user.id == current_user.id || event_manager?(params[:event_id])

      items = TicketItem.where(user_id: user.id, event_id: params[:event_id])
    else
      # No user filter: the whole event's order list — managers only.
      return render_error("not authorized", status: :forbidden) unless event_manager?(params[:event_id])
      items = TicketItem.where(event_id: params[:event_id])
    end
    items = items.where(status: params[:status]) if params[:status].present?
    render json: TicketItemBlueprint.render(items.includes(:user), view: :with_profile)
  end

  # GET /api/v1/tickets/coupons?event_id=
  def coupons
    event = Event.find(params[:event_id])
    authorize event, :update?
    render json: CouponBlueprint.render(event.coupons.where(removed: [false, nil]))
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
    event && (event.owner_id == current_user.id || current_user.memberships.exists?(group: event.group, role: %w[manager owner]))
  end

  def find_ticket_item_by_order
    TicketItem.find_by(chain: params[:chain], event_id: params[:product_id], id: params[:item_id])
  end

  def holds_required_badge?(ticket)
    Badge.where(badge_class_id: ticket.check_badge_class_id, owner_id: current_user.id)
         .where.not(status: "burned").exists?
  end

  # Consumes one coupon usage for a persisted ticket_item, re-checking
  # availability under a row lock so concurrent RSVPs can't over-redeem the
  # last unit. Raises CouponUnavailable (rolling back the enclosing rsvp
  # transaction) if the coupon was exhausted between quoting and checkout.
  def consume_coupon!(ticket_item)
    return unless ticket_item.coupon_id

    coupon = ticket_item.coupon
    coupon.with_lock do
      raise CouponUnavailable unless coupon.available?
      coupon.increment!(:order_usage_count)
    end
  end

  def save_form_submission!
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

  # Verifies that a payment actually settled, per the item's rail. Returns true
  # when confirmed; on a hard failure it renders the error itself and returns
  # false, so callers just `return unless payment_proof_ok?(...)`.
  def payment_proof_ok?(ticket_item, chain:, txhash:)
    if ticket_item.chain == "stripe"
      return true if stripe_payment_confirmed?(ticket_item)
      render_error("stripe payment not confirmed")
      return false
    end

    if txhash.blank?
      render_error("txhash is required for crypto payments")
      return false
    end
    # A single on-chain transfer must not be replayed across multiple orders.
    if TicketItem.where(txhash: txhash, status: "succeeded").where.not(id: ticket_item.id).exists?
      render_error("this transaction was already used for another ticket")
      return false
    end
    pm = ticket_item.payment_method
    unless pm
      render_error("payment_method not found")
      return false
    end

    result = EvmPaymentVerifier.verify(
      txhash: txhash, chain: chain,
      token_address: pm.token_address_for_chain(chain),
      receiver_address: pm.receiver_address, amount: ticket_item.amount,
      product_id: ticket_item.event_id, item_id: ticket_item.id
    )
    unless result.success
      render_error("tx verification failed: #{result.error}")
      return false
    end
    true
  end

  # Confirms a Stripe PaymentIntent server-side (the item stores the intent id in
  # txhash). Any Stripe/API error is treated as "not confirmed".
  def stripe_payment_confirmed?(ticket_item)
    return false if ticket_item.txhash.blank?

    intent = Stripe::PaymentIntent.retrieve(ticket_item.txhash)
    intent.status == "succeeded" && intent.amount.to_i >= ticket_item.amount.to_i
  rescue Stripe::StripeError
    false
  end

  def build_paid_ticket_item(participant)
    paymethod = PaymentMethod.find_by(id: params[:payment_method_id], item_type: "Ticket", item_id: @ticket.id)
    unless paymethod
      render_error("payment_method not found")
      return nil
    end

    quote = Ticketing::Quote.call(
      paymethod: paymethod, requested_chain: params[:chain].presence,
      require_chain: true, coupon_code: params[:coupon].presence,
      event: @event, ticket: @ticket
    )
    unless quote.ok?
      render_error(quote.error)
      return nil
    end

    status = quote.amount.zero? ? "succeeded" : "pending"

    TicketItem.new(
      status: status, ticket_type: @ticket.ticket_type, user: current_user, ticket: @ticket, event: @event,
      chain: quote.chain, protocol: paymethod.protocol, participant: participant, amount: quote.amount,
      original_price: paymethod.price, payment_method_id: paymethod.id,
      discount_value: quote.discount_value, discount_data: quote.discount_data,
      # Record the coupon on the item; usage is consumed only once the item
      # actually persists (see consume_coupon!), never on an aborted request.
      coupon_id: quote.discount_value ? quote.coupon&.id : nil,
      payment_provider: quote.chain == "stripe" ? "stripe" : "evm",
      currency: quote.chain == "stripe" ? "usd" : nil,
      paid_at: status == "succeeded" ? Time.current : nil,
      reserved_until: status == "pending" ? RESERVATION_TTL.from_now : nil
    )
  end

  # Verifies the Stripe-Signature header when a signing secret is configured.
  # Without a secret we fail *closed* in production (an unverified webhook must
  # not flip a real order to paid) but stay open in dev/test for local testing.
  def stripe_event_verified?
    secret = ENV["STRIPE_WEBHOOK_SECRET"]
    return !Rails.env.production? if secret.blank?

    Stripe::Webhook.construct_event(request.raw_post, request.headers["Stripe-Signature"], secret)
    true
  rescue Stripe::SignatureVerificationError, JSON::ParserError
    false
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
