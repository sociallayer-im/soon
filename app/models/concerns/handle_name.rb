# The one rule for `name` on both User and Group, and the registry that keeps
# the two namespaces from colliding.
#
# The shape used to be three different things — users `[a-z0-9_]{6,30}`, groups
# `[a-z0-9_-]{3,30}`, and a frontend validator that enforced 6-20 hyphens-only
# for groups while the register screen enforced the user rule. A person picking
# a handle had no way to know which they were up against.
#
# One shape now, here and in the frontend: 6-20 lowercase letters, digits and
# single interior hyphens. Hyphen rather than underscore because it is what a URL slug
# conventionally uses and what most live handles already do ("edge-city");
# existing underscores are converted by `rake handles:underscores_to_hyphens`.
#
# NOTE the `will_save_change_to_name?` guard, which is not a detail. Live data
# predates every version of this rule — 97 users hold names shorter than 6, 11
# hold names longer than 20 (mostly 0x… wallet addresses auto-assigned by an
# older backend), 6 groups are out of range and one user is called "success".
# Validating them unconditionally would mean none of those rows could ever be
# saved again, for a change to any other column. The rule applies to a name
# being CHOSEN, not to one already held.
module HandleName
  extend ActiveSupport::Concern

  # 6-20 lowercase letters, digits and hyphens, where a hyphen has to sit
  # BETWEEN two of the others: no leading, trailing or repeated hyphen. The
  # length is a lookahead so the rest can stay a plain "groups of characters
  # joined by single hyphens" — expressing both in one alternation is how you
  # get a regex nobody can check.
  FORMAT = /\A(?=.{6,20}\z)[a-z0-9]+(?:-[a-z0-9]+)*\z/
  FORMAT_MESSAGE = "must be 6-20 lowercase letters, digits and hyphens, and a hyphen " \
                   "cannot start or end it or repeat".freeze

  # Handles that would shadow a frontend route rather than resolve to their
  # own page. `/group/create` is the group creation screen and `/event/detail`
  # the event page, so a group actually named "create" or "detail" would be
  # unreachable — its URL is already taken by a static route that wins.
  #
  # Derived from the real static siblings of the dynamic segments in
  # seastar-app: (normal)/group/{create}, (normal)/event/{checkin,
  # checkin-for-participants,detail,edit,share,success}. "edit" and "share" are
  # below the length floor and unreachable anyway; they are listed so that
  # lowering the floor later does not silently reopen them.
  #
  # Applied to users as well as groups. No /profile/<reserved> route exists
  # today, so it costs a user nothing and means one list rather than two — and
  # the one live account called "success" keeps its name under the guard above.
  RESERVED = %w[create checkin detail edit share success].freeze

  included do
    validates :name,
      format: { with: FORMAT, message: FORMAT_MESSAGE },
      allow_blank: true,
      if: :will_save_change_to_name?
    validate :name_not_reserved, if: :will_save_change_to_name?
    validate :name_not_taken_across_handles, if: :will_save_change_to_name?

    after_save :sync_handle_domain!, if: :saved_change_to_name?
  end

  private def name_not_reserved
    return if name.blank?
    errors.add(:name, "is reserved") if RESERVED.include?(name)
  end

  # `users.name` and `groups.name` are each uniquely indexed, but separately —
  # nothing stopped a user and a group from claiming the same handle, and one
  # pair already has ("infinitacity" is a user from 2025-01-07 and a group from
  # two days later). `domains` is the shared registry that makes the two
  # namespaces one: a single uniquely-indexed row per handle, whoever holds it.
  #
  # sails maintained it; soon stopped on the 2026-07-29 cutover and nothing
  # noticed, because nothing reads the table — which is exactly why the
  # constraint quietly stopped existing. It is written again here.
  private def name_not_taken_across_handles
    return if name.blank?
    return unless Domain.where(name: name)
                        .where.not(item_type: self.class.name, item_id: id)
                        .exists?

    errors.add(:name, "is already taken")
  end

  # Kept in step with the name inside the same transaction as the save, so a
  # registry row can never outlive the name it records.
  #
  # An item can arrive here holding more than one row: UserMerger repoints the
  # absorbed account's row at the survivor (user_merger.rb), so a merge of two
  # named accounts leaves two. Whichever is kept, the others are deleted —
  # picking `.first` and leaving the rest would mean a stale row still holding
  # a handle nobody is called, blocking it for everyone, and which row that was
  # would depend on insertion order.
  private def sync_handle_domain!
    return if name.blank?

    mine = Domain.where(item_type: self.class.name, item_id: id).order(:created_at).to_a
    domain = mine.shift || Domain.new(item_type: self.class.name, item_id: id)
    Domain.where(id: mine.map(&:id)).delete_all if mine.any?

    domain.name = name
    domain.fullname = handle_fullname
    domain.save!
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Two people claiming one handle in the same instant: the validation above
    # missed it and Domain's own uniqueness check or the unique index caught
    # it. Those are the only ways this save can fail — every other Domain
    # validation is satisfied by construction. Re-raised as a validation
    # failure so the caller gets the 422 it would have got a moment earlier
    # rather than a 500 — and so the name change rolls back with it.
    errors.add(:name, "is already taken")
    raise ActiveRecord::RecordInvalid, self
  end

  # Every existing row holds "<name>.sola.day". APP_HOST is the deployment's
  # own host ("sola.day" here, "www.juluo.xyz" on CN), and the "www." is
  # dropped because "alice.www.juluo.xyz" is not a subdomain anyone means.
  private def handle_fullname
    "#{name}.#{ENV.fetch('APP_HOST', 'sola.day').sub(/\Awww\./, '')}"
  end
end
