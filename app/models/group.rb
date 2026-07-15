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

  validates :name, presence: true

  def add_member(user_id, role)
    membership = memberships.find_by(user_id: user_id)
    if membership
      membership.update(role: role)
    else
      membership = memberships.create(user_id: user_id, role: role, active: true)
      increment!(:memberships_count)
    end
    membership
  end
end
