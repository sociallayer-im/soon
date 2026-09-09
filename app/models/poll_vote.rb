# One row per (voter, option) for choice polls; one row with `value` for a
# number poll. Exclusivity for single-choice polls is enforced here, not by
# the index — see the migration.
class PollVote < ApplicationRecord
  belongs_to :poll
  belongs_to :user
  belongs_to :option, class_name: "PollOption", optional: true

  validate :shape_matches_poll_type

  private

  def shape_matches_poll_type
    return if poll.nil?

    if poll.number?
      errors.add(:option_id, "must be blank for a number poll") if option_id.present?
      if value.nil? || value < poll.min_value || value > poll.max_value
        errors.add(:value, "must be between #{poll.min_value} and #{poll.max_value}")
      end
    else
      errors.add(:value, "must be blank") if value.present?
      errors.add(:option, "must belong to this poll") if option.nil? || option.poll_id != poll_id
      if poll.single? && poll.poll_votes.where(user_id: user_id).where.not(id: id).exists?
        errors.add(:base, "single-choice poll already has a vote from this user")
      end
    end
  end
end
