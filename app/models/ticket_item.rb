class TicketItem < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :ticket
  belongs_to :event, optional: true
  belongs_to :participant, optional: true
  belongs_to :payment_method, optional: true
  belongs_to :group, optional: true
  belongs_to :coupon, optional: true

  has_many :refunds, dependent: :destroy
  # dependent: nil — an order's history outlives the order. Cascading the
  # delete would erase exactly the record a chargeback needs.
  has_many :ticketing_activities, as: :subject, class_name: "Ticketing::Activity", dependent: nil

  class InvalidTransition < StandardError; end

  # The order state machine (design/PAYMENTS_PLAN.md §3.6). Wire names are
  # kept from the legacy vocabulary — pending == awaiting_payment,
  # succeeded == paid, timeout == expired — because the deployed frontend
  # matches on these strings. "unbounded" (sails' unclaimed email-grant
  # state) was removed 2026-07-30; that flow lives in GroupInvite now.
  #
  #   pending ──(payment verified)──► succeeded ──► refunded | partially_refunded | disputed
  #      └──(user cancel | sweeper)──► cancelled | timeout
  #   disputed ──(dispute won)──► succeeded, (lost/conceded)──► refunded
  TRANSITIONS = {
    "pending"             => %w[succeeded cancelled timeout],
    # succeeded → cancelled is allowed only for a FREE order (nothing to
    # refund), so a comped/free RSVP can be withdrawn. A paid order must go
    # through the refund flow; #transition! enforces that below, not just the
    # controller.
    "succeeded"           => %w[refunded partially_refunded disputed cancelled],
    "partially_refunded"  => %w[refunded partially_refunded disputed],
    "disputed"            => %w[succeeded refunded],
    "cancelled"           => [],
    "timeout"             => [],
    "refunded"            => []
  }.freeze

  validates :status, inclusion: { in: TRANSITIONS.keys }
  validates :ticket_type, inclusion: { in: %w(event group membership_card) }

  enum :auth_type, { free: "free", payment: "payment", badge: "badge", invite: "invite" }

  # Every status change funnels through here so the allowed-transition table
  # is actually enforced — nothing else may write `status`.
  #
  # It is also where the audit row is written, for the same reason: this is
  # the one place a status change is guaranteed to pass through, so recording
  # here cannot be forgotten at a call site.
  # `metadata:` is a separate kwarg rather than part of **attrs on purpose:
  # everything in attrs is written as a column, so a stray audit field there
  # raises UnknownAttributeError from inside a payment.
  def transition!(to, source: "system", actor: nil, reason: nil, action: nil, metadata: {}, **attrs)
    to = to.to_s
    from = status
    unless TRANSITIONS.fetch(status, []).include?(to)
      raise InvalidTransition, "ticket_item #{id}: #{status} → #{to}"
    end
    if status == "succeeded" && to == "cancelled" && amount.to_i.positive?
      raise InvalidTransition, "ticket_item #{id} was paid — refund it instead of cancelling"
    end
    update!(attrs.merge(status: to))

    Ticketing::Activity.record!(
      self, action || Ticketing::Activity.action_for_transition(from, to),
      source: source, from: from, to: to, actor: actor, reason: reason,
      **{ provider: payment_provider, amount: amount, currency: currency }.merge(metadata)
    )
  end

  # Non-transition events worth remembering: a retry, a rejected callback, a
  # prepay re-issued. None of them change status, which is exactly why the
  # status column can never explain them.
  def record_activity!(action, source:, actor: nil, reason: nil, **metadata)
    Ticketing::Activity.record!(self, action, source: source, actor: actor, reason: reason, **metadata)
  end

  # Only meaningful for group tickets: checks whether this ticket's date/track
  # restrictions grant access to a specific event within the group.
  def check_permission(event)
    return false unless ticket_type == "group"

    tz = event.group.timezone.presence || "UTC"
    event_period = (event.start_time.in_time_zone(tz).to_date..event.end_time.in_time_zone(tz).to_date)

    if ticket.start_date.present?
      return false unless (ticket.start_date..ticket.end_date).overlaps?(event_period)
    elsif ticket.days_allowed.present?
      return false unless ticket.days_allowed.any? { |day| event_period.include?(day) }
    end

    # todo : use track_id
    if ticket.tracks_allowed.present?
      return false unless ticket.tracks_allowed.intersect?(event.tags)
    end

    true
  end

  def cancel(source: "api", actor: nil)
    close!("cancelled", source: source, actor: actor)
  end

  def timeout(source: "sweeper")
    close!("timeout", source: source)
  end

  # Confirms payment on every rail (crypto verify_payment, webhook
  # set_payment_status, and stripe_callback all funnel through here) so the
  # succeed-side effects can't drift between paths. Verification of the payment
  # itself happens in the controller before this is called.
  def confirm_payment!(txhash: nil, sender_address: nil, source: "system", actor: nil)
    attrs = { paid_at: Time.current }
    attrs[:txhash] = txhash if txhash.present?
    attrs[:sender_address] = sender_address if sender_address.present?

    newly_paid = participant && participant.payment_status != "succeeded"
    # membership_card's grant EXTENDS on every call — unlike the "group"
    # branch below, it has no exists?-based idempotency to fall back on — so
    # it must only run on the transition that actually pays this order, not
    # on a repeat webhook/callback for an order that was already succeeded
    # (Stripe and friends deliver webhooks at-least-once; this method is
    # explicitly written to tolerate repeat calls, see newly_paid above).
    first_confirmation = status != "succeeded"
    transaction do
      if status == "succeeded"
        # Already-paid items (free path creates them succeeded directly, and
        # this also runs for the confirm side effects) just take the attrs.
        update!(attrs)
      else
        transition!(:succeeded, source: source, actor: actor, **attrs)
      end
      if ticket_type == "group" && group && !group.memberships.active.exists?(user_id: user_id)
        group.add_member(user_id, "member")
      elsif ticket_type == "membership_card" && group && first_confirmation
        group.grant_or_extend_membership(user_id, ticket.membership_duration_days.days)
      end
      participant.refresh_payment_status! if participant
    end
    # Only on the first confirmation — a repeat webhook/callback for an
    # already-succeeded purchase shouldn't re-email the buyer.
    EventMailer.ticket_purchased(participant_id: participant.id).deliver_later if newly_paid
    notify_group_owner
  end

  def notify_group_owner
    return unless ticket_type == "group" && group.present? && status == "succeeded"

    group_owner = group.users.joins(:memberships).where(memberships: { role: "owner" }).first
    return unless group_owner&.email.present?

    GroupMailer.ticket_purchased(ticket_item_id: id, recipient: group_owner.email).deliver_later
  end

  private

  # Shared teardown for cancel/timeout: releases the reserved ticket unit and
  # refunds the coupon usage consumed at RSVP. The seat is NOT given back here
  # — that follows the participant's status, in Participant#sync_event_seat!.
  def close!(new_status, source: "system", actor: nil)
    transaction do
      closing_participant = participant
      transition!(new_status, source: source, actor: actor, participant_id: nil)
      release_resources!
      # Withdraw the person only when this was their LAST live order. They may
      # hold several for one event (a second ticket type, a re-purchase after
      # an abandoned checkout); cancelling one used to flip the participant to
      # cancelled outright, dropping an attendance they had already paid for.
      settle_participant!(closing_participant)
    end
  end

  # Keeps the participant's summary in step with its orders, and withdraws
  # them only if nothing live is left. Public because a lost dispute has the
  # same outcome as a full refund and settles from the webhook.
  public def settle_participant!(target = participant)
    return unless target

    live = TicketItem.where(participant_id: target.id, status: %w[pending succeeded partially_refunded disputed])
                     .where.not(id: id)
    if live.none? && !target.cancelled?
      target.transition!(:cancelled)
    else
      target.refresh_payment_status!
    end
  end

  # Finalizes a refund that Stripe has confirmed (webhook, sweeper, or
  # reconciliation) and applies the decision-#10 side effects: a full refund
  # releases the seat/coupon/count, cancels the participant, and revokes a
  # group-ticket auto-join membership; a partial refund moves money only.
  public def apply_refund_success!(refund, source: "webhook")
    transaction do
      refund.update!(status: "succeeded")
      if refund.full_refund
        holder = participant
        transition!(:refunded, source: source, reason: refund.reason, metadata: { refund_id: refund.id })
        release_resources!
        settle_participant!(holder)
        revoke_purchase_membership!
      else
        transition!(:partially_refunded, source: source, reason: refund.reason, metadata: { refund_id: refund.id })
      end
    end
  end

  # Only the plain membership the purchase auto-join created — never an
  # owner/manager role the user holds for other reasons.
  public def revoke_purchase_membership!
    return unless ticket_type == "group" && group

    group.memberships.find_by(user_id: user_id, role: "member")&.destroy
  end

  # Inventory is handed back exactly once per order, guarded by released_at —
  # never inferred from status. A second close/expire/refund path arriving
  # later becomes a no-op instead of double-crediting quantity or the coupon.
  # Public: the sweeper and the refund finalizer call it directly.
  #
  # Order-scoped only: the ticket unit and the coupon usage belong to THIS
  # order. The event's seat does not — one person can hold several orders, and
  # an order can exist for someone who was never seated, so decrementing here
  # took a seat away that this order never occupied. That now lives on the
  # participant (Participant#sync_event_seat!).
  public def release_resources!
    return if released_at

    transaction do
      update!(released_at: Time.current)
      coupon&.decrement!(:order_usage_count) if coupon && coupon.order_usage_count.to_i > 0
    end
    ticket.release!
    Ticketing::Activity.record!(self, "inventory_released", source: "system",
      coupon_id: coupon_id, ticket_id: ticket_id)
  end
end
