class Campaign < ApplicationRecord
  belongs_to :group
  belongs_to :owner, class_name: "User"
  has_many :campaign_events, -> { order(:position, :id) }, dependent: :destroy
  has_many :events, through: :campaign_events

  validates :title, presence: true, length: { maximum: 200 }
  validates :status, inclusion: { in: %w[draft published archived] }
  validates :introduction, presence: true, if: -> { status == "published" }
  validate :valid_media_and_links

  private

  def valid_media_and_links
    unless media.is_a?(Array) && media.size <= 12 && media.all? { |m| m.is_a?(Hash) && m["type"] == "image" && http_url?(m["url"]) }
      errors.add(:media, "must contain at most 12 HTTP(S) images")
    end
    errors.add(:cover_url, "must be an HTTP(S) URL") if cover_url.present? && !http_url?(cover_url)
    unless resource_links.is_a?(Array) && resource_links.size <= 50 && resource_links.all? { |url| http_url?(url) }
      errors.add(:resource_links, "must contain at most 50 HTTP(S) URLs")
    end
  end

  def http_url?(value)
    uri = URI.parse(value.to_s)
    %w[http https].include?(uri.scheme) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end
end
