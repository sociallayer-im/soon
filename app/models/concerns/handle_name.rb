# The one rule for `name` on both User and Group.
#
# They were two rules for a long time — users `[a-z0-9_]{6,30}`, groups
# `[a-z0-9_-]{3,30}` — and the frontend enforced a third thing again for
# groups (6-20, hyphens only, no underscores). A person picking a handle had
# no way to know which of the three they were up against.
#
# One shape now, on both models and in the frontend: 6-20 lowercase letters,
# digits and hyphens. Hyphen rather than underscore because it is what a URL
# slug conventionally uses and what most of the live group handles already do
# ("edge-city"); existing underscores are converted by
# `rake handles:underscores_to_hyphens`, not by this file.
#
# NOTE the `will_save_change_to_name?` guard, which is not a detail. Live data
# predates every version of this rule — 97 users hold names shorter than 6, 11
# hold names longer than 20 (mostly 0x… wallet addresses auto-assigned by an
# older backend), and 5 groups are shorter than 6. Validating them
# unconditionally would mean none of those rows could ever be saved again, for
# any change to any other column. The rule applies to a name being CHOSEN, not
# to one already held.
module HandleName
  extend ActiveSupport::Concern

  FORMAT = /\A[a-z0-9-]{6,20}\z/
  FORMAT_MESSAGE = "must be 6-20 lowercase letters, digits, or hyphens".freeze

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
  RESERVED = %w[create checkin detail edit share success].freeze

  included do
    validates :name,
      format: { with: FORMAT, message: FORMAT_MESSAGE },
      allow_blank: true,
      if: :will_save_change_to_name?
    validate :name_not_reserved, if: :will_save_change_to_name?
  end

  private def name_not_reserved
    return if name.blank?
    errors.add(:name, "is reserved") if RESERVED.include?(name)
  end
end
