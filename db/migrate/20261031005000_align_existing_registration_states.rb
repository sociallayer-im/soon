class AlignExistingRegistrationStates < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE participants p
      SET status = 'awaiting_payment', payment_due_at = (
        SELECT MIN(t.reserved_until) FROM ticket_items t WHERE t.participant_id = p.id AND t.status = 'pending'
      ) WHERE p.status = 'attending' AND p.payment_status = 'pending'
    SQL
    execute <<~SQL
      UPDATE events e SET participant_count = (
        SELECT COUNT(*) FROM participants p WHERE p.event_id = e.id AND p.status = 'attending'
          AND (p.payment_status IS NULL OR p.payment_status = 'succeeded')
      ) WHERE EXISTS (SELECT 1 FROM participants p WHERE p.event_id = e.id AND p.status = 'awaiting_payment')
    SQL
    execute <<~SQL
      WITH released AS (
        UPDATE ticket_items i SET inventory_reserved = false, reserved_until = NULL
        FROM participants p WHERE i.participant_id = p.id AND p.status = 'pending'
          AND i.status = 'pending' AND i.inventory_reserved = true AND i.released_at IS NULL
        RETURNING i.ticket_id
      )
      UPDATE tickets t SET quantity = t.quantity + r.n
      FROM (SELECT ticket_id, COUNT(*)::integer n FROM released GROUP BY ticket_id) r
      WHERE t.id = r.ticket_id AND t.quantity IS NOT NULL
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Confirmed attendance cannot be converted back into unpaid attendance safely'
  end
end
