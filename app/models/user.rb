class User < ApplicationRecord
  has_many :memberships, dependent: :delete_all
  has_many :groups, through: :memberships
  has_many :events, foreign_key: "owner_id", dependent: :destroy
  has_many :participants, dependent: :destroy
  has_many :participated_events, through: :participants, source: :event
  has_many :markers, foreign_key: "owner_id", dependent: :destroy
  has_many :venues, foreign_key: "owner_id", dependent: :destroy
  has_many :track_roles, dependent: :destroy
  has_many :tracks, through: :track_roles
  has_many :domains, as: :item, dependent: :destroy
  has_many :created_badge_classes, class_name: "BadgeClass", foreign_key: "creator_id", dependent: :destroy
  has_many :owned_badges, class_name: "Badge", foreign_key: "owner_id", dependent: :destroy
  has_many :created_badges, class_name: "Badge", foreign_key: "creator_id", dependent: :destroy

  validates :email, presence: true, uniqueness: true
  # `name` is the user's unique identifier/username (the handle concept). It must
  # be a well-formed slug and unique (the column is uniquely indexed).
  validates :name, presence: true, uniqueness: true
  validates :name, format: { with: /\A[a-z0-9_]{3,30}\z/, message: "must be 3-30 lowercase letters, digits, or underscores" },
    allow_blank: true
end
