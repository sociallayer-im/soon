class BadgeClass < ApplicationRecord
  belongs_to :creator, class_name: "User"
  belongs_to :group, optional: true

  has_many :badges, dependent: :destroy

  validates :name, presence: true
  validates :title, presence: true
  validates :can_send_badge, inclusion: { in: %w(owner group_member_send) }, allow_nil: true

  enum :display, { normal: "normal", hidden: "hidden", pinned: "pinned" }
end
