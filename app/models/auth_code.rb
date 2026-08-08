class AuthCode < ApplicationRecord
  # Emailed codes are read by a human who usually has to leave the page to
  # fetch them — inside the WeChat browser that means switching apps and coming
  # back, which routinely outlasted the old 15 minutes.
  # AuthMailer derives the "expires in N minutes" line from this.
  EXPIRY = 30.minutes
  # A SIWE nonce is redeemed by a wallet signature in the same sitting, so it
  # keeps the tighter window deliberately: it is single-use and server-minted,
  # and widening it would only enlarge the replay surface for no user benefit.
  NONCE_EXPIRY = 15.minutes
  MAX_ATTEMPTS = 5

  validates :code, presence: true
  validates :recipient, :recipient_type, :context, presence: true

  scope :active, -> { where(used_at: nil).where("created_at > ?", EXPIRY.ago) }
  scope :active_nonce, -> { where(used_at: nil).where("created_at > ?", NONCE_EXPIRY.ago) }
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
