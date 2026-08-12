class HardenFederationRoundTwo < ActiveRecord::Migration[8.1]
  def change
    # P1-1: a Delete announcing an actor's removal must be signed with that
    # actor's key even though the row is gone by delivery time — snapshot the
    # signing identity onto the delivery instead of resolving it at send time.
    add_column :fed_deliveries, :signing_key_id, :string
    add_column :fed_deliveries, :signing_key_pem, :text

    # P1-4: bind the idempotency claim to what was actually received, not
    # just the (remote-chosen) activity id.
    add_column :fed_inbound_activities, :body_digest, :string

    # P1-11: monotonic barrier for remote mirrors — out-of-order Create/
    # Update retries must not resurrect older state or a deleted event.
    add_column :fed_events, :remote_updated_at, :datetime
  end
end
