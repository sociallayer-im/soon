class BadgeClass < ApplicationRecord
  belongs_to :creator, class_name: "User"
  belongs_to :group, optional: true

  has_many :badges, dependent: :destroy

  validates :name, presence: true
  validates :title, presence: true

  enum :status, { active: "active", freezed: "freezed" }
  enum :display, { normal: "normal", hidden: "hidden", pinned: "pinned" }
end
