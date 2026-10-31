class RefundRequest < ApplicationRecord
  include SiteNotifiable
  belongs_to :ticket_item
  belongs_to :user
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :refund, optional: true
  validates :status, inclusion: {in: %w[requested processing succeeded failed rejected]}
  validates :reason, :review_reason, length: {maximum: 1000}
  scope :open, -> {where(status: %w[requested processing])}

  def self.required_before_exit?(participant)
    event = participant.event
    event.start_time && event.start_time > Time.current && TicketItem.where(participant_id: participant.id, status: %w[succeeded partially_refunded], payment_provider: %w[wechat stripe]).where("amount > 0").where.not(txhash: [nil, ""]).exists?
  end

  def self.eligible?(item, user)
    user && item.user_id == user.id && item.event && item.event.start_time && item.event.start_time > Time.current &&
      item.amount.to_i.positive? && item.txhash.present? && %w[succeeded partially_refunded].include?(item.status) &&
      %w[wechat stripe].include?(item.payment_provider) && !item.refunds.any? { |refund| refund.status == "pending" } &&
      item.amount.to_i > item.refunds.select { |refund| refund.status == "succeeded" }.sum(&:amount)
  end
end
