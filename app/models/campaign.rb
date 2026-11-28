class Campaign < ApplicationRecord
  surf_visible_by

  include SiteNotifiable
  has_many :campaign_review_logs, dependent: :destroy
  validates :review_status, inclusion: {in: %w[pending approved rejected]}
  scope :publicly_visible, -> { where(status: "published", review_status: "approved", group_id: Group.where(active: true, review_status: "approved").select(:id)) }

  def public_submission_errors
    errors = []
    errors << "专题介绍不能为空" if introduction.blank?
    errors << "专题至少需要关联一个公开活动" unless events.exists?
    errors << "所属群组尚未通过审核或已停用" unless group.active? && group.review_status == "approved"
    errors << "专题只能收录已发布的公开活动" if events.where.not(status: "published").exists? || events.where.not(visibility: %w[normal open_registration]).exists?
    errors
  end
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
