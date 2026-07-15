class Activity < ApplicationRecord
  belongs_to :item, polymorphic: true, optional: true
  belongs_to :initiator, class_name: "User"
  belongs_to :receiver, class_name: "User", optional: true

  validates :action, presence: true

  scope :for_receiver, ->(user) { where(receiver_id: user.id) }
  scope :unread, -> { where(has_read: false) }
end
