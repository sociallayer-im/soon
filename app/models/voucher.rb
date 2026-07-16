class Voucher < ApplicationRecord
  belongs_to :sender, class_name: "User"
  belongs_to :receiver, class_name: "User", optional: true
  belongs_to :badge_class
  has_many :badges, dependent: :nullify

  validates :strategy, inclusion: { in: %w(code account address email event remember) }
  validates :counter, numericality: { greater_than_or_equal_to: 0 }

  def invalid?
    counter == 0 || (expires_at.present? && expires_at < Time.current)
  end

  # Builds (does not save) the Badge this voucher grants to `user`, applying the
  # voucher's per-badge overrides on top of the badge_class defaults. This keeps
  # the override precedence in one place instead of inline in the controller.
  # Caller is responsible for allocating `index` (needs the badge_class lock).
  def build_badge_for(user)
    badge = badges.build(
      content: badge_content.presence || message.presence || badge_class.content,
      status: "minted",
      badge_class: badge_class,
      creator_id: sender_id,
      owner_id: user.id,
      title: badge_title.presence || badge_class.title,
      image_url: badge_image.presence || badge_class.image_url
    )
    if data.present?
      badge.value = data["value"] if data["value"]
      badge.start_time = data["start_time"] if data["start_time"]
      badge.end_time = data["end_time"] if data["end_time"]
    end
    badge
  end
end
