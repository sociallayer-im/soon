class Group < ApplicationRecord
  belongs_to :parent, class_name: "Group", optional: true
  has_many :children, class_name: "Group", foreign_key: :parent_id, dependent: :nullify

  has_many :memberships, dependent: :delete_all
  has_many :users, through: :memberships
  has_many :events, dependent: :destroy
  has_many :markers, dependent: :destroy
  has_many :tracks, dependent: :destroy
  has_many :venues, dependent: :destroy
  has_many :domains, as: :item, dependent: :destroy
  has_many :group_invites, dependent: :destroy
  has_many :badge_classes, dependent: :destroy
  has_many :tickets, dependent: :nullify

  # `name` is the group's unique slug (the handle concept) — it appears in URLs
  # (/group/<name>) so it must be well-formed and unique. Unlike user names,
  # group slugs also allow hyphens ("edge-city").
  validates :name, presence: true, uniqueness: true
  validates :name, format: { with: /\A[a-z0-9_-]{3,30}\z/, message: "must be 3-30 lowercase letters, digits, underscores, or hyphens" },
    allow_blank: true

  # Looks a group up by primary key OR unique slug — API paths accept either
  # (/groups/0GA2... or /groups/edge-city). Raises RecordNotFound like find.
  def self.resolve!(identifier)
    find_by(id: identifier) || find_by!(name: identifier)
  end

  # Human-facing label — the friendly nickname when set, else the handle-like name.
  def display_name
    nickname.presence || name
  end

  # Raises ActiveRecord::RecordInvalid on failure (e.g. an invalid role) instead
  # of silently returning a membership whose write didn't actually persist —
  # every caller must be able to trust that a returned membership is saved.
  # memberships_count is maintained by Membership's counter_cache, not here.
  def add_member(user_id, role)
    membership = memberships.find_by(user_id: user_id)
    if membership
      membership.update!(role: role)
    else
      membership = memberships.create!(user_id: user_id, role: role, active: true)
    end
    membership
  end
end
