# A remote event mirrored locally so our users can see and join it. The
# authoritative copy lives on the origin instance; this is a cache keyed by uri.
class FedEvent < ApplicationRecord
  belongs_to :fed_actor, optional: true
  has_many :fed_participations, dependent: :destroy

  validates :uri, presence: true, uniqueness: true

  scope :upcoming, -> { where("end_time IS NULL OR end_time >= ?", Time.current) }
  scope :listable, -> { where.not(status: "CANCELLED") }
  # Everything the public read surface may show: an admin block must cover
  # content mirrored BEFORE the block, not just future inbound (P1-17).
  scope :visible, -> {
    base = joins(:fed_actor).where(fed_actors: {blocked_at: nil})
    if FedDomainPolicy.mode == "allowlist"
      base.where(fed_actors: {domain: FedDomainPolicy.allowed_domains})
    else
      base.where.not(fed_actors: {domain: FedDomainPolicy.blocked_domains})
    end
  }

  def cancelled? = status == "CANCELLED"

  # Where a Join for this event has to be delivered.
  def origin_inbox_url = fed_actor&.delivery_inbox_url

  def joinable?
    !cancelled? && %w[free restricted].include?(join_mode) &&
      (end_time.nil? || end_time > Time.current)
  end
end
