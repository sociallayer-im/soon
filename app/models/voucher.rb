class Voucher < ApplicationRecord
  belongs_to :sender, class_name: "User"
  belongs_to :receiver, class_name: "User", optional: true
  belongs_to :badge_class
  has_many :badges, dependent: :nullify

  validates :receiver_address_type, inclusion: { in: %w(id email address) }, allow_nil: true
  validates :strategy, inclusion: { in: %w(code account address email event remember) }
  validates :counter, numericality: { greater_than_or_equal_to: 0 }

  def invalid?
    counter == 0 || (expires_at.present? && expires_at < Time.current)
  end
end
