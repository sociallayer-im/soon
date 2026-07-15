class GroupInvite < ApplicationRecord
  belongs_to :sender, class_name: "User", optional: true
  belongs_to :receiver, class_name: "User", optional: true
  belongs_to :group
  belongs_to :badge_class, optional: true
  belongs_to :badge, optional: true
  belongs_to :ticket, optional: true

  validates :role, inclusion: { in: %w(member manager owner) }

  enum :status, { sending: "sending", requesting: "requesting", accepted: "accepted", cancelled: "cancelled", revoked: "revoked" }

  scope :pending_for_email, ->(email) { where(status: "sending", receiver_address_type: "email", receiver_address: email).where("expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end
end
