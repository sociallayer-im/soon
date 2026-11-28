class CommunityProject < ApplicationRecord
  surf_visible_by

  belongs_to :group
  belongs_to :user
  has_many :members, class_name: "CommunityProjectMember", dependent: :destroy
  has_many :comments, class_name: "CommunityProjectComment", dependent: :destroy

  validates :status, inclusion: { in: %w[draft published hidden] }
  validates :title, presence: true, length: { maximum: 160 }
  validates :tagline, length: { maximum: 240 }
  validates :content, length: { maximum: 20_000 }
  validates :tagline, :content, :icon_url, :cover_url, presence: true, if: -> { status == "published" }
  validate :validate_media

  private

  def validate_media
    unless gallery.is_a?(Array) && gallery.size <= 8 && gallery.all? { |item|
      item.is_a?(Hash) && web_url?(item["url"]) && item["caption"].to_s.length <= 240
    }
      errors.add(:gallery, "must contain up to eight images with valid URLs and captions")
    end

    %i[icon_url cover_url website_url].each do |field|
      value = public_send(field)
      errors.add(field, "must be an HTTP or HTTPS URL") if value.present? && !web_url?(value)
    end
  end

  def web_url?(value)
    return false unless value.is_a?(String) && value.length <= 2048

    url = URI.parse(value)
    url.is_a?(URI::HTTP) && url.host.present? && url.userinfo.nil?
  rescue URI::InvalidURIError
    false
  end
end
