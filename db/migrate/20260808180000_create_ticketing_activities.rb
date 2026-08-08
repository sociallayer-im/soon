class CreateTicketingActivities < ActiveRecord::Migration[8.1]
  def change
    # Append-only record of what happened in the ticketing domain.
    #
    # It exists because an order keeps only a CURRENT status, so anything that
    # needs the past has to reconstruct it from timestamps — and that
    # reconstruction is both incomplete and quietly wrong:
    #
    #   - `updated_at` is the last write of ANY kind, not the moment of a
    #     transition. apply_refund_success! transitions and then writes
    #     released_at, so the refund's own timestamp is already lost.
    #   - A dispute lost at the provider goes through transition!(:refunded)
    #     with no Refund row, so afterwards it is indistinguishable from an
    #     organizer refunding voluntarily. Those two facts mean opposite
    #     things to the organizer.
    #   - Retries leave no trace at all: a buyer who abandons the payment
    #     sheet and pays again never changes status.
    #
    # Deliberately has no updated_at. A row is an observation; observations
    # are not edited. Anything that "changes" is a new row.
    create_table :ticketing_activities, id: :string do |t|
      # Polymorphic and NOT NULL, both halves load-bearing. Polymorphic so a
      # coupon redemption or a ticket-type change can live here too; NOT NULL
      # because the guarantee this table is for — "this subject's history is
      # exactly these rows" — is what makes it usable as evidence in a
      # chargeback. A generic log with an optional owner degrades into a
      # dumping ground and stops being trustworthy.
      t.string :subject_type, null: false
      t.string :subject_id, null: false

      t.string :action, null: false, comment: "see Ticketing::Activity::ACTIONS"
      # Present on state changes, null on everything else (a retry, a rejected
      # callback) — which is precisely why `action` and not `to_status` is the
      # required column.
      t.string :from_status
      t.string :to_status

      t.string :source, null: false, comment: "api | webhook | sweeper | reconciliation | system | backfill"
      t.string :actor_user_id, comment: "only when a person caused it"
      t.string :reason

      # Whatever makes the row explainable later: provider refs, amounts, the
      # callback's own id, the mismatch that got it rejected.
      t.jsonb :metadata, null: false, default: {}

      t.datetime :created_at, null: false

      t.index [ :subject_type, :subject_id, :created_at ]
      t.index [ :action, :created_at ]
      t.index :actor_user_id
    end
  end
end
