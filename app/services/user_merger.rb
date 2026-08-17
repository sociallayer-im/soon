# Moves every piece of data owned by `from` onto `into`, then destroys `from`.
# Platform-admin-only, irreversible. Unlike AuthController#merge_wechat_account!
# (which only ever merges a bare WeChat shell with no data of its own), this
# assumes `from` may own real content — memberships, events, badges, etc.
#
# Login identity columns (email/phone/eth/sol/wechat_*) are deliberately NOT
# carried over: merging identities is a distinct, narrower operation
# (AuthController#merge_wechat_account!) with its own uniqueness rules. This
# service only moves *data*; `from` keeps its identity until destroyed.
#
# NOT handled: db/schema.rb defines fed_participations.user_id with a live FK
# and a unique(user_id, fed_event_id) index, but no FedParticipation model
# exists on main (only on the federation branch(es)) — the schema was carried
# over without the model. If `from` ever has rows there, `from.destroy!` will
# raise ActiveRecord::InvalidForeignKey. Revisit once federation lands on main.
class UserMerger
  # Tables where a duplicate (from, into) row would collide with a DB-level
  # uniqueness constraint once repointed — these need per-row dedup instead of
  # a blind UPDATE. Value is the column(s), besides user_id, that make up the
  # unique key.
  DEDUPE_ASSOCIATIONS = {
    memberships: [ :group_id ],
    participants: [ :event_id ],
    track_roles: [ :track_id ],
    form_submissions: [ :form_id ],
    # Both accounts can already be in the same team, so a blind repoint would
    # hit the unique index on [team_id, user_id].
    team_memberships: [ :team_id ]
  }.freeze

  # Straight FK repoints — no uniqueness risk on these tables.
  REPOINT_OWNER_ID = %w[events markers venues].freeze

  def self.call(from:, into:)
    new(from, into).call
  end

  def initialize(from, into)
    @from = from
    @into = into
  end

  def call
    raise ArgumentError, "cannot merge a user into itself" if @from.id == @into.id

    User.transaction do
      # BEFORE the membership dedup, and that order is load-bearing:
      # Membership#after_destroy drops the leaver's team memberships in that
      # group, so deduping memberships first would delete `from`'s team rows
      # while they were still waiting to be handed over — the merge would
      # succeed and the teams would silently vanish.
      dedupe_and_repoint(:team_memberships, :team_id)

      dedupe_and_repoint_memberships
      dedupe_and_repoint(:participants, :event_id)
      dedupe_and_repoint(:track_roles, :track_id)
      dedupe_and_repoint(:form_submissions, :form_id)

      REPOINT_OWNER_ID.each { |table| repoint(table, "owner_id") }
      repoint("stripe_settings", "user_id")
      repoint("badge_classes", "creator_id")
      repoint("badges", "owner_id")
      repoint("badges", "creator_id")
      repoint("comments", "user_id")
      # Discussion. Without these, `from.destroy!` hits topics/replies' foreign
      # keys and the whole merge raises — and User's dependent: :destroy would
      # otherwise delete a person's posts rather than hand them to the account
      # they merged into. The audit columns follow for the same reason: the
      # person who hid or deleted something still exists, as `into`.
      repoint("topics", "user_id")
      repoint("topics", "last_reply_user_id")
      repoint("topics", "flagged_by_id")
      repoint("topics", "deleted_by_id")
      repoint("replies", "user_id")
      repoint("replies", "flagged_by_id")
      repoint("replies", "deleted_by_id")
      repoint("activities", "initiator_id")
      repoint("activities", "receiver_id")
      repoint("vouchers", "sender_id")
      repoint("vouchers", "receiver_id")
      repoint("refunds", "requested_by_user_id")
      repoint("ticket_items", "user_id")
      repoint("wechat_pay_settings", "user_id")
      repoint("group_invites", "receiver_id")
      repoint("group_invites", "sender_id")
      repoint("forms", "created_by_id")
      # A developer's OAuth clients follow the developer. Their *consents* and
      # tokens do not — those are destroyed with `from` (see User), because a
      # merge must not hand a third party access to the surviving account.
      repoint("oauth_applications", "owner_id")
      Ticketing::Activity.where(actor_user_id: @from.id).update_all(actor_user_id: @into.id)

      Domain.where(item_type: "User", item_id: @from.id).update_all(item_id: @into.id)
      dedupe_and_repoint_event_roles

      @from.destroy!
    end

    @into
  end

  private

  # memberships also carries a role — when both users are already in the same
  # group, keep the higher-ranked role rather than an arbitrary survivor.
  ROLE_RANK = { "member" => 0, "manager" => 1, "owner" => 2 }.freeze

  def dedupe_and_repoint_memberships
    @from.memberships.find_each do |m|
      existing = Membership.find_by(user_id: @into.id, group_id: m.group_id)
      if existing
        if ROLE_RANK.fetch(m.role, -1) > ROLE_RANK.fetch(existing.role, -1)
          existing.update!(role: m.role)
        end
        m.destroy!
      else
        m.update!(user_id: @into.id)
      end
    end
  end

  # event_roles.item is polymorphic (User | Group); unique on
  # [event_id, item_id, item_type], so the same dedupe shape applies but
  # keyed on item_id/item_type rather than a plain user_id column.
  def dedupe_and_repoint_event_roles
    EventRole.where(item_type: "User", item_id: @from.id).find_each do |r|
      if EventRole.exists?(item_type: "User", item_id: @into.id, event_id: r.event_id)
        r.destroy!
      else
        r.update!(item_id: @into.id)
      end
    end
  end

  def dedupe_and_repoint(table, scope_column)
    klass = table.to_s.classify.constantize
    klass.where(user_id: @from.id).find_each do |row|
      if klass.exists?(user_id: @into.id, scope_column => row[scope_column])
        row.destroy!
      else
        row.update!(user_id: @into.id)
      end
    end
  end

  # IDs are TSID strings, not integers — use the AR query interface (bound
  # params) rather than hand-built SQL, both for safety and because a raw
  # integer cast would silently zero out the WHERE clause.
  def repoint(table, column)
    klass = table.to_s.classify.constantize
    klass.where(column => @from.id).update_all(column => @into.id)
  end
end
