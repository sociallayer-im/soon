class Api::V1::TicketsController < Api::BaseController
  skip_before_action :authenticate!, only: %i[set_payment_status list_group_ticket_types check_coupon coupon_price]
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
    return if stripe_setting_rejected?(@event)
    return if wechat_organizer_rejected?(@event)
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
    return if stripe_setting_rejected?(@event)
    return if wechat_organizer_rejected?(@event)

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
    if @ticket.check_group_ids.present? && !member_of_required_group?(@ticket)
      return render_error("this ticket is limited to members of specific groups", status: :forbidden)
    end
    # A live order for THIS ticket already exists — a double-click, or a retry
    # during the post-payment confirmation window. Reserving again would hold a
    # second unit of inventory for one seat; the existing order is what needs
    # finishing (checkout_session hands back its open Stripe session).
    # Deliberately per-ticket: buying a DIFFERENT ticket type of the same event
    # stays allowed.
    if TicketItem.exists?(event_id: @event.id, ticket_id: @ticket.id, user_id: current_user.id, status: "pending")
      return render_error("you already have an unpaid order for this ticket")
    end
    return render_error("run out of ticket") unless @ticket.reserve!

    # Buying a ticket does not skip the door: an event that requires approval,
    # carries an application form, or sells a need_approval ticket puts the
    # buyer in "pending" until a manager approves them. rsvp used to hardcode
    # "attending", so paying bypassed approval entirely — while the free join
    # path (participants#create) honoured it.
    is_manager = current_user.memberships.exists?(group: @event.group, role: %w[manager owner])
    needs_approval = !is_manager &&
      (@event.require_approval || @event.form_id.present? || @ticket.need_approval)
    new_status = needs_approval ? "pending" : "attending"

    # A withdrawn (soft-deleted) participant is reused rather than re-inserted
    # — (user_id, event_id) is unique — and registered_at is re-stamped since
    # they signed up again.
    participant = Participant.find_by(event: @event, user: current_user)
    was_seated = participant&.seated?
    if participant.nil?
      participant = @event.participants.new(user: current_user, status: new_status, registered_at: Time.current, message: params[:message])
    elsif participant.cancelled? || participant.status == "declined"
      participant.assign_attributes(status: new_status, registered_at: Time.current, message: params[:message])
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
      # Only a seated participant counts, and only once — buying a second
      # ticket for an event you already attend must not count twice, and a
      # pending (unapproved) buyer holds no seat until approval.
      @event.increment!(:participant_count) if participant.seated? && !was_seated
      ticket_item.save!
      ticket_item.record_activity!("order_placed", source: "api", actor: current_user,
        amount: ticket_item.amount, currency: ticket_item.currency,
        provider: ticket_item.payment_provider, ticket_id: ticket_item.ticket_id)
      consume_coupon!(ticket_item)
      save_form_submission! if params[:answers].present? && @event.form_id
      # payment_status is a summary of the orders, never set by hand:
      # confirm_payment! refreshes it for a settled order, so only an order
      # still awaiting payment needs the explicit call.
      if ticket_item.status == "succeeded"
        ticket_item.confirm_payment!
      else
        participant.refresh_payment_status!
      end
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
    return unless approved_for_payment?(ticket_item)

    if ticket_item.amount.to_i > 0
      return unless payment_proof_ok?(ticket_item, chain: ticket_item.chain, txhash: params[:txhash])
    end

    ticket_item.confirm_payment!(txhash: params[:txhash], sender_address: params[:sender_address])
    render json: { result: "ok", participant: ParticipantBlueprint.render_as_hash(ticket_item.participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
  end

  # POST /api/v1/tickets/cancel_unpaid_item
  #
  # Abandoning a registration that never completed. Cancelling releases the
  # held unit and (if it was their last live order) withdraws the participant,
  # which is what lets the person sign up again afterwards — rsvp treats a
  # cancelled participant as a fresh one.
  def cancel_unpaid_item
    ticket_item = find_ticket_item_by_order
    return render_error("ticket_item not found") unless ticket_item
    # Ownership BEFORE status: the old order answered "only for pending" for
    # someone else's order, which told a stranger its status.
    return render_error("not allowed", status: :forbidden) unless ticket_item.user_id == current_user.id
    return render json: { result: "ok", message: "only for pending ticket_item" } unless ticket_item.status == "pending"

    ticket_item.cancel(actor: current_user)
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

    # Fiat orders confirm exclusively through a signature-verified callback or
    # the sweeper's server-side query — never through this shared-secret
    # endpoint, which skipped real verification and let any NEXT_TOKEN holder
    # mint paid tickets (PAYMENTS_PLAN §3.5). Written against the rail set so
    # a new rail is closed by default rather than open until someone notices.
    if PaymentMethod::FIAT_CHAINS.include?(ticket_item.chain)
      return render_error("#{ticket_item.chain} orders are confirmed via webhook only", status: :forbidden)
    end

    if ticket_item.amount.to_i > 0
      return unless payment_proof_ok?(ticket_item, chain: params[:chain].presence || ticket_item.chain, txhash: params[:txhash])
    end

    ticket_item.confirm_payment!(txhash: params[:txhash], sender_address: params[:sender_address])
    render json: { participant: ParticipantBlueprint.render_as_hash(ticket_item.participant), ticket_item: TicketItemBlueprint.render_as_hash(ticket_item) }
  end

  # POST /api/v1/tickets/checkout_session  {ticket_item_id}
  #
  # Mints (or re-serves) the Stripe-hosted Checkout page for a pending stripe
  # order. One open session per order: closing the tab and clicking "pay"
  # again returns the SAME session, never an orphaned duplicate (§2.2).
  def checkout_session
    return render_not_found unless stripe_enabled?

    ticket_item = TicketItem.find_by(id: params[:ticket_item_id])
    return render_error("ticket_item not found") unless ticket_item
    return render_error("not authorized", status: :forbidden) unless ticket_item.user_id == current_user.id
    return render_error("ticket_item is not for stripe") unless ticket_item.payment_provider == "stripe"
    return render_error("ticket_item is not pending") unless ticket_item.status == "pending"
    return unless approved_for_payment?(ticket_item)

    setting = StripeSetting.find_by(id: ticket_item.stripe_setting_id)
    unless setting&.status == "active"
      return render_error("stripe is not configured for this ticket")
    end

    # The whole lookup-or-create runs under a row lock: two double-clicked
    # requests would otherwise BOTH create payable sessions carrying the same
    # metadata before either provider_ref write lands — both chargeable, only
    # one order. The lock holds across the Stripe call; that's a per-order
    # serialization, acceptable and simpler than any optimistic scheme.
    checkout = nil
    stale = false
    ticket_item.with_lock do
      # Re-check under the lock — the pre-lock check can go stale.
      if ticket_item.status != "pending"
        stale = true
        next
      end

      if ticket_item.provider_ref.present?
        existing = StripeGateway.retrieve_checkout_session(setting, ticket_item.provider_ref)
        if existing&.status == "open"
          checkout = existing
          next
        end
      end

      session = StripeGateway.create_checkout_session(setting, ticket_item)
      # Keep the reservation alive at least as long as the session Stripe
      # will happily accept payment on, plus sweeper slack.
      ticket_item.update!(provider_ref: session.id, reserved_until: Time.zone.at(session.expires_at) + 2.minutes)
      checkout = session
    end
    return render_error("ticket_item is not pending") if stale

    render json: { result: "ok", checkout_url: checkout.url, session_id: checkout.id }
  rescue Stripe::StripeError => e
    render_error("stripe error: #{e.message}")
  end

  # POST /api/v1/tickets/wechat_prepay  {ticket_item_id}
  #
  # Places the JSAPI order and returns the parameters WeixinJSBridge needs.
  # Unlike Stripe there is no reuse-the-open-session dance: WeChat keys an
  # order by out_trade_no (our ticket_item id) and only one payment can ever
  # succeed against it, so re-placing simply supersedes the previous
  # prepay_id. The row lock is still needed for the writes below and to
  # re-check the status that the pre-lock check may have read stale.
  def wechat_prepay
    return render_not_found unless wechat_pay_enabled?

    ticket_item = TicketItem.find_by(id: params[:ticket_item_id])
    return render_error("ticket_item not found") unless ticket_item
    return render_error("not authorized", status: :forbidden) unless ticket_item.user_id == current_user.id
    return render_error("ticket_item is not for wechat") unless ticket_item.payment_provider == "wechat"
    return render_error("ticket_item is not pending") unless ticket_item.status == "pending"
    return unless approved_for_payment?(ticket_item)

    setting = WechatPaySetting.find_by(id: ticket_item.wechat_pay_setting_id)
    return render_error("wechat pay is not configured for this ticket") unless setting&.status == "active"

    # JSAPI cannot place an order without the payer's openid, and it must be
    # one issued by THIS merchant's appid. Buyers who signed in by email have
    # none, so answer with a code the frontend can act on — a silent
    # snsapi_base authorize — rather than a dead end.
    if current_user.wechat_openid.blank?
      return render json: { error: "wechat openid required", code: "OPENID_REQUIRED" }, status: :unprocessable_entity
    end

    prepay_id = nil
    stale = false
    ticket_item.with_lock do
      if ticket_item.status != "pending"
        stale = true
        next
      end

      prepay_id = WechatPayGateway.create_jsapi_order(setting, ticket_item, payer_openid: current_user.wechat_openid)
      # Hold the seat until just past the point WeChat will still accept
      # payment, so the sweeper is never the thing that expires a payable order.
      # A second prepay on the same order is a retry — the buyer closed the
      # sheet and came back. It changes no status, so this row is the only
      # place it is ever visible.
      ticket_item.record_activity!(
        ticket_item.provider_ref.present? ? "payment_retried" : "prepay_created",
        source: "api", actor: current_user, prepay_id: prepay_id, previous_ref: ticket_item.provider_ref
      )
      ticket_item.update!(provider_ref: prepay_id,
        reserved_until: WechatPayGateway::ORDER_TTL.from_now + 2.minutes)
    end
    return render_error("ticket_item is not pending") if stale

    render json: { result: "ok", pay_params: WechatPayGateway.pay_params(setting, prepay_id) }
  rescue WechatPayGateway::Error => e
    render_error("wechat pay error: #{e.message}")
  end

  # POST /api/v1/tickets/:ticket_item_id/refund  {amount?, reason?}
  #
  # Organizer-initiated only (decision #12). Writes a pending Refund and asks
  # the provider; the provider's own callback (or reconciliation) finalizes it
  # and applies the side effects — never synchronously, refunds fail async on
  # both rails.
  def refund
    ticket_item = TicketItem.find_by(id: params[:ticket_item_id])
    return render_error("ticket_item not found") unless ticket_item

    # The rail decides which deployment gate applies. Checked before authorize
    # so a disabled rail is indistinguishable from a missing route, which is
    # the point of gating it.
    case ticket_item.payment_provider
    when "stripe" then return render_not_found unless stripe_enabled?
    when "wechat" then return render_not_found unless wechat_pay_enabled?
    else return render_error("only card and WeChat orders can be refunded here")
    end

    authorize ticket_item, :refund?
    unless %w[succeeded partially_refunded].include?(ticket_item.status)
      return render_error("ticket_item is not refundable (status: #{ticket_item.status})")
    end
    return render_error("order has no captured payment reference") if ticket_item.txhash.blank?

    setting = refund_setting(ticket_item)
    return render_error("the collecting account is no longer available") unless setting

    # Pending refunds count against the balance too — the provider would
    # ultimately reject an over-refund, but two in-flight partials must not
    # both claim the same remainder (and full/partial labeling depends on it).
    refunded_so_far = ticket_item.refunds.where(status: %w[pending succeeded]).sum(:amount)
    remaining = ticket_item.amount.to_i - refunded_so_far
    amount = params[:amount].present? ? params[:amount].to_i : remaining
    return render_error("invalid refund amount") unless amount.positive? && amount <= remaining

    refund = ticket_item.refunds.create!(
      requested_by: current_user, amount: amount,
      currency: ticket_item.currency || (ticket_item.payment_provider == "wechat" ? "cny" : "usd"),
      full_refund: amount == remaining, reason: params[:reason].presence
    )
    ticket_item.record_activity!("refund_requested", source: "api", actor: current_user,
      reason: refund.reason, refund_id: refund.id, amount: refund.amount,
      currency: refund.currency, full_refund: refund.full_refund)
    begin
      refund.update!(provider_ref: send_refund(ticket_item, setting, refund))
      render json: { result: "ok", refund_id: refund.id, status: refund.status }
    rescue WechatPayGateway::Unreachable, Stripe::APIConnectionError => e
      # The refund was SENT; we just could not read the answer. Leaving the row
      # pending is the only safe state: the provider's callback settles it by
      # out_refund_no, and the reconciliation job catches it otherwise.
      #
      # Marking it failed here — which is what happened before this branch
      # existed — would be a lie in the dangerous direction. The organizer
      # sees a failure, clicks again, and a partial refund goes out twice.
      # (A full one is caught by the one-live-full-refund index; a partial one
      # is not.)
      ticket_item.record_activity!("refund_requested", source: "api", actor: current_user,
        reason: "provider response unreadable — awaiting callback", refund_id: refund.id)
      Rails.logger.warn("[refund] #{refund.id} sent but unconfirmed: #{e.message}")
      render json: { result: "ok", refund_id: refund.id, status: refund.status, awaiting_confirmation: true }
    rescue Stripe::StripeError, WechatPayGateway::Error => e
      # The provider answered and refused. Nothing moved, so this is safe to
      # record as failed — which also frees the one-live-full-refund index for
      # a retry.
      refund.update!(status: "failed", error: e.message)
      ticket_item.record_activity!("refund_failed", source: "api", actor: current_user,
        reason: e.message, refund_id: refund.id)
      render_error("refund failed: #{e.message}")
    end
  rescue ActiveRecord::RecordNotUnique
    render_error("a refund for this order is already in progress")
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
      ticket_item = TicketItem.create_with(status: "succeeded", user_id: user.id, paid_at: Time.current).find_or_create_by(
        event_id: group.group_ticket_event_id, ticket_id: ticket.id,
        selector_type: "email", selector_address: email, ticket_type: "group",
        group_id: group.id, auth_type: "invite"
      )
      if ticket_item.previously_new_record?
        ticket_item.record_activity!("ticket_granted", source: "api", actor: current_user,
          reason: "granted to #{email}")
      elsif ticket_item.status != "succeeded"
        # Was `update(status: "succeeded")` — a direct write that skipped the
        # transition table, its paid-order guard and (once this existed) the
        # audit row. It is the only place that ever bypassed transition!, so a
        # grant to an expired or cancelled order silently resurrected it: the
        # seat and coupon had already been handed back, and now two people
        # hold one unit.
        begin
          ticket_item.update!(user_id: user.id)
          ticket_item.transition!(:succeeded, source: "api", actor: current_user,
            action: "ticket_granted", reason: "granted to #{email}", paid_at: Time.current)
        rescue TicketItem::InvalidTransition
          # Terminal orders stay terminal. Granting again means issuing a new
          # order, which is a decision for whoever is granting.
          return render_error("this email already has a #{ticket_item.status} order for that ticket — it cannot be reopened")
        end
      end
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

    # Managers get the fuller shape — refunds and the timestamps their order
    # list reconstructs a history from. A buyer looking at their own orders
    # gets the plain view: the refund rows carry who requested them and why,
    # which is organizer-facing.
    if event_manager?(params[:event_id])
      return render json: TicketItemBlueprint.render(
        items.includes(:user, :ticket, refunds: :requested_by, ticketing_activities: :actor)
             .order(created_at: :desc),
        view: :order_detail
      )
    end

    render json: TicketItemBlueprint.render(items.includes(:user), view: :with_profile)
  end

  # GET /api/v1/tickets/order_summary?event_id= — organizer-only revenue
  # rollup for the orders tab. Gross is broken out per rail+currency since an
  # event can sell tickets on more than one rail; only wechat gets a fee
  # breakdown/withdrawable figure, because it's the only rail where the
  # platform (rather than the organizer's own merchant account or wallet)
  # actually holds the money — see Withdrawal.
  def order_summary
    return render_error("not authorized", status: :forbidden) unless event_manager?(params[:event_id])

    scope = TicketItem.where(event_id: params[:event_id], status: %w[succeeded partially_refunded])
    breakdown = scope.group(:payment_provider, :currency).sum(:amount)
    # Refunds netted per rail+currency so a partially-refunded WeChat order's
    # ORIGINAL charge doesn't inflate withdrawable_amount — gross_amount
    # itself stays un-netted on purpose, matching how the order list below
    # always shows an order's original amount (refund history is separate).
    refunded = Refund.joins(:ticket_item)
                      .merge(scope)
                      .where(status: "succeeded")
                      .group("ticket_items.payment_provider", "ticket_items.currency")
                      .sum(:amount)

    summary = breakdown.map do |(provider, currency), gross_amount|
      entry = { payment_provider: provider, currency: currency, gross_amount: gross_amount }
      if provider == "wechat"
        net_amount = gross_amount - refunded[[ provider, currency ]].to_i
        entry[:wechat_fee_pct] = 1
        entry[:sola_fee_pct] = 3
        entry[:withdrawable_amount] = net_amount * Withdrawal::NET_NUM / Withdrawal::NET_DEN
      end
      entry
    end

    render json: { summary: summary }
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

  # `ticket_item_id` is the direct form; the chain/product_id/item_id triple is
  # sails' vocabulary, kept because deployed clients still send it. The triple
  # cannot address a card order at all — those have no `chain` — so anything
  # that has to cancel a Stripe or WeChat order uses the direct form.
  def find_ticket_item_by_order
    return TicketItem.find_by(id: params[:ticket_item_id]) if params[:ticket_item_id].present?

    TicketItem.find_by(chain: params[:chain], event_id: params[:product_id], id: params[:item_id])
  end

  def holds_required_badge?(ticket)
    Badge.where(badge_class_id: ticket.check_badge_class_id, owner_id: current_user.id)
         .where.not(status: "burned").exists?
  end

  # Any listed group qualifies — the list is an OR, so a ticket can honour
  # several member communities at once.
  def member_of_required_group?(ticket)
    current_user.memberships.active.exists?(group_id: ticket.check_group_ids)
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
    # A redemption otherwise leaves only a counter, which a refund decrements
    # back — so afterwards there is no way to say WHICH orders used a coupon,
    # or that a given order used one at all once it has been refunded.
    ticket_item.record_activity!("coupon_redeemed", source: "api", actor: current_user,
      coupon_id: coupon.id, code: coupon.code,
      discount_value: ticket_item.discount_value)
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
    case ticket_item.chain
    when "stripe"
      return true if stripe_payment_confirmed?(ticket_item)
      render_error("stripe payment not confirmed")
      return false
    when "wechat"
      # Without this branch a WeChat order falls through to the crypto path
      # below and is asked for a txhash it will never have.
      return true if wechat_payment_confirmed?(ticket_item)
      render_error("wechat payment not confirmed")
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

  # Confirms a Stripe PaymentIntent server-side (the item stores the intent id
  # in txhash), using the key snapshotted on the order — items with no
  # snapshot (pre-stripe_settings legacy) can never confirm this way. Any
  # Stripe/API error is treated as "not confirmed".
  def stripe_payment_confirmed?(ticket_item)
    return false if ticket_item.txhash.blank?

    setting = StripeSetting.find_by(id: ticket_item.stripe_setting_id)
    return false unless setting

    intent = Stripe::PaymentIntent.retrieve(ticket_item.txhash, { api_key: setting.secret_key })
    intent.status == "succeeded" && intent.amount.to_i >= ticket_item.amount.to_i
  rescue Stripe::StripeError
    false
  end

  # Always the account SNAPSHOTTED on the order, never the one currently
  # configured: a rotated key or a re-installed merchant must not silently
  # redirect a refund to somewhere the money never went (§2.1).
  def refund_setting(ticket_item)
    if ticket_item.payment_provider == "wechat"
      WechatPaySetting.find_by(id: ticket_item.wechat_pay_setting_id)
    else
      StripeSetting.find_by(id: ticket_item.stripe_setting_id)
    end
  end

  # Returns the provider's own refund reference.
  def send_refund(ticket_item, setting, refund)
    if ticket_item.payment_provider == "wechat"
      # out_refund_no is refund.id, so WeChat's own dedupe on it plays the
      # role Stripe's idempotency_key does.
      WechatPayGateway.create_refund(setting, ticket_item, refund)["refund_id"]
    else
      StripeGateway.create_refund(
        setting, payment_intent: ticket_item.txhash, amount: refund.amount,
        idempotency_key: "refund-#{refund.id}"
      ).id
    end
  end

  # Asks WeChat directly, keyed by our own order id. A nil answer means the
  # merchant API could not be reached, which is not evidence of payment.
  def wechat_payment_confirmed?(ticket_item)
    setting = WechatPaySetting.find_by(id: ticket_item.wechat_pay_setting_id)
    return false unless setting

    order = WechatPayGateway.query_order(setting, ticket_item.id)
    return false unless order

    order["trade_state"] == "SUCCESS" && order.dig("amount", "total").to_i >= ticket_item.amount.to_i
  end

  # rsvp puts a participant into "pending" until a manager approves them
  # (event.require_approval / form_id / ticket.need_approval), but that used
  # to only affect seat counting — the TicketItem it built was payable right
  # away, so a buyer could pay via any rail before ever being approved. This
  # is the shared gate the three payment endpoints (checkout_session,
  # wechat_prepay, verify_payment) all call before moving money.
  def approved_for_payment?(ticket_item)
    return true unless ticket_item.participant&.status == "pending"

    render_error("registration is awaiting approval — payment is not available until then")
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
    # The fiat rail this order is priced on, or nil for crypto. It decides the
    # provider, the currency and which collecting account gets snapshotted, so
    # all three stay consistent by construction instead of by three separate
    # `== "stripe"` tests that a new rail could each be added to separately.
    rail = Ticketing::Quote.fiat_rail(paymethod, quote.chain)

    TicketItem.new(
      status: status, ticket_type: @ticket.ticket_type, user: current_user, ticket: @ticket, event: @event,
      chain: quote.chain, protocol: paymethod.protocol, participant: participant, amount: quote.amount,
      original_price: paymethod.price, payment_method_id: paymethod.id,
      discount_value: quote.discount_value, discount_data: quote.discount_data,
      # Record the coupon on the item; usage is consumed only once the item
      # actually persists (see consume_coupon!), never on an aborted request.
      coupon_id: quote.discount_value ? quote.coupon&.id : nil,
      payment_provider: rail || "evm",
      # Snapshot the currency as charged. Re-deriving it later from the rail
      # would rewrite the history of any order taken before a rail's default
      # changed — and refunds must be issued in the currency that was paid.
      currency: rail ? paymethod.currency : nil,
      # Snapshot the collecting account: refunds/verification use the account
      # that took the money, never "current event owner" (§2.1). One of these
      # per rail — neither is set for a crypto order.
      stripe_setting_id: rail == "stripe" ? paymethod.stripe_setting_id : nil,
      wechat_pay_setting_id: rail == "wechat" ? paymethod.wechat_pay_setting_id : nil,
      paid_at: status == "succeeded" ? Time.current : nil,
      reserved_until: status == "pending" ? RESERVATION_TTL.from_now : nil
    )
  end

  # Money always lands in the event owner's account (decision #5): whoever is
  # editing — owner, co-host, group manager — a stripe payment method may only
  # reference one of the EVENT OWNER's keys. Without this, any editor could
  # silently point ticket revenue at their own Stripe account.
  def stripe_setting_rejected?(event)
    ids = Array(ticket_params[:payment_methods_attributes]).filter_map { |pm| pm[:stripe_setting_id].presence }
    return false if ids.empty?

    owned = StripeSetting.where(id: ids.uniq, user_id: event.owner_id).pluck(:id)
    if (ids.uniq - owned).any?
      render_error("stripe key must belong to the event owner")
      return true
    end
    false
  end

  # WeChat's single-merchant model pools every organizer's revenue into the
  # platform's own account (Withdrawal), and that pool is now shared at the
  # GROUP level across all its managers — so a WeChat-paid ticket may only be
  # set up by someone who is themselves accountable for that pool, and by an
  # event whose owner is too. A plain member who can merely publish events
  # (can_publish_event) could otherwise create a paid WeChat event nobody
  # but the group's managers can ever withdraw for — or worse, one whose
  # revenue nobody who touched it is authorized to see settled.
  def wechat_organizer_rejected?(event)
    return false unless Array(ticket_params[:payment_methods_attributes]).any? { |pm| pm[:chain] == "wechat" }

    group_role = ->(user_id) { event.group.memberships.exists?(user_id: user_id, role: %w[manager owner]) }

    unless group_role.call(current_user.id)
      render_error("only a group manager or owner may set up a WeChat-paid ticket")
      return true
    end
    unless event.owner_id.present? && group_role.call(event.owner_id)
      render_error("the event owner must be a group manager or owner for a WeChat-paid ticket")
      return true
    end
    false
  end

  def ticket_params
    params.require(:ticket).permit(:title, :content, :check_badge_class_id, :quantity, :end_time,
      :need_approval, :status, :ticket_type, :group_id, :start_date, :end_date, :membership_duration_days,
      days_allowed: [], tracks_allowed: [], check_group_ids: [],
      payment_methods_attributes: [:id, :chain, :kind, :token_name, :token_address, :receiver_address, :price, :protocol, :currency, :stripe_setting_id, :_destroy, chains: []])
  end

  def coupon_params
    params.require(:coupons).map do |c|
      c.permit(:id, :selector_type, :label, :code, :receiver_address, :discount_type, :discount,
        :expires_at, :max_allowed_usages, :order_usage_count, :_destroy,
        applicable_ticket_ids: [], ticket_item_ids: [])
    end
  end
end
