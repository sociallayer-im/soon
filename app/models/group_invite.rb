class GroupInvite < ApplicationRecord
  belongs_to :sender, class_name: "User", optional: true
  belongs_to :receiver, class_name: "User", optional: true
  belongs_to :group
  belongs_to :badge_class, optional: true
  belongs_to :badge, optional: true
  belongs_to :ticket, optional: true

  # Must match Membership's role vocabulary exactly — an invite's role is passed
  # straight through to Group#add_member on acceptance, so any value valid here
  # but not there would silently fail to grant membership.
  validates :role, inclusion: { in: %w(member admin owner) }

  enum :status, { sending: "sending", requesting: "requesting", accepted: "accepted", cancelled: "cancelled", revoked: "revoked" }

  scope :pending_for_email, ->(email) { where(status: "sending", receiver_address_type: "email", receiver_address: email).where("expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end
end
