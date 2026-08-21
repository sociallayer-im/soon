# One request to settle a GROUP's WeChat Pay revenue out of the platform's
# merchant account (see WechatPaySetting — single-merchant mode means the
# money is sitting there, not in an account any organizer controls). There
# is no transfer API behind this: an operator pays the bank details by hand
# and flips `status`, so `amount` is a snapshot taken at request time, not a
# live balance.
#
# Balance is tracked per GROUP, not per requesting user — a group can have
# several managers, and any of them may request the group's withdrawal
# (TicketsController#wechat_organizer_rejected? requires both the actor and
# the event owner to be a manager/owner before a WeChat-paid ticket can even
# be created, so everyone who could touch this money already has to qualify
# for that role). `user_id` still records who made each individual request,
# for the audit trail — it is never part of the balance calculation.
class Withdrawal < ApplicationRecord
  belongs_to :user
  belongs_to :group
  belongs_to :processed_by, class_name: "User", optional: true

  STATUSES = %w(pending completed rejected).freeze
  validates :status, inclusion: { in: STATUSES }
  validates :amount, numericality: { only_integer: true, greater_than: 0 }
  validates :bank_name, :bank_account_number, :bank_account_name, presence: true

  # WeChat takes 1%, sola takes 3% of NET revenue (gross minus whatever was
  # refunded back to the buyer) — see WECHAT_MERCHANT_MATERIALS.md. Kept as
  # integer numerator/denominator, not a Float, because Float can't represent
  # 0.96 exactly and this decides how much money changes hands.
  NET_NUM = 96
  NET_DEN = 100

  # Groups this user organizes (owner/manager) — the groups whose WeChat
  # balance they may view/withdraw. Parent-group managers are deliberately
  # not expanded to child groups here (unlike GroupPolicy#manage? elsewhere)
  # — each group's own manager withdraws its own events' revenue. Revisit if
  # that turns out to be the wrong call for popup-city-style hierarchies.
  def self.manageable_groups(user)
    Group.where(id: Membership.where(user_id: user.id, role: %w[owner manager]).select(:group_id))
  end

  def self.may_manage?(user, group)
    Membership.exists?(user_id: user.id, group_id: group.id, role: %w[owner manager])
  end

  # WeChat orders under this group. Left-joined to event (not inner) and
  # matched on either the order's own group_id (set today for ticket_type
  # == "group" rows) or its event's group_id (the common, ticket_type ==
  # "event" case) — an inner join alone would silently drop any order whose
  # event_id happens to be null.
  def self.wechat_ticket_items(group, currency: "cny")
    TicketItem.left_outer_joins(:event)
              .where(payment_provider: "wechat", status: %w[succeeded partially_refunded], currency: currency)
              .where("ticket_items.group_id = :gid OR events.group_id = :gid", gid: group.id)
  end

  # Gross charges minus whatever has actually been refunded back to the buyer
  # on those same orders. A partially_refunded order's `amount` column still
  # holds the ORIGINAL charge — without netting the refund out, withdrawable
  # balance would include money the platform already paid back and no longer
  # holds.
  def self.wechat_net_amount(group, currency: "cny")
    items = wechat_ticket_items(group, currency: currency)
    gross = items.sum(:amount)
    refunded = Refund.where(ticket_item_id: items.select(:id), status: "succeeded").sum(:amount)
    gross - refunded
  end

  def self.withdrawn_amount(group, currency: "cny")
    where(group: group, currency: currency, status: %w[pending completed]).sum(:amount)
  end

  # What's actually been settled and paid out, for the "cumulative
  # withdrawn" figure on the withdrawals page — pending requests aren't
  # money that has moved yet, so they don't belong in this total.
  def self.total_withdrawn(group, currency: "cny")
    where(group: group, currency: currency, status: "completed").sum(:amount)
  end

  # What's left to withdraw right now: 96% of net WeChat revenue, minus
  # whatever has already been requested by ANY manager of this group
  # (pending counts too, so a second request — by the same or a different
  # manager — can't double-claim the same money while the first is still
  # awaiting settlement) or paid out.
  #
  # Callers that go on to CREATE a withdrawal from this number must call it
  # inside a `group.with_lock` block (see WithdrawalsController#create) —
  # read here, then insert elsewhere, races two managers' concurrent
  # requests onto the same balance exactly as a single user's two tabs would.
  def self.available_balance(group, currency: "cny")
    net_total = wechat_net_amount(group, currency: currency) * NET_NUM / NET_DEN
    [ net_total - withdrawn_amount(group, currency: currency), 0 ].max
  end
end
