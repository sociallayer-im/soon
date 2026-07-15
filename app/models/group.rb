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

  validates :name, presence: true
end
