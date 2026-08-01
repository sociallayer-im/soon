# Cached remote federation actor (design/FEDERATION_PLAN.md §2.5).
class FedActor < ApplicationRecord
  STALE_AFTER = 1.day # Mastodon's webfinger staleness threshold

  has_many :fed_follows, dependent: :destroy

  validates :uri, presence: true, uniqueness: true
  validates :domain, presence: true
  validates :inbox_url, presence: true

  scope :blocked, -> { where.not(blocked_at: nil) }

  def blocked? = blocked_at.present?
  def stale? = last_fetched_at.nil? || last_fetched_at < STALE_AFTER.ago

  # Delivery goes to the shared inbox when the actor advertises one.
  def delivery_inbox_url = shared_inbox_url.presence || inbox_url

  def acct
    "#{preferred_username}@#{domain}"
  end
end
