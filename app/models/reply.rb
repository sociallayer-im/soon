# One floor in a topic. Flat and time-ordered; `reply_to_id` is a weak pointer
# used to render "in reply to @someone", never a tree.
class Reply < ApplicationRecord
  include SoftDelete
  include Flaggable
  include Starrable

  MAX_CONTENT = 64.kilobytes

  belongs_to :topic
  belongs_to :user
  belongs_to :reply_to, class_name: "Reply", optional: true
  has_many :replies_to_this, class_name: "Reply", foreign_key: :reply_to_id,
    dependent: :nullify, inverse_of: :reply_to

  validates :content, presence: true, length: { maximum: MAX_CONTENT }

  # A reply_to pointing into a different topic can only come from a forged
  # request body. Blanking it silently is better than refusing the whole
  # reply: it has no bearing on what the person actually wrote.
  before_validation :drop_foreign_reply_to

  validate :topic_must_be_open, on: :create

  after_commit :refresh_topic!, on: %i[create destroy]

  scope :alive, -> { not_flagged }
  scope :chronological, -> { order(created_at: :asc, id: :asc) }

  # What `user` may see. Soft-deleted rows are already gone via the
  # default_scope, so this only has to answer for flagging.
  def self.visible_to(user, manager: false)
    return all if manager
    return not_flagged if user.nil?

    not_flagged.or(where(user_id: user.id))
  end

  def after_flag_change! = refresh_topic!

  private

  def refresh_topic!
    topic&.refresh_last_reply!
  end

  def drop_foreign_reply_to
    self.reply_to_id = nil if reply_to_id.present? && reply_to&.topic_id != topic_id
  end

  def topic_must_be_open
    errors.add(:topic, "is closed") if topic&.closed?
  end
end
