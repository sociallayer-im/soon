class PollOption < ApplicationRecord
  belongs_to :poll, inverse_of: :poll_options
  has_many :poll_votes, foreign_key: :option_id, dependent: :destroy

  validates :title, presence: true, length: { maximum: 200 }
end
