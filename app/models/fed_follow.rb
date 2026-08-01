# A follow edge between a local actor (User/Group) and a remote actor.
# direction "inbound" = remote follows local; "outbound" = local follows
# remote. `uri` is the Follow activity id — Accept and Undo match on it.
class FedFollow < ApplicationRecord
  DIRECTIONS = %w[inbound outbound].freeze
  STATES = %w[pending accepted rejected].freeze

  belongs_to :fed_actor
  belongs_to :local, polymorphic: true

  validates :direction, inclusion: {in: DIRECTIONS}
  validates :state, inclusion: {in: STATES}
  validates :uri, presence: true, uniqueness: true

  scope :accepted, -> { where(state: "accepted") }
  scope :inbound, -> { where(direction: "inbound") }
  scope :outbound, -> { where(direction: "outbound") }
end
