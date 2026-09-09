class Group < ApplicationRecord
  belongs_to :parent, class_name: "Group", optional: true
  has_many :children, class_name: "Group", foreign_key: :parent_id, dependent: :nullify

  has_many :memberships, dependent: :delete_all
  has_many :users, through: :memberships
  has_many :events, dependent: :destroy, inverse_of: :group
  has_many :withdrawals, dependent: :destroy
  has_many :markers, dependent: :destroy
  has_many :tracks, dependent: :destroy
  # Discussion boards. restrict_with_error rather than destroy: deleting a
  # group with live discussion should be a deliberate act, not a side effect.
  has_many :teams, dependent: :destroy
  has_many :categories, dependent: :restrict_with_error
  has_many :topics, dependent: :restrict_with_error
  has_many :polls, dependent: :restrict_with_error
  has_many :hackathons, dependent: :restrict_with_error
  has_many :venues, dependent: :destroy
  # Removing a venue is a soft delete (VenuesController#destroy sets archived),
  # so `venues` still contains removed rows — it exists for dependent: :destroy
  # and for lookups by id. Everything that LISTS a group's venues (the venues
  # page, the event editor's venue picker, the schedule venue view — all of
  # which read GroupBlueprint :detail) must go through this instead, or a
  # removed venue keeps showing up.
  has_many :active_venues, -> { where(archived: false) },
    class_name: "Venue", inverse_of: :group
  has_many :domains, as: :item, dependent: :destroy
  has_many :group_invites, dependent: :destroy
  # The single event whose tickets grant membership in this group; its tickets
  # become ticket_type "group" (Ticket#inherit_group_ticket_type) and
  # add_group_ticket_item / GroupInvite hang their grants off it.
  belongs_to :group_ticket_event, class_name: "Event", optional: true
  has_many :badge_classes, dependent: :destroy
  has_many :tickets, dependent: :nullify

  # An app registered under a group. Nullified rather than destroyed when the
  # group goes away: it still has a real user as `owner`, and deleting a
  # community should not silently break a live third-party integration. Without
  # any `dependent:` this FK would simply block the group's deletion.
  has_many :oauth_applications, dependent: :nullify

  # `name` is the group's unique slug (the handle concept) — it appears in URLs
  # (/group/<name>) so it must be well-formed and unique. Same shape as a user
  # name; see HandleName, which is also where the guard that keeps the six
  # existing out-of-range group handles saveable lives.
  validates :name, presence: true, uniqueness: true
  include HandleName

  # Eager-loads every association GroupBlueprint's :detail view walks. Render
  # that view without this and each group costs five extra queries, plus one
  # per membership for its user — against a networked database that is round
  # trips, not milliseconds. On the homepage (21 popup cities, 2407 memberships
  # between them, one group alone with 712) it turned a ~70ms page into a
  # 9-second one. Keep in step with GroupBlueprint's :detail view.
  scope :with_detail_associations, -> {
    # memberships: { user: :teams } — the roster renders each member's team
    # badges, and without preloading the teams that is one query per member.
    includes(:parent, :children, { tracks: :group }, { active_venues: :place },
             :teams, { memberships: { user: :teams } })
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

  # Addresses of the group's owners and managers who still have the
  # admin_notification flag set — the audience for "someone submitted an event
  # to your group". Same shape and reasoning as member_emails: one definition
  # so the job that sends and anything that counts recipients can't disagree.
  def admin_notification_emails
    memberships.where(active: true, role: %w[owner manager], admin_notification: true)
               .joins(:user)
               .where.not(users: { email: [ nil, "" ] })
               .distinct.pluck(Arel.sql("users.email"))
  end

  # Raises ActiveRecord::RecordInvalid on failure (e.g. an invalid role) instead
  # of silently returning a membership whose write didn't actually persist —
  # every caller must be able to trust that a returned membership is saved.
  # memberships_count is maintained by Membership's counter_cache, not here.
  # Grants permanent membership, so it also clears any expires_at left over
  # from a prior membership_card purchase — a manager grant or a permanent
  # group-ticket purchase should not leave the row set to lapse.
  def add_member(user_id, role)
    membership = memberships.find_by(user_id: user_id)
    if membership
      membership.update!(role: role, expires_at: nil)
    else
      membership = memberships.create!(user_id: user_id, role: role, active: true)
    end
    membership
  end

  # membership_card purchase grant: stacks the new 30-day window onto whatever
  # is left of the current one rather than resetting from now, so renewing
  # early never wastes remaining time. A lapsed or first-time buyer starts
  # fresh from now.
  #
  # A manager/owner already has permanent, unrestricted access — setting an
  # expires_at on their row would downgrade it to a lapsing membership, so a
  # membership_card purchase by one is a no-op on the membership itself (the
  # order/payment still records normally).
  def grant_or_extend_membership(user_id, duration)
    membership = memberships.find_by(user_id: user_id)
    return membership if membership && membership.role != "member"

    base = [ Time.current, membership&.expires_at ].compact.max
    if membership
      membership.update!(expires_at: base + duration)
    else
      membership = memberships.create!(user_id: user_id, role: "member", active: true, expires_at: base + duration)
    end
    membership
  end
end
