class EventRole < ApplicationRecord
  # The four values production actually holds (13k rows migrated from sails):
  # group_host  — the Group presented as host
  # custom_host — a hand-typed host (often no account)
  # co_host / speaker — people, either linked accounts or email invites
  ROLES = %w(group_host custom_host co_host speaker).freeze

  belongs_to :event
  # item is optional: email-invited co-hosts and hand-typed speakers have no
  # account — they carry only email/display_name/image_url (1.6k prod rows).
  belongs_to :item, polymorphic: true, optional: true

  validates :item_type, presence: true, inclusion: { in: %w(User Group) }
  validates :role, presence: true, inclusion: { in: ROLES }
  # optional: true also stops Rails checking that a *present* item_id resolves,
  # so re-assert it: a role that names an item must name a real one.
  validates :item, presence: true, if: -> { item_id.present? }
  # allow_nil: several account-less roles per event are legitimate, and the
  # backing unique index treats NULLs as distinct anyway.
  validates :item_id, uniqueness: { scope: [:event_id, :item_type], allow_nil: true,
                                    message: "can only have one role per item per event" }
end
