class AuthCode < ApplicationRecord
  EXPIRY = 15.minutes

  validates :code, presence: true
  validates :recipient, :recipient_type, :context, presence: true

  scope :active, -> { where(used_at: nil).where("created_at > ?", EXPIRY.ago) }
  scope :for_recipient, ->(recipient) { where(recipient: recipient) }

  def expired?
    created_at <= EXPIRY.ago
  end

  def used?
    used_at.present?
  end

  def mark_used!
    update!(used_at: Time.current)
  end
end
