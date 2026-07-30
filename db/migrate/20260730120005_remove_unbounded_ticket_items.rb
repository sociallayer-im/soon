class RemoveUnboundedTicketItems < ActiveRecord::Migration[8.1]
  # sails' "unbounded" = a group ticket granted to an email with no account
  # yet, claimed on email verification by Profile#bind_ticket_items. soon
  # replaced that flow with GroupInvite + auto-accept and has no claim path
  # for these rows — they can never activate. Decision (PAYMENTS_PLAN §3.6,
  # 2026-07-30): delete the legacy rows outright, no GroupInvite conversion.
  #
  # Destructive prod-data step: ~227 rows expected in production. The ids are
  # logged to the migration output before deletion for the record.
  def up
    ids = select_values("SELECT id FROM ticket_items WHERE status = 'unbounded'")
    say "deleting #{ids.size} legacy unbounded ticket_items"
    say ids.join(", "), true if ids.any?
    execute "DELETE FROM ticket_items WHERE status = 'unbounded'"
  end

  def down
    # Irreversible: the deleted grants are deliberately not carried forward.
    raise ActiveRecord::IrreversibleMigration
  end
end
