class PaymentsAndParticipantState < ActiveRecord::Migration[8.1]
  # Everything the payments work needs on top of the three new tables
  # (stripe_settings / stripe_events / refunds), plus the participant
  # lifecycle fields it exposed. Merged into one migration because none of it
  # has been deployed yet — see design/PAYMENTS_PLAN.md.
  #
  # Contains ONE destructive step: it deletes the ~227 legacy `unbounded`
  # ticket_items (see below). Their ids are logged before the delete.
  def up
    # ---- orders ----------------------------------------------------------
    change_table :ticket_items, bulk: true do |t|
      t.string :payment_provider, comment: "stripe | evm | free"
      t.string :provider_ref, comment: "Checkout Session / PaymentIntent id for stripe; txhash stays the crypto column"
      t.string :currency
      t.datetime :reserved_until, comment: "sweeper expires unpaid orders past this"
      t.datetime :released_at, comment: "inventory released exactly once, guarded here — never inferred from status"
      t.datetime :paid_at
      # Snapshot of the key that took (or will take) the money. Refunds and
      # verification resolve the account from here, never from "current event
      # owner" — key rotation or an ownership change must not misroute money.
      t.string :stripe_setting_id
    end
    add_index :ticket_items, [ :status, :reserved_until ], name: "index_ticket_items_sweeper"
    add_index :ticket_items, :provider_ref, unique: true, where: "provider_ref IS NOT NULL"
    add_index :ticket_items, :stripe_setting_id, where: "stripe_setting_id IS NOT NULL"

    # sails' "unbounded" = a group ticket granted to an email with no account
    # yet, claimed on email verification by Profile#bind_ticket_items. soon
    # replaced that flow with GroupInvite + auto-accept and has no claim path
    # for these rows, so they can never activate. Decided 2026-07-30: delete
    # them rather than convert.
    ids = select_values("SELECT id FROM ticket_items WHERE status = 'unbounded'")
    say "deleting #{ids.size} legacy unbounded ticket_items"
    say ids.join(", "), true if ids.any?
    execute "DELETE FROM ticket_items WHERE status = 'unbounded'"
    change_column_comment :ticket_items, :status,
      from: "pending | unbounded | succeeded | cancelled | timeout",
      to: "pending | succeeded | cancelled | timeout | refunded | partially_refunded | disputed — see TicketItem"

    # Backfill the new columns for existing orders. chain='stripe' rows kept
    # the PaymentIntent id in txhash; crypto rows keep txhash as their own
    # reference.
    execute <<~SQL
      UPDATE ticket_items SET
        payment_provider = CASE
          WHEN chain = 'stripe' THEN 'stripe'
          WHEN chain IS NOT NULL THEN 'evm'
          ELSE 'free'
        END,
        currency = CASE WHEN chain = 'stripe' THEN 'usd' END,
        provider_ref = CASE WHEN chain = 'stripe' THEN txhash END,
        paid_at = CASE WHEN status = 'succeeded' THEN updated_at END
    SQL

    # ---- payment methods -------------------------------------------------
    change_table :payment_methods, bulk: true do |t|
      t.string :stripe_setting_id, comment: "which of the event owner's keys this method charges to"
      t.string :currency
    end
    add_index :payment_methods, :stripe_setting_id

    # ---- participants ----------------------------------------------------
    # register_time carried two incompatible meanings: RSVP stamped it as the
    # registration time and the door-scan check_in re-stamped it as the
    # check-in time, so anything reading it as "checked in" saw every
    # registrant as checked in. Split, and renamed to match.
    #
    # checked_in_at is NOT backfilled: for existing rows the two meanings are
    # indistinguishable, and treating every registrant as checked-in is the
    # bug being fixed.
    rename_column :participants, :register_time, :registered_at
    change_table :participants, bulk: true do |t|
      t.datetime :checked_in_at
      # Soft delete (withdrawal) gets a timestamp like the other lifecycle
      # marks rather than only a status string.
      t.datetime :cancelled_at
      # Write-only column: rsvp stamped it and nothing ever read it. It also
      # cannot be right — a participant may hold orders for several ticket
      # types, which ticket_items already records per order.
      t.remove :ticket_id
    end
    execute "UPDATE participants SET cancelled_at = updated_at WHERE status = 'cancelled'"

    change_column_comment :participants, :status,
      from: "attending | declined | maybe",
      to: "attending | pending | declined | maybe | cancelled — see Participant"
    change_column_comment :participants, :payment_status, from: nil,
      to: "derived summary of this participant's ticket_items; see Participant#refresh_payment_status!"
    # Every seat-counting query filters on this.
    add_index :participants, [ :event_id, :status ]
  end

  # Restores the SCHEMA only. Deleted rows (the legacy `unbounded` orders) and
  # dropped data (participants.ticket_id) are not recovered — nothing wants
  # them back; this exists so the structure can be rolled back cleanly.
  def down
    remove_index :participants, [ :event_id, :status ]
    change_column_comment :participants, :payment_status,
      from: "derived summary of this participant's ticket_items; see Participant#refresh_payment_status!", to: nil
    change_column_comment :participants, :status,
      from: "attending | pending | declined | maybe | cancelled — see Participant",
      to: "attending | declined | maybe"
    change_table :participants, bulk: true do |t|
      t.string :ticket_id
      t.remove :cancelled_at
      t.remove :checked_in_at
    end
    # Dropping the column in #up took its foreign key with it.
    add_foreign_key :participants, :tickets
    rename_column :participants, :registered_at, :register_time

    remove_index :payment_methods, :stripe_setting_id
    change_table :payment_methods, bulk: true do |t|
      t.remove :stripe_setting_id
      t.remove :currency
    end

    change_column_comment :ticket_items, :status,
      from: "pending | succeeded | cancelled | timeout | refunded | partially_refunded | disputed — see TicketItem",
      to: "pending | unbounded | succeeded | cancelled | timeout"
    remove_index :ticket_items, name: "index_ticket_items_sweeper"
    remove_index :ticket_items, :provider_ref
    remove_index :ticket_items, :stripe_setting_id
    change_table :ticket_items, bulk: true do |t|
      t.remove :payment_provider, :provider_ref, :currency, :reserved_until,
               :released_at, :paid_at, :stripe_setting_id
    end
  end
end
