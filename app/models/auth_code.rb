class AuthCode < ApplicationRecord
  EXPIRY = 15.minutes
  MAX_ATTEMPTS = 5

  validates :code, presence: true
  validates :recipient, :recipient_type, :context, presence: true

  scope :active, -> { where(used_at: nil).where("created_at > ?", EXPIRY.ago) }
  scope :for_recipient, ->(recipient) { where(recipient: recipient) }
  scope :for_context, ->(context) { where(context: context) }

  def expired?
    created_at <= EXPIRY.ago
  end

  def used?
    used_at.present?
  end

  def mark_used!
    update!(used_at: Time.current)
  end

  # Records a wrong-code guess; burns the code once too many have been tried so a
  # single code can't be brute-forced across its 15-minute lifetime.
  def register_failed_attempt!
    increment!(:attempts)
    mark_used! if attempts >= MAX_ATTEMPTS
  end
end
