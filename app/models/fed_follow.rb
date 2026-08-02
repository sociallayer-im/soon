# A follow edge between a local actor (User/Group) and a remote actor.
# direction "inbound" = remote follows local; "outbound" = local follows
# remote. `uri` is the Follow activity id — Accept and Undo match on it.
class FedFollow < ApplicationRecord
  DIRECTIONS = %w[inbound outbound].freeze
  # "lapsed": reconciliation probed the peer MAX_PROBES times without an
  # Accept — the edge is presumed gone on the remote side. A lapsed follow is
  # excluded from delivery audiences; re-following mints a fresh activity id.
  STATES = %w[pending accepted rejected lapsed].freeze

  belongs_to :fed_actor
  belongs_to :local, polymorphic: true

  validates :direction, inclusion: {in: DIRECTIONS}
  validates :state, inclusion: {in: STATES}
  validates :uri, presence: true, uniqueness: true

  scope :accepted, -> { where(state: "accepted") }
  scope :inbound, -> { where(direction: "inbound") }
  scope :outbound, -> { where(direction: "outbound") }
end
