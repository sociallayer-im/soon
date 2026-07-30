class Group < ApplicationRecord
  belongs_to :parent, class_name: "Group", optional: true
  has_many :children, class_name: "Group", foreign_key: :parent_id, dependent: :nullify

  has_many :memberships, dependent: :delete_all
  has_many :users, through: :memberships
  has_many :events, dependent: :destroy, inverse_of: :group
  has_many :markers, dependent: :destroy
  has_many :tracks, dependent: :destroy
  has_many :venues, dependent: :destroy
  has_many :domains, as: :item, dependent: :destroy
  has_many :group_invites, dependent: :destroy
  # The single event whose tickets grant membership in this group; its tickets
  # become ticket_type "group" (Ticket#inherit_group_ticket_type) and
  # add_group_ticket_item / GroupInvite hang their grants off it.
  belongs_to :group_ticket_event, class_name: "Event", optional: true
  has_many :badge_classes, dependent: :destroy
  has_many :tickets, dependent: :nullify

  # `name` is the group's unique slug (the handle concept) — it appears in URLs
  # (/group/<name>) so it must be well-formed and unique. Unlike user names,
  # group slugs also allow hyphens ("edge-city").
  validates :name, presence: true, uniqueness: true
  validates :name, format: { with: /\A[a-z0-9_-]{3,30}\z/, message: "must be 3-30 lowercase letters, digits, underscores, or hyphens" },
    allow_blank: true

  # Eager-loads every association GroupBlueprint's :detail view walks. Render
  # that view without this and each group costs five extra queries, plus one
  # per membership for its user — against a networked database that is round
  # trips, not milliseconds. On the homepage (21 popup cities, 2407 memberships
  # between them, one group alone with 712) it turned a ~70ms page into a
  # 9-second one. Keep in step with GroupBlueprint's :detail view.
  scope :with_detail_associations, -> {
    includes(:parent, :children, { tracks: :group }, { venues: :place }, { memberships: :user })
  }

  # Looks a group up by primary key OR unique slug — API paths accept either
  # (/groups/0GA2... or /groups/edge-city). Raises RecordNotFound like find.
  def self.resolve!(identifier)
    find_by(id: identifier) || find_by(name: identifier) ||
      (identifier.to_s.match?(/\A\d+\z/) ? find_by(ref_id: identifier.to_s) : nil) ||
      raise(ActiveRecord::RecordNotFound,
            "Couldn't find Group with id, name or ref_id=#{identifier.inspect}")
  end

  # Human-facing label — the friendly nickname when set, else the handle-like name.
  def display_name
    nickname.presence || name
  end

  # Cross-group event-listing federation (ported from sails' `group_union`):
  # a browse/schedule request for this group also pulls in events owned by
  # every group listed here — e.g. a popup-city cluster where partner
  # communities cross-list each other's events. Always includes self.
  def event_group_ids
    event_union.present? ? ([id] + event_union).uniq : [id]
  end

  # Cross-group venue-sharing (ported from sails' `venue_union`): an event
  # belonging to this group may book a venue owned by any group listed here,
  # not only its own. Always includes self.
  def venue_group_ids
    venue_union.present? ? ([id] + venue_union).uniq : [id]
  end

  # Distinct, deliverable addresses of the group's active members — the audience
  # for a manager broadcast. Lives here so the controller (which reports how
  # many people the broadcast will reach) and GroupBroadcastMailJob (which
  # actually sends it) can never disagree about who that is.
  def member_emails
    memberships.where(active: true).joins(:user)
               .where.not(users: { email: [ nil, "" ] })
               .distinct.pluck(Arel.sql("users.email"))
  end

  # Raises ActiveRecord::RecordInvalid on failure (e.g. an invalid role) instead
  # of silently returning a membership whose write didn't actually persist —
  # every caller must be able to trust that a returned membership is saved.
  # memberships_count is maintained by Membership's counter_cache, not here.
  def add_member(user_id, role)
    membership = memberships.find_by(user_id: user_id)
    if membership
      membership.update!(role: role)
    else
      membership = memberships.create!(user_id: user_id, role: role, active: true)
    end
    membership
  end
end
